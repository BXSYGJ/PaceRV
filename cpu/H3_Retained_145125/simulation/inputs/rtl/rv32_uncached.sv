`timescale 1ns/1ps
module rv32_uncached #(
    parameter integer READ_ONLY=0
) (
    input wire clk,
    input wire rst_n,
    input wire req_valid,
    output wire req_ready,
    input wire [31:0] req_address,
    input wire req_write,
    input wire [31:0] req_data,
    input wire [3:0] req_strobe,
    output wire rsp_valid,
    input wire rsp_ready,
    output reg [31:0] rsp_data,
    output reg rsp_error,
    input wire flush_valid,
    output wire flush_ready,
    output wire flush_error,
    output wire cmd_valid,
    input wire cmd_ready,
    output wire cmd_write,
    output wire [31:0] cmd_address,
    output wire [7:0] cmd_length,
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
    input wire r_error,
    output wire [31:0] hit_count,
    output wire [31:0] miss_count,
    output wire [31:0] writeback_count
);
    localparam [2:0] IDLE=0,READ_CMD=1,READ_DATA=2,WRITE_CMD=3,
        WRITE_DATA=4,WRITE_ACK=5,RESPONSE=6,FLUSH_DONE=7;
    reg [2:0] state;
    reg [31:0] request_address,request_data;
    reg [3:0] request_strobe;
    reg request_write,read_failed;
    wire [31:0] byte_mask={{8{request_strobe[3]}},{8{request_strobe[2]}},{8{request_strobe[1]}},{8{request_strobe[0]}}};
    assign req_ready=state==IDLE && !flush_valid;
    assign rsp_valid=state==RESPONSE;
    assign flush_ready=state==FLUSH_DONE;
    assign flush_error=0;
    assign cmd_valid=state==READ_CMD || state==WRITE_CMD;
    assign cmd_write=state==WRITE_CMD;
    assign cmd_address=request_address;
    assign cmd_length=0;
    assign w_valid=state==WRITE_DATA;
    assign w_data=request_data;
    assign w_last=1;
    assign b_ready=state==WRITE_ACK;
    assign r_ready=state==READ_DATA;
    assign hit_count=0;
    assign miss_count=0;
    assign writeback_count=0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; request_address<=0; request_data<=0; request_strobe<=0;
            request_write<=0; read_failed<=0; rsp_data<=0; rsp_error<=0;
        end else begin
            case(state)
                IDLE: begin
                    if(flush_valid) state<=FLUSH_DONE;
                    else if(req_valid) begin
                        request_address<=req_address; request_data<=req_data;
                        request_strobe<=req_strobe; request_write<=req_write;
                        rsp_data<=0; rsp_error<=0; read_failed<=0;
                        if(req_address[1:0]!=0 || (READ_ONLY!=0 && req_write)) begin
                            rsp_error<=1; state<=RESPONSE;
                        end else if(req_write && req_strobe==0) state<=RESPONSE;
                        else if(req_write && &req_strobe) state<=WRITE_CMD;
                        else state<=READ_CMD;
                    end
                end
                READ_CMD: if(cmd_ready) state<=READ_DATA;
                READ_DATA: if(r_valid) begin
                    if(r_error || !r_last) read_failed<=1;
                    if(r_last) begin
                        if(read_failed || r_error) begin rsp_error<=1; state<=RESPONSE; end
                        else if(request_write) begin
                            request_data<=(r_data & ~byte_mask) | (request_data & byte_mask);
                            state<=WRITE_CMD;
                        end else begin rsp_data<=r_data; state<=RESPONSE; end
                    end
                end
                WRITE_CMD: if(cmd_ready) state<=WRITE_DATA;
                WRITE_DATA: if(w_ready) state<=WRITE_ACK;
                WRITE_ACK: if(b_valid) begin rsp_error<=b_error; state<=RESPONSE; end
                RESPONSE: if(rsp_ready) state<=IDLE;
                FLUSH_DONE: if(!flush_valid) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
