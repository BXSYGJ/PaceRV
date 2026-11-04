`timescale 1ns/1ps
module rv32_alu (
    input wire [31:0] operand_a,
    input wire [31:0] operand_b,
    input wire [3:0] operation,
    output reg [31:0] result
);
    wire [16:0] sum_low={1'b0,operand_a[15:0]}+{1'b0,operand_b[15:0]};
    (* syn_keep=1 *) wire [15:0] sum_high_zero;
    (* syn_keep=1 *) wire [15:0] sum_high_one;
    wire [16:0] difference_low={1'b0,operand_a[15:0]}-{1'b0,operand_b[15:0]};
    (* syn_keep=1 *) wire [15:0] difference_high_zero;
    (* syn_keep=1 *) wire [15:0] difference_high_one;
    assign sum_high_zero=operand_a[31:16]+operand_b[31:16];
    assign sum_high_one=operand_a[31:16]+operand_b[31:16]+16'd1;
    assign difference_high_zero=operand_a[31:16]-operand_b[31:16];
    assign difference_high_one=operand_a[31:16]-operand_b[31:16]-16'd1;
    wire [15:0] sum_high=sum_low[16] ? sum_high_one : sum_high_zero;
    wire [15:0] difference_high=difference_low[16] ? difference_high_one : difference_high_zero;
    always @* begin
        case (operation)
            0: result={sum_high,sum_low[15:0]};
            1: result={difference_high,difference_low[15:0]};
            2: result=operand_a<<operand_b[4:0];
            3: result={31'b0,($signed(operand_a)<$signed(operand_b))};
            4: result={31'b0,(operand_a<operand_b)};
            5: result=operand_a^operand_b;
            6: result=operand_a>>operand_b[4:0];
            7: result=$signed(operand_a)>>>operand_b[4:0];
            8: result=operand_a|operand_b;
            9: result=operand_a&operand_b;
            default: result=0;
        endcase
    end
endmodule
