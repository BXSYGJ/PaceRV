// ---------------------------------------------------------------------------
// spectrum_disp.v -- Mel spectrogram overlay (M3, design.md 7.2)
//
// Maps a 258 x 64 uint8 Mel feature page onto a 512 x 256 window:
//   col = (x - X0) * 258 / 512   (approximated by a shift/multiply)
//   row = (y - Y0) * 64  / 256
// The page RAM is external (double-buffered by the caller, written in the
// core_clk domain). This module only issues a synchronous read address and
// colours the returned byte with a 5-stop heat map.
//
// Pixel domain (148.5 MHz). Registered RGB + on flag, aligned with the
// caller's de delay.
// ---------------------------------------------------------------------------

module spectrum_disp (
    input  wire        pix_clk,
    input  wire        rst_pix_n,

    input  wire [10:0] x,
    input  wire [10:0] y,
    input  wire        de,

    // page RAM read port (synchronous, 1-cycle)
    output reg  [14:0] ram_addr,
    input  wire [7:0]  ram_data,
    input  wire        page_ready,

    output reg  [23:0] rgb,
    output reg         spec_on
);

    localparam [10:0] X0 = 11'd80;
    localparam [10:0] Y0 = 11'd80;
    localparam [10:0] WD = 11'd512;
    localparam [10:0] HT = 11'd256;

    wire in_region = (x >= X0) && (x < X0 + WD) && (y >= Y0) && (y < Y0 + HT);

    // col = dx * 258 / 512  == (dx * 258) >> 9; dx < 512 -> product < 132096
    wire [10:0] dx = x - X0;
    wire [10:0] dy = y - Y0;
    wire [17:0] col_p = dx * 11'd258;
    wire [10:0] col   = col_p[17:9];

    // row = dy * 64 / 256 == dy >> 2; dy < 256 -> 0..63
    wire [5:0] row = dy[7:2];

    // Address in the (row-major 64 x 258) page.
    // row*258 + col = row*256 + row*2 + col
    wire [14:0] addr_c = {row, 8'd0} + {8'd0, row, 1'd0} + {6'd0, col};

    // 5-stop heat map on the 8-bit value.
    reg [23:0] colour;
    reg on_p1;
    reg on_p2;
    always @* begin
        if (ram_data < 8'd32)        colour = 24'h00_00_20;
        else if (ram_data < 8'd96)   colour = 24'h00_20_80;
        else if (ram_data < 8'd160)  colour = 24'h00_A0_C0;
        else if (ram_data < 8'd224)  colour = 24'hE0_C0_40;
        else                         colour = 24'hFF_FF_E0;
    end

    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            ram_addr <= 15'd0;
            rgb      <= 24'd0;
            spec_on  <= 1'b0;
            on_p1 <= 1'b0;
            on_p2 <= 1'b0;
        end else begin
            if (in_region && de) ram_addr <= addr_c;
            // Address register, external RAM read, then colour register.
            // Delay validity by the same three pixel edges.
            on_p1 <= de && in_region && page_ready;
            on_p2 <= on_p1;
            spec_on <= on_p2;
            rgb     <= colour;
        end
    end

endmodule
