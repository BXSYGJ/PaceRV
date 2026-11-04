// -----------------------------------------------------------------------------
// File    : ui_renderer.v
// Module  : ui_renderer
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Purpose : M0 UI integration layer (T-M0-08, design.md sections 7.1/7.7).
//
//           Consumes the pix_clk-domain timing outputs of hdmi_tx_if
//           (pix_x / pix_y / pix_de / pix_hs / pix_vs, all registered
//           outputs of sync_vg) and produces the rendered 24-bit RGB
//           stream plus the aligned de / hs / vs control signals that
//           feed the hdmi_tx_if rgb_in / de_in / hs_in / vs_in inputs.
//
//           M0 subset: waveform_disp is the only display sub-module
//           (waveform region + grid, design.md 7.2 zone 1). M1/M3 will
//           add spectrum_disp / font_rom / bars_disp as sibling stages
//           inside the same pixel pipeline.
//
// Pixel pipeline and alignment (design.md section 7.7):
//   The waveform path inside waveform_disp is a 3-stage pipeline
//   (memory lookup 1 reg + envelope geometry 1 reg + output register,
//   see its header), so its rgb output corresponds to the pixel that
//   appeared on pix_x / pix_y three pix_clk cycles earlier. This module
//   therefore delays pix_de / pix_hs / pix_vs by exactly 3 cycles
//   (shift registers) so that rgb and de_out / hs_out / vs_out are
//   aligned when they leave ui_renderer. All outputs are driven from
//   registers. hdmi_tx_if adds one further IO register stage on
//   rgb_in / de_in / hs_in / vs_in together, which keeps the mutual
//   alignment intact (total latency 4 pix_clk = 27 ns << 1 line of
//   14.8 us, so the frame phase shift is invisible).
//
// vsync_pulse (design.md section 1.4 CDC table, pix -> core path):
//   Single-cycle strobe on the rising edge of pix_vs (frame start,
//   v_count == 0). audio_sink (T-M0-06) uses it - after its own 2-flop
//   synchronizer and edge detector - as the page-switch anchor of the
//   waveform column ping-pong buffer, so that buffer updates only take
//   effect during vertical blanking (REQ-UI-007 anti-tearing).
//
// wave_rd channel pass-through: the read address is generated inside
//   waveform_disp from pix_x (combinational) and forwarded unchanged;
//   wave_min / wave_max / wave_valid / mute_flag_sync come from the
//   audio_sink column buffer (pix-domain synchronized by the producer,
//   1-cycle synchronous read contract, see waveform_disp header).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module ui_renderer #(
    // Height of the waveform region (forwarded to waveform_disp).
    parameter [10:0] WAVE_REGION_ROWS = 11'd300
) (
    // Pixel clock domain (148.5 MHz) and reset from hdmi_tx_if.
    input  wire        pix_clk,
    input  wire        rst_pix_n,

    // Scan timing inputs from hdmi_tx_if (sync_vg outputs).
    input  wire [10:0] pix_x,
    input  wire [10:0] pix_y,
    input  wire        pix_de,
    input  wire        pix_hs,
    input  wire        pix_vs,

    // Waveform column buffer read channel (audio_sink, T-M0-06).
    output wire [10:0] wave_rd_addr,
    input  wire [15:0] wave_min,
    input  wire [15:0] wave_max,
    input  wire        wave_valid,

    // Audio status flags (pix-domain synchronized by the producer).
    input  wire        mute_flag_sync,

    // Vertical blanking anchor for audio_sink page switching
    // (single-cycle pulse on the rising edge of pix_vs).
    output wire        vsync_pulse,

    // Overlay layers, already registered in the pix domain.
    input  wire [23:0] spec_rgb,
    input  wire        spec_on,
    input  wire [23:0] text_rgb,
    input  wire        text_on,
    input  wire [23:0] bars_rgb,
    input  wire        bars_on,

    // Rendered video towards hdmi_tx_if.
    output wire [23:0] rgb,
    output wire        de_out,
    output wire        hs_out,
    output wire        vs_out
);

    // -----------------------------------------------------------------
    // Waveform renderer (only display sub-module of the M0 build).
    // -----------------------------------------------------------------
    wire [23:0] wf_rgb;

    waveform_disp #(
        .WAVE_REGION_ROWS ( WAVE_REGION_ROWS )
    ) u_waveform_disp (
        .pix_clk        ( pix_clk        ),
        .rst_pix_n      ( rst_pix_n      ),
        .pix_x          ( pix_x          ),
        .pix_y          ( pix_y          ),
        .pix_de         ( pix_de         ),
        .wave_rd_addr   ( wave_rd_addr   ),
        .wave_min       ( wave_min       ),
        .wave_max       ( wave_max       ),
        .wave_valid     ( wave_valid     ),
        .mute_flag_sync ( mute_flag_sync ),
        .rgb            ( wf_rgb         )
    );

    // -----------------------------------------------------------------
    // Control-signal pipeline: 3-cycle waveform delay, followed by the
    // overlay output register.
    // -----------------------------------------------------------------
    reg [3:0] de_pipe;
    reg [3:0] hs_pipe;
    reg [3:0] vs_pipe;

    always @(posedge pix_clk) begin
        if (!rst_pix_n) begin
            de_pipe <= 4'b0000;
            hs_pipe <= 4'b0000;
            vs_pipe <= 4'b0000;
        end else begin
            de_pipe <= {de_pipe[2:0], pix_de};
            hs_pipe <= {hs_pipe[2:0], pix_hs};
            vs_pipe <= {vs_pipe[2:0], pix_vs};
        end
    end

    ui_overlay u_overlay (
        .pix_clk   (pix_clk),
        .rst_pix_n (rst_pix_n),
        .de        (de_pipe[2]),
        .base_rgb  (wf_rgb),
        .base_on   (de_pipe[2]),
        .spec_rgb  (spec_rgb),
        .spec_on   (spec_on),
        .text_rgb  (text_rgb),
        .text_on   (text_on),
        .bars_rgb  (bars_rgb),
        .bars_on   (bars_on),
        .rgb       (rgb),
        .de_out    (de_out)
    );

    assign hs_out = hs_pipe[3];
    assign vs_out = vs_pipe[3];

    // -----------------------------------------------------------------
    // vsync_pulse: rising-edge strobe of pix_vs (frame start marker).
    // pix_vs is a registered sync_vg output of the same pix_clk domain,
    // so a one-flop edge detector is sufficient here (no synchronizer
    // needed for a same-domain signal). The consumer in the core domain
    // applies its own 2-flop synchronizer per design.md section 1.4.
    // -----------------------------------------------------------------
    reg vs_d;

    always @(posedge pix_clk) begin
        if (!rst_pix_n)
            vs_d <= 1'b0;
        else
            vs_d <= pix_vs;
    end

    assign vsync_pulse = pix_vs & ~vs_d;

endmodule
