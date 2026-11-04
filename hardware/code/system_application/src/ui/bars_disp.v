// ---------------------------------------------------------------------------
// bars_disp.v -- 8-class probability bars for the InstRec UI (M3)
//
// Draws eight horizontal bars in a fixed region of the 1920x1080 frame.
// Bar length is pct*4 pixels (pct is 0..100, region width 400), so no
// divider is needed. The colour per class is taken from a small palette;
// unfilled parts stay transparent so the grid/wave background shows
// through.
//
// Pixel domain (148.5 MHz). One-cycle registered outputs, aligned with the
// caller's de/hs/vs delay.
// ---------------------------------------------------------------------------

module bars_disp (
    input  wire        pix_clk,
    input  wire        rst_pix_n,

    input  wire [10:0] x,
    input  wire [10:0] y,
    input  wire        de,

    // Latched probabilities (percent, 0..100).
    input  wire [7:0]  pct0,
    input  wire [7:0]  pct1,
    input  wire [7:0]  pct2,
    input  wire [7:0]  pct3,
    input  wire [7:0]  pct4,
    input  wire [7:0]  pct5,
    input  wire [7:0]  pct6,
    input  wire [7:0]  pct7,

    output reg  [23:0] rgb,
    output reg         bars_on
);

    localparam [10:0] X0 = 11'd1200;   // bar origin
    localparam [10:0] W  = 11'd400;    // 100 % width
    localparam [10:0] Y0 = 11'd700;    // first bar top
    localparam [10:0] BH = 11'd20;     // bar height
    localparam [10:0] GAP = 11'd8;     // gap between bars
    localparam [10:0] PITCH = BH + GAP;

    wire [10:0] dy = y - Y0;
    wire [10:0] dx = x - X0;

    wire in_region = (y >= Y0) && (dy < (PITCH * 8)) && (x >= X0) && (dx < W);

    // Exact slot = dy / 28 for dy < 224. A descending loop without a break
    // would be overwritten by the d=0 iteration (measured: slot always 0),
    // so use an explicit priority chain.
    reg [2:0] slot;
    always @* begin
        if      (dy >= 11'd196) slot = 3'd7;
        else if (dy >= 11'd168) slot = 3'd6;
        else if (dy >= 11'd140) slot = 3'd5;
        else if (dy >= 11'd112) slot = 3'd4;
        else if (dy >= 11'd84)  slot = 3'd3;
        else if (dy >= 11'd56)  slot = 3'd2;
        else if (dy >= 11'd28)  slot = 3'd1;
        else                    slot = 3'd0;
    end

    reg [7:0] pct;
    always @* begin
        case (slot)
            3'd0: pct = pct0;
            3'd1: pct = pct1;
            3'd2: pct = pct2;
            3'd3: pct = pct3;
            3'd4: pct = pct4;
            3'd5: pct = pct5;
            3'd6: pct = pct6;
            default: pct = pct7;
        endcase
    end

    wire [10:0] bar_len = {3'd0, pct} << 2;      // pct * 4 <= 400
    // Offset inside the slot: dy - slot*(BH+GAP).
    wire [10:0] dy_in = dy - slot * (BH + GAP);
    wire in_bar = in_region && (dy_in < BH) && (dx < bar_len);

    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            rgb     <= 24'd0;
            bars_on <= 1'b0;
        end else begin
            bars_on <= de && in_bar;
            if (in_bar) begin
                case (slot)
                    3'd0: rgb <= 24'h30_80_FF;
                    3'd1: rgb <= 24'h30_C0_60;
                    3'd2: rgb <= 24'hFF_C0_30;
                    3'd3: rgb <= 24'hFF_60_30;
                    3'd4: rgb <= 24'hC0_60_FF;
                    3'd5: rgb <= 24'h60_E0_E0;
                    3'd6: rgb <= 24'hE0_E0_60;
                    default: rgb <= 24'hFF_80_C0;
                endcase
            end else begin
                rgb <= 24'd0;
            end
        end
    end

endmodule