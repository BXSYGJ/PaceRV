module hann_rom #(

    parameter HAN_HEX_FILE = "hann_q15.hex"
) (
    input  wire        clk,
    input  wire [10:0] addr,
    output reg  [15:0] q
);

    reg [15:0] rom [0:2047];

    initial begin
        q = 16'd0;
        $readmemh(HAN_HEX_FILE, rom);
    end

    always @(posedge clk) begin
        q <= rom[addr];
    end

endmodule
