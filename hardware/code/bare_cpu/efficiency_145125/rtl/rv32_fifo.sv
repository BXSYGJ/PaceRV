`timescale 1ns/1ps
module rv32_fifo #(
    parameter integer WIDTH=8,
    parameter integer DEPTH_BITS=4
) (
    input wire clk,
    input wire rst_n,
    input wire in_valid,
    output wire in_ready,
    input wire [WIDTH-1:0] in_data,
    output wire out_valid,
    input wire out_ready,
    output wire [WIDTH-1:0] out_data,
    output reg [DEPTH_BITS:0] count
);
    reg [WIDTH-1:0] storage[0:(1<<DEPTH_BITS)-1];
    reg [DEPTH_BITS-1:0] read_pointer,write_pointer;
    reg occupied;
    wire pop=out_valid && out_ready;
    wire push=in_valid && in_ready;
    assign out_valid=occupied;
    assign in_ready=count!=(1<<DEPTH_BITS) || pop;
    assign out_data=storage[read_pointer];
    always @(posedge clk) begin
        if(push) storage[write_pointer]<=in_data;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin read_pointer<=0; write_pointer<=0; count<=0; occupied<=0; end
        else begin
            if(push) write_pointer<=write_pointer+1'b1;
            if(pop) read_pointer<=read_pointer+1'b1;
            case({push,pop})
                2'b10: begin count<=count+1'b1; occupied<=1; end
                2'b01: begin count<=count-1'b1; occupied<=count!=1; end
                default: begin end
            endcase
        end
    end
endmodule
