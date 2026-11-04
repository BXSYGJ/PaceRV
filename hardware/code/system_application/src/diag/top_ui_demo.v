// -----------------------------------------------------------------------------
// File    : top_ui_demo.v
// Module  : top_ui_demo
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Contract: C-TOP-UI-DEMO@1 (plan revision P1, section 2.2.5)
//
// Purpose : Stand-alone UI demonstration top level (C line of the DDR3
//           unblock plan, task T7). It contains NO ddr3_wrapper, NO
//           mel_engine, NO npu_top and NO audio_pll: the whole HDMI + pixel
//           pipeline (I2C configuration, 1080p video timing, four overlay
//           layers) is driven from on-chip fake data sources, so M3 can be
//           validated on the board while the DDR3 root cause is still open.
//
//           hdmi_tx_if  ->  pix_clk / rst_pix_n / pix_x / pix_y / pix_de /
//                            pix_hs / pix_vs  ->  ui_renderer (four layers)
//           ui_renderer ->  rgb / de_out / hs_out / vs_out  ->  hdmi_tx_if
//
// Four-layer connectivity self-check list (producer -> consumer, port names)
// -----------------------------------------------------------------------------
//   Layer 1 waveform (base):
//     ui_renderer.wave_rd_addr[10:0]      -> demo_wave_source.wave_rd_addr
//     demo_wave_source.wave_min[15:0]     -> ui_renderer.wave_min
//     demo_wave_source.wave_max[15:0]     -> ui_renderer.wave_max
//     demo_wave_source.wave_valid         -> ui_renderer.wave_valid
//     (ui_renderer instantiates waveform_disp.u_waveform_disp internally;
//      WAVE_REGION_ROWS = 300, identical to the full build)
//   Layer 2 spectrum (spec):
//     ui_coord_delay u_spec_delay.x_d     -> spectrum_disp.x        (3-cyc)
//     ui_coord_delay u_spec_delay.y_d     -> spectrum_disp.y
//     ui_coord_delay u_spec_delay.de_d    -> spectrum_disp.de
//     spectrum_disp.ram_addr[14:0]        -> demo_spec_source.ram_addr
//     demo_spec_source.ram_data[7:0]      -> spectrum_disp.ram_data
//     demo_spec_source.page_ready         -> spectrum_disp.page_ready
//     spectrum_disp.rgb[23:0]             -> ui_renderer.spec_rgb
//     spectrum_disp.spec_on               -> ui_renderer.spec_on
//   Layer 3 text (class label + percentage):
//     text_x / text_y / text_de (1-cyc regs) -> text_disp.pix_x / pix_y / de
//     text_disp.class_idx (constant 4)       -> text_disp input
//     text_disp.pct       (constant 72)      -> text_disp input
//     text_disp.rgb[23:0]                    -> ui_renderer.text_rgb
//     text_disp.text_on                      -> ui_renderer.text_on
//     (text_disp instantiates font_rom internally, 2-cycle latency, hence
//      the single-cycle coordinate delay in front of it, same as
//      instrec_top.v)
//   Layer 4 probability bars:
//     ui_coord_delay u_bars_delay.x_d / y_d / de_d -> bars_disp.x / y / de
//     bars_disp.pct0..pct7 (constants 72/15/6/3/2/1/1/0) -> bars_disp inputs
//     bars_disp.rgb[23:0]                     -> ui_renderer.bars_rgb
//     bars_disp.bars_on                       -> ui_renderer.bars_on
//   Compositor and video output:
//     ui_renderer.rgb / de_out / hs_out / vs_out -> hdmi_tx_if.rgb_in /
//     de_in / hs_in / vs_in
//     hdmi_tx_if.vout_clk / vout_de / vout_hs / vout_vs / vout_data[23:0]
//     drive the HDMI pads; hdmi_tx_if.iic_tx_scl / iic_tx_sda drive the
//     transmitter I2C configuration (cfg_clk domain).
//
// Statistics (all eight fields live in the pix_clk domain, no CDC):
//   A = vsync_cnt       rising edges of pix_vs (frames seen)
//   B = pix_de_cnt      cycles with pix_de high
//   C = de_nonzero_cnt  cycles with pix_de high AND the ui_renderer rgb
//                       word non-zero (contract gate is the raw pix_de; the
//                       rgb path trails pix_de by the 4-cycle renderer
//                       latency, so C is a conservative lower bound of the
//                       non-black active pixels)
//   D = bars_on_cnt     cycles with bars_disp.bars_on high
//   E = text_on_cnt     cycles with text_disp.text_on high
//   F = spec_on_cnt     cycles with spectrum_disp.spec_on high
//   G = {4'd0, hdmi_init_fail, hdmi_init_over, pll_lock, rst_pix_n}
//   H = {3'd0, pix_de, pix_hs, pix_vs, pix_clk, rst_pix_n}
//   A..F are pix_clk counters. G has no second-domain counter either: the
//   three quasi-static status flags are re-sampled by two-flop synchronizers
//   into pix_clk first (pll_lock / init_over / init_fail), so every bit of
//   G and H is a pix_clk-domain value at capture time. The pix_clk bit of H
//   is a clock-level observation only and drives no functional logic.
//
// Diagnostic frames (C-DIAG-UART@1): frame_tag = 1 (= UIDEMO), one frame
// every 25 ms of pix_clk = 3712500 cycles (148.5 MHz), emitted only when the
// report engine is idle (fire is gated by ~busy). BAUD_DIV = 1289 for both
// diag_uart_report and uart_tx (148.5 MHz / 1289 = 115207 baud, +6 ppm).
//
// Resource estimate and build-time argument (acceptance item 11):
//   ui_renderer + waveform_disp                ~1.2 k LUT
//   spectrum_disp + text_disp + font_rom      ~1.3 k LUT
//   bars_disp                                 ~0.3 k LUT
//   hdmi_tx_if + ms72xx_ctl + sync_vg         ~1.0 k LUT
//   diag_uart_report + uart_tx                ~0.5 k LUT
//   demo sources + 8 counters + glue          ~0.2 k LUT
//   total                                     ~4.5 k LUT (about 7 percent)
//   The full instrec_top build occupies 34327 LUT (52 percent) and sits at
//   the measured routing cliff (53.57 percent passes, 53.59 percent stalls),
//   which is why E-3 forbids adding features to it in one step. This
//   bitstream uses about one seventh of that logic, far below the cliff, so
//   detail routing has no congestion pressure and the build finishes in the
//   12..20 minute class rather than the 1.5 hour full build.
//
// Constraints: constraints/top_ui_demo.fdc holds only the pins of this top
// level (clk / rst_n / key1_n / uart_tx / led / vout_* / iic_*) plus the
// clk, pix_clk and cfg_clk clock declarations and one set_clock_groups.
// ddr3_100h.fdc is NOT loaded: this top level has no ref_clk and no mem_*
// ports.
//
// key1_n is kept only so the copied pin table of instrec_top.fdc stays
// complete; it drives no logic in this design.
//
// No string literals anywhere (PDS string-literal byte order is not
// reproducible). SV-2005 subset only: always @(posedge clk or negedge rst_n)
// and always @*, no always_ff / always_comb / logic / interface / unique.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module top_ui_demo (
    // 27 MHz board crystal (pin D18), GPLL_B reference.
    input  wire        clk,
    // KEY0 asynchronous board reset (pin C22, active low).
    input  wire        rst_n,
    // KEY1 (pin C23): reserved, not used by this design.
    input  wire        key1_n,

    // Status LEDs (A20 / C18 / C19 / E18 / A17 / A18 / C17 / B17).
    output wire [7:0]  led,
    // 115200 8N1 diagnostic UART (pin C24).
    output wire        uart_tx,

    // HDMI transmitter I2C configuration pads (K22 / K23).
    output wire        iic_tx_scl,
    inout  wire        iic_tx_sda,

    // HDMI parallel video pads.
    output wire        vout_clk,     // T24
    output wire        vout_de,      // N19
    output wire        vout_hs,      // R20
    output wire        vout_vs,      // R21
    output wire [23:0] vout_data     // P16, K25, K26, L24 ... P19
);

    // ------------------------------------------------------------------
    // Constants (contract section 2.2.5).
    // ------------------------------------------------------------------
    // Frame period: 3712500 pix_clk cycles = 25 ms at 148.5 MHz
    // (22 bits, 3712500 < 2^22 = 4194304).
    localparam [21:0] FIRE_PERIOD = 22'd3712500;

    // Latched class probabilities, percent (single dominant class 4).
    localparam [7:0] PCT_CLASS0 = 8'd72;
    localparam [7:0] PCT_CLASS1 = 8'd15;
    localparam [7:0] PCT_CLASS2 = 8'd6;
    localparam [7:0] PCT_CLASS3 = 8'd3;
    localparam [7:0] PCT_CLASS4 = 8'd2;
    localparam [7:0] PCT_CLASS5 = 8'd1;
    localparam [7:0] PCT_CLASS6 = 8'd1;
    localparam [7:0] PCT_CLASS7 = 8'd0;

    // Top-1 class index and its percentage for the text layer.
    localparam [7:0] TEXT_CLASS_IDX = 8'd4;
    localparam [7:0] TEXT_PCT       = 8'd72;

    // ------------------------------------------------------------------
    // hdmi_tx_if pixel-domain outputs.
    // ------------------------------------------------------------------
    wire        pix_clk;
    wire        rst_pix_n;
    wire [10:0] pix_x;
    wire [10:0] pix_y;
    wire        pix_de;
    wire        pix_hs;
    wire        pix_vs;

    // Quasi-static status flags from hdmi_tx_if (cfg_clk / GPLL domain).
    wire        hdmi_init_over;
    wire        hdmi_init_fail;
    wire        hdmi_pll_lock;

    // ------------------------------------------------------------------
    // Rendered video returned by ui_renderer.
    // ------------------------------------------------------------------
    wire [23:0] ui_rgb;
    wire        ui_de;
    wire        ui_hs;
    wire        ui_vs;

    // ------------------------------------------------------------------
    // Layer 1: waveform read channel (fake envelope source).
    // ------------------------------------------------------------------
    wire [10:0] wave_rd_addr;
    wire [15:0] wave_min;
    wire [15:0] wave_max;
    wire        wave_valid;
    wire        ui_vsync_pulse;      // frame anchor, observed only here

    // ------------------------------------------------------------------
    // Layer 4: probability bars.
    // ------------------------------------------------------------------
    wire [10:0] bars_x;
    wire [10:0] bars_y;
    wire        bars_de;
    wire [23:0] bars_rgb;
    wire        bars_on;

    // ------------------------------------------------------------------
    // Layer 3: class text (one-cycle coordinate delay, as in instrec_top).
    // ------------------------------------------------------------------
    reg  [10:0] text_x;
    reg  [10:0] text_y;
    reg         text_de;
    wire [23:0] text_rgb;
    wire        text_on;

    // ------------------------------------------------------------------
    // Layer 2: Mel spectrogram (fake page).
    // ------------------------------------------------------------------
    wire [10:0] spec_x;
    wire [10:0] spec_y;
    wire        spec_de;
    wire [14:0] spec_ram_addr;
    wire [7:0]  spec_ram_data;
    wire        spec_page_ready;
    wire [23:0] spec_rgb;
    wire        spec_on;

    // ------------------------------------------------------------------
    // Diagnostic report path (pix_clk domain).
    // ------------------------------------------------------------------
    wire [7:0]  report_tx_data;
    wire        report_tx_valid;
    wire        report_tx_ready;
    wire        report_busy;

    // ------------------------------------------------------------------
    // Statistics counters (all pix_clk domain).
    // ------------------------------------------------------------------
    reg  [31:0] vsync_cnt;
    reg  [31:0] pix_de_cnt;
    reg  [31:0] de_nonzero_cnt;
    reg  [31:0] bars_on_cnt;
    reg  [31:0] text_on_cnt;
    reg  [31:0] spec_on_cnt;

    reg         vs_d;                // pix_vs one-cycle delay
    wire        vs_rise;

    // Two-flop synchronizers for the quasi-static HDMI status flags, so the
    // G field is a pure pix_clk-domain value (zero-CDC statistics).
    reg  [1:0]  pll_lock_sync;
    reg  [1:0]  init_over_sync;
    reg  [1:0]  init_fail_sync;
    wire        pll_lock_pix;
    wire        init_over_pix;
    wire        init_fail_pix;

    // Packed status bytes for the diagnostic frame.
    wire [7:0]  f_g;
    wire [7:0]  f_h;

    // Report period counter and the accepted one-cycle fire request.
    reg  [21:0] fire_cnt;
    wire        fire_due;
    wire        fire_req;

    // ==================================================================
    // HDMI transmitter front end (GPLL_B + I2C configuration + video pads).
    // ==================================================================
    hdmi_tx_if u_hdmi_tx_if (
        .clk_27m        ( clk             ),
        .rst_n          ( rst_n           ),
        .pix_clk        ( pix_clk         ),
        .rst_pix_n      ( rst_pix_n       ),
        .pix_x          ( pix_x           ),
        .pix_y          ( pix_y           ),
        .pix_de         ( pix_de          ),
        .pix_hs         ( pix_hs          ),
        .pix_vs         ( pix_vs          ),
        .rgb_in         ( ui_rgb          ),
        .de_in          ( ui_de           ),
        .hs_in          ( ui_hs           ),
        .vs_in          ( ui_vs           ),
        .vout_clk       ( vout_clk        ),
        .vout_de        ( vout_de         ),
        .vout_hs        ( vout_hs         ),
        .vout_vs        ( vout_vs         ),
        .vout_data      ( vout_data       ),
        .iic_tx_scl     ( iic_tx_scl      ),
        .iic_tx_sda     ( iic_tx_sda      ),
        .hdmi_init_over ( hdmi_init_over  ),
        .hdmi_init_fail ( hdmi_init_fail  ),
        .pll_lock       ( hdmi_pll_lock   )
    );

    // ==================================================================
    // Fake data sources (on chip, no DDR3 / Mel / NPU).
    // ==================================================================
    demo_wave_source u_demo_wave (
        .pix_clk      ( pix_clk       ),
        .rst_pix_n    ( rst_pix_n     ),
        .wave_rd_addr ( wave_rd_addr  ),
        .wave_min     ( wave_min      ),
        .wave_max     ( wave_max      ),
        .wave_valid   ( wave_valid    )
    );

    demo_spec_source u_demo_spec (
        .pix_clk    ( pix_clk        ),
        .rst_pix_n  ( rst_pix_n      ),
        .ram_addr   ( spec_ram_addr  ),
        .ram_data   ( spec_ram_data  ),
        .page_ready ( spec_page_ready )
    );


    // ==================================================================
    // Layer 4: probability bars (3-cycle coordinate delay to match the
    // waveform base layer, same wiring as instrec_top.v).
    // ==================================================================
    ui_coord_delay u_bars_delay (
        .pix_clk   ( pix_clk    ),
        .rst_pix_n ( rst_pix_n  ),
        .x         ( pix_x      ),
        .y         ( pix_y      ),
        .de        ( pix_de     ),
        .x_d       ( bars_x     ),
        .y_d       ( bars_y     ),
        .de_d      ( bars_de    )
    );

    bars_disp u_bars_disp (
        .pix_clk   ( pix_clk    ),
        .rst_pix_n ( rst_pix_n  ),
        .x         ( bars_x     ),
        .y         ( bars_y     ),
        .de        ( bars_de    ),
        .pct0      ( PCT_CLASS0 ),
        .pct1      ( PCT_CLASS1 ),
        .pct2      ( PCT_CLASS2 ),
        .pct3      ( PCT_CLASS3 ),
        .pct4      ( PCT_CLASS4 ),
        .pct5      ( PCT_CLASS5 ),
        .pct6      ( PCT_CLASS6 ),
        .pct7      ( PCT_CLASS7 ),
        .rgb       ( bars_rgb   ),
        .bars_on   ( bars_on    )
    );

    // ==================================================================
    // Layer 3: class label text (text_disp already costs 2 cycles, so the
    // coordinates are delayed by one cycle, exactly as in instrec_top.v).
    // ==================================================================
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            text_x  <= 11'd0;
            text_y  <= 11'd0;
            text_de <= 1'b0;
        end else begin
            text_x  <= pix_x;
            text_y  <= pix_y;
            text_de <= pix_de;
        end
    end

    text_disp u_text_disp (
        .pix_clk   ( pix_clk        ),
        .rst_pix_n ( rst_pix_n      ),
        .pix_x     ( text_x         ),
        .pix_y     ( text_y         ),
        .de        ( text_de        ),
        .class_idx ( TEXT_CLASS_IDX ),
        .pct       ( TEXT_PCT       ),
        .rgb       ( text_rgb       ),
        .text_on   ( text_on        )
    );

    // ==================================================================
    // Layer 2: Mel spectrogram shader (3-cycle coordinate delay as well).
    // ==================================================================
    ui_coord_delay u_spec_delay (
        .pix_clk   ( pix_clk    ),
        .rst_pix_n ( rst_pix_n  ),
        .x         ( pix_x      ),
        .y         ( pix_y      ),
        .de        ( pix_de     ),
        .x_d       ( spec_x     ),
        .y_d       ( spec_y     ),
        .de_d      ( spec_de    )
    );

    spectrum_disp u_spectrum (
        .pix_clk    ( pix_clk         ),
        .rst_pix_n  ( rst_pix_n       ),
        .x          ( spec_x          ),
        .y          ( spec_y          ),
        .de         ( spec_de         ),
        .ram_addr   ( spec_ram_addr   ),
        .ram_data   ( spec_ram_data   ),
        .page_ready ( spec_page_ready ),
        .rgb        ( spec_rgb        ),
        .spec_on    ( spec_on         )
    );

    // ==================================================================
    // UI renderer: waveform base layer + overlay compositor.
    // ==================================================================
    // WAVE_REGION_ROWS = 300, identical to the full instrec_top build.
    ui_renderer #(
        .WAVE_REGION_ROWS ( 11'd300 )
    ) u_ui_renderer (
        .pix_clk        ( pix_clk        ),
        .rst_pix_n      ( rst_pix_n      ),
        .pix_x          ( pix_x          ),
        .pix_y          ( pix_y          ),
        .pix_de         ( pix_de         ),
        .pix_hs         ( pix_hs         ),
        .pix_vs         ( pix_vs         ),
        .wave_rd_addr   ( wave_rd_addr   ),
        .wave_min       ( wave_min       ),
        .wave_max       ( wave_max       ),
        .wave_valid     ( wave_valid     ),
        .mute_flag_sync ( 1'b0           ),
        .vsync_pulse    ( ui_vsync_pulse ),
        .spec_rgb       ( spec_rgb       ),
        .spec_on        ( spec_on        ),
        .text_rgb       ( text_rgb       ),
        .text_on        ( text_on        ),
        .bars_rgb       ( bars_rgb       ),
        .bars_on        ( bars_on        ),
        .rgb            ( ui_rgb         ),
        .de_out         ( ui_de          ),
        .hs_out         ( ui_hs          ),
        .vs_out         ( ui_vs          )
    );

    // ==================================================================
    // Statistics: every counter below is clocked by pix_clk only.
    // ==================================================================
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            vsync_cnt      <= 32'd0;
            pix_de_cnt     <= 32'd0;
            de_nonzero_cnt <= 32'd0;
            bars_on_cnt    <= 32'd0;
            text_on_cnt    <= 32'd0;
            spec_on_cnt    <= 32'd0;
        end else begin
            if (vs_rise)
                vsync_cnt <= vsync_cnt + 32'd1;
            if (pix_de)
                pix_de_cnt <= pix_de_cnt + 32'd1;
            if (pix_de && (ui_rgb != 24'd0))
                de_nonzero_cnt <= de_nonzero_cnt + 32'd1;
            if (bars_on)
                bars_on_cnt <= bars_on_cnt + 32'd1;
            if (text_on)
                text_on_cnt <= text_on_cnt + 32'd1;
            if (spec_on)
                spec_on_cnt <= spec_on_cnt + 32'd1;
        end
    end

    // pix_vs rising edge detector (frame start marker).
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n)
            vs_d <= 1'b0;
        else
            vs_d <= pix_vs;
    end

    assign vs_rise = pix_vs & ~vs_d;

    // Quasi-static HDMI status flags into the pixel domain (2-flop each).
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            pll_lock_sync  <= 2'b00;
            init_over_sync <= 2'b00;
            init_fail_sync <= 2'b00;
        end else begin
            pll_lock_sync  <= { pll_lock_sync[0],  hdmi_pll_lock  };
            init_over_sync <= { init_over_sync[0], hdmi_init_over };
            init_fail_sync <= { init_fail_sync[0], hdmi_init_fail };
        end
    end

    assign pll_lock_pix  = pll_lock_sync[1];
    assign init_over_pix = init_over_sync[1];
    assign init_fail_pix = init_fail_sync[1];

    // G field, contract packing:
    //   {4'd0, hdmi_init_fail, hdmi_init_over, pll_lock, rst_pix_n}
    // bit3 = init_fail, bit2 = init_over, bit1 = pll_lock, bit0 = the
    // pixel-domain reset level. The three status flags are the 2-flop
    // pixel-domain synchronizer outputs (init_fail_pix / init_over_pix /
    // pll_lock_pix), so every bit of G is a pix_clk-domain value.
    assign f_g = { 4'd0, init_fail_pix, init_over_pix, pll_lock_pix, rst_pix_n };

    // H field, contract packing:
    //   {3'd0, pix_de, pix_hs, pix_vs, pix_clk, rst_pix_n}
    // The pix_clk bit observes the clock level only; no functional logic
    // consumes it. Every other bit is a pix_clk-domain register output.
    assign f_h = { 3'd0, pix_de, pix_hs, pix_vs, pix_clk, rst_pix_n };

    // LED report: init flags plus a frame-rate heartbeat.
    assign led = { init_over_pix, init_fail_pix, 5'b00000, vsync_cnt[6] };

    // ==================================================================
    // Diagnostic UART frame engine (UIDEMO, every 25 ms of pix_clk).
    // ==================================================================
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n)
            fire_cnt <= 22'd0;
        else if (fire_due)
            fire_cnt <= 22'd0;
        else
            fire_cnt <= fire_cnt + 22'd1;
    end

    assign fire_due = (fire_cnt == FIRE_PERIOD - 22'd1);
    assign fire_req = fire_due & ~report_busy;

    diag_uart_report #(
        .BAUD_DIV ( 1289 )
    ) u_report (
        .clk           ( pix_clk        ),
        .rst_n         ( rst_pix_n      ),
        .fire          ( fire_req       ),
        .frame_tag     ( 2'd1           ),
        .f_a           ( vsync_cnt      ),
        .f_b           ( pix_de_cnt     ),
        .f_c           ( de_nonzero_cnt ),
        .f_d           ( bars_on_cnt    ),
        .f_e           ( text_on_cnt    ),
        .f_f           ( spec_on_cnt    ),
        .f_g           ( f_g            ),
        .f_h           ( f_h            ),
        .busy          ( report_busy    ),
        .tx_byte_data  ( report_tx_data ),
        .tx_byte_valid ( report_tx_valid ),
        .tx_byte_ready ( report_tx_ready )
    );

    uart_tx #(
        .BAUD_DIV ( 1289 )
    ) u_uart_tx (
        .clk         ( pix_clk        ),
        .rst_n       ( rst_pix_n      ),
        .byte_wdata  ( report_tx_data ),
        .byte_wvalid ( report_tx_valid ),
        .byte_wready ( report_tx_ready ),
        .uart_txd    ( uart_tx        )
    );

endmodule