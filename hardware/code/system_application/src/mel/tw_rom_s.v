`timescale 1ns / 1ps

module tw_rom_s #(

    parameter integer AW = 10,

    parameter TW_FILE = "src/mel/twiddle_s11.hex"
) (
    input  wire        clk,
    input  wire [AW-1:0] addr,
    output reg  [31:0] q
);

    reg [31:0] rom [0:(1 << AW) - 1];

    initial begin
        $readmemh(TW_FILE, rom);
    end

    always @(posedge clk) begin
        q <= rom[addr];
    end

endmodule
