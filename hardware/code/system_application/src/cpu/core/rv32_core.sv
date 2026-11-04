`timescale 1ns/1ps
module rv32_core #(
    parameter [31:0] RESET_VECTOR=32'h00000000,
    parameter integer ENABLE_PREDICTOR=1,
    parameter integer ENABLE_M=0,
    parameter integer FETCH_OVERLAP=0,
    parameter integer EARLY_D_REQUEST=0,
    parameter integer BTB_INDEX_BITS=4,
    parameter integer BTB_ADDRESS_BITS=32,
    parameter integer LOAD_USE_BUBBLE=0
) (
    input wire clk,
    input wire rst_n,
    output wire i_req_valid,
    input wire i_req_ready,
    output wire [31:0] i_req_address,
    input wire i_rsp_valid,
    output wire i_rsp_ready,
    input wire [31:0] i_rsp_data,
    input wire i_rsp_error,
    output wire d_req_valid,
    input wire d_req_ready,
    output wire [31:0] d_req_address,
    output wire [31:0] d_req_data,
    output wire [3:0] d_req_strobe,
    output wire d_req_write,
    input wire d_rsp_valid,
    output wire d_rsp_ready,
    input wire [31:0] d_rsp_data,
    input wire d_rsp_error,
    output wire maintenance_valid,
    input wire maintenance_ready,
    input wire [63:0] timer_value,
    input wire irq_external,
    input wire irq_software,
    input wire irq_timer,
    output wire trace_valid,
    output wire [31:0] trace_pc,
    output wire [31:0] trace_instruction,
    output wire trace_write,
    output wire [4:0] trace_rd,
    output wire [31:0] trace_data,
    output wire trap_valid,
    output wire [31:0] trap_pc,
    output wire [31:0] trap_cause,
    output wire [31:0] trap_value,
    output wire [4:0] pipeline_valid,
    output wire [63:0] cycle_count,
    output wire [63:0] retired_count
);
    typedef struct packed {
        logic uses_rs1,uses_rs2,writes_rd;
        logic [31:0] immediate;
        logic [3:0] alu_op;
        logic alu_immediate;
        logic is_lui,is_auipc,is_branch,is_jal,is_jalr,is_load,is_store;
        logic is_fence,is_fence_i,is_csr,is_ecall,is_ebreak,is_mret,is_wfi,illegal;
    } decode_t;
    decode_t id_decode,ex_decode;
    reg [31:0] registers[0:31];
    integer reset_index;
    reg [31:0] next_pc,fetch_address,fetch_prediction;
    reg fetch_active,fetch_sent,fetch_discard;
    reg if_valid,if_error;
    reg [31:0] if_pc,if_instruction,if_prediction;
    reg id_valid,id_error;
    reg [31:0] id_pc,id_instruction,id_prediction;
    wire [4:0] id_rs1,id_rs2,id_rd;
    reg ex_valid,ex_error;
    reg [31:0] ex_pc,ex_instruction,ex_prediction,ex_operand_a,ex_operand_b;
    reg [4:0] ex_rd;
    wire [4:0] ex_rs1=ex_instruction[19:15],ex_rs2=ex_instruction[24:20];
    reg mem_valid,mem_sent,mem_load,mem_store,mem_writes,mem_exception;
    reg mem_csr,mem_csr_write,mem_mret,mem_fence_i,mem_branch,mem_conditional,mem_taken;
    reg [31:0] mem_pc,mem_instruction,mem_prediction,mem_next_pc;
    reg [31:0] mem_result,mem_address,mem_store_data,mem_cause,mem_csr_data,mem_target;
    reg [4:0] mem_rd;
    reg [3:0] mem_strobe;
    reg [2:0] mem_funct3;
    reg wb_valid,wb_writes;
    reg [31:0] wb_pc,wb_instruction,wb_data;
    reg [4:0] wb_rd;
    wire wb_counter_write=wb_instruction[6:0]==7'h73 && wb_instruction[14:12]!=0 &&
        (wb_instruction[13:12]==1 || wb_instruction[19:15]!=0) &&
        (wb_instruction[31:20]==12'hb02 || wb_instruction[31:20]==12'hb82);
    wire mem_access=(mem_load || mem_store) && !mem_exception;
    wire mem_fire=mem_valid && (mem_access ? (mem_sent && d_rsp_valid) : (!mem_fence_i || mem_exception || maintenance_ready));
    wire mem_fault=mem_exception || (mem_access && mem_sent && d_rsp_valid && d_rsp_error);
    wire mem_ready=!mem_valid || mem_fire;
    wire frontend_barrier=mem_valid && mem_fence_i && !mem_exception;
    wire [31:0] trap_target,return_pc,csr_read_data,interrupt_cause;
    wire csr_illegal,interrupt_pending;
    wire mem_flush=mem_fire && (mem_fault || mem_mret || mem_fence_i || mem_next_pc!=mem_prediction);
    wire [31:0] redirect_pc=mem_fault ? trap_target : mem_next_pc;
    wire ex_serial=ex_decode.is_csr || ex_decode.is_mret || interrupt_pending;
    wire load_use_wait=LOAD_USE_BUBBLE!=0 && mem_valid && mem_load && mem_writes && mem_rd!=0 &&
        ((ex_decode.uses_rs1 && ex_rs1==mem_rd) || (ex_decode.uses_rs2 && ex_rs2==mem_rd));
    wire ex_can_fire=ex_valid && mem_ready && !mem_flush && !load_use_wait && !(ex_serial && (mem_valid || wb_valid));
    wire ex_muldiv=ENABLE_M!=0 && ex_instruction[6:0]==7'h33 && ex_instruction[31:25]==1;
    wire muldiv_valid,muldiv_ready;
    wire [31:0] muldiv_result;
    reg muldiv_started;
    wire ex_fire=ex_can_fire && (!ex_muldiv || execute_common_exception || muldiv_valid);
    wire ex_ready=!ex_valid || ex_fire;
    wire id_fire=id_valid && ex_ready && !mem_flush && !frontend_barrier;
    wire id_ready=!id_valid || id_fire;
    wire if_fire=if_valid && id_ready && !mem_flush && !frontend_barrier;
    wire fetch_complete=i_rsp_valid && i_rsp_ready;
    wire predicted_taken,prediction_hit;
    wire [31:0] predicted_target;
    wire csr_write_intent=(ex_instruction[13:12]==1) || ex_instruction[19:15]!=0;
    wire [31:0] csr_source=ex_instruction[14] ? ex_decode.immediate : forwarded_a;
    reg [31:0] csr_new_data;
    reg [31:0] forwarded_a,forwarded_b;
    wire [31:0] alu_a=ex_decode.is_auipc ? ex_pc : forwarded_a;
    wire [31:0] alu_b=(ex_decode.alu_immediate || ex_decode.is_auipc) ? ex_decode.immediate : forwarded_b;
    wire [31:0] alu_result;
    reg [31:0] mem_value,load_shifted;
    reg branch_taken;
    reg [31:0] branch_target,actual_next,execute_result;
    reg execute_exception;
    reg [31:0] execute_cause,mem_tval;
    reg [3:0] execute_strobe;
    wire [31:0] effective_address=forwarded_a+ex_decode.immediate;
    wire data_misaligned=(ex_instruction[13:12]==1 && effective_address[0]) ||
        (ex_instruction[13:12]==2 && effective_address[1:0]!=0);
    wire execute_common_exception=interrupt_pending || ex_pc[1:0]!=0 || ex_error || ex_decode.illegal;
    wire execute_data_exception=execute_common_exception || data_misaligned;
    wire fetch_overlap=FETCH_OVERLAP!=0 && fetch_complete && !mem_flush && !frontend_barrier;
    assign i_req_valid=fetch_active && (!fetch_sent || fetch_overlap);
    assign i_req_address=fetch_overlap ? next_pc : fetch_address;
    assign i_rsp_ready=fetch_active && fetch_sent && (!if_valid || if_fire || fetch_discard || mem_flush || frontend_barrier);
    wire early_data_request=EARLY_D_REQUEST!=0 && ex_fire && (ex_decode.is_load || ex_decode.is_store) && !execute_data_exception;
    wire select_ex_data=EARLY_D_REQUEST!=0 && !(mem_valid && mem_access && !mem_sent);
    assign d_req_valid=(mem_valid && mem_access && !mem_sent) || early_data_request;
    assign d_req_address=select_ex_data ? {effective_address[31:2],2'b0} : {mem_address[31:2],2'b0};
    assign d_req_data=select_ex_data ? (forwarded_b << {effective_address[1:0],3'b0}) : mem_store_data;
    assign d_req_strobe=select_ex_data ? execute_strobe : mem_strobe;
    assign d_req_write=select_ex_data ? ex_decode.is_store : mem_store;
    assign d_rsp_ready=mem_valid && mem_access && mem_sent;
    assign maintenance_valid=mem_valid && mem_fence_i && !mem_exception;
    assign trace_valid=wb_valid;
    assign trace_pc=wb_pc;
    assign trace_instruction=wb_instruction;
    assign trace_write=wb_valid && wb_writes && wb_rd!=0;
    assign trace_rd=wb_rd;
    assign trace_data=wb_data;
    assign trap_valid=mem_fire && mem_fault;
    assign trap_pc=mem_pc;
    assign trap_cause=mem_exception ? mem_cause : (mem_store ? 32'd7 : 32'd5);
    assign trap_value=mem_exception ? mem_tval : mem_address;
    always @* begin
        case(mem_cause)
            0: mem_tval=mem_pc[1:0]!=0 ? mem_pc : mem_target;
            1,3: mem_tval=mem_pc;
            2: mem_tval=mem_instruction;
            4,6: mem_tval=mem_address;
            default: mem_tval=0;
        endcase
    end
    assign pipeline_valid={wb_valid,mem_valid,ex_valid,id_valid,if_valid};
    rv32_decode #(.ENABLE_M(ENABLE_M)) decoder (
        .instruction(id_instruction),.rs1(id_rs1),.rs2(id_rs2),.rd(id_rd),
        .uses_rs1(id_decode.uses_rs1),.uses_rs2(id_decode.uses_rs2),.writes_rd(id_decode.writes_rd),
        .immediate(id_decode.immediate),.alu_op(id_decode.alu_op),.alu_immediate(id_decode.alu_immediate),
        .is_lui(id_decode.is_lui),.is_auipc(id_decode.is_auipc),.is_branch(id_decode.is_branch),
        .is_jal(id_decode.is_jal),.is_jalr(id_decode.is_jalr),.is_load(id_decode.is_load),.is_store(id_decode.is_store),
        .is_fence(id_decode.is_fence),.is_fence_i(id_decode.is_fence_i),.is_csr(id_decode.is_csr),
        .is_ecall(id_decode.is_ecall),.is_ebreak(id_decode.is_ebreak),.is_mret(id_decode.is_mret),
        .is_wfi(id_decode.is_wfi),.illegal(id_decode.illegal)
    );
    rv32_alu alu(.operand_a(alu_a),.operand_b(alu_b),.operation(ex_decode.alu_op),.result(alu_result));
    generate if(ENABLE_M!=0) begin : multiply_divide
        rv32_muldiv unit(
            .clk(clk),.rst_n(rst_n),.cancel(mem_flush || (ex_valid && ex_muldiv && execute_common_exception)),
            .req_valid(ex_can_fire && ex_muldiv && !execute_common_exception && !muldiv_started),.req_ready(muldiv_ready),
            .req_operation(ex_instruction[14:12]),.req_operand_a(forwarded_a),.req_operand_b(forwarded_b),
            .rsp_valid(muldiv_valid),.rsp_ready(ex_can_fire && ex_muldiv && !execute_common_exception),.rsp_data(muldiv_result)
        );
    end else begin : no_multiply_divide
        assign muldiv_ready=0;
        assign muldiv_valid=0;
        assign muldiv_result=0;
    end endgenerate
    rv32_btb #(.INDEX_BITS(BTB_INDEX_BITS),.ADDRESS_BITS(BTB_ADDRESS_BITS)) predictor (
        .clk(clk),.rst_n(rst_n),.invalidate(mem_fire && mem_fence_i && !mem_fault),.fetch_pc(next_pc),
        .predicted_taken(predicted_taken),.predicted_target(predicted_target),.prediction_hit(prediction_hit),
        .update_valid(mem_fire && mem_branch && !mem_fault),.update_pc(mem_pc),.update_target(mem_target),
        .update_taken(mem_taken),.update_conditional(mem_conditional)
    );
    rv32_machine #(.ENABLE_M(ENABLE_M)) machine (
        .clk(clk),.rst_n(rst_n),.retire(wb_valid && !wb_counter_write),.timer_value(timer_value),
        .irq_external(irq_external),.irq_software(irq_software),.irq_timer(irq_timer),
        .read_address(ex_instruction[31:20]),.read_write_intent(csr_write_intent),
        .read_data(csr_read_data),.read_illegal(csr_illegal),
        .write_valid(mem_fire && mem_csr && mem_csr_write && !mem_fault),
        .write_address(mem_instruction[31:20]),.write_data(mem_csr_data),
        .trap_enter(trap_valid),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_value(trap_value),
        .return_from_trap(mem_fire && mem_mret && !mem_fault),.return_pc(return_pc),.trap_target(trap_target),
        .interrupt_pending(interrupt_pending),.interrupt_cause(interrupt_cause),
        .cycle_count(cycle_count),.retired_count(retired_count)
    );
    always @* begin
        load_shifted=d_rsp_data >> {mem_address[1:0],3'b0};
        mem_value=mem_result;
        if(mem_load) begin
            case(mem_funct3)
                0: mem_value={{24{load_shifted[7]}},load_shifted[7:0]};
                1: mem_value={{16{load_shifted[15]}},load_shifted[15:0]};
                2: mem_value=load_shifted;
                4: mem_value={24'b0,load_shifted[7:0]};
                5: mem_value={16'b0,load_shifted[15:0]};
                default: mem_value=0;
            endcase
        end
    end
    always @* begin
        forwarded_a=ex_operand_a; forwarded_b=ex_operand_b;
        if(wb_valid && wb_writes && wb_rd!=0) begin
            if(ex_rs1==wb_rd) forwarded_a=wb_data;
            if(ex_rs2==wb_rd) forwarded_b=wb_data;
        end
        if(mem_valid && mem_writes && mem_rd!=0 && !mem_exception && (!mem_load || LOAD_USE_BUBBLE==0)) begin
            if(ex_rs1==mem_rd) forwarded_a=LOAD_USE_BUBBLE!=0 ? mem_result : mem_value;
            if(ex_rs2==mem_rd) forwarded_b=LOAD_USE_BUBBLE!=0 ? mem_result : mem_value;
        end
        if(ex_rs1==0 || !ex_decode.uses_rs1) forwarded_a=0;
        if(ex_rs2==0 || !ex_decode.uses_rs2) forwarded_b=0;
    end
    always @* begin
        case(ex_instruction[13:12])
            1: csr_new_data=csr_source;
            2: csr_new_data=csr_read_data | csr_source;
            3: csr_new_data=csr_read_data & ~csr_source;
            default: csr_new_data=csr_read_data;
        endcase
        branch_taken=ex_decode.is_jal || ex_decode.is_jalr;
        if(ex_decode.is_branch) begin
            case(ex_instruction[14:12])
                0: branch_taken=forwarded_a==forwarded_b;
                1: branch_taken=forwarded_a!=forwarded_b;
                4: branch_taken=$signed(forwarded_a)<$signed(forwarded_b);
                5: branch_taken=$signed(forwarded_a)>=$signed(forwarded_b);
                6: branch_taken=forwarded_a<forwarded_b;
                7: branch_taken=forwarded_a>=forwarded_b;
                default: branch_taken=0;
            endcase
        end
        branch_target=ex_decode.is_jalr ? (effective_address & 32'hfffffffe) : ex_pc+ex_decode.immediate;
        actual_next=branch_taken ? branch_target : ex_pc+32'd4;
        if(ex_decode.is_mret) actual_next=return_pc;
        execute_result=alu_result;
        if(ex_muldiv) execute_result=muldiv_result;
        if(ex_decode.is_fence || ex_decode.is_wfi) execute_result=0;
        if(ex_decode.is_lui) execute_result=ex_decode.immediate;
        if(ex_decode.is_jal || ex_decode.is_jalr) execute_result=ex_pc+32'd4;
        if(ex_decode.is_csr) execute_result=csr_read_data;
        case(ex_instruction[13:12])
            0: execute_strobe=4'b0001 << effective_address[1:0];
            1: execute_strobe=4'b0011 << effective_address[1:0];
            default: execute_strobe=4'b1111;
        endcase
        execute_exception=1; execute_cause=0;
        if(interrupt_pending) begin execute_cause=interrupt_cause; end
        else if(ex_pc[1:0]!=0) begin execute_cause=0; end
        else if(ex_error) begin execute_cause=1; end
        else if(ex_decode.illegal || (ex_decode.is_csr && csr_illegal)) begin execute_cause=2; end
        else if(ex_decode.is_ebreak) begin execute_cause=3; end
        else if(branch_taken && branch_target[1:0]!=0) begin execute_cause=0; end
        else if((ex_decode.is_load || ex_decode.is_store) && data_misaligned) begin
            execute_cause=ex_decode.is_store ? 32'd6 : 32'd4;
        end
        else if(ex_decode.is_ecall) begin execute_cause=11; end
        else execute_exception=0;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            muldiv_started<=0;
            next_pc<=RESET_VECTOR; fetch_address<=RESET_VECTOR; fetch_prediction<=RESET_VECTOR;
            fetch_active<=0; fetch_sent<=0; fetch_discard<=0;
            if_valid<=0; id_valid<=0; ex_valid<=0; mem_valid<=0; wb_valid<=0; mem_sent<=0;
            if_error<=0; id_error<=0; ex_error<=0;
            if_pc<=0; if_instruction<=0; if_prediction<=0;
            id_pc<=0; id_instruction<=0; id_prediction<=0;
            ex_pc<=0; ex_instruction<=0; ex_prediction<=0; ex_operand_a<=0; ex_operand_b<=0;
            ex_rd<=0; ex_decode<=0;
            mem_load<=0; mem_store<=0; mem_writes<=0; mem_exception<=0;
            mem_csr<=0; mem_csr_write<=0; mem_mret<=0; mem_fence_i<=0;
            mem_branch<=0; mem_conditional<=0; mem_taken<=0; mem_pc<=0; mem_instruction<=0;
            mem_prediction<=0; mem_next_pc<=0; mem_result<=0; mem_address<=0; mem_store_data<=0;
            mem_cause<=0; mem_csr_data<=0; mem_target<=0; mem_rd<=0; mem_strobe<=0; mem_funct3<=0;
            wb_writes<=0; wb_pc<=0; wb_instruction<=0; wb_data<=0; wb_rd<=0;
            for(reset_index=0;reset_index<32;reset_index=reset_index+1) registers[reset_index]<=0;
        end else begin
            if(ex_can_fire && ex_muldiv && !execute_common_exception && !muldiv_started && muldiv_ready) muldiv_started<=1;
            if(ex_fire || mem_flush) muldiv_started<=0;
            if(trace_write) registers[wb_rd]<=wb_data;
            wb_valid<=mem_fire && !mem_fault;
            if(mem_fire && !mem_fault) begin
                wb_pc<=mem_pc; wb_instruction<=mem_instruction; wb_writes<=mem_writes; wb_rd<=mem_rd; wb_data<=mem_value;
            end
            if(d_req_valid && d_req_ready) mem_sent<=1;
            if(mem_fire) begin mem_valid<=0; mem_sent<=0; end
            if(ex_valid) begin ex_operand_a<=forwarded_a; ex_operand_b<=forwarded_b; end
            if(ex_fire) begin
                ex_valid<=0; mem_valid<=1; mem_sent<=early_data_request && d_req_ready;
                mem_pc<=ex_pc; mem_instruction<=ex_instruction; mem_prediction<=ex_prediction; mem_next_pc<=actual_next;
                mem_result<=execute_result; mem_rd<=ex_rd; mem_writes<=ex_decode.writes_rd;
                mem_address<=effective_address; mem_store_data<=forwarded_b << {effective_address[1:0],3'b0};
                mem_strobe<=execute_strobe; mem_funct3<=ex_instruction[14:12];
                mem_load<=ex_decode.is_load; mem_store<=ex_decode.is_store;
                mem_exception<=execute_exception; mem_cause<=execute_cause;
                mem_csr<=ex_decode.is_csr; mem_csr_write<=csr_write_intent; mem_csr_data<=csr_new_data;
                mem_mret<=ex_decode.is_mret; mem_fence_i<=ex_decode.is_fence_i;
                mem_branch<=ex_decode.is_branch || ex_decode.is_jal || ex_decode.is_jalr;
                mem_conditional<=ex_decode.is_branch; mem_taken<=branch_taken; mem_target<=branch_target;
            end
            if(id_fire) begin
                id_valid<=0; ex_valid<=1; ex_pc<=id_pc; ex_instruction<=id_instruction; ex_prediction<=id_prediction;
                ex_error<=id_error; ex_decode<=id_decode; ex_rd<=id_rd;
                ex_operand_a<=(trace_write && wb_rd==id_rs1) ? wb_data : registers[id_rs1];
                ex_operand_b<=(trace_write && wb_rd==id_rs2) ? wb_data : registers[id_rs2];
            end
            if(if_fire) begin
                if_valid<=0; id_valid<=1; id_pc<=if_pc; id_instruction<=if_instruction; id_prediction<=if_prediction; id_error<=if_error;
            end
            if(i_req_valid && i_req_ready) fetch_sent<=1;
            if(fetch_complete) begin
                fetch_active<=0; fetch_sent<=0;
                if(!fetch_discard && !mem_flush && !frontend_barrier) begin
                    if_valid<=1; if_pc<=fetch_address; if_instruction<=i_rsp_data; if_prediction<=fetch_prediction; if_error<=i_rsp_error;
                end
            end
            if((!fetch_active || fetch_complete) && !mem_flush && !frontend_barrier) begin
                fetch_active<=1; fetch_sent<=fetch_overlap && i_req_ready; fetch_discard<=0; fetch_address<=next_pc;
                fetch_prediction<=(ENABLE_PREDICTOR!=0 && prediction_hit && predicted_taken) ? predicted_target : next_pc+32'd4;
                next_pc<=(ENABLE_PREDICTOR!=0 && prediction_hit && predicted_taken) ? predicted_target : next_pc+32'd4;
            end
            if(frontend_barrier) begin
                if_valid<=0; id_valid<=0; ex_valid<=0;
                if(fetch_active && !fetch_complete) fetch_discard<=1;
            end
            if(mem_flush) begin
                next_pc<=redirect_pc; if_valid<=0; id_valid<=0; ex_valid<=0;
                if(fetch_active && !fetch_complete) fetch_discard<=1;
            end
        end
    end
endmodule
