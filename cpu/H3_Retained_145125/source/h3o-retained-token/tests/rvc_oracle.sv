module rvc_oracle (
    input wire [15:0] compressed,
    output wire [31:0] actual, expected,
    output wire actual_illegal, expected_illegal
);
    rv32_rvc_expand dut(.compressed(compressed),.instruction(actual),.illegal(actual_illegal));
    ibex_compressed_decoder #(.RV32ZC(ibex_pkg::RV32Zca),.BaseIsa(ibex_pkg::BaseIsaRV32I)) reference_decoder (
        .clk_i(1'b0),.rst_ni(1'b0),.valid_i(1'b1),.id_in_ready_i(1'b1),
        .instr_i({16'b0,compressed}),.cheriot_enable_i(ibex_pkg::IbexMuBiOff),
        .instr_o(expected),.is_compressed_o(),.gets_expanded_o(),.flush_expanded_i(1'b0),
        .illegal_instr_o(expected_illegal)
    );
endmodule
