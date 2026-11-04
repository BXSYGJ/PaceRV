`timescale 1ns/1ps
module rv32_rvc_frontend #(
    parameter [31:0] RESET_VECTOR=32'h00000000,
    parameter integer ENABLE_C=1,
    parameter integer ADDRESS_BITS=32
) (
    input wire clk, rst_n,
    input wire invalidate,
    input wire redirect_valid,
    input wire redirect_in_range,
    input wire [31:0] redirect_pc,
    input wire predicted_taken,
    input wire [31:0] predicted_target,
    output wire [31:0] predictor_pc,
    output wire out_valid,
    input wire out_ready,
    output wire [31:0] out_pc, out_instruction, out_prediction,
    output wire [2:0] out_length,
    output wire out_error,
    output wire i_req_valid,
    input wire i_req_ready,
    output wire [31:0] i_req_address,
    input wire i_rsp_valid,
    output wire i_rsp_ready,
    input wire [31:0] i_rsp_data,
    input wire [31:0] i_rsp_pair_data,
    input wire [1:0] i_rsp_is_c,i_rsp_pair_is_c,
    input wire i_rsp_pair_valid,
    input wire i_rsp_error
);
    reg [31:0] pc;
    reg word0_valid,word1_valid;
    reg [ADDRESS_BITS-1:0] word0_tag,word1_tag;
    wire [31:0] word0_address={{(32-ADDRESS_BITS){1'b0}},word0_tag};
    wire [31:0] word1_address={{(32-ADDRESS_BITS){1'b0}},word1_tag};
    reg [31:0] word0_data,word1_data;
    reg [1:0] word0_is_c,word1_is_c;
    reg word0_error,word1_error;
    reg request_pending,request_discard;
    reg [ADDRESS_BITS-1:0] request_tag;
    wire [31:0] request_address={{(32-ADDRESS_BITS){1'b0}},request_tag};
    wire response_fire=request_pending && i_rsp_valid;
    wire response_usable=response_fire && !request_discard && !invalidate;
    wire [31:0] aligned_pc={pc[31:2],2'b0};
    wire [31:0] following_address=aligned_pc+32'd4;
    wire current_range_error=(pc >> ADDRESS_BITS)!=0;
    wire following_range_error=(following_address >> ADDRESS_BITS)!=0;
    wire [31:0] pair_address={request_address[31:3],1'b1,2'b0};
    wire current_pair=request_address!=aligned_pc && i_rsp_pair_valid && pair_address==aligned_pc;
    wire following_pair=request_address!=following_address && i_rsp_pair_valid && pair_address==following_address;
    wire current_pending=request_pending && !request_discard && (request_address==aligned_pc || current_pair);
    wire following_pending=request_pending && !request_discard && (request_address==following_address || following_pair);
    wire current_response=response_usable && current_pending;
    wire following_response=response_usable && following_pending;
    wire current_buffer_valid=pc[2] ? word1_valid && word1_address==aligned_pc : word0_valid && word0_address==aligned_pc;
    wire following_buffer_valid=pc[2] ? word0_valid && word0_address==following_address : word1_valid && word1_address==following_address;
    wire current_valid=current_range_error || current_response || current_buffer_valid;
    wire following_valid=following_range_error || following_response || following_buffer_valid;
    wire [31:0] current_data=current_buffer_valid ? (pc[2] ? word1_data : word0_data) : current_pair ? i_rsp_pair_data : i_rsp_data;
    wire [31:0] following_data=following_buffer_valid ? (pc[2] ? word0_data : word1_data) : following_pair ? i_rsp_pair_data : i_rsp_data;
    wire current_error=current_range_error || (current_buffer_valid ? (pc[2] ? word1_error : word0_error) : i_rsp_error);
    wire following_error=following_range_error || (following_buffer_valid ? (pc[2] ? word0_error : word1_error) : i_rsp_error);
    wire [15:0] halfword=pc[1] ? current_data[31:16] : current_data[15:0];
    wire [1:0] current_is_c=current_buffer_valid ? (pc[2] ? word1_is_c : word0_is_c) :
        current_pair ? i_rsp_pair_is_c : i_rsp_is_c;
    wire compressed=ENABLE_C!=0 && current_is_c[pc[1]];
    wire straddles=ENABLE_C!=0 && pc[1] && !compressed;
    wire instruction_available=current_valid && (current_error || !straddles || following_valid);
    wire output_fire=out_valid && out_ready;
    wire [29:0] incremented_word=pc[31:2]+30'd1;
    wire [31:0] next_pc={(pc[1] || !compressed ? incremented_word : pc[31:2]),pc[1]^compressed,pc[0]};
    wire [31:0] predicted_pc=predicted_taken ? predicted_target : next_pc;
    function automatic staged(input [31:0] address);
        begin
            staged=(address[2] ? word1_valid && word1_address==address : word0_valid && word0_address==address) ||
                (request_pending && !request_discard && (request_address==address || (i_rsp_pair_valid && pair_address==address)));
        end
    endfunction
    wire [31:0] ahead_address=aligned_pc+32'd8;
    wire current_staged=staged(aligned_pc);
    wire following_staged=staged(following_address);
    wire ahead_staged=staged(ahead_address);
    wire advance_word=pc[1] || !compressed;
    wire [31:0] hold_request=current_staged ? following_address : aligned_pc;
    wire hold_needed=!current_staged || !following_staged;
    wire [31:0] sequential_request=pc[1] ? (following_staged ? ahead_address : following_address) : hold_request;
    wire sequential_needed=pc[1] ? (!following_staged || !ahead_staged) : hold_needed;
    wire [31:0] target_address={predicted_target[31:2],2'b0};
    wire release_word1=out_ready && instruction_available && advance_word;
    wire [31:0] redirect_address={redirect_pc[31:2],2'b0};
    wire [31:0] accepted_request=predicted_taken ? target_address : sequential_request;
    wire accepted_needed=predicted_taken || sequential_needed;
    wire accept_staged=out_ready && current_staged && (!pc[1] || following_staged);
    wire redirect_request_valid=redirect_in_range;
    wire accepted_request_valid=accepted_needed && (accepted_request >> ADDRESS_BITS)==0;
    wire hold_request_valid=hold_needed && (hold_request >> ADDRESS_BITS)==0;
    wire [ADDRESS_BITS-1:0] selected_request=redirect_valid ? redirect_address[ADDRESS_BITS-1:0] :
        accept_staged ? accepted_request[ADDRESS_BITS-1:0] : hold_request[ADDRESS_BITS-1:0];
    assign predictor_pc=pc;
    assign out_pc=pc;
    assign out_valid=instruction_available && !redirect_valid && !invalidate;
    assign out_instruction=out_error ? (current_error ? pc : following_address) :
        compressed ? {16'b0,halfword} : straddles ? {following_data[15:0],current_data[31:16]} : current_data;
    assign out_length=compressed ? 3'd2 : 3'd4;
    assign out_prediction=predicted_pc;
    assign out_error=current_error || (straddles && following_error);
    assign i_req_valid=!invalidate && (!request_pending || response_fire) &&
        (redirect_valid ? redirect_request_valid : accept_staged ? accepted_request_valid : hold_request_valid);
    assign i_req_address={{(32-ADDRESS_BITS){1'b0}},selected_request};
    assign i_rsp_ready=request_pending;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pc<=RESET_VECTOR;
            word0_valid<=0; word1_valid<=0;
            word0_tag<=0; word1_tag<=0;
            word0_data<=0; word1_data<=0;
            word0_is_c<=2'b11; word1_is_c<=2'b11;
            word0_error<=0; word1_error<=0;
            request_pending<=0; request_discard<=0; request_tag<=0;
        end else begin
            if(redirect_valid) pc<=redirect_pc;
            else if(output_fire) pc<=predicted_pc;
            if(response_fire) begin
                request_pending<=0;
                request_discard<=0;
                if(response_usable) begin
                    if(request_address[2]) begin
                        word1_valid<=1; word1_tag<=request_tag;
                        word1_data<=i_rsp_data; word1_error<=i_rsp_error;
                        word1_is_c<=i_rsp_is_c;
                    end else begin
                        word0_valid<=1; word0_tag<=request_tag;
                        word0_data<=i_rsp_data; word0_error<=i_rsp_error;
                        word0_is_c<=i_rsp_is_c;
                        if(i_rsp_pair_valid && (!word1_valid || word1_address!=aligned_pc || release_word1)) begin
                            word1_valid<=1; word1_tag<=pair_address[ADDRESS_BITS-1:0];
                            word1_data<=i_rsp_pair_data; word1_error<=0;
                            word1_is_c<=i_rsp_pair_is_c;
                        end
                    end
                end
            end
            if(invalidate) begin
                word0_valid<=0; word1_valid<=0;
                request_discard<=request_pending && !response_fire;
            end
            if(i_req_valid && i_req_ready) begin
                request_pending<=1; request_discard<=0;
            end
            if(!request_pending || response_fire)
                request_tag<=i_req_address[ADDRESS_BITS-1:0];
        end
    end
endmodule
