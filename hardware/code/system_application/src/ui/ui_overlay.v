// ---------------------------------------------------------------------------
// ui_overlay.v -- layer compositor for the InstRec UI (M3)
//
// Priority: probability bars > class text > spectrogram > base layer
// (grid + waveform). The text label sits above the spectrogram but below
// the probability bars so a bar never covers the class name.
// All inputs are registered by their own modules in the same pix_clk
// domain and carry an "on" flag aligned with their RGB. The composer adds
// one register stage so the caller's de/hs/vs delay grows by exactly one.
// ---------------------------------------------------------------------------

module ui_overlay (
    input  wire        pix_clk,
    input  wire        rst_pix_n,

    input  wire        de,
    input  wire [23:0] base_rgb,
    input  wire        base_on,

    input  wire [23:0] spec_rgb,
    input  wire        spec_on,

    input  wire [23:0] text_rgb,
    input  wire        text_on,

    input  wire [23:0] bars_rgb,
    input  wire        bars_on,

    output reg  [23:0] rgb,
    output reg         de_out
);

    reg [23:0] mix;

    always @* begin
        if (bars_on)      mix = bars_rgb;
        else if (text_on) mix = text_rgb;
        else if (spec_on) mix = spec_rgb;
        else if (base_on) mix = base_rgb;
        else              mix = 24'h00_00_00;
    end

    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            rgb    <= 24'd0;
            de_out <= 1'b0;
        end else begin
            rgb    <= mix;
            de_out <= de;
        end
    end

endmodule