`timescale 1ns/1ps
module rvc_expand_tb;
    reg [15:0] compressed;
    wire [31:0] instruction;
    wire illegal;
    integer failures;

    rv32_rvc_expand dut(
        .compressed(compressed),
        .instruction(instruction),
        .illegal(illegal)
    );

    task automatic check_vector;
        input [15:0] compressed_value;
        input [31:0] expected_instruction;
        input expected_illegal;
        begin
            compressed = compressed_value;
            #1;
            if(instruction !== expected_instruction || illegal !== expected_illegal) begin
                $display("FAIL compressed=%h got=%h illegal=%b expected=%h illegal=%b", compressed_value, instruction, illegal, expected_instruction, expected_illegal);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        failures = 0;
        check_vector(16'h0001,32'h00000013,1'b0);
        check_vector(16'h0085,32'h00108093,1'b0);
        check_vector(16'h117d,32'hfff10113,1'b0);
        check_vector(16'h52fd,32'hfff00293,1'b0);
        check_vector(16'h6305,32'h00001337,1'b0);
        check_vector(16'h0141,32'h01010113,1'b0);
        check_vector(16'h038e,32'h00339393,1'b0);
        check_vector(16'h8009,32'h00245413,1'b0);
        check_vector(16'h8485,32'h4014d493,1'b0);
        check_vector(16'h9971,32'hffc57513,1'b0);
        check_vector(16'h95b2,32'h00c585b3,1'b0);
        check_vector(16'h8e99,32'h40e686b3,1'b0);
        check_vector(16'h8fb9,32'h00e7c7b3,1'b0);
        check_vector(16'h8fd9,32'h00e7e7b3,1'b0);
        check_vector(16'h8ff9,32'h00e7f7b3,1'b0);
        check_vector(16'h8ada,32'h01600ab3,1'b0);
        check_vector(16'h9be2,32'h018b8bb3,1'b0);
        check_vector(16'ha021,32'h0080006f,1'b0);
        check_vector(16'h2021,32'h008000ef,1'b0);
        check_vector(16'h287d,32'h0be000ef,1'b0);
        check_vector(16'hbf5d,32'hfb7ff06f,1'b0);
        check_vector(16'hc011,32'h00040263,1'b0);
        check_vector(16'he011,32'h00041263,1'b0);
        check_vector(16'hdee5,32'hfe068ce3,1'b0);
        check_vector(16'h46b2,32'h00c12683,1'b0);
        check_vector(16'h4d32,32'h00c12d03,1'b0);
        check_vector(16'hc666,32'h01912623,1'b0);
        check_vector(16'h87aa,32'h00a007b3,1'b0);
        check_vector(16'h8c52,32'h01400c33,1'b0);
        check_vector(16'h8cbe,32'h00f00cb3,1'b0);
        check_vector(16'h8082,32'h00008067,1'b0);
        check_vector(16'h9082,32'h000080e7,1'b0);
        check_vector(16'h9002,32'h00100073,1'b0);
        check_vector(16'h4080,32'h0004a403,1'b0);
        check_vector(16'hc0c0,32'h0084a223,1'b0);
        check_vector(16'h4522,32'h00812503,1'b0);
        check_vector(16'hc62a,32'h00a12623,1'b0);
        check_vector(16'h0800,32'h01010413,1'b0);
        check_vector(16'h0000,32'h00000013,1'b1);
        check_vector(16'h6001,32'h00000013,1'b1);
        check_vector(16'h6101,32'h00000013,1'b1);
        if(failures != 0) begin
            $display("RVC expansion regression FAILED failures=%0d", failures);
            $fatal(1,"RVC expansion mismatch");
        end
        $display("RVC expansion directed regression PASSED");
        $finish(0);
    end
endmodule
