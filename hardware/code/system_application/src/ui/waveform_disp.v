// -----------------------------------------------------------------------------
// File    : waveform_disp.v
// Module  : waveform_disp
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Purpose : M0 waveform-region renderer (T-M0-08, design.md sections 7.2/7.4).
//
// Region : y in [0, 300), x in [0, 1920) of the 1080p frame. One screen
//           column corresponds to one audio_sink min/max envelope pair
//           (1920 columns per 3 s window = 132096 / 1920 = 68.8 samples
//           per column, produced by T-M0-06 audio_sink).
//
// Visual elements, priority high -> low (design.md section 7.2):
//   1. waveform envelope vertical bar : green  (8'h00, 8'hFF, 8'h40),
//      drawn for pix_y in [y_top, y_bot] of the current column;
//   2. centre line (y == 150)         : dark green (8'h00, 8'h80, 8'h20),
//      brightened when mute_flag_sync is asserted (M0 mute placeholder
//      per REQ-REL-003; M3 will replace it by a text overlay);
//   3. grid lines                     : dark grey (8'h20, 8'h20, 8'h20),
//      horizontal every 50 rows (6 lines), vertical every 160 columns
//      (12 lines) -> 6 x 12 grid cells, replicating the demo grid look;
//   4. region background              : dark blue (8'h10, 8'h18, 8'h2A).
// Outside the waveform region a plain dark placeholder background is
// emitted (M0 keeps the rest of the frame undefined-but-black; M1/M3
// extend spectrum / text / bars in ui_renderer). When wave_valid is low
// the grid and centre line stay visible but no envelope bars are drawn
// ("empty grid" state while the audio_sink column buffer is not ready).
//
// Amplitude -> pixel mapping (int16 full scale onto 300 rows):
//   amp_pos = (wave_max > 0) ?  wave_max : 0;   // positive lobe, unsigned
//   amp_neg = (wave_min < 0) ? -wave_min : 0;   // negative lobe, unsigned
//   y_top   = 150 - ((amp_pos * 150) >> 15);    // inside [0, 150]
//   y_bot   = 150 + ((amp_neg * 150) >> 15);    // inside [150, 300]
// The multiplication by 150 is implemented as a shift-add tree
// (150 = 2^7 + 2^4 + 2^2 + 2^1), so amp * 150 is EXACT in integers:
//   amp*150 = (amp<<7) + (amp<<4) + (amp<<2) + (amp<<1), then >>15.
// The only quantisation error is the single floor of the final >>15,
// which is < 150/32768 ~= 1/218 pixel - far below the 0.5 pixel visual
// threshold, therefore visually lossless. |wave_min| = 32768 (min =
// -32768) is representable in 16-bit unsigned, so no overflow occurs and
// y_top / y_bot stay inside [0, 300] by construction (no clamps needed).
//
// Pixel pipeline (design.md section 7.7: lookup + selector + register,
// de/hs/vs compensated by 3 cycles in ui_renderer):
//   stage 1 (lookup, memory owned by audio_sink): wave_rd_addr is driven
//           combinationally from pix_x (no internal register on the
//           address); the column buffer returns wave_min/wave_max one
//           pix_clk cycle later;
//   stage 2 (this module, register #1): positive/negative lobe select ->
//           shift-add scale by 150 -> y_top_r / y_bot_r registers;
//   stage 3 (this module, register #2): region / envelope / grid compare
//           and colour select -> rgb output register.
// The rgb output corresponds to the pixel that appeared on pix_x / pix_y
// three pix_clk cycles earlier (address path 0 regs + memory 1 reg +
// geometry 1 reg + output 1 reg = 3 register stages).
//
// wave_rd interface contract (implemented by audio_sink in T-M0-06):
//   * wave_rd_addr is a purely combinational copy of pix_x, valid in the
//     same cycle as pix_x (i.e. while pix_de = 1). During pix_de = 0 the
//     address is don't-care and the producer may ignore it; the source
//     must feed it straight into a synchronous read port with exactly
//     1-cycle read latency (registered memory outputs);
//   * wave_min / wave_max must be valid exactly one pix_clk cycle after
//     wave_rd_addr is presented and hold for that one cycle;
//   * wave_min = smallest PCM sample of the column (int16, negative
//     lobe), wave_max = largest PCM sample of the column (int16,
//     positive lobe);
//   * wave_valid is a quasi-static level (column buffer ready flag),
//     already synchronized to the pix_clk domain by the producer;
//   * the source is a ping-pong page buffer written at 125 MHz (core
//     domain) and read here at 148.5 MHz (pix domain); page switching
//     must happen only during vertical blanking (REQ-UI-007), using the
//     vsync_pulse output of ui_renderer as the frame anchor.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module waveform_disp #(
    // Height of the waveform region in display rows (design.md 7.2).
    parameter [10:0] WAVE_REGION_ROWS = 11'd300
) (
    // Pixel clock domain (148.5 MHz, from hdmi_tx_if GPLL_B).
    input  wire        pix_clk,
    input  wire        rst_pix_n,

    // Scan coordinates from hdmi_tx_if (sync_vg outputs, registered).
    input  wire [10:0] pix_x,
    input  wire [10:0] pix_y,
    input  wire        pix_de,

    // Waveform column buffer read channel (contract in the header).
    output wire [10:0] wave_rd_addr,
    input  wire [15:0] wave_min,
    input  wire [15:0] wave_max,
    input  wire        wave_valid,

    // Mute indication (already pix-domain synchronized by producer).
    input  wire        mute_flag_sync,

    // Rendered pixel, registered, aligned with the pixel presented on
    // pix_x / pix_y three pix_clk cycles earlier.
    output reg  [23:0] rgb
);

    // -----------------------------------------------------------------
    // Colour constants (8 bits per channel, design.md 7.2 M0 palette).
    // -----------------------------------------------------------------
    localparam [23:0] COLOR_WAVE        = 24'h00_FF_40; // envelope bar green
    localparam [23:0] COLOR_CENTRE      = 24'h00_80_20; // centre line dark green
    localparam [23:0] COLOR_CENTRE_MUTE = 24'h00_C0_60; // centre line bright (mute)
    localparam [23:0] COLOR_GRID        = 24'h20_20_20; // grid dark grey
    localparam [23:0] COLOR_BG          = 24'h10_18_2A; // waveform region background
    localparam [23:0] COLOR_BG_REST     = 24'h08_08_0C; // placeholder background
    localparam [23:0] COLOR_BLANK       = 24'h00_00_00; // blanking (pix_de = 0)

    // -----------------------------------------------------------------
    // Stage 1: column address issue (combinational, no register).
    // -----------------------------------------------------------------
    assign wave_rd_addr = pix_x;

    // -----------------------------------------------------------------
    // Stage 2: envelope geometry. Inputs wave_max / wave_min are valid
    // one cycle after wave_rd_addr (1-cycle synchronous read of the
    // producer memory); everything below is combinational and is
    // captured by the y_top_r / y_bot_r registers at the end of that
    // cycle.
    // -----------------------------------------------------------------
    // Positive / negative lobe selection (sign test on int16).
    wire [15:0] amp_pos = wave_max[15] ? 16'd0 : wave_max;
    wire [15:0] amp_neg = wave_min[15] ? (~wave_min + 16'd1) : 16'd0;

    // Exact scale by 150 via shift-add (150 = 2^7 + 2^4 + 2^2 + 2^1).
    // Max value 32767 * 150 = 4'915'050 < 2^23, fits 24 bits.
    wire [23:0] pos_scaled = ({8'd0, amp_pos} << 7) + ({8'd0, amp_pos} << 4)
                           + ({8'd0, amp_pos} << 2) + ({8'd0, amp_pos} << 1);
    wire [23:0] neg_scaled = ({8'd0, amp_neg} << 7) + ({8'd0, amp_neg} << 4)
                           + ({8'd0, amp_neg} << 2) + ({8'd0, amp_neg} << 1);

    // y_top in [0, 150], y_bot in [150, 300] by construction.
    wire [8:0]  y_top = 9'd150 - pos_scaled[23:15];
    wire [8:0]  y_bot = 9'd150 + neg_scaled[23:15];

    reg  [8:0]  y_top_r;
    reg  [8:0]  y_bot_r;
    reg         wave_vld_r;
    reg         mute_r;

    always @(posedge pix_clk) begin
        if (!rst_pix_n) begin
            y_top_r   <= 9'd150;
            y_bot_r   <= 9'd150;
            wave_vld_r <= 1'b0;
            mute_r     <= 1'b0;
        end else begin
            y_top_r    <= y_top;
            y_bot_r    <= y_bot;
            wave_vld_r <= wave_valid;
            mute_r     <= mute_flag_sync;
        end
    end

    // -----------------------------------------------------------------
    // Scan coordinate pipeline: two register stages so that pix_x_d2 /
    // pix_y_d2 / pix_de_d2 are valid in the same cycle as y_top_r /
    // y_bot_r (both correspond to the pixel presented two cycles ago).
    // -----------------------------------------------------------------
    reg  [10:0] pix_x_d1;
    reg  [10:0] pix_y_d1;
    reg  [10:0] pix_x_d2;
    reg  [10:0] pix_y_d2;
    reg         pix_de_d2;

    always @(posedge pix_clk) begin
        if (!rst_pix_n) begin
            pix_x_d1  <= 11'd0;
            pix_y_d1  <= 11'd0;
            pix_x_d2  <= 11'd0;
            pix_y_d2  <= 11'd0;
            pix_de_d2 <= 1'b0;
        end else begin
            pix_x_d1  <= pix_x;
            pix_y_d1  <= pix_y;
            pix_x_d2  <= pix_x_d1;
            pix_y_d2  <= pix_y_d1;
            pix_de_d2 <= pix_de;
        end
    end

    // -----------------------------------------------------------------
    // Stage 3: element compares and colour select (combinational).
    // -----------------------------------------------------------------
    // Waveform region membership (y in [0, 300)).
    wire in_region = (pix_y_d2 < WAVE_REGION_ROWS);

    // Envelope bar hit: pixel inside [y_top_r, y_bot_r] of its column.
    wire env_hit = pix_de_d2 & wave_vld_r & in_region
                 & (pix_y_d2 >= {2'b00, y_top_r})
                 & (pix_y_d2 <= {2'b00, y_bot_r});

    // Horizontal grid lines every 50 rows: y == 0, 50, ..., 250.
    wire grid_h = (pix_y_d2 == 11'd0)   || (pix_y_d2 == 11'd50)
               || (pix_y_d2 == 11'd100) || (pix_y_d2 == 11'd150)
               || (pix_y_d2 == 11'd200) || (pix_y_d2 == 11'd250);

    // Vertical grid lines every 160 columns: x == 0, 160, ..., 1760.
    wire grid_v = (pix_x_d2 == 11'd0)    || (pix_x_d2 == 11'd160)
               || (pix_x_d2 == 11'd320)  || (pix_x_d2 == 11'd480)
               || (pix_x_d2 == 11'd640)  || (pix_x_d2 == 11'd800)
               || (pix_x_d2 == 11'd960)  || (pix_x_d2 == 11'd1120)
               || (pix_x_d2 == 11'd1280) || (pix_x_d2 == 11'd1440)
               || (pix_x_d2 == 11'd1600) || (pix_x_d2 == 11'd1760);

    // Centre line of the waveform region (y == 150, one grid row).
    wire centre_line = (pix_y_d2 == 11'd150);

    // Colour priority: blanking > region select > envelope > centre
    // line > grid > background.
    reg [23:0] rgb_next;

    always @* begin
        if (!pix_de_d2)
            rgb_next = COLOR_BLANK;
        else if (!in_region)
            rgb_next = COLOR_BG_REST;
        else if (env_hit)
            rgb_next = COLOR_WAVE;
        else if (centre_line)
            rgb_next = mute_r ? COLOR_CENTRE_MUTE : COLOR_CENTRE;
        else if (grid_h || grid_v)
            rgb_next = COLOR_GRID;
        else
            rgb_next = COLOR_BG;
    end

    // Stage 3 register: rgb aligned with the pixel of three cycles ago.
    always @(posedge pix_clk) begin
        if (!rst_pix_n)
            rgb <= COLOR_BLANK;
        else
            rgb <= rgb_next;
    end

endmodule