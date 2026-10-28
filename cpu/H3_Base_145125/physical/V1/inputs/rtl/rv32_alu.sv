`timescale 1ns/1ps
module rv32_alu (
    input wire [31:0] operand_a,
    input wire [31:0] operand_b,
    input wire [3:0] operation,
    output reg [31:0] result
);
    // One arithmetic cone serves ADD, SUB, SLT and SLTU.
    wire subtract=operation==1 || operation==3 || operation==4;
    wire [31:0] arithmetic_b=operand_b ^ {32{subtract}};
    wire [32:0] arithmetic_result={1'b0,operand_a}+{1'b0,arithmetic_b}+{32'b0,subtract};
    wire unsigned_less=!arithmetic_result[32];
    wire signed_less=(operand_a[31]^operand_b[31]) ? operand_a[31] : arithmetic_result[31];
    wire shift_left=operation==2;
    wire [31:0] reversed_operand,shift_operand;
    wire signed [32:0] extended_shift_operand;
    wire [31:0] shifted_operand;
    wire unused_shifted_sign;
    wire [31:0] reversed_shifted,shift_result;
    generate for(genvar shift_bit=0;shift_bit<32;shift_bit=shift_bit+1) begin: shift_reverse
        assign reversed_operand[shift_bit]=operand_a[31-shift_bit];
        assign reversed_shifted[shift_bit]=shifted_operand[31-shift_bit];
    end endgenerate
    assign shift_operand=shift_left ? reversed_operand : operand_a;
    assign extended_shift_operand={operation==7 ? operand_a[31] : 1'b0,shift_operand};
    assign {unused_shifted_sign,shifted_operand}=extended_shift_operand>>>operand_b[4:0];
    assign shift_result=shift_left ? reversed_shifted : shifted_operand[31:0];
    always @* begin
        case (operation)
            0,1: result=arithmetic_result[31:0];
            2,6,7: result=shift_result;
            3: result={31'b0,signed_less};
            4: result={31'b0,unsigned_less};
            5: result=operand_a^operand_b;
            8: result=operand_a|operand_b;
            9: result=operand_a&operand_b;
            default: result=0;
        endcase
    end
endmodule
