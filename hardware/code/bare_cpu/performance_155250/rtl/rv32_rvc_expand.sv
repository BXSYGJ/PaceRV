`timescale 1ns/1ps
module rv32_rvc_expand (
    input wire [15:0] compressed,
    output reg [31:0] instruction,
    output reg illegal
);
    wire [1:0] quadrant=compressed[1:0];
    wire [2:0] funct3=compressed[15:13];
    wire [4:0] rd=compressed[11:7];
    wire [4:0] rs2=compressed[6:2];
    wire [4:0] rd_prime={2'b01,compressed[4:2]};
    wire [4:0] rs1_prime={2'b01,compressed[9:7]};
    wire [4:0] rs2_prime={2'b01,compressed[4:2]};
    wire [4:0] rs2_alt={2'b01,compressed[4:2]};
    reg [11:0] immediate;
    reg [12:0] branch_immediate;
    reg [20:0] jump_immediate;
    reg [6:0] function7;
    reg [2:0] function3;
    reg [31:0] encoded;

    always @* begin
        instruction=32'h00000013;
        illegal=0;
        immediate=0;
        branch_immediate=0;
        jump_immediate=0;
        function7=0;
        function3=0;
        encoded=32'h00000013;
        case(quadrant)
            2'b00: begin
                case(funct3)
                    3'b000: begin
                        immediate={2'b0,compressed[10:7],compressed[12:11],compressed[5],compressed[6],2'b0};
                        if(immediate==0) illegal=1;
                        encoded={immediate,5'd2,3'b000,rd_prime,7'h13};
                    end
                    3'b010: begin
                        immediate={5'b0,compressed[5],compressed[12:10],compressed[6],2'b0};
                        encoded={immediate,rs1_prime,3'b010,rd_prime,7'h03};
                    end
                    3'b110: begin
                        immediate={5'b0,compressed[5],compressed[12:10],compressed[6],2'b0};
                        encoded={immediate[11:5],rs2_prime,rs1_prime,3'b010,immediate[4:0],7'h23};
                    end
                    default: illegal=1;
                endcase
            end
            2'b01: begin
                case(funct3)
                    3'b000: begin
                        immediate={{6{compressed[12]}},compressed[12],compressed[6:2]};
                        encoded={immediate,rd,3'b000,rd,7'h13};
                    end
                    3'b001: begin
                        jump_immediate={{9{compressed[12]}},compressed[12],compressed[8],compressed[10:9],compressed[6],compressed[7],compressed[2],compressed[11],compressed[5:3],1'b0};
                        encoded={jump_immediate[20],jump_immediate[10:1],jump_immediate[11],jump_immediate[19:12],5'd1,7'h6f};
                    end
                    3'b010: begin
                        immediate={{6{compressed[12]}},compressed[12],compressed[6:2]};
                        encoded={immediate,5'd0,3'b000,rd,7'h13};
                    end
                    3'b011: begin
                        if(rd==5'd2) begin
                            immediate={{2{compressed[12]}},compressed[12],compressed[4:3],compressed[5],compressed[2],compressed[6],4'b0};
                            if(immediate==0) illegal=1;
                            encoded={immediate,5'd2,3'b000,5'd2,7'h13};
                        end else begin
                            if({compressed[12],compressed[6:2]}==0) illegal=1;
                            encoded={{14{compressed[12]}},compressed[12],compressed[6:2],rd,7'h37};
                        end
                    end
                    3'b100: begin
                        case(compressed[11:10])
                            2'b00: begin
                                if(compressed[12]) illegal=1;
                                immediate={7'b0,compressed[6:2]};
                                encoded={7'b0000000,immediate[4:0],rs1_prime,3'b101,rs1_prime,7'h13};
                            end
                            2'b01: begin
                                if(compressed[12]) illegal=1;
                                immediate={7'b0,compressed[6:2]};
                                encoded={7'b0100000,immediate[4:0],rs1_prime,3'b101,rs1_prime,7'h13};
                            end
                            2'b10: begin
                                immediate={{6{compressed[12]}},compressed[12],compressed[6:2]};
                                encoded={immediate,rs1_prime,3'b111,rs1_prime,7'h13};
                            end
                            2'b11: begin
                                if(compressed[12]) illegal=1;
                                function7=compressed[6:5]==2'b00 ? 7'b0100000 : 7'b0000000;
                                function3=compressed[6:5]==2'b00 ? 3'b000 :
                                    compressed[6:5]==2'b01 ? 3'b100 :
                                    compressed[6:5]==2'b10 ? 3'b110 : 3'b111;
                                encoded={function7,rs2_alt,rs1_prime,function3,rs1_prime,7'h33};
                            end
                        endcase
                    end
                    3'b101: begin
                        jump_immediate={{9{compressed[12]}},compressed[12],compressed[8],compressed[10:9],compressed[6],compressed[7],compressed[2],compressed[11],compressed[5:3],1'b0};
                        encoded={jump_immediate[20],jump_immediate[10:1],jump_immediate[11],jump_immediate[19:12],5'd0,7'h6f};
                    end
                    3'b110: begin
                        branch_immediate={{4{compressed[12]}},compressed[12],compressed[6:5],compressed[2],compressed[11:10],compressed[4:3],1'b0};
                        encoded={branch_immediate[12],branch_immediate[10:5],5'd0,rs1_prime,3'b000,branch_immediate[4:1],branch_immediate[11],7'h63};
                    end
                    3'b111: begin
                        branch_immediate={{4{compressed[12]}},compressed[12],compressed[6:5],compressed[2],compressed[11:10],compressed[4:3],1'b0};
                        encoded={branch_immediate[12],branch_immediate[10:5],5'd0,rs1_prime,3'b001,branch_immediate[4:1],branch_immediate[11],7'h63};
                    end
                endcase
            end
            2'b10: begin
                case(funct3)
                    3'b000: begin
                        if(compressed[12]) illegal=1;
                        immediate={7'b0,compressed[6:2]};
                        encoded={7'b0000000,immediate[4:0],rd,3'b001,rd,7'h13};
                    end
                    3'b010: begin
                        if(rd==0) illegal=1;
                        immediate={4'b0,compressed[3:2],compressed[12],compressed[6:4],2'b0};
                        encoded={immediate,5'd2,3'b010,rd,7'h03};
                    end
                    3'b100: begin
                        if(!compressed[12]) begin
                            if(rs2==0 && rd==0) illegal=1;
                            else if(rs2==0) encoded={12'b0,rd,3'b000,5'd0,7'h67};
                            else encoded={7'b0000000,rs2,5'd0,3'b000,rd,7'h33};
                        end else begin
                            if(rd==0 && rs2==0) encoded=32'h00100073;
                            else if(rs2==0) encoded={12'b0,rd,3'b000,5'd1,7'h67};
                            else encoded={7'b0000000,rs2,rd,3'b000,rd,7'h33};
                        end
                    end
                    3'b110: begin
                        immediate={4'b0,compressed[8:7],compressed[12:9],2'b0};
                        encoded={immediate[11:5],rs2,5'd2,3'b010,immediate[4:0],7'h23};
                    end
                    default: illegal=1;
                endcase
            end
            default: illegal=1;
        endcase
        if(!illegal) instruction=encoded;
    end
endmodule
