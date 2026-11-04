`timescale 1ns/1ps
module rv32_observed_soc #(
    parameter integer ENABLE_M=1, ENABLE_C=1, ENABLE_PREDICTOR=1, LOAD_USE_BUBBLE=1,
    parameter integer FAST_ICACHE_HIT=1, FAST_DCACHE_READ=1, FAST_DCACHE_WRITE=1,
    parameter integer FETCH_OVERLAP=1, DATA_OVERLAP=1, EARLY_D_REQUEST=1,
    parameter integer BTB_INDEX_BITS=8, ICACHE_SET_BITS=9, CACHE_SET_BITS=6,
    parameter integer ENABLE_CACHE=1, MEMORY_ADDRESS_BITS=14,
    parameter integer CLOCK_HZ=3200, BAUD=100,
    parameter INIT_FILE="firmware.hex"
) (
    input wire clk, rst_n, serial_rx,
    input wire [7:0] gpio_input,
    output wire serial_tx,
    output wire [7:0] gpio_output,
    output wire [31:0] status_code, trace_pc, trace_instruction, trap_cause,
    output wire maintenance_fault, trace_valid, trap_valid,
    output wire [63:0] cycle_count, retired_count,
    output wire [31:0] snapshot_sequence,
    output wire [63:0] snapshot_cycles, snapshot_retired,
    output wire retire_event, wb_write,
    output wire [4:0] wb_rd,
    output wire [31:0] wb_data,
    output wire redirect_event, redirect_eligible, fetch_request_stall, fetch_response_wait, frontend_barrier,
    output wire [2:0] redirect_kind
);
    rv32_soc #(
        .ENABLE_M(ENABLE_M),.ENABLE_C(ENABLE_C),.ENABLE_PREDICTOR(ENABLE_PREDICTOR),.LOAD_USE_BUBBLE(LOAD_USE_BUBBLE),
        .FAST_ICACHE_HIT(FAST_ICACHE_HIT),.FAST_DCACHE_READ(FAST_DCACHE_READ),.FAST_DCACHE_WRITE(FAST_DCACHE_WRITE),
        .FETCH_OVERLAP(FETCH_OVERLAP),.DATA_OVERLAP(DATA_OVERLAP),.EARLY_D_REQUEST(EARLY_D_REQUEST),
        .BTB_INDEX_BITS(BTB_INDEX_BITS),.ICACHE_SET_BITS(ICACHE_SET_BITS),.CACHE_SET_BITS(CACHE_SET_BITS),
        .ENABLE_CACHE(ENABLE_CACHE),.MEMORY_ADDRESS_BITS(MEMORY_ADDRESS_BITS),
        .CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD),.INIT_FILE(INIT_FILE)
    ) soc(
        .clk(clk),.rst_n(rst_n),.serial_rx(serial_rx),.gpio_input(gpio_input),.serial_tx(serial_tx),.gpio_output(gpio_output),
        .status_code(status_code),.maintenance_fault(maintenance_fault),.trace_valid(trace_valid),
        .trace_pc(trace_pc),.trace_instruction(trace_instruction),.trap_valid(trap_valid),.trap_cause(trap_cause),
        .cycle_count(cycle_count),.retired_count(retired_count)
    );
    assign snapshot_sequence=soc.peripherals.snapshot_sequence;
    always @(posedge clk) if(rst_n && soc.core.frontend_flush)
        if(soc.core.redirect_fetch_valid!==((soc.core.redirect_pc >> (MEMORY_ADDRESS_BITS+2))==0))
            $fatal(1,"Redirect range factoring mismatch");
    always @(posedge clk) if(rst_n && soc.core.ex_fire && !soc.core.ex_decode.is_mret)
        if(soc.core.execute_prediction_miss!==(soc.core.actual_next!=soc.core.ex_prediction))
            $fatal(1,"Prediction mismatch factoring changed the next-PC comparison");
    reg expected_mem_prediction_miss;
    reg [99:0] expected_if_payload;
    reg [31:0] expected_ex_operand_a,expected_ex_operand_b;
    reg [31:0] expected_fetch_request;
    wire reference_ex_capacity=soc.core.ex_valid && soc.core.mem_ready && !soc.core.load_use_wait &&
        !((soc.core.ex_decode.is_csr || soc.core.ex_decode.is_mret) && (soc.core.mem_valid || soc.core.wb_valid)) &&
        (!soc.core.ex_muldiv || soc.core.execute_local_exception || soc.core.muldiv_valid);
    always @(posedge clk) if(rst_n) begin
        if(soc.core.ex_fire!==(soc.core.interrupt_pending ? soc.core.ex_fire_with_irq : reference_ex_capacity && !soc.core.mem_flush))
            $fatal(1,"Multiply availability factoring changed execution transfer");
        if(soc.core.ex_fire && soc.core.ex_muldiv && !soc.core.execute_common_exception && !soc.core.muldiv_valid)
            $fatal(1,"Multiply result consumed without a valid response");
    end
    generate for(genvar predicate_pair=0;predicate_pair<6;predicate_pair=predicate_pair+1) begin: predicate_equivalence
        always @(posedge clk) if(rst_n && soc.core.ex_valid)
            if(soc.core.early_pair_condition[predicate_pair]!==
                (|(soc.core.early_pair_result[predicate_pair] & soc.core.early_condition_select)))
                $fatal(1,"Branch predicate factoring changed the selected relation");
    end endgenerate
    always @(posedge clk) begin
        if(rst_n) begin
            if(soc.core.wb_valid && soc.core.wb_write_candidate!==(soc.core.wb_writes && soc.core.wb_rd!=0))
                $fatal(1,"Registered writeback eligibility mismatch");
            if(soc.core.mem_valid && soc.core.mem_forward_candidate!==
                (soc.core.mem_writes && soc.core.mem_rd!=0 && !soc.core.mem_exception))
                $fatal(1,"Registered memory forwarding eligibility mismatch");
            if(soc.core.frontend.request_pending && soc.core.frontend.request_address!==expected_fetch_request)
                $fatal(1,"Fetch request payload enable changed an outstanding address");
            if(soc.i_req_valid && soc.i_req_ready) expected_fetch_request<=soc.i_req_address;
            if(soc.core.predictor.prediction_hit &&
               soc.core.predictor.direction_storage[soc.core.predictor.fetch_index]!==
               (!soc.core.predictor.conditional[soc.core.predictor.fetch_index] ||
                soc.core.predictor.pattern_prediction[soc.core.predictor.history[soc.core.predictor.fetch_index]]))
                $fatal(1,"Precomputed branch direction differs from the local-history predictor");
            if(soc.core.ex_valid && (soc.core.ex_operand_a!==expected_ex_operand_a ||
                                    soc.core.ex_operand_b!==expected_ex_operand_b))
                $fatal(1,"Execution operand enable factoring changed a valid operand");
            if(soc.core.ex_valid) begin
                expected_ex_operand_a<=soc.core.forwarded_a;
                expected_ex_operand_b<=soc.core.forwarded_b;
            end
            if(soc.core.id_fire) begin
                expected_ex_operand_a<=soc.core.id_operand_a;
                expected_ex_operand_b<=soc.core.id_operand_b;
            end
            if(soc.core.if_valid && {soc.core.if_pc,soc.core.if_instruction,soc.core.if_prediction,
                soc.core.if_length,soc.core.if_error}!==expected_if_payload)
                $fatal(1,"Fetch payload enable factoring changed a valid instruction");
            if(soc.core.frontend_fire)
                expected_if_payload<={soc.core.frontend_pc,soc.core.frontend_instruction,soc.core.frontend_prediction,
                    soc.core.frontend_length,soc.core.frontend_out_error};
            if(soc.i_rsp_valid && soc.i_rsp_is_c!=={soc.i_rsp_data[17:16]!=2'b11,soc.i_rsp_data[1:0]!=2'b11})
                $fatal(1,"Cache instruction-length metadata mismatch");
            if(soc.i_rsp_valid && soc.i_rsp_pair_valid && soc.i_rsp_pair_is_c!==
                {soc.i_rsp_pair_data[17:16]!=2'b11,soc.i_rsp_pair_data[1:0]!=2'b11})
                $fatal(1,"Cache companion-length metadata mismatch");
            if(soc.core.frontend.out_valid && !soc.core.frontend.out_error && soc.core.ENABLE_C!=0 &&
               soc.core.frontend.compressed!==(soc.core.frontend.halfword[1:0]!=2'b11))
                $fatal(1,"Buffered instruction-length metadata mismatch");
            if(soc.core.frontend_fire!==(soc.core.frontend_out_valid &&
               (!soc.core.if_valid || !soc.core.id_valid || !soc.core.ex_valid || soc.core.ex_fire) &&
               !soc.core.frontend_flush && !soc.core.frontend_barrier))
                $fatal(1,"Fetch acceptance factoring changed a handshake");
            if(soc.peripherals.rx_fifo_valid!==(soc.peripherals.rx_count!=0) ||
               soc.peripherals.uart_tx_valid!==(soc.peripherals.tx_count!=0))
                $fatal(1,"Registered FIFO occupancy differs from its count");
            if(soc.core.ex_valid && (soc.core.early_zero_a!==(soc.core.ex_rs1==0 || !soc.core.ex_decode.uses_rs1) ||
                                    soc.core.early_zero_b!==(soc.core.ex_rs2==0 || !soc.core.ex_decode.uses_rs2)))
                $fatal(1,"Registered source-operand mask mismatch");
            if(soc.core.wb_valid && (soc.core.wb_match_a!==(soc.core.ex_rs1==soc.core.wb_rd) ||
                                    soc.core.wb_match_b!==(soc.core.ex_rs2==soc.core.wb_rd)))
                $fatal(1,"Registered writeback dependency mismatch");
        end
        if(rst_n && soc.core.ex_fire)
            expected_mem_prediction_miss<=soc.core.actual_next!=soc.core.ex_prediction;
        if(rst_n && soc.core.mem_valid && !soc.core.mem_mret)
            if(soc.core.mem_prediction_miss!==expected_mem_prediction_miss)
                $fatal(1,"Registered prediction mismatch changed the next-PC comparison");
    end
    generate for(genvar comparison_byte=0;comparison_byte<4;comparison_byte=comparison_byte+1) begin: wb_comparison_checks
        always @(posedge clk) if(rst_n && soc.core.wb_valid) begin
            if(soc.core.wb_a_byte_equal[comparison_byte]!==
                (soc.core.ex_operand_a[comparison_byte*8+:8]==soc.core.wb_data[comparison_byte*8+:8]) ||
               soc.core.wb_a_byte_less[comparison_byte]!==
                (soc.core.ex_operand_a[comparison_byte*8+:8]<soc.core.wb_data[comparison_byte*8+:8]) ||
               soc.core.wb_b_byte_equal[comparison_byte]!==
                (soc.core.wb_data[comparison_byte*8+:8]==soc.core.ex_operand_b[comparison_byte*8+:8]) ||
               soc.core.wb_b_byte_less[comparison_byte]!==
                (soc.core.wb_data[comparison_byte*8+:8]<soc.core.ex_operand_b[comparison_byte*8+:8]))
                $fatal(1,"Writeback comparison precomputation mismatch");
        end
    end endgenerate
    assign snapshot_cycles=soc.peripherals.performance_snapshot[63:0];
    assign snapshot_retired=soc.peripherals.performance_snapshot[127:64];
    assign retire_event=soc.core.wb_valid && !soc.core.wb_counter_write;
    assign wb_write=soc.core.trace_write;
    assign wb_rd=soc.core.trace_rd;
    assign wb_data=soc.core.trace_data;
    wire [6:0] redirect_opcode=soc.core.mem_flush ? soc.core.mem_instruction[6:0] : soc.core.ex_instruction[6:0];
    assign redirect_event=soc.core.frontend_flush;
    assign frontend_barrier=soc.core.frontend_barrier;
    assign redirect_eligible=redirect_event && !frontend_barrier;
    assign redirect_kind=(soc.core.mem_flush && soc.core.mem_fault) ? 3'd3 :
        (soc.core.mem_flush && soc.core.mem_mret) ? 3'd4 :
        (soc.core.mem_flush && soc.core.mem_fence_i) ? 3'd5 :
        redirect_opcode==7'h63 ? 3'd0 : redirect_opcode==7'h6f ? 3'd1 : redirect_opcode==7'h67 ? 3'd2 : 3'd6;
    assign fetch_request_stall=soc.i_req_valid && !soc.i_req_ready;
    assign fetch_response_wait=soc.core.frontend.request_pending && !soc.core.frontend.i_rsp_valid;
endmodule
