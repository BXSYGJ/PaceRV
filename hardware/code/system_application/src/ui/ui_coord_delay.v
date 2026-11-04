// ---------------------------------------------------------------------------
// ui_coord_delay.v -- pixel-coordinate delay for overlay layers (M3)
//
// waveform_disp renders through a 3-stage pipeline, so its RGB corresponds
// to the pixel seen 3 cycles earlier. The bar/spectrum overlays read the
// raw pix_x/pix_y, so they must delay their coordinates by the same 3
// cycles before colouring. This module is that shift register.
// ---------------------------------------------------------------------------

module ui_coord_delay #(
    parameter integer DELAY = 3
) (
    input  wire        pix_clk,
    input  wire        rst_pix_n,
    input  wire [10:0] x,
    input  wire [10:0] y,
    input  wire        de,
    output reg  [10:0] x_d,
    output reg  [10:0] y_d,
    output reg         de_d
);

    reg [10:0] x_p1, x_p2;
    reg [10:0] y_p1, y_p2;
    reg        de_p1, de_p2;

    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            x_p1 <= 11'd0; x_p2 <= 11'd0; x_d <= 11'd0;
            y_p1 <= 11'd0; y_p2 <= 11'd0; y_d <= 11'd0;
            de_p1 <= 1'b0; de_p2 <= 1'b0; de_d <= 1'b0;
        end else begin
            x_p1 <= x;  x_p2 <= x_p1;
            y_p1 <= y;  y_p2 <= y_p1;
            de_p1 <= de; de_p2 <= de_p1;
            x_d <= (DELAY == 1) ? x : (DELAY == 2) ? x_p1 : x_p2;
            y_d <= (DELAY == 1) ? y : (DELAY == 2) ? y_p1 : y_p2;
            de_d <= (DELAY == 1) ? de : (DELAY == 2) ? de_p1 : de_p2;
        end
    end

endmodule
