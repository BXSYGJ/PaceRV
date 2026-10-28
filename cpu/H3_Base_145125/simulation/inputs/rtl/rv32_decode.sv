`timescale 1ns/1ps
module rv32_decode #(
    parameter integer ENABLE_M=0
) (
    input  wire [31:0] instruction,
    output wire [4:0] rs1,
    output wire [4:0] rs2,
    output wire [4:0] rd,
    output reg uses_rs1,
    output reg uses_rs2,
    output reg writes_rd,
    output reg [31:0] immediate,
    output reg [3:0] alu_op,
    output reg alu_immediate,
    output reg is_lui,
    output reg is_auipc,
    output reg is_branch,
    output reg is_jal,
    output reg is_jalr,
    output reg is_load,
    output reg is_store,
    output reg is_fence,
    output reg is_fence_i,
    output reg is_csr,
    output reg is_ecall,
    output reg is_ebreak,
    output reg is_mret,
    output reg is_wfi,
    output reg illegal
);
    localparam [3:0] ALU_ADD=0, ALU_SUB=1, ALU_SLL=2, ALU_SLT=3,
        ALU_SLTU=4, ALU_XOR=5, ALU_SRL=6, ALU_SRA=7, ALU_OR=8, ALU_AND=9;
    wire [6:0] opcode = instruction[6:0];
    wire [2:0] funct3 = instruction[14:12];
    wire [6:0] funct7 = instruction[31:25];
    assign rs1 = instruction[19:15];
    assign rs2 = instruction[24:20];
    assign rd = instruction[11:7];
    always @* begin
        uses_rs1=0; uses_rs2=0; writes_rd=0; immediate=0;
        alu_op=ALU_ADD; alu_immediate=0;
        is_lui=0; is_auipc=0; is_branch=0; is_jal=0; is_jalr=0;
        is_load=0; is_store=0; is_fence=0; is_fence_i=0;
        is_csr=0; is_ecall=0; is_ebreak=0; is_mret=0; is_wfi=0;
        illegal=0;
        case (opcode)
            7'h37: begin
                is_lui=1; writes_rd=1; immediate={instruction[31:12],12'b0};
            end
            7'h17: begin
                is_auipc=1; writes_rd=1; immediate={instruction[31:12],12'b0};
            end
            7'h6f: begin
                is_jal=1; writes_rd=1;
                immediate={{11{instruction[31]}},instruction[31],instruction[19:12],instruction[20],instruction[30:21],1'b0};
            end
            7'h67: begin
                is_jalr=1; writes_rd=1; uses_rs1=1;
                immediate={{20{instruction[31]}},instruction[31:20]};
                illegal=(funct3!=0);
            end
            7'h63: begin
                is_branch=1; uses_rs1=1; uses_rs2=1;
                immediate={{19{instruction[31]}},instruction[31],instruction[7],instruction[30:25],instruction[11:8],1'b0};
                illegal=(funct3==2 || funct3==3);
            end
            7'h03: begin
                is_load=1; writes_rd=1; uses_rs1=1; alu_immediate=1;
                immediate={{20{instruction[31]}},instruction[31:20]};
                illegal=!(funct3==0 || funct3==1 || funct3==2 || funct3==4 || funct3==5);
            end
            7'h23: begin
                is_store=1; uses_rs1=1; uses_rs2=1; alu_immediate=1;
                immediate={{20{instruction[31]}},instruction[31:25],instruction[11:7]};
                illegal=(funct3>2);
            end
            7'h13,7'h33: begin
                writes_rd=1; uses_rs1=1;
                uses_rs2=(opcode==7'h33); alu_immediate=(opcode==7'h13);
                immediate={{20{instruction[31]}},instruction[31:20]};
                case (funct3)
                    0: alu_op=(opcode==7'h33 && funct7==7'h20) ? ALU_SUB : ALU_ADD;
                    1: alu_op=ALU_SLL;
                    2: alu_op=ALU_SLT;
                    3: alu_op=ALU_SLTU;
                    4: alu_op=ALU_XOR;
                    5: alu_op=instruction[30] ? ALU_SRA : ALU_SRL;
                    6: alu_op=ALU_OR;
                    7: alu_op=ALU_AND;
                endcase
                if (opcode==7'h33)
                    illegal=!(funct7==0 || (ENABLE_M!=0 && funct7==1) || (funct7==7'h20 && (funct3==0 || funct3==5)));
                else if (funct3==1) illegal=(funct7!=0);
                else if (funct3==5) illegal=!(funct7==0 || funct7==7'h20);
            end
            7'h0f: begin
                is_fence=(funct3==0); is_fence_i=(funct3==1);
                illegal=!(is_fence || is_fence_i);
            end
            7'h73: begin
                if (funct3==0) begin
                    case (instruction)
                        32'h00000073: is_ecall=1;
                        32'h00100073: is_ebreak=1;
                        32'h30200073: is_mret=1;
                        32'h10500073: is_wfi=1;
                        default: illegal=1;
                    endcase
                end else if (funct3!=4) begin
                    is_csr=1; writes_rd=1; uses_rs1=!funct3[2];
                    immediate={27'b0,rs1};
                end else illegal=1;
            end
            default: illegal=1;
        endcase
        if (illegal) begin
            writes_rd=0; is_store=0; is_load=0; is_csr=0;
            is_branch=0; is_jal=0; is_jalr=0;
        end
    end
endmodule
