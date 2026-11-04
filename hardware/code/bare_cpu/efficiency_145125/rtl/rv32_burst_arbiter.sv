`timescale 1ns/1ps
module rv32_burst_arbiter (
    input wire clk,
    input wire rst_n,
    input wire a_cmd_valid,
    output wire a_cmd_ready,
    input wire a_cmd_write,
    input wire [31:0] a_cmd_address,
    input wire [7:0] a_cmd_length,
    input wire a_w_valid,
    output wire a_w_ready,
    input wire [31:0] a_w_data,
    input wire a_w_last,
    output wire a_b_valid,
    input wire a_b_ready,
    output wire a_b_error,
    output wire a_r_valid,
    input wire a_r_ready,
    output wire [31:0] a_r_data,
    output wire a_r_last,
    output wire a_r_error,
    input wire b_cmd_valid,
    output wire b_cmd_ready,
    input wire b_cmd_write,
    input wire [31:0] b_cmd_address,
    input wire [7:0] b_cmd_length,
    input wire b_w_valid,
    output wire b_w_ready,
    input wire [31:0] b_w_data,
    input wire b_w_last,
    output wire b_b_valid,
    input wire b_b_ready,
    output wire b_b_error,
    output wire b_r_valid,
    input wire b_r_ready,
    output wire [31:0] b_r_data,
    output wire b_r_last,
    output wire b_r_error,
    output wire cmd_valid,
    input wire cmd_ready,
    output reg cmd_write,
    output reg [31:0] cmd_address,
    output reg [7:0] cmd_length,
    output wire w_valid,
    input wire w_ready,
    output wire [31:0] w_data,
    output wire w_last,
    input wire b_valid,
    output wire b_ready,
    input wire b_error,
    input wire r_valid,
    output wire r_ready,
    input wire [31:0] r_data,
    input wire r_last,
    input wire r_error
);
    localparam [1:0] SELECT=0,COMMAND=1,TRANSFER=2;
    reg [1:0] state;
    reg owner,prefer_b;
    wire choose_b=b_cmd_valid && (!a_cmd_valid || prefer_b);
    wire transfer_a=state==TRANSFER && !owner;
    wire transfer_b=state==TRANSFER && owner;
    assign cmd_valid=state==COMMAND;
    assign a_cmd_ready=state==COMMAND && !owner && cmd_ready;
    assign b_cmd_ready=state==COMMAND && owner && cmd_ready;
    assign w_valid=state==TRANSFER && cmd_write && (owner ? b_w_valid : a_w_valid);
    assign w_data=owner ? b_w_data : a_w_data;
    assign w_last=owner ? b_w_last : a_w_last;
    assign a_w_ready=transfer_a && cmd_write && w_ready;
    assign b_w_ready=transfer_b && cmd_write && w_ready;
    assign a_b_valid=transfer_a && cmd_write && b_valid;
    assign b_b_valid=transfer_b && cmd_write && b_valid;
    assign a_b_error=b_error;
    assign b_b_error=b_error;
    assign b_ready=state==TRANSFER && cmd_write && (owner ? b_b_ready : a_b_ready);
    assign a_r_valid=transfer_a && !cmd_write && r_valid;
    assign b_r_valid=transfer_b && !cmd_write && r_valid;
    assign a_r_data=r_data;
    assign b_r_data=r_data;
    assign a_r_last=r_last;
    assign b_r_last=r_last;
    assign a_r_error=r_error;
    assign b_r_error=r_error;
    assign r_ready=state==TRANSFER && !cmd_write && (owner ? b_r_ready : a_r_ready);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin state<=SELECT; owner<=0; prefer_b<=0; cmd_write<=0; cmd_address<=0; cmd_length<=0; end
        else begin
            case(state)
                SELECT: if(a_cmd_valid || b_cmd_valid) begin
                    owner<=choose_b; cmd_write<=choose_b ? b_cmd_write : a_cmd_write;
                    cmd_address<=choose_b ? b_cmd_address : a_cmd_address;
                    cmd_length<=choose_b ? b_cmd_length : a_cmd_length;
                    state<=COMMAND;
                end
                COMMAND: if(cmd_ready) state<=TRANSFER;
                TRANSFER: if((cmd_write && b_valid && b_ready) || (!cmd_write && r_valid && r_ready && r_last)) begin
                    prefer_b<=!owner; state<=SELECT;
                end
                default: state<=SELECT;
            endcase
        end
    end
endmodule
