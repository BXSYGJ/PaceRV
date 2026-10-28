`timescale 1ns/1ps
module rv32_core #(
    parameter [31:0] RESET_VECTOR=32'h00000000,
    parameter integer ENABLE_PREDICTOR=1,
    parameter integer ENABLE_M=0,
    parameter integer ENABLE_C=0,
    parameter integer FETCH_ADDRESS_BITS=32,
    parameter integer FETCH_OVERLAP=0,
    parameter integer EARLY_D_REQUEST=0,
    parameter integer RETAIN_MUL_ELIGIBILITY=1,
    parameter integer BTB_INDEX_BITS=4,
    parameter integer BTB_ADDRESS_BITS=32,
    parameter integer LOAD_USE_BUBBLE=0
) (
    input wire clk,
    input wire rst_n,
    output wire i_req_valid,
    input wire i_req_ready,
    output wire [31:0] i_req_address,
    output wire [31:0] i_req_pair_address,
    input wire i_rsp_valid,
    output wire i_rsp_ready,
    input wire [31:0] i_rsp_data,
    input wire [31:0] i_rsp_pair_data,
    input wire [1:0] i_rsp_is_c,i_rsp_pair_is_c,
    input wire i_rsp_pair_valid,
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
    reg [31:0] register_valid;
    reg if_valid,if_error;
    reg [31:0] if_pc,if_instruction,if_prediction;
    reg [2:0] if_length;
    wire [31:0] if_expanded_instruction;
    wire if_compressed_illegal;
    wire [31:0] if_normalized_instruction=ENABLE_C!=0 && if_length==3'd2 && !if_error && !if_compressed_illegal ?
        if_expanded_instruction : if_instruction;
    rv32_rvc_expand expand(.compressed(if_instruction[15:0]),.instruction(if_expanded_instruction),.illegal(if_compressed_illegal));
    reg id_valid,id_error;
    reg [31:0] id_pc,id_instruction,id_prediction;
    reg [2:0] id_length;
    wire [4:0] id_rs1,id_rs2,id_rd;
    reg ex_valid,ex_error;
    reg [31:0] ex_pc,ex_instruction,ex_prediction,ex_operand_a,ex_operand_b;
    reg [2:0] ex_length;
    reg [31:0] ex_relative_target;
    reg [31:0] compare_next_a,compare_next_b;
    reg [4:0] ex_rd;
    wire [4:0] ex_rs1=ex_instruction[19:15],ex_rs2=ex_instruction[24:20];
    reg mem_valid,mem_sent,mem_load,mem_store,mem_writes,mem_exception,mem_early_redirect;
    reg mem_forward_candidate;
    reg mem_csr,mem_csr_write,mem_mret,mem_fence_i,mem_branch,mem_conditional,mem_taken;
    reg [31:0] mem_pc,mem_instruction,mem_next_pc;
    reg mem_sequential_prediction_miss,mem_target_prediction_miss;
    wire mem_prediction_miss=mem_taken ? mem_target_prediction_miss : mem_sequential_prediction_miss;
    reg [31:0] mem_result,mem_address,mem_store_data,mem_cause,mem_csr_data,mem_target;
    reg [4:0] mem_rd;
    reg mem_match_a,mem_match_b;
    reg [3:0] mem_strobe;
    reg [2:0] mem_funct3;
    reg wb_valid,wb_writes;
    reg wb_write_candidate;
    reg [31:0] wb_pc,wb_instruction,wb_data;
    reg wb_data_zero;
    reg [4:0] wb_rd;
    reg wb_match_a,wb_match_b;
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
    wire mem_flush=mem_fire && (mem_fault || mem_mret || mem_fence_i || (!mem_early_redirect && mem_prediction_miss));
    wire [31:0] memory_redirect_pc=mem_fault ? trap_target : mem_next_pc;
    wire [31:0] redirect_pc=mem_flush ? memory_redirect_pc : ex_redirect_candidate ? early_next : id_zero_next;
    // Compute companion addresses before late pipeline-capacity arbitration.
    // Every addition is 32-bit, including carry beyond FETCH_ADDRESS_BITS.
    // Preserve the per-source companion carry before late redirect selection.
    // Only the addressable bits plus overflow are kept, avoiding unused tails.
    localparam integer PAIR_PRECOMPUTE_BITS=FETCH_ADDRESS_BITS<32 ? FETCH_ADDRESS_BITS+1 : 32;
    wire [31:0] memory_redirect_pair_full={memory_redirect_pc[31:2],2'b0}+32'd4;
    (* syn_keep=1 *) wire [PAIR_PRECOMPUTE_BITS-1:0] memory_redirect_pair_kept=memory_redirect_pair_full[PAIR_PRECOMPUTE_BITS-1:0];
    wire [31:0] memory_redirect_pair=(memory_redirect_pair_full & (32'hffffffff<<PAIR_PRECOMPUTE_BITS)) |
        {{(32-PAIR_PRECOMPUTE_BITS){1'b0}},memory_redirect_pair_kept};
    wire [31:0] ex_target_pair_full={early_target[31:2],2'b0}+32'd4;
    (* syn_keep=1 *) wire [PAIR_PRECOMPUTE_BITS-1:0] ex_target_pair_kept=ex_target_pair_full[PAIR_PRECOMPUTE_BITS-1:0];
    wire [31:0] ex_target_pair=(ex_target_pair_full & (32'hffffffff<<PAIR_PRECOMPUTE_BITS)) |
        {{(32-PAIR_PRECOMPUTE_BITS){1'b0}},ex_target_pair_kept};
    wire [31:0] ex_fallthrough_pair_full={early_fallthrough[31:2],2'b0}+32'd4;
    (* syn_keep=1 *) wire [PAIR_PRECOMPUTE_BITS-1:0] ex_fallthrough_pair_kept=ex_fallthrough_pair_full[PAIR_PRECOMPUTE_BITS-1:0];
    wire [31:0] ex_fallthrough_pair=(ex_fallthrough_pair_full & (32'hffffffff<<PAIR_PRECOMPUTE_BITS)) |
        {{(32-PAIR_PRECOMPUTE_BITS){1'b0}},ex_fallthrough_pair_kept};
    wire [31:0] id_target_pair_full={id_zero_target[31:2],2'b0}+32'd4;
    (* syn_keep=1 *) wire [PAIR_PRECOMPUTE_BITS-1:0] id_target_pair_kept=id_target_pair_full[PAIR_PRECOMPUTE_BITS-1:0];
    wire [31:0] id_target_pair=(id_target_pair_full & (32'hffffffff<<PAIR_PRECOMPUTE_BITS)) |
        {{(32-PAIR_PRECOMPUTE_BITS){1'b0}},id_target_pair_kept};
    wire [31:0] id_fallthrough_pair_full={id_zero_fallthrough[31:2],2'b0}+32'd4;
    (* syn_keep=1 *) wire [PAIR_PRECOMPUTE_BITS-1:0] id_fallthrough_pair_kept=id_fallthrough_pair_full[PAIR_PRECOMPUTE_BITS-1:0];
    wire [31:0] id_fallthrough_pair=(id_fallthrough_pair_full & (32'hffffffff<<PAIR_PRECOMPUTE_BITS)) |
        {{(32-PAIR_PRECOMPUTE_BITS){1'b0}},id_fallthrough_pair_kept};
    wire [31:0] ex_redirect_pair=early_taken ? ex_target_pair : ex_fallthrough_pair;
    wire [31:0] id_redirect_pair=id_zero_taken ? id_target_pair : id_fallthrough_pair;
    wire [31:0] redirect_pair_pc=mem_flush ? memory_redirect_pair : ex_redirect_candidate ? ex_redirect_pair : id_redirect_pair;
    wire redirect_fetch_valid=mem_flush ? (memory_redirect_pc >> FETCH_ADDRESS_BITS)==0 :
        ex_redirect_candidate ? (early_taken ? (early_target >> FETCH_ADDRESS_BITS)==0 : (early_fallthrough >> FETCH_ADDRESS_BITS)==0) :
        id_zero_taken ? (id_zero_target >> FETCH_ADDRESS_BITS)==0 : (id_zero_fallthrough >> FETCH_ADDRESS_BITS)==0;
    wire ex_serial=ex_decode.is_csr || ex_decode.is_mret || interrupt_pending;
    wire equality_branch=ex_decode.is_branch && ex_instruction[14:13]==2'b00;
    wire load_address_bypass=ex_decode.is_load && mem_load_route[9];
    wire load_use_wait=LOAD_USE_BUBBLE!=0 && !equality_branch && !load_address_bypass && mem_valid && mem_load && mem_writes && mem_rd!=0 &&
        ((ex_decode.uses_rs1 && mem_match_a) || (ex_decode.uses_rs2 && mem_match_b));
    wire ex_can_fire=ex_valid && mem_ready && !mem_flush && !load_use_wait && !(ex_serial && (mem_valid || wb_valid));
    wire ex_muldiv=ENABLE_M!=0 && ex_instruction[6:0]==7'h33 && ex_instruction[31:25]==1;
    wire muldiv_valid,muldiv_ready,muldiv_available;
    wire [31:0] muldiv_result;
    reg muldiv_started;
    reg mul_precomputed;
    wire mul_prefetch_operands=!(ex_valid && ex_muldiv);
    wire mul_precompute=id_fire && id_instruction[6:0]==7'h33 &&
        id_instruction[31:25]==1 && id_instruction[14:12]==0 &&
        mul_prefetch_operands && muldiv_ready && mul_id_a_available && mul_id_b_available &&
        !(ex_valid && ex_decode.writes_rd && ex_rd!=0 && (ex_rd==id_rs1 || ex_rd==id_rs2)) &&
        !(mem_valid && mem_writes && mem_rd!=0 && (mem_rd==id_rs1 || mem_rd==id_rs2));
    // The EX slot owns an admitted preparation until consumption or cancellation.
    // Admission already excludes older EX/MEM operand writers. The product
    // bank is held by the same token; no second operand or result bank is needed.
    wire mul_request_accept=ex_can_fire && ex_muldiv && !execute_common_exception &&
        !muldiv_started && muldiv_ready;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) mul_precomputed<=0;
        else if(RETAIN_MUL_ELIGIBILITY==0) mul_precomputed<=mul_precompute;
        else if(mem_flush || frontend_barrier) mul_precomputed<=0;
        else if(mul_precompute) mul_precomputed<=1;
        else if(mul_request_accept || ex_fire || !ex_valid || !ex_muldiv ||
            execute_common_exception || muldiv_started) mul_precomputed<=0;
    end
    (* syn_keep=1 *) wire ex_transfer_capacity=ex_valid && mem_ready && !load_use_wait &&
        !((ex_decode.is_csr || ex_decode.is_mret) && (mem_valid || wb_valid)) &&
        (!ex_muldiv || execute_local_exception || muldiv_available);
    (* syn_keep=1 *) wire ex_fire_without_irq=ex_transfer_capacity && !mem_flush;
    (* syn_keep=1 *) wire ex_fire_with_irq=ex_valid && !mem_valid && !wb_valid;
    wire ex_fire=interrupt_pending ? ex_fire_with_irq : ex_fire_without_irq;
    wire ex_redirect_without_irq=ex_fire_without_irq && !early_local_exception && !early_load_dependency &&
        (ex_decode.is_branch || ex_decode.is_jal) && (early_taken ? relative_prediction_miss : sequential_prediction_miss);
    wire ex_redirect=!interrupt_pending && ex_redirect_without_irq;
    // Address preselection only: actual redirect and transfer enables stay unchanged.
    // An ID redirect cannot coincide with this candidate: if EX can transfer,
    // its redirect suppresses id_fire; otherwise the occupied EX blocks id_fire.
    wire ex_redirect_candidate=ex_valid && !interrupt_pending && !early_local_exception &&
        !early_load_dependency && (ex_decode.is_branch || ex_decode.is_jal) &&
        (early_taken ? relative_prediction_miss : sequential_prediction_miss);
    wire frontend_flush=mem_flush || ex_redirect || id_zero_redirect;
    wire ex_ready=!ex_valid || ex_fire;
    wire id_fire_without_irq=id_valid && (!ex_valid || ex_fire_without_irq) &&
        !mem_flush && !ex_redirect_without_irq && !frontend_barrier;
    (* syn_keep=1 *) wire id_fire_with_irq=id_valid && (!ex_valid || (!mem_valid && !wb_valid)) &&
        !mem_flush && !frontend_barrier;
    wire id_fire=interrupt_pending ? id_fire_with_irq : id_fire_without_irq;
    wire [1:0] unused_early_control_observation={ex_ready,early_exception};
    // ID operands read the live register file with explicit current-WB bypass.
    // Pending EX/MEM writes exclude early resolution; normal EX execution remains.
    wire id_zero_hazard=(ex_valid && ex_decode.writes_rd && ex_rd!=0 &&
        (ex_rd==id_rs1 || ex_rd==id_rs2)) ||
        (mem_valid && mem_writes && mem_rd!=0 && (mem_rd==id_rs1 || mem_rd==id_rs2));
    // The ID redirect is suppressed when an older load is still forwarding
    // data into EX.  In the remaining cases the address low bits are already
    // available in the latched EX operand; use only the low two-bit add here
    // instead of importing the full D-cache/effective-address cone.
    wire [1:0] id_early_address_lsb=ex_operand_a[1:0]+ex_decode.immediate[1:0];
    wire id_early_data_misaligned=(ex_decode.is_load || ex_decode.is_store) &&
        !early_load_dependency &&
        ((ex_instruction[13:12]==1 && id_early_address_lsb[0]) ||
         (ex_instruction[13:12]==2 && id_early_address_lsb!=0));
    wire id_zero_older_fault=execute_local_exception || (ex_decode.is_csr && csr_illegal) ||
        ex_decode.is_ecall || ex_decode.is_ebreak ||
        id_early_data_misaligned ||
        ((ex_decode.is_branch || ex_decode.is_jal) &&
         (ex_relative_target[0] || (ENABLE_C==0 && ex_relative_target[1])));
    wire id_zero_pair=id_fire && !interrupt_pending && !id_zero_hazard &&
        !(ex_valid && (id_zero_older_fault || ex_decode.is_mret || ex_decode.is_fence_i || ex_decode.is_jalr)) &&
        !id_error && !id_decode.illegal && !id_pc[0] && (ENABLE_C!=0 || !id_pc[1]) &&
        id_instruction[6:0]==7'h63 && id_instruction[14:13]==2'b00 &&
        (id_rs1==0 || id_rs2==0);
    // Unreset metadata is observable only for written registers; current WB wins.
    (* syn_ramstyle="lut_ram" *) reg register_zero[0:31];
    always @(posedge clk) if(trace_write) register_zero[wb_rd]<=wb_data_zero;
    wire id_value_a_zero=(trace_write && wb_rd==id_rs1) ? wb_data_zero :
        !id_register_a_valid || register_zero[id_rs1];
    wire id_value_b_zero=(trace_write && wb_rd==id_rs2) ? wb_data_zero :
        !id_register_b_valid || register_zero[id_rs2];
    wire id_zero_zero=id_rs1==0 ? (id_rs2==0 || id_value_b_zero) : id_value_a_zero;
    wire id_zero_taken=id_zero_zero ^ id_instruction[12];
    // ID early resolution only accepts legal BEQ/BNE instructions, including
    // normalized compressed branches. B-immediate wiring bypasses generic decode.
    wire [31:0] id_zero_branch_immediate={{19{id_instruction[31]}},id_instruction[31],
        id_instruction[7],id_instruction[30:25],id_instruction[11:8],1'b0};
    wire [31:0] id_zero_target=id_pc+id_zero_branch_immediate;
    wire [31:0] id_zero_fallthrough=id_pc+{{29{1'b0}},id_length};
    wire [31:0] id_zero_next=id_zero_taken ? id_zero_target : id_zero_fallthrough;
    wire id_zero_resolve=id_zero_pair &&
        !(id_zero_taken && (id_zero_target[0] || (ENABLE_C==0 && id_zero_target[1])));
    wire id_zero_redirect=id_zero_resolve &&
        (id_zero_taken ? id_prediction!=id_zero_target : id_prediction!=id_zero_fallthrough);
    // Address-only candidate: remove EX redirect suppression before combining
    // redirects, because an EX redirect already selects the redirect address.
    // Architectural fire, redirect and flush enables retain their original logic.
    wire id_address_fire=id_valid && (!ex_valid || ex_fire_without_irq) &&
        !mem_flush && !frontend_barrier;
    wire id_zero_address_pair=id_address_fire && !interrupt_pending && !id_zero_hazard &&
        !(ex_valid && (id_zero_older_fault || ex_decode.is_mret || ex_decode.is_fence_i || ex_decode.is_jalr)) &&
        !id_error && !id_decode.illegal && !id_pc[0] && (ENABLE_C!=0 || !id_pc[1]) &&
        id_instruction[6:0]==7'h63 && id_instruction[14:13]==2'b00 &&
        (id_rs1==0 || id_rs2==0);
    wire id_zero_address_resolve=id_zero_address_pair &&
        !(id_zero_taken && (id_zero_target[0] || (ENABLE_C==0 && id_zero_target[1])));
    (* syn_keep=1 *) wire id_zero_address_redirect=id_zero_address_resolve &&
        (id_zero_taken ? id_prediction!=id_zero_target : id_prediction!=id_zero_fallthrough);
    (* syn_keep=1 *) wire frontend_redirect_address_select=
        mem_flush || ex_redirect || id_zero_address_redirect;
    wire id_ready=!id_valid || id_fire;
    wire if_fire=if_valid && id_ready && !frontend_flush && !frontend_barrier;
    wire id_payload_load=!id_valid || !ex_valid || ex_fire;
    wire predicted_taken,prediction_hit;
    wire [31:0] predicted_target;
    wire [31:0] frontend_pc,frontend_instruction,frontend_prediction;
    wire [2:0] frontend_length;
    wire frontend_out_valid,frontend_out_error,frontend_out_ready,frontend_fire;
    wire csr_write_intent=(ex_instruction[13:12]==1) || ex_instruction[19:15]!=0;
    wire [31:0] csr_source=ex_instruction[14] ? ex_decode.immediate : forwarded_a;
    reg [31:0] csr_new_data;
    reg [31:0] forwarded_a,forwarded_b;
    wire early_mem_forward=mem_valid && mem_forward_candidate && !mem_load;
    wire early_load_dependency=mem_valid && mem_load && mem_writes && mem_rd!=0 && !mem_exception &&
        ((ex_decode.uses_rs1 && mem_match_a) || (ex_decode.uses_rs2 && mem_match_b));
    wire [31:0] early_operand_a=ex_rs1==0 || !ex_decode.uses_rs1 ? 32'b0 :
        early_mem_forward && mem_match_a ? mem_result :
        trace_write && wb_match_a ? wb_data : ex_operand_a;
    wire [31:0] early_operand_b=ex_rs2==0 || !ex_decode.uses_rs2 ? 32'b0 :
        early_mem_forward && mem_match_b ? mem_result :
        trace_write && wb_match_b ? wb_data : ex_operand_b;
    wire [3:0] early_source_a,early_source_b;
    reg early_zero_a,early_zero_b;
    assign early_source_a[0]=early_zero_a;
    assign early_source_b[0]=early_zero_b;
    assign early_source_a[2]=!early_zero_a && early_mem_forward && mem_match_a;
    assign early_source_b[2]=!early_zero_b && early_mem_forward && mem_match_b;
    assign early_source_a[3]=!early_zero_a && !(early_mem_forward && mem_match_a) && trace_write && wb_match_a;
    assign early_source_b[3]=!early_zero_b && !(early_mem_forward && mem_match_b) && trace_write && wb_match_b;
    assign early_source_a[1]=!early_zero_a && !(early_mem_forward && mem_match_a) && !(trace_write && wb_match_a);
    assign early_source_b[1]=!early_zero_b && !(early_mem_forward && mem_match_b) && !(trace_write && wb_match_b);
    wire [63:0] unused_early_compare_operands={early_operand_a,early_operand_b};
    function automatic parallel_less(input [3:1] byte_equal,input [3:0] byte_less);
        begin
            parallel_less=byte_less[3] || (byte_equal[3] && byte_less[2]) ||
                (byte_equal[3] && byte_equal[2] && byte_less[1]) ||
                (byte_equal[3] && byte_equal[2] && byte_equal[1] && byte_less[0]);
        end
    endfunction
    function automatic [2:0] operand_relation(input [31:0] operand_left,operand_right);
        reg [3:0] byte_equal,byte_less;
        reg unsigned_less;
        integer byte_index;
        begin
            for(byte_index=0;byte_index<4;byte_index=byte_index+1) begin
                byte_equal[byte_index]=operand_left[byte_index*8+:8]==operand_right[byte_index*8+:8];
                byte_less[byte_index]=operand_left[byte_index*8+:8]<operand_right[byte_index*8+:8];
            end
            unsigned_less=parallel_less(byte_equal[3:1],byte_less);
            operand_relation={&byte_equal,unsigned_less,
                (operand_left[31]^operand_right[31]) ? operand_left[31] : unsigned_less};
        end
    endfunction
    (* syn_maxfan=16 *) wire id_register_a_valid=register_valid[id_rs1];
    (* syn_maxfan=16 *) wire id_register_b_valid=register_valid[id_rs2];
    wire mul_id_a_available=id_rs1!=0 && (id_register_a_valid || (trace_write && wb_rd==id_rs1));
    wire mul_id_b_available=id_rs2!=0 && (id_register_b_valid || (trace_write && wb_rd==id_rs2));
    wire [31:0] mul_id_operand_a=(trace_write && wb_rd==id_rs1) ? wb_data : registers[id_rs1];
    wire [31:0] mul_id_operand_b=(trace_write && wb_rd==id_rs2) ? wb_data : registers[id_rs2];
    wire [31:0] id_operand_a=(trace_write && wb_rd==id_rs1) ? wb_data : (id_register_a_valid ? registers[id_rs1] : 32'd0);
    wire [31:0] id_operand_b=(trace_write && wb_rd==id_rs2) ? wb_data : (id_register_b_valid ? registers[id_rs2] : 32'd0);
    always @* begin
        compare_next_a=ex_ready ? id_operand_a : forwarded_a;
        compare_next_b=ex_ready ? id_operand_b : forwarded_b;
    end
    // One comparison bank follows the existing forwarding muxes.
    // Early redirects remain inhibited for outstanding load dependencies.
    wire [2:0] early_result=operand_relation(forwarded_a,forwarded_b);
    wire [2:0] early_condition_select={ex_instruction[14:13]==2'b00,ex_instruction[14:13]==2'b11,ex_instruction[14:13]==2'b10};
    wire early_selected_condition=|(early_result & early_condition_select);
    reg early_taken;
    wire [31:0] early_target=ex_relative_target;
    wire [31:0] early_fallthrough=ex_pc+{{29{1'b0}},ex_length};
    wire [31:0] early_next=early_taken ? early_target : early_fallthrough;
    wire sequential_prediction_miss=early_fallthrough!=ex_prediction;
    wire relative_prediction_miss=early_target!=ex_prediction;
    wire indirect_prediction_miss={effective_address[31:1],1'b0}!=ex_prediction;
    wire execute_prediction_miss=branch_taken ?
        (ex_decode.is_jalr ? indirect_prediction_miss : relative_prediction_miss) : sequential_prediction_miss;
    wire early_local_exception=execute_local_exception || (early_taken && (early_target[0] || (ENABLE_C==0 && early_target[1])));
    wire early_exception=interrupt_pending || early_local_exception;
    always @* begin
        early_taken=ex_decode.is_jal;
        if(ex_decode.is_branch) early_taken=(|early_condition_select) && (early_selected_condition^ex_instruction[12]);
    end
    wire [31:0] alu_a=ex_decode.is_auipc ? ex_pc : forwarded_a;
    wire [31:0] alu_b=(ex_decode.alu_immediate || ex_decode.is_auipc) ? ex_decode.immediate : forwarded_b;
    wire [31:0] alu_result;
    reg [31:0] mem_value;
    function automatic [16:0] decode_load_route(input [2:0] load_format,input [1:0] byte_offset);
        reg [3:0] byte_lane;
        reg byte_format,half_format,word_format;
        begin
            byte_lane=4'b0001<<byte_offset;
            byte_format=load_format==0 || load_format==4;
            half_format=load_format==1 || load_format==5;
            word_format=load_format==2;
            decode_load_route[3:0]={4{byte_format || half_format || word_format}} & byte_lane;
            decode_load_route[6:4]={3{half_format || word_format}} & byte_lane[2:0];
            decode_load_route[8:7]={2{word_format}} & byte_lane[1:0];
            decode_load_route[9]=word_format && byte_lane[0];
            decode_load_route[13:10]={4{load_format==0}} & byte_lane;
            decode_load_route[16:14]={3{load_format==1}} & byte_lane[2:0];
        end
    endfunction
    reg [16:0] mem_load_route;
    wire [2:0] unused_mem_funct3=mem_funct3;
    wire load_byte_sign=|(mem_load_route[13:10] & {d_rsp_data[31],d_rsp_data[23],d_rsp_data[15],d_rsp_data[7]});
    wire load_half_sign=|(mem_load_route[16:14] & {d_rsp_data[31],d_rsp_data[23],d_rsp_data[15]});
    wire [7:0] load_byte0=({8{mem_load_route[0]}} & d_rsp_data[7:0]) |
        ({8{mem_load_route[1]}} & d_rsp_data[15:8]) |
        ({8{mem_load_route[2]}} & d_rsp_data[23:16]) |
        ({8{mem_load_route[3]}} & d_rsp_data[31:24]);
    wire [7:0] load_byte1=({8{mem_load_route[4]}} & d_rsp_data[15:8]) |
        ({8{mem_load_route[5]}} & d_rsp_data[23:16]) |
        ({8{mem_load_route[6]}} & d_rsp_data[31:24]) | {8{load_byte_sign}};
    wire [7:0] load_byte2=({8{mem_load_route[7]}} & d_rsp_data[23:16]) |
        ({8{mem_load_route[8]}} & d_rsp_data[31:24]) | {8{load_byte_sign || load_half_sign}};
    wire [7:0] load_byte3=({8{mem_load_route[9]}} & d_rsp_data[31:24]) | {8{load_byte_sign || load_half_sign}};
    wire branch_load_forward=LOAD_USE_BUBBLE!=0 && mem_valid && mem_load && mem_writes && mem_rd!=0 && !mem_exception;
    wire [31:0] branch_operand_a=branch_load_forward && ex_decode.uses_rs1 && mem_match_a ? mem_value : forwarded_a;
    wire [31:0] branch_operand_b=branch_load_forward && ex_decode.uses_rs2 && mem_match_b ? mem_value : forwarded_b;
    reg branch_taken;
    reg [31:0] branch_target,actual_next,execute_result;
    reg execute_exception;
    reg [31:0] execute_cause,mem_tval;
    reg [3:0] execute_strobe;
    wire word_address_forward=load_address_bypass && branch_load_forward && ex_decode.uses_rs1 && mem_match_a;
    wire [31:0] address_operand=word_address_forward ? d_rsp_data : forwarded_a;
    wire [8:0] address_byte0={1'b0,address_operand[7:0]}+{1'b0,ex_decode.immediate[7:0]};
    (* syn_keep=1 *) wire [8:0] address_byte1_zero={1'b0,address_operand[15:8]}+{1'b0,ex_decode.immediate[15:8]};
    (* syn_keep=1 *) wire [7:0] address_byte1_one=address_operand[15:8]+ex_decode.immediate[15:8]+8'd1;
    (* syn_keep=1 *) wire [8:0] address_byte2_zero={1'b0,address_operand[23:16]}+{1'b0,ex_decode.immediate[23:16]};
    (* syn_keep=1 *) wire [7:0] address_byte2_one=address_operand[23:16]+ex_decode.immediate[23:16]+8'd1;
    (* syn_keep=1 *) wire [7:0] address_byte3_zero=address_operand[31:24]+ex_decode.immediate[31:24];
    (* syn_keep=1 *) wire [7:0] address_byte3_one=address_operand[31:24]+ex_decode.immediate[31:24]+8'd1;
    wire address_propagate1=&(address_operand[15:8]^ex_decode.immediate[15:8]);
    wire address_propagate2=&(address_operand[23:16]^ex_decode.immediate[23:16]);
    wire address_carry16=address_byte1_zero[8] || (address_propagate1 && address_byte0[8]);
    wire address_carry24=address_byte2_zero[8] || (address_propagate2 && address_byte1_zero[8]) ||
        (address_propagate2 && address_propagate1 && address_byte0[8]);
    wire [31:0] effective_address={address_carry24 ? address_byte3_one : address_byte3_zero,
        address_carry16 ? address_byte2_one : address_byte2_zero[7:0],
        address_byte0[8] ? address_byte1_one : address_byte1_zero[7:0],address_byte0[7:0]};
    wire data_misaligned=(ex_instruction[13:12]==1 && effective_address[0]) ||
        (ex_instruction[13:12]==2 && effective_address[1:0]!=0);
    wire execute_local_exception=ex_pc[0] || (ENABLE_C==0 && ex_pc[1]) || ex_error || ex_decode.illegal;
    wire execute_common_exception=interrupt_pending || execute_local_exception;
    wire execute_data_exception=execute_common_exception || data_misaligned;
    (* syn_keep=1 *) wire fetch_accept_space=!if_valid || !id_valid || !ex_valid ||
        (interrupt_pending ? ex_fire_with_irq : ex_transfer_capacity);
    assign frontend_out_ready=fetch_accept_space;
    assign frontend_fire=frontend_out_valid && frontend_out_ready;
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
    assign trace_write=wb_valid && wb_write_candidate;
    assign trace_rd=wb_rd;
    assign trace_data=wb_data;
    assign trap_valid=mem_fire && mem_fault;
    assign trap_pc=mem_pc;
    assign trap_cause=mem_exception ? mem_cause : (mem_store ? 32'd7 : 32'd5);
    assign trap_value=mem_exception ? mem_tval : mem_address;
    always @* begin
        case(mem_cause)
            0: mem_tval=(mem_pc[0] || (ENABLE_C==0 && mem_pc[1])) ? mem_pc : mem_target;
            1: mem_tval=mem_instruction;
            3: mem_tval=mem_pc;
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
        rv32_muldiv #(.PRECOMPUTE(1),.RETAIN_PREPARATION(RETAIN_MUL_ELIGIBILITY)) unit(
            .clk(clk),.rst_n(rst_n),.cancel(mem_flush || (ex_valid && ex_muldiv && execute_common_exception)),
            .req_valid(ex_can_fire && ex_muldiv && !execute_common_exception && !muldiv_started),.req_ready(muldiv_ready),
            .req_precomputed(mul_precomputed && !muldiv_started),.req_operation(ex_instruction[14:12]),
            .req_operand_a(mul_prefetch_operands ? mul_id_operand_a : forwarded_a),
            .req_operand_b(mul_prefetch_operands ? mul_id_operand_b : forwarded_b),
            .rsp_valid(muldiv_valid),.rsp_available(muldiv_available),
            .rsp_ready(ex_can_fire && ex_muldiv && !execute_common_exception),.rsp_data(muldiv_result)
        );
    end else begin : no_multiply_divide
        assign muldiv_ready=0;
        assign muldiv_valid=0;
        assign muldiv_available=0;
        assign muldiv_result=0;
    end endgenerate
    wire stack_destination_link=mem_instruction[11:7]==5'd1 || mem_instruction[11:7]==5'd5;
    wire stack_source_link=mem_instruction[19:15]==5'd1 || mem_instruction[19:15]==5'd5;
    wire stack_jal=mem_instruction[6:0]==7'h6f;
    wire stack_jalr=mem_instruction[6:0]==7'h67 && mem_instruction[14:12]==0;
    wire stack_return_hint=stack_jalr && stack_source_link &&
        (!stack_destination_link || mem_instruction[11:7]!=mem_instruction[19:15]);
    wire stack_call_hint=(stack_jal || stack_jalr) && stack_destination_link;
    wire stack_commit=mem_fire && !mem_fault && mem_branch;
    wire frontend_buffered_valid;
    wire [31:0] frontend_buffered_instruction;
    wire [2:0] frontend_buffered_length;
    // Direct jumps carry their target in the instruction; reserve BTB entries for dynamic control.
    wire frontend_direct_c=frontend_buffered_length==3'd2 && frontend_buffered_instruction[1:0]==2'b01 &&
        (frontend_buffered_instruction[15:13]==3'b001 || frontend_buffered_instruction[15:13]==3'b101);
    wire frontend_direct_jal=frontend_buffered_valid && (frontend_direct_c ||
        (frontend_buffered_length==3'd4 && frontend_buffered_instruction[6:0]==7'h6f));
    wire [31:0] frontend_direct_offset=frontend_direct_c ?
        {{20{frontend_buffered_instruction[12]}},frontend_buffered_instruction[12],frontend_buffered_instruction[8],
         frontend_buffered_instruction[10:9],frontend_buffered_instruction[6],frontend_buffered_instruction[7],
         frontend_buffered_instruction[2],frontend_buffered_instruction[11],frontend_buffered_instruction[5:3],1'b0} :
        {{11{frontend_buffered_instruction[31]}},frontend_buffered_instruction[31],frontend_buffered_instruction[19:12],
         frontend_buffered_instruction[20],frontend_buffered_instruction[30:21],1'b0};
    wire [31:0] frontend_direct_target=frontend_pc+frontend_direct_offset;
    wire frontend_ras_available;
    wire [31:0] frontend_ras_target;
    wire frontend_return_c=frontend_buffered_length==3'd2 && frontend_buffered_instruction[15:13]==3'b100 &&
        frontend_buffered_instruction[1:0]==2'b10 && frontend_buffered_instruction[6:2]==0 &&
        (frontend_buffered_instruction[11:7]==5'd1 || frontend_buffered_instruction[11:7]==5'd5) &&
        (!frontend_buffered_instruction[12] || frontend_buffered_instruction[11:7]!=5'd1);
    wire frontend_return_32=frontend_buffered_length==3'd4 && frontend_buffered_instruction[6:0]==7'h67 &&
        frontend_buffered_instruction[14:12]==0 && frontend_buffered_instruction[31:20]==0 &&
        (frontend_buffered_instruction[19:15]==5'd1 || frontend_buffered_instruction[19:15]==5'd5) &&
        ((frontend_buffered_instruction[11:7]!=5'd1 && frontend_buffered_instruction[11:7]!=5'd5) ||
         frontend_buffered_instruction[11:7]!=frontend_buffered_instruction[19:15]);
    wire frontend_return=frontend_buffered_valid && frontend_ras_available &&
        (frontend_return_c || frontend_return_32);
    rv32_rvc_frontend #(.RESET_VECTOR(RESET_VECTOR),.ENABLE_C(ENABLE_C),.ADDRESS_BITS(FETCH_ADDRESS_BITS),.USE_PRECOMPUTED_REDIRECT_PAIR_ADDRESS(1),.USE_REDIRECT_ADDRESS_SELECT(1)) frontend(
        .buffered_valid(frontend_buffered_valid),.buffered_instruction(frontend_buffered_instruction),.buffered_length(frontend_buffered_length),
        .i_rsp_pair_data(i_rsp_pair_data),.i_rsp_pair_valid(i_rsp_pair_valid),.i_rsp_is_c(i_rsp_is_c),.i_rsp_pair_is_c(i_rsp_pair_is_c),
        .invalidate(frontend_barrier),
        .clk(clk),.rst_n(rst_n),.redirect_valid(frontend_flush),.redirect_address_select(frontend_redirect_address_select),.redirect_pc(redirect_pc),.redirect_pair_pc(redirect_pair_pc),
        .redirect_in_range(redirect_fetch_valid),
        .predicted_taken(ENABLE_PREDICTOR!=0 && (frontend_direct_jal || frontend_return || predicted_taken)),.predicted_target(frontend_direct_jal ? frontend_direct_target : frontend_return ? frontend_ras_target : predicted_target),.predictor_pc(frontend_pc),
        .out_valid(frontend_out_valid),.out_ready(frontend_out_ready),.out_pc(frontend_pc),
        .out_instruction(frontend_instruction),.out_prediction(frontend_prediction),.out_length(frontend_length),.out_error(frontend_out_error),
        .i_req_valid(i_req_valid),.i_req_ready(i_req_ready),.i_req_address(i_req_address),.i_req_pair_address(i_req_pair_address),
        .i_rsp_valid(i_rsp_valid),.i_rsp_ready(i_rsp_ready),.i_rsp_data(i_rsp_data),.i_rsp_error(i_rsp_error)
    );
    rv32_btb #(.INDEX_BITS(BTB_INDEX_BITS),.ADDRESS_BITS(BTB_ADDRESS_BITS),.RETURN_STACK_DEPTH(1)) predictor (
        .clk(clk),.rst_n(rst_n),.invalidate(mem_valid && mem_fence_i && !mem_exception && maintenance_ready),.fetch_pc(frontend_pc),
        .predicted_taken(predicted_taken),.predicted_target(predicted_target),.prediction_hit(prediction_hit),
        .return_stack_available(frontend_ras_available),.return_stack_target(frontend_ras_target),
        .update_valid(mem_valid && mem_branch && !mem_exception && (!stack_jal || mem_prediction_miss)),.update_pc(mem_pc),.update_target(mem_target),
        .update_taken(mem_taken),.update_conditional(mem_conditional),
        .update_return(stack_return_hint),.stack_push(stack_commit && stack_call_hint),
        .stack_pop(stack_commit && stack_return_hint),.stack_push_address(mem_result)
    );
    rv32_machine #(.ENABLE_M(ENABLE_M),.ENABLE_C(ENABLE_C)) machine (
        .clk(clk),.rst_n(rst_n),.retire(wb_valid && !wb_counter_write),.timer_value(timer_value),
        .irq_external(irq_external),.irq_software(irq_software),.irq_timer(irq_timer),
        .read_address(ex_instruction[31:20]),.read_write_intent(csr_write_intent),
        .read_data(csr_read_data),.read_illegal(csr_illegal),
        .write_valid(mem_valid && mem_csr && mem_csr_write && !mem_exception),
        .write_address(mem_instruction[31:20]),.write_data(mem_csr_data),
        .trap_enter(trap_valid),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_value(trap_value),
        .return_from_trap(mem_valid && mem_mret && !mem_exception),.return_pc(return_pc),.trap_target(trap_target),
        .interrupt_pending(interrupt_pending),.interrupt_cause(interrupt_cause),
        .cycle_count(cycle_count),.retired_count(retired_count)
    );
    always @* begin
        mem_value=mem_load ? {load_byte3,load_byte2,load_byte1,load_byte0} : mem_result;
    end
    always @* begin
        forwarded_a=ex_operand_a; forwarded_b=ex_operand_b;
        if(trace_write) begin
            if(wb_match_a) forwarded_a=wb_data;
            if(wb_match_b) forwarded_b=wb_data;
        end
        if(mem_valid && mem_forward_candidate && (!mem_load || LOAD_USE_BUBBLE==0)) begin
            if(mem_match_a) forwarded_a=LOAD_USE_BUBBLE!=0 ? mem_result : mem_value;
            if(mem_match_b) forwarded_b=LOAD_USE_BUBBLE!=0 ? mem_result : mem_value;
        end
        if(early_zero_a) forwarded_a=0;
        if(early_zero_b) forwarded_b=0;
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
            if(LOAD_USE_BUBBLE!=0) begin
                // Reuse the relation already selected for early resolution.
                // Equality branches retain their same-cycle load bypass.
                if(equality_branch && early_load_dependency)
                    branch_taken=(branch_operand_a==branch_operand_b)^ex_instruction[12];
                else
                    branch_taken=(|early_condition_select) && (early_selected_condition^ex_instruction[12]);
            end else begin
                case(ex_instruction[14:12])
                    0: branch_taken=branch_operand_a==branch_operand_b;
                    1: branch_taken=branch_operand_a!=branch_operand_b;
                    4: branch_taken=$signed(forwarded_a)<$signed(forwarded_b);
                    5: branch_taken=$signed(forwarded_a)>=$signed(forwarded_b);
                    6: branch_taken=forwarded_a<forwarded_b;
                    7: branch_taken=forwarded_a>=forwarded_b;
                    default: branch_taken=0;
                endcase
            end
        end
        branch_target=ex_decode.is_jalr ? (effective_address & 32'hfffffffe) : ex_relative_target;
        actual_next=branch_taken ? branch_target : ex_pc+{{29{1'b0}},ex_length};
        if(ex_decode.is_mret) actual_next=return_pc;
        execute_result=alu_result;
        if(ex_muldiv) execute_result=muldiv_result;
        if(ex_decode.is_fence || ex_decode.is_wfi) execute_result=0;
        if(ex_decode.is_lui) execute_result=ex_decode.immediate;
        if(ex_decode.is_jal || ex_decode.is_jalr) execute_result=ex_pc+{{29{1'b0}},ex_length};
        if(ex_decode.is_csr) execute_result=csr_read_data;
        case(ex_instruction[13:12])
            0: execute_strobe=4'b0001 << effective_address[1:0];
            1: execute_strobe=4'b0011 << effective_address[1:0];
            default: execute_strobe=4'b1111;
        endcase
        execute_exception=1; execute_cause=0;
        if(interrupt_pending) begin execute_cause=interrupt_cause; end
        else if(ex_pc[0] || (ENABLE_C==0 && ex_pc[1])) begin execute_cause=0; end
        else if(ex_error) begin execute_cause=1; end
        else if(ex_decode.illegal || (ex_decode.is_csr && csr_illegal)) begin execute_cause=2; end
        else if(ex_decode.is_ebreak) begin execute_cause=3; end
        else if(branch_taken && (branch_target[0] || (ENABLE_C==0 && branch_target[1]))) begin execute_cause=0; end
        else if((ex_decode.is_load || ex_decode.is_store) && data_misaligned) begin
            execute_cause=ex_decode.is_store ? 32'd6 : 32'd4;
        end
        else if(ex_decode.is_ecall) begin execute_cause=11; end
        else execute_exception=0;
    end
    always @(posedge clk) begin
        if(trace_write) registers[wb_rd]<=wb_data;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            muldiv_started<=0;
            if_valid<=0; id_valid<=0; ex_valid<=0; mem_valid<=0; wb_valid<=0; mem_sent<=0;
            if_error<=0; id_error<=0; ex_error<=0;
            if_pc<=0; if_instruction<=0; if_prediction<=0; if_length<=3'd4;
            id_pc<=0; id_instruction<=0; id_prediction<=0; id_length<=3'd4;
            ex_pc<=0; ex_instruction<=0; ex_prediction<=0; ex_length<=3'd4; ex_operand_a<=0; ex_operand_b<=0;
            ex_relative_target<=0;
            ex_rd<=0; ex_decode<=0; mem_match_a<=1; mem_match_b<=1;
            mem_load<=0; mem_store<=0; mem_writes<=0; mem_exception<=0; mem_early_redirect<=0;
            mem_forward_candidate<=0;
            mem_csr<=0; mem_csr_write<=0; mem_mret<=0; mem_fence_i<=0;
            mem_branch<=0; mem_conditional<=0; mem_taken<=0; mem_pc<=0; mem_instruction<=0;
            mem_sequential_prediction_miss<=0; mem_target_prediction_miss<=0;
            mem_next_pc<=0; mem_result<=0; mem_address<=0; mem_store_data<=0;
            mem_cause<=0; mem_csr_data<=0; mem_target<=0; mem_rd<=0; mem_strobe<=0; mem_funct3<=0; mem_load_route<=decode_load_route(3'd0,2'd0);
            wb_writes<=0; wb_pc<=0; wb_instruction<=0; wb_data<=0; wb_data_zero<=1; wb_rd<=0;
            wb_write_candidate<=0;
            wb_match_a<=1; wb_match_b<=1; early_zero_a<=1; early_zero_b<=1;
            register_valid<=0;
        end else begin
            wb_match_a<=id_fire ? id_rs1==mem_rd : mem_match_a;
            wb_match_b<=id_fire ? id_rs2==mem_rd : mem_match_b;
            if(id_fire) begin
                early_zero_a<=id_rs1==0 || !id_decode.uses_rs1;
                early_zero_b<=id_rs2==0 || !id_decode.uses_rs2;
            end
            if(ex_can_fire && ex_muldiv && !execute_common_exception && !muldiv_started && muldiv_ready) muldiv_started<=1;
            if(ex_fire || mem_flush) muldiv_started<=0;
            if(trace_write) register_valid[wb_rd]<=1'b1;
            wb_valid<=mem_fire && !mem_fault;
            if(mem_fire && !mem_fault) begin
                wb_pc<=mem_pc; wb_instruction<=mem_instruction; wb_writes<=mem_writes; wb_rd<=mem_rd; wb_data<=mem_value; wb_data_zero<=mem_value==0;
                wb_write_candidate<=mem_writes && mem_rd!=0;
            end
            if(d_req_valid && d_req_ready) mem_sent<=1;
            if(mem_fire) begin mem_valid<=0; mem_sent<=0; end
            ex_operand_a<=compare_next_a;
            ex_operand_b<=compare_next_b;
            if(ex_fire) begin
                ex_valid<=0; mem_valid<=1; mem_sent<=early_data_request && d_req_ready;
                mem_pc<=ex_pc; mem_instruction<=ex_instruction; mem_next_pc<=actual_next;
                mem_sequential_prediction_miss<=sequential_prediction_miss;
                mem_target_prediction_miss<=ex_decode.is_jalr ? indirect_prediction_miss : relative_prediction_miss;
                mem_result<=execute_result; mem_rd<=ex_rd; mem_writes<=ex_decode.writes_rd;
                mem_forward_candidate<=ex_decode.writes_rd && ex_rd!=0 && !execute_exception;
                mem_address<=effective_address; mem_store_data<=forwarded_b << {effective_address[1:0],3'b0};
                mem_strobe<=execute_strobe; mem_funct3<=ex_instruction[14:12]; mem_load_route<=decode_load_route(ex_instruction[14:12],effective_address[1:0]);
                mem_load<=ex_decode.is_load; mem_store<=ex_decode.is_store;
                mem_exception<=execute_exception; mem_cause<=execute_cause; mem_early_redirect<=ex_redirect;
                mem_csr<=ex_decode.is_csr; mem_csr_write<=csr_write_intent; mem_csr_data<=csr_new_data;
                mem_mret<=ex_decode.is_mret; mem_fence_i<=ex_decode.is_fence_i;
                mem_branch<=ex_decode.is_branch || ex_decode.is_jal || ex_decode.is_jalr;
                mem_conditional<=ex_decode.is_branch; mem_taken<=branch_taken; mem_target<=branch_target;
            end
            if(id_fire) begin
                if(ex_fire) begin
                    mem_match_a<=id_rs1==ex_rd;
                    mem_match_b<=id_rs2==ex_rd;
                end else begin
                    mem_match_a<=id_rs1==mem_rd;
                    mem_match_b<=id_rs2==mem_rd;
                end
            end else if(ex_fire) begin
                mem_match_a<=ex_rs1==ex_rd;
                mem_match_b<=ex_rs2==ex_rd;
            end
            if(id_fire) begin
                id_valid<=0; ex_valid<=1; ex_pc<=id_pc; ex_instruction<=id_instruction; ex_prediction<=id_zero_resolve ? id_zero_next : id_prediction;
                ex_length<=id_length;
                ex_error<=id_error; ex_decode<=id_decode; ex_rd<=id_rd;
                ex_relative_target<=id_pc+id_decode.immediate;
            end
            if(id_payload_load) begin
                id_pc<=if_pc; id_instruction<=if_normalized_instruction; id_prediction<=if_prediction; id_length<=if_length; id_error<=if_error;
            end
            if(if_fire) begin
                if_valid<=0; id_valid<=1;
            end
            if(frontend_fire) begin
                if_valid<=1; if_pc<=frontend_pc; if_instruction<=frontend_instruction; if_prediction<=frontend_prediction;
                if_length<=frontend_length; if_error<=frontend_out_error;
            end
            if(frontend_barrier) begin
                if_valid<=0; id_valid<=0; ex_valid<=0;
            end
            if(frontend_flush) begin
                if_valid<=0; id_valid<=0;
                if(mem_flush || ex_redirect) ex_valid<=0;
            end
        end
    end
endmodule
