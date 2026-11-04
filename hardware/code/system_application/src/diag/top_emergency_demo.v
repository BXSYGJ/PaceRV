// top_emergency_demo: DEMO ONLY: real audio and video, scripted results, no inference.
// -----------------------------------------------------------------------------
// File    : instrec_top.v
// Module  : instrec_top
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Purpose : RV32 control + I2S capture -> CDC -> DDR3 -> NPU -> HDMI
//           waveform display with the debug / self-test chain
//           (design doc sections 1.1 / 2.2.1, REQ-VER-001 M0 scope).
//
// Clock domains (design doc section 1.2):
//   clk       27 MHz board crystal (D18), reference of video GPLL
//   clk_nco   27 MHz audio processing clock (alias of board clk)
//   pix_clk   148.5 MHz pixel clock (hdmi_tx_if / demo GPLL_B IP)
//   core_clk  125 MHz DDR3 controller user clock (ddr3_wrapper IP output)
//
// Reset tree (design doc section 1.3):
//   rst_n     asynchronous board reset (KEY0, C22)
//   rst_sync_nco   clk_nco domain, two-FF synchronous reset release
//   rst_pix_n      pix_clk domain, sync release (hdmi_tx_if)
//   rst_sync_core  = rst_n directly; feeds ONLY ddr3_wrapper.resetn.
//                  Must not depend on core_clk (the IP GPLL produces it,
//                  so a core_clk-based release counter deadlocks).
//   core_clk_rst_n core_clk domain, sync release (ddr3_wrapper IP)
//
// CDC points (producers synchronize internally, the top level only wires):
//   * pcm path        clk_nco -> core_clk  : audio_cdc_fifo dual-clock FIFO
//   * sd_idle         clk_nco -> core_clk  : 2FF inside audio_sink/sys_ctrl
//   * vsync_pulse     pix_clk -> core_clk  : 2FF + edge detect in audio_sink
//   * wave_rd channel pix_clk -> pix_clk   : same domain, direct wiring
//   * overflow_cnt    clk_nco -> core_clk  : 2FF in sys_ctrl (quasi-static)
//
// Observation taps left unconnected at this milestone (consumed by the
// T-M2-07 UART stats exporter; synthesis prunes them): wait_cnt_0..3,
// addr_err, to_err, cmd_to_err, dbg_to_state, wlast_miss_cnt, win_tick,
// win_id, mute_flag, err_cnt, fifo_full, sys_run, rx_byte_cnt,
// dbg_line_wready.
//
// The DDR3 IP instance hierarchy is instrec_top.ddr3_wrapper.I_ips_ddr_top
// (constraint paths in ddr3_100h.fdc depend on it, REQ-MEM-001).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module top_emergency_demo #(
    // 0 = CPU-controlled launch; 1 = automatic Mel -> NPU launch. Weights load
    // before sys_ctrl reaches RUN; CPU requests launch at a Mel boundary.
    parameter NPU_ENABLE = 0
) (
    // ---- board pins ----
    input  wire        clk,          // 27 MHz crystal (D18)
    input  wire        rst_n,        // KEY0, active low (C22)
    input  wire        key1_n,       // KEY1, export trigger (C23)
    output wire [7:0]  led,          // status LEDs (A20..B17)
    input  wire        uart_rx,      // CP2102 RX (B24)
    output wire        uart_tx,      // CP2102 TX (C24)
    // ---- I2S audio pins ----
    input  wire        i2s_bck,      // PCM1808 bit clock 3.072 MHz (U20)
    input  wire        i2s_lrck,     // PCM1808 frame clock 48 kHz (T20)
    input  wire        i2s_sd,       // serial data (V16)
    output wire        hdmi_rst_n,   // board MS7210 reset (G25)
    // ---- HDMI transmitter pins (demo fdc pinout) ----
    output wire        iic_tx_scl,   // I2C clock (K22)
    inout  wire        iic_tx_sda,   // I2C data (K23)
    output wire        vout_clk,     // pixel clock (T24)
    output wire        vout_de,      // data enable (N19)
    output wire        vout_hs,      // horizontal sync (R20)
    output wire        vout_vs,      // vertical sync (R21)
    output wire [23:0] vout_data,    // parallel RGB (demo 24-pin map)
    // ---- DDR3 physical side (ddr3_wrapper pass-through, N3/N2 + 73 pins) ----
    input  wire        ref_clk_p,    // 125 MHz differential reference
    input  wire        ref_clk_n,
    output wire        mem_cs_n,
    output wire        mem_rst_n,
    output wire        mem_ck,
    output wire        mem_ck_n,
    output wire        mem_cke,
    output wire        mem_ras_n,
    output wire        mem_cas_n,
    output wire        mem_we_n,
    output wire        mem_odt,
    output wire [14:0] mem_a,
    output wire [2:0]  mem_ba,
    inout  wire [3:0]  mem_dqs,
    inout  wire [3:0]  mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [3:0]  mem_dm
);

    // ==================================================================
    // Clock and reset nets
    // ==================================================================
    wire clk_nco;            // 27 MHz board-clock alias
    wire pll_audio_locked;   // audio reset-release readiness
    wire rst_sync_nco;       // 27 MHz synchronized reset release
    wire pix_clk;            // 148.5 MHz pixel clock
    wire rst_pix_n;          // pix_clk domain reset
    wire core_clk;           // 125 MHz DDR3 user clock
    wire core_clk_rst_n;     // core_clk domain reset
    wire ddr_init_done;      // DDR3 initialization done
    wire ddr_pll_lock;       // DDR3 controller PLL lock
    wire ddrphy_cpd_lock;    // DDR3 PHY CPD lock
    wire hdmi_init_over;     // HDMI I2C configuration done
    wire hdmi_init_fail;     // HDMI I2C retries exhausted
    wire hdmi_pll_lock;      // HDMI GPLL_B lock

    // ==================================================================
    // DDR3 IP reset: drive resetn straight from the board reset.
    // The IP's GPLL produces core_clk, so a reset-release counter that
    // runs on core_clk would deadlock (no reset -> no GPLL clock ->
    // counter never advances -> reset never releases). The validated
    // 100H CPU top (pds_cpu_top_100h.v.in) also ties .resetn(rst_n);
    // the IP's internal ips2l_rst_sync_v1_3 releases core_clk_rst_n
    // synchronously, so all core_clk logic still gets a clean reset.
    // ==================================================================
    wire rst_sync_core = rst_n;   // DDR3 IP reset, active low

    // ==================================================================
    // Audio chain (clk_nco / core_clk domains)
    // ==================================================================
    wire [15:0] pcm_l;
    wire [15:0] pcm_r;
    wire        pcm_valid;
    wire        sd_idle;
    wire        fifo_rd_en;
    wire [31:0] fifo_rd_data;
    wire        fifo_rd_valid;
    wire        fifo_empty;
    wire        fifo_full;       // observation tap (unused in M0)
    wire [15:0] overflow_cnt;
    wire        m0_cmd_valid;
    wire [36:0] m0_cmd;
    wire [255:0] m0_wdata;
    wire        m0_done;
    wire        m0_wready_beat;  // observation tap (audio single-beat cmds)
    wire        win_tick;        // observation tap (T0.2 board check)
    wire [15:0] win_id;         // observation tap
    wire        mute_flag;       // observation tap
    wire [15:0] audio_err_cnt;  // observation tap

    // ==================================================================
    // Video chain (pix_clk domain)
    // ==================================================================
    wire [10:0] pix_x;
    wire [10:0] pix_y;
    wire        pix_de;
    wire        pix_hs;
    wire        pix_vs;
    wire [23:0] ui_rgb;
    wire        ui_de;
    wire        ui_hs;
    wire        ui_vs;
    wire [10:0] wave_rd_addr;
    wire [15:0] wave_min;
    wire [15:0] wave_max;
    wire        wave_valid;
    wire        mute_flag_sync;
    wire        vsync_pulse;
    // NPU top-1 class index (core_clk domain, quasi-static per window).
    wire [3:0]  npu_top1_u;

    // ==================================================================
    // DDR3 controller user side (core_clk domain)
    // ==================================================================
    // master 0: audio_sink PCM writes; master 1: NPU wdma (M2, tied off);
    // master 2: mel_engine (M1, wired below); master 3: self_test.
    wire [3:0]   ddr_cmd_valid;
    wire [36:0]  m1_cmd;          // tied off (T-M2-02 wdma alignment point)
    wire [36:0]  m2_cmd;          // mel_engine
    wire [36:0]  m3_cmd;
    wire [255:0] m1_wdata;        // tied off (T-M2-02)
    wire [255:0] m2_wdata;        // mel_engine
    wire [255:0] m3_wdata;
    wire [3:0]   ddr_wready_beat;
    wire [3:0]   ddr_rd_valid;
    wire [255:0] rd_data_0;
    wire [255:0] rd_data_1;
    wire [255:0] rd_data_2;
    wire [255:0] rd_data_3;
    wire [3:0]   ddr_done;
    // 2026-10-31: m0_done was declared but never driven. PDS only emitted
    // "Verilog-2036: Net m0_done ... has no driver, tie it to 0" and silently
    // tied it low, so audio_sink held m0_cmd_valid high forever (its FSM waits
    // for m0_done before releasing). With fixed-priority arbitration, master 0
    // then starved master 3: self_test aborted its first write after 4096
    // cycles and reported DDR3 ERR @00300000 on board.
    assign m0_done = ddr_done[0];
    // mel_engine master-2 port nets (per-master signals, packed into the
    // shared ctrl_axi buses exactly like audio_sink does for master 0)
    wire         mel_m2_cmd_valid;
    wire [36:0]  mel_m2_cmd;
    wire [255:0] mel_m2_wdata;
    wire         mel_m2_rd_ready;
    // AXI nets between ddr3_ctrl_axi and ddr3_wrapper
    wire [27:0]  axi_awaddr;
    wire         axi_awuser_ap;
    wire [3:0]   axi_awuser_id;
    wire [3:0]   axi_awlen;
    wire         axi_awvalid;
    wire         axi_awready;
    wire [255:0] axi_wdata;
    wire [31:0]  axi_wstrb;
    wire         axi_wready;
    wire [3:0]   axi_wusero_id;
    wire         axi_wusero_last;
    wire [27:0]  axi_araddr;
    wire         axi_aruser_ap;
    wire [3:0]   axi_aruser_id;
    wire [3:0]   axi_arlen;
    wire         axi_arvalid;
    wire         axi_arready;
    wire [255:0] axi_rdata;
    wire [3:0]   axi_rid;
    wire         axi_rlast;
    wire         axi_rvalid;
    wire         axi_rvalid_ctrl;
    // observation taps (M0: unconsumed, T-M2-07 UART exporter)
    wire [31:0]  wait_cnt_0;
    wire [31:0]  wait_cnt_1;
    wire [31:0]  wait_cnt_2;
    wire [31:0]  wait_cnt_3;
    wire [3:0]   ddr_addr_err;
    wire         ddr_to_err;
    wire [3:0]   ddr_cmd_to_err;
    wire [2:0]   ddr_dbg_to_state;
    wire [7:0]   ddr_wlast_miss_cnt;

    // ==================================================================
    // Control / debug chain (core_clk domain)
    // ==================================================================
    wire        st_start;
    wire        st_cmd_valid;
    wire        st_done;
    wire        st_fail;
    wire [27:0] st_fail_addr;
    wire        st_wready_beat;
    wire        st_rd_ready;
    wire [2:0]  dbg_line_id;
    wire [31:0] dbg_line_arg;
    wire        dbg_line_fire;
    wire        dbg_busy;
    wire        sys_run;           // observation tap (pipeline gate)
    wire        safe_err;
    wire [1:0]  stage_code;
    wire        heartbeat;
    wire        overflow_warn;
    wire [7:0]  tx_byte_data;
    wire        tx_byte_valid;
    wire        tx_byte_ready;
    wire [7:0]  rx_byte_data;
    wire        rx_byte_valid;
    wire        dbg_line_wready;   // observation tap (no text writer in M0)
    wire [15:0] uart_rx_byte_cnt;  // observation tap

    // ==================================================================
    // Module instances
    // ==================================================================

    // PCM1808 supplies its own clocks; the board clock has ample FIR budget.
    // 288 processing cycles fit within 562.5 cycles per 48 kHz stereo pair.
    reg [1:0] audio_reset_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) audio_reset_sync <= 2'b00;
        else audio_reset_sync <= {audio_reset_sync[0],1'b1};
    end
    assign clk_nco = clk;
    assign rst_sync_nco = audio_reset_sync[1];
    assign pll_audio_locked = audio_reset_sync[1];

    // PCM1808 owns both clocks. Convert coherent stereo pairs to 44.1 kHz.
    wire [15:0] capture_l, capture_r;
    wire capture_valid, capture_idle, resample_overrun;
    assign sd_idle = capture_idle | resample_overrun;
    i2s_slave_rx #(.TIMEOUT_CYCLES(27000)) u_i2s_slave_rx (
        .clk_nco(clk_nco), .rst_n(rst_sync_nco),
        .i2s_bck(i2s_bck), .i2s_lrck(i2s_lrck), .i2s_sd(i2s_sd),
        .pcm_l(capture_l), .pcm_r(capture_r),
        .pcm_valid(capture_valid), .sd_idle(capture_idle)
    );
    pcm1808_resampler u_pcm1808_resampler (
        .clk(clk_nco), .rst_n(rst_sync_nco), .stream_idle(capture_idle),
        .in_valid(capture_valid), .in_l(capture_l), .in_r(capture_r),
        .out_valid(pcm_valid), .out_l(pcm_l), .out_r(pcm_r),
        .overrun(resample_overrun)
    );

    // ---- 27 MHz -> 125 MHz stereo sample CDC FIFO ----
    audio_cdc_fifo u_audio_cdc_fifo (
        .clk_nco     (clk_nco),
        .wr_rst_n    (rst_sync_nco),
        .pcm_valid   (pcm_valid),
        .pcm_l       (pcm_l),
        .pcm_r       (pcm_r),
        .i2s_lrck    (1'b0), // Pair-valid is already once per stereo frame.
        .clk_core    (core_clk),
        .rd_rst_n    (core_clk_rst_n),
        .rd_en       (fifo_rd_en),
        .rd_data     (fifo_rd_data),
        .rd_valid    (fifo_rd_valid),
        .empty       (fifo_empty),
        .full        (fifo_full),
        .overflow_cnt(overflow_cnt)
    );

    // ---- PCM ring-buffer writer / DDR3 master 0 / waveform columns ----
    // Keep master 0 quiet until DDR self-test and weight loading finish.
    wire fifo_rd_valid_run = fifo_rd_valid & sys_run;
    wire fifo_empty_run = sys_run ? fifo_empty : 1'b0;
    audio_sink u_audio_sink (
        .clk           (core_clk),
        .rst_n         (core_clk_rst_n),
        .fifo_rd_en    (fifo_rd_en),
        .fifo_rd_data  (fifo_rd_data),
        .fifo_rd_valid (fifo_rd_valid_run),
        .fifo_empty    (fifo_empty_run),
        .sd_idle       (sd_idle),
        .m0_cmd_valid  (m0_cmd_valid),
        .m0_cmd        (m0_cmd),
        .m0_wdata      (m0_wdata),
        .m0_done       (m0_done),
        .win_tick      (win_tick),
        .win_id        (win_id),
        .mute_flag     (mute_flag),
        .err_cnt       (audio_err_cnt),
        .pix_clk       (pix_clk),
        .vsync_pulse   (vsync_pulse),
        .wave_rd_addr  (wave_rd_addr),
        .wave_min      (wave_min),
        .wave_max      (wave_max),
        .wave_valid    (wave_valid),
        .mute_flag_sync(mute_flag_sync)
    );

    // ---- Mel feature engine (M1): PCM window -> log2 mel -> int8 feat ----
    // Master 2 of ddr3_ctrl_axi; starts on audio_sink win_tick (window
    // complete in DDR3). Feature export (npu_start/feat_rd_*) is the
    // T-M2 NPU alignment point - observation taps until the NPU lands.
    // Hex tables: PDS resolves $readmemh paths against the -work_dir
    // root (probe-verified in T-M1-06), so the "src/mel/..." prefix
    // form is used here (matching the fft twiddle ROM hardcodes) and
    // build_full.tcl copies src/mel/*.hex into <work_dir>/src/mel/.
    wire        mel_npu_start;
    wire        mel_feat_page;
    wire [14:0] mel_feat_rd_addr;   // NPU read request (tied 0 until M2)
    wire [7:0]  mel_feat_rd_data;
    wire        mel_done;
    wire [31:0] mel_cycles;
    wire        mel_timeout;
    wire        mel_win_miss;
    wire        mel_busy;

    mel_engine #(
        .HAN_HEX_FILE ("src/mel/hann_q15.hex"),
        .COO_HEX_FILE ("src/mel/mel_coo.hex"),
        .LUT_HEX_FILE ("src/mel/log2_lut.hex")
    ) u_mel_engine (
        .clk           (core_clk),
        .rst_n         (core_clk_rst_n),
        .win_tick      (win_tick),
        .win_id        (win_id),
        .m2_cmd_valid  (mel_m2_cmd_valid),
        .m2_cmd        (mel_m2_cmd),
        .m2_wdata      (mel_m2_wdata),
        .m2_wready     (ddr_wready_beat[2]),
        .m2_rd_valid   (ddr_rd_valid[2]),
        .m2_rd_ready   (mel_m2_rd_ready),
        .m2_rd_data    (rd_data_2),
        .m2_done       (ddr_done[2]),
        .npu_start     (mel_npu_start),
        .feat_page     (mel_feat_page),
        .feat_rd_addr  (mel_feat_rd_addr),
        .feat_rd_data  (mel_feat_rd_data),
        .mel_done      (mel_done),
        .mel_cycles    (mel_cycles),
        .mel_timeout   (mel_timeout),
        .win_miss      (mel_win_miss),
        .busy          (mel_busy)
    );

    // The NPU drives mel_feat_rd_addr and consumes the synchronous read
    // data one cycle later.

    // ---- HDMI transmitter front end (GPLL_B + I2C config + pads) ----
    hdmi_tx_if u_hdmi_tx_if (
        .hdmi_rst_n     (hdmi_rst_n),
        .clk_27m        (clk),
        .rst_n          (rst_n),
        .pix_clk        (pix_clk),
        .rst_pix_n      (rst_pix_n),
        .pix_x          (pix_x),
        .pix_y          (pix_y),
        .pix_de         (pix_de),
        .pix_hs         (pix_hs),
        .pix_vs         (pix_vs),
        .rgb_in         (ui_rgb),
        .de_in          (ui_de),
        .hs_in          (ui_hs),
        .vs_in          (ui_vs),
        .vout_clk       (vout_clk),
        .vout_de        (vout_de),
        .vout_hs        (vout_hs),
        .vout_vs        (vout_vs),
        .vout_data      (vout_data),
        .iic_tx_scl     (iic_tx_scl),
        .iic_tx_sda     (iic_tx_sda),
        .hdmi_init_over (hdmi_init_over),
        .hdmi_init_fail (hdmi_init_fail),
        .pll_lock       (hdmi_pll_lock)
    );

    // ---- UI renderer (waveform region; instantiates waveform_disp) ----
    // Frame-coherent probability snapshot and labeled dashboard.
    wire [7:0] b0, b1, b2, b3, b4, b5, b6, b7;
    wire result_frame_ready;
    wire [3:0] frame_class;
    bars_data u_bars_data (
        .core_clk    (core_clk),
        .core_rst_n  (core_clk_rst_n),
        .probs_valid (npu_probs_valid_u),
        .probs_pct   (npu_probs_pct_u),
        .probs_idx   (npu_probs_idx_u),
        .top1        (npu_top1_u),
        .frame_start (vsync_pulse),
        .frame_class (frame_class),
        .frame_ready (result_frame_ready),
        .pix_clk     (pix_clk),
        .pix_rst_n   (rst_pix_n),
        .pct0(b0), .pct1(b1), .pct2(b2), .pct3(b3),
        .pct4(b4), .pct5(b5), .pct6(b6), .pct7(b7)
    );

    wire [14:0] npu_feat_rd_addr;

    // ---- Mel spectrogram chain (M3): copy the window into a double page,
    // then shade it in the pixel domain ----
    wire [14:0] copy_src_addr;
    wire        copy_src_en;
    wire [14:0] copy_dst_addr;
    wire [7:0]  copy_dst_data;
    wire        copy_dst_we;
    wire        copy_dst_page;
    wire        copy_done_u;

    feat_copy_engine #(.SOURCE_FRAME_MAJOR(1)) u_feat_copy (
        .core_clk   (core_clk),
        .core_rst_n (core_clk_rst_n),
        .start      (mel_npu_start),
        .busy_in    (npu_feat_rd_en_u),
        .src_addr   (copy_src_addr),
        .src_en     (copy_src_en),
        .src_data   (mel_feat_rd_data),
        .dst_addr   (copy_dst_addr),
        .dst_data   (copy_dst_data),
        .dst_we     (copy_dst_we),
        .dst_page   (copy_dst_page),
        .done       (copy_done_u)
    );

    // The NPU has priority on the mel feature port; the copy engine runs
    // only while the NPU is idle.
    assign mel_feat_rd_addr = npu_feat_rd_en_u ? npu_feat_rd_addr : copy_src_addr;

    wire [14:0] spec_ram_addr;
    wire [7:0]  spec_ram_data;

    wire spec_page_ready;
    feat_page_buf u_feat_page (
        .core_clk   (core_clk),
        .core_rst_n (core_clk_rst_n),
        .wr_en      (copy_dst_we),
        .wr_addr    (copy_dst_addr),
        .wr_data    (copy_dst_data),
        .wr_page    (copy_dst_page),
        .copy_done  (copy_done_u),
        .frame_start(vsync_pulse),
        .page_ready (spec_page_ready),
        .pix_clk    (pix_clk),
        .pix_rst_n  (rst_pix_n),
        .rd_addr    (spec_ram_addr),
        .rd_data    (spec_ram_data)
    );

    demo_dashboard_renderer u_ui_renderer (
        .pix_clk(pix_clk), .rst_pix_n(rst_pix_n),
        .pix_x(pix_x), .pix_y(pix_y), .pix_de(pix_de),
        .pix_hs(pix_hs), .pix_vs(pix_vs),
        .wave_rd_addr(wave_rd_addr), .wave_min(wave_min), .wave_max(wave_max),
        .wave_valid(wave_valid), .mute_flag_sync(mute_flag_sync),
        .spec_ram_addr(spec_ram_addr), .spec_ram_data(spec_ram_data),
        .feature_ready(spec_page_ready), .result_ready(result_frame_ready),
        .class_idx(frame_class),
        .pct0(b0), .pct1(b1), .pct2(b2), .pct3(b3),
        .pct4(b4), .pct5(b5), .pct6(b6), .pct7(b7),
        .vsync_pulse(vsync_pulse), .rgb(ui_rgb),
        .de_out(ui_de), .hs_out(ui_hs),
        .vs_out        (ui_vs)
    );

    // ---- DDR3 arbitration + IP contract adaptation ----
    wire        wl_tx_valid, wl_tx_ready;
    wire [7:0]  wl_tx_data;
    wire        wl_cmd_valid, wl_done, wl_wready;
    wire [36:0] wl_cmd;
    wire [255:0] wl_wdata;
    wire        wl_rd_ready;
    wire        weight_ok, weight_err;
    wire [27:0] wl_err_unused;
    wire [15:0] wl_cnt_unused;
    wire [31:0] wl_digest_unused;
    wire        npu_rd_cmd_valid_u;
    wire [36:0] npu_rd_cmd_u;
    wire        npu_rd_ready_u;

    // Snapshot-only native NPU integration. Owner locks each transaction.
    wire wl_busy;
    wire native_owner_idle,native_owner_error,native_fault;
    wire loader_m1_wready,loader_m1_rvalid,loader_m1_done;
    wire native_m1_valid,native_m1_rd_ready;
    wire [36:0] native_m1_cmd;
    wire [255:0] native_m1_wdata;
    wire bridge_mvalid,bridge_mready,bridge_wready,bridge_rvalid,bridge_done,bridge_abort;
    wire [36:0] bridge_mcmd;
    wire [255:0] bridge_mwdata;
    wire bridge_error,bridge_failed,aligner_error,aligner_failed;
    wire aligned_valid,aligned_rdvalid,aligned_done;
    wire [36:0] aligned_cmd;
    wire [255:0] aligned_data,npu_weight_data;
    wire npu_weight_valid,npu_weight_done;
    wire act_cmd_valid,act_cmd_write,act_cmd_ready,act_wr_valid,act_wr_ready,act_rd_valid;
    wire [31:0] act_cmd_addr;
    wire [255:0] act_wr_data,act_rd_data;
    wire npu_done_raw,npu_timeout_raw,npu_probs_valid_raw;
    assign npu_done_u=npu_done_raw && !native_fault;
    assign npu_timeout_u=npu_timeout_raw || native_fault;
    assign npu_probs_valid_u=npu_probs_valid_raw && !native_fault;
    assign native_fault=native_owner_error || bridge_error || aligner_error || ddr_addr_err[1] || ddr_cmd_to_err[1];
    assign npu_rd_ready_u=1'b1;
    assign ddr_cmd_valid = ddr_init_done ?
                           {st_cmd_valid,mel_m2_cmd_valid,native_m1_valid,m0_cmd_valid} :
                           4'b0000;
    assign m1_cmd=native_m1_cmd;
    assign m1_wdata=native_m1_wdata;
    weight_read_aligner_hardened u_weight_read_aligner(
        .clk(core_clk),.rst_n(core_clk_rst_n),.up_valid(npu_rd_cmd_valid_u),.up_cmd(npu_rd_cmd_u),
        .up_data(npu_weight_data),.up_rd_valid(npu_weight_valid),.up_done(npu_weight_done),.up_rd_ready(npu_rd_ready_u),
        .dn_valid(aligned_valid),.dn_cmd(aligned_cmd),.dn_data(aligned_data),.dn_rd_valid(aligned_rdvalid),.dn_done(aligned_done),
        .dn_abort(bridge_abort || bridge_failed || ddr_addr_err[1]),.protocol_error(aligner_error),.transaction_failed(aligner_failed));
    npu_m1_bridge u_npu_m1_bridge(
        .clk(core_clk),.rst_n(core_clk_rst_n),.wgt_cmd_valid(aligned_valid),.wgt_cmd(aligned_cmd),.wgt_rd_ready(1'b1),
        .wgt_rd_data(aligned_data),.wgt_rd_valid(aligned_rdvalid),.wgt_done(aligned_done),
        .act_cmd_valid(act_cmd_valid),.act_cmd_write(act_cmd_write),.act_cmd_addr(act_cmd_addr),.act_cmd_ready(act_cmd_ready),
        .act_wr_valid(act_wr_valid),.act_wr_data(act_wr_data),.act_wr_ready(act_wr_ready),.act_rd_valid(act_rd_valid),.act_rd_data(act_rd_data),
        .m1_cmd_valid(bridge_mvalid),.m1_cmd(bridge_mcmd),.m1_wdata(bridge_mwdata),.m1_rd_ready(bridge_mready),
        .m1_wready(bridge_wready),.m1_rdata(rd_data_1),.m1_rvalid(bridge_rvalid),.m1_done(bridge_done),.m1_abort(bridge_abort),
        .protocol_error(bridge_error),.transaction_failed(bridge_failed));
    npu_m1_owner u_npu_m1_owner(
        .clk(core_clk),.rst_n(core_clk_rst_n),.loader_allowed(!npu_busy_u && !npu_start && !native_fault),
        .l_valid(wl_cmd_valid),.l_cmd(wl_cmd),.l_wdata(wl_wdata),.l_rd_ready(wl_rd_ready),
        .l_wready(loader_m1_wready),.l_rvalid(loader_m1_rvalid),.l_done(loader_m1_done),
        .n_valid(bridge_mvalid),.n_cmd(bridge_mcmd),.n_wdata(bridge_mwdata),.n_rd_ready(bridge_mready),
        .n_wready(bridge_wready),.n_rvalid(bridge_rvalid),.n_done(bridge_done),.n_abort(bridge_abort),
        .m_valid(native_m1_valid),.m_cmd(native_m1_cmd),.m_wdata(native_m1_wdata),.m_rd_ready(native_m1_rd_ready),
        .m_wready(ddr_wready_beat[1]),.m_rvalid(ddr_rd_valid[1]),.m_done(ddr_done[1]),.m_abort(ddr_cmd_to_err[1] || ddr_addr_err[1]),
        .idle(native_owner_idle),.protocol_error(native_owner_error));
    assign m2_cmd        = mel_m2_cmd;
    assign m2_wdata      = mel_m2_wdata;
    assign axi_rvalid_ctrl = ddr_init_done && axi_rvalid;

    ddr3_ctrl_axi u_ddr3_ctrl_axi (
        .clk            (core_clk),
        .rst_n          (core_clk_rst_n),
        .cmd_valid      (ddr_cmd_valid),
        .m0_cmd         (m0_cmd),
        .m1_cmd         (m1_cmd),
        .m2_cmd         (m2_cmd),
        .m3_cmd         (m3_cmd),
        .m0_wdata       (m0_wdata),
        .m1_wdata       (m1_wdata),
        .m2_wdata       (m2_wdata),
        .m3_wdata       (m3_wdata),
        .wready_beat    (ddr_wready_beat),
        .rd_ready       ({st_rd_ready, mel_m2_rd_ready, native_m1_rd_ready, 1'b0}),
        .rd_data_0      (rd_data_0),
        .rd_data_1      (rd_data_1),
        .rd_data_2      (rd_data_2),
        .rd_data_3      (rd_data_3),
        .rd_valid       (ddr_rd_valid),
        .done           (ddr_done),
        .wait_cnt_0     (wait_cnt_0),
        .wait_cnt_1     (wait_cnt_1),
        .wait_cnt_2     (wait_cnt_2),
        .wait_cnt_3     (wait_cnt_3),
        .addr_err       (ddr_addr_err),
        .to_err         (ddr_to_err),
        .cmd_to_err     (ddr_cmd_to_err),
        .dbg_to_state   (ddr_dbg_to_state),
        .wlast_miss_cnt (ddr_wlast_miss_cnt),
        .axi_awaddr     (axi_awaddr),
        .axi_awuser_ap  (axi_awuser_ap),
        .axi_awuser_id  (axi_awuser_id),
        .axi_awlen      (axi_awlen),
        .axi_awvalid    (axi_awvalid),
        .axi_awready    (axi_awready),
        .axi_wdata      (axi_wdata),
        .axi_wstrb      (axi_wstrb),
        .axi_wready     (axi_wready),
        .axi_wusero_id  (axi_wusero_id),
        .axi_wusero_last(axi_wusero_last),
        .axi_araddr     (axi_araddr),
        .axi_aruser_ap  (axi_aruser_ap),
        .axi_aruser_id  (axi_aruser_id),
        .axi_arlen      (axi_arlen),
        .axi_arvalid    (axi_arvalid),
        .axi_arready    (axi_arready),
        .axi_rdata      (axi_rdata),
        .axi_rid        (axi_rid),
        .axi_rlast      (axi_rlast),
        .axi_rvalid     (axi_rvalid_ctrl)
    );

    // ---- DDR3 IP shell (instance hierarchy: ddr3_wrapper.I_ips_ddr_top) ----
    ddr3_wrapper ddr3_wrapper (
        .ref_clk_p      (ref_clk_p),
        .ref_clk_n      (ref_clk_n),
        .resetn         (rst_sync_core),
        .core_clk       (core_clk),
        .core_clk_rst_n (core_clk_rst_n),
        .ddr_init_done  (ddr_init_done),
        .pll_lock       (ddr_pll_lock),
        .ddrphy_cpd_lock(ddrphy_cpd_lock),
        .axi_awaddr     (axi_awaddr),
        .axi_awuser_ap  (axi_awuser_ap),
        .axi_awuser_id  (axi_awuser_id),
        .axi_awlen      (axi_awlen),
        .axi_awvalid    (axi_awvalid),
        .axi_awready    (axi_awready),
        .axi_wdata      (axi_wdata),
        .axi_wstrb      (axi_wstrb),
        .axi_wready     (axi_wready),
        .axi_wusero_id  (axi_wusero_id),
        .axi_wusero_last(axi_wusero_last),
        .axi_araddr     (axi_araddr),
        .axi_aruser_ap  (axi_aruser_ap),
        .axi_aruser_id  (axi_aruser_id),
        .axi_arlen      (axi_arlen),
        .axi_arvalid    (axi_arvalid),
        .axi_arready    (axi_arready),
        .axi_rdata      (axi_rdata),
        .axi_rid        (axi_rid),
        .axi_rlast      (axi_rlast),
        .axi_rvalid     (axi_rvalid),
        .mem_cs_n       (mem_cs_n),
        .mem_rst_n      (mem_rst_n),
        .mem_ck         (mem_ck),
        .mem_ck_n       (mem_ck_n),
        .mem_cke        (mem_cke),
        .mem_ras_n      (mem_ras_n),
        .mem_cas_n      (mem_cas_n),
        .mem_we_n       (mem_we_n),
        .mem_odt        (mem_odt),
        .mem_a          (mem_a),
        .mem_ba         (mem_ba),
        .mem_dqs        (mem_dqs),
        .mem_dqs_n      (mem_dqs_n),
        .mem_dq         (mem_dq),
        .mem_dm         (mem_dm)
    );

    // ---- DDR3 write-read self test (master 3, self-test pattern area) ----
    // master-3 write-beat pulse (C-SELFTEST@1 F2/S1/S2).  Without this tap
    // PDS reports "Verilog-2036: Net st_wready_beat ... has no driver, tie
    // it to 0"; self_test then never sees a beat handshake and the first
    // write command aborts with st_fail at SELFTEST_BASE.
    assign st_wready_beat = ddr_wready_beat[3];

    self_test u_self_test (
        .clk          (core_clk),
        .rst_n        (core_clk_rst_n),
        .st_start     (st_start),
        .cmd_valid    (st_cmd_valid),
        .cmd          (m3_cmd),
        .wdata        (m3_wdata),
        .wready_beat  (st_wready_beat),
        .rd_ready     (st_rd_ready),
        .rd_data      (rd_data_3),
        .rd_valid     (ddr_rd_valid[3]),
        .done         (ddr_done[3]),
        .st_done      (st_done),
        .st_fail      (st_fail),
        .st_fail_addr (st_fail_addr)
    );

    // ---- System controller (boot self-test chain + LED encoding) ----

    wire weight_start_unused;

    sys_ctrl u_sys_ctrl (
        .weight_ok    (1'b1),
        .weight_err   (1'b0),
        .weight_start (weight_start_unused),
        .clk             (core_clk),
        .rst_n           (core_clk_rst_n),
        .pll_locked      (pll_audio_locked),
        .ddrphy_cpd_lock (ddrphy_cpd_lock),
        .ddr_init_done   (ddr_init_done),
        .hdmi_init_over  (hdmi_init_over),
        .hdmi_init_fail  (hdmi_init_fail),
        .sd_idle         (sd_idle),
        .overflow_cnt    (overflow_cnt),
        .st_start        (st_start),
        .st_done         (st_done),
        .st_fail         (st_fail),
        .st_fail_addr    (st_fail_addr),
        // DDR3 AXI diagnostic taps: consumed by sys_ctrl for the
        // "DDR3 STS <hex8>" line (T21).  These nets were left dangling
        // (no consumer) until now.
        .ddr_dbg_to_state(ddr_dbg_to_state),
        .ddr_to_err      (ddr_to_err),
        .ddr_cmd_to_err  (ddr_cmd_to_err),
        .dbg_line_id     (dbg_line_id),
        .dbg_line_arg    (dbg_line_arg),
        .dbg_line_fire   (dbg_line_fire),
        .dbg_busy        (dbg_busy),
        .sys_run         (sys_run),
        .safe_err        (safe_err),
        .stage_code      (stage_code),
        .heartbeat       (heartbeat),
        .overflow_warn   (overflow_warn),
        .key1_n          (1'b1)
    );

    // ---- UART physical byte layer ----
    wire [7:0] dbg_tx_data;
    wire       dbg_tx_valid;
    wire       dbg_tx_ready;

    reg tx_accept_hold;
    wire tx_accept_ready = tx_byte_ready & ~tx_accept_hold;
    always @(posedge core_clk or negedge core_clk_rst_n) begin
        if (!core_clk_rst_n) tx_accept_hold <= 1'b0;
        else if (!tx_byte_ready) tx_accept_hold <= 1'b0;
        else if (tx_accept_ready && (wl_tx_valid | dbg_tx_valid | cpu_tx_valid))
            tx_accept_hold <= 1'b1;
    end
    assign wl_tx_ready   = tx_accept_ready;
    assign dbg_tx_ready  = tx_accept_ready & ~wl_tx_valid;

    // ---- RV32 control core (lowest-priority UART source) ----
    wire        cpu_tx_valid;
    wire [7:0]  cpu_tx_data;
    wire [7:0]  cpu_led;
    wire        cpu_alive;
    wire        cpu_trap;
    wire [31:0] cpu_trap_cause;
    wire        cpu_npu_start;
    wire        cpu_tx_ready;

    uart_tx u_uart_tx (
        .clk         (core_clk),
        .rst_n       (core_clk_rst_n),
        .byte_wdata  (wl_tx_valid ? wl_tx_data :
                      (dbg_tx_valid ? dbg_tx_data : cpu_tx_data)),
        .byte_wvalid ((wl_tx_valid | dbg_tx_valid | cpu_tx_valid) & ~tx_accept_hold),
        .byte_wready (tx_byte_ready),
        .uart_txd    (uart_tx)
    );

    // The CPU may only pop its FIFO when the multiplexer actually selects it,
    // otherwise a byte would be consumed while wl/dbg data goes out instead.
    assign cpu_tx_ready = tx_accept_ready & ~wl_tx_valid & ~dbg_tx_valid;

    uart_rx u_uart_rx (
        .clk         (core_clk),
        .rst_n       (core_clk_rst_n),
        .uart_rxd    (uart_rx),
        .byte_rdata  (rx_byte_data),
        .byte_rvalid (rx_byte_valid)
    );

    // ---- Weight loader (T-M2-01): UART frames -> DDR3 master 1 ----

    weight_loader #(.BASE_ADDR(28'h100000)) u_weight_loader (
        .clk         (core_clk),
        .rst_n       (core_clk_rst_n),
        .rx_valid    (rx_byte_valid && !npu_busy_u && !npu_start && !native_fault),
        .rx_data     (rx_byte_data),
        .tx_valid    (wl_tx_valid),
        .tx_data     (wl_tx_data),
        .tx_ready    (wl_tx_ready),
        .cmd_valid   (wl_cmd_valid),
        .cmd         (wl_cmd),
        .wdata       (wl_wdata),
        .wready_beat (loader_m1_wready),
        .done        (loader_m1_done),
        .rd_ready    (wl_rd_ready),
        .rd_data     (rd_data_1),
        .rd_valid    (loader_m1_rvalid),
        .busy        (wl_busy),
        .weight_ok   (weight_ok),
        .weight_err  (weight_err),
        .err_addr    (wl_err_unused),
        .frame_cnt   (wl_cnt_unused),
        .digest      (wl_digest_unused)
    );

    // ---- NPU top (T-M2-06): instantiated but gated off until the mel
    // feat read port and m1 arbitration are finalized. Keeping the instance
    // here fixes the top-level topology and lets PDS elaborate the chain.
    wire        npu_busy_u, npu_done_u, npu_timeout_u;
    wire [31:0] npu_cycles_u;
    wire        npu_probs_valid_u;
    wire [7:0]  npu_probs_pct_u;
    wire [3:0]  npu_probs_idx_u;
    wire        npu_feat_rd_en_u;
    reg cpu_npu_pending;
    wire npu_launch_ready = sys_run && st_done && !st_fail && !safe_err &&
                            ddr_init_done && weight_ok && !weight_err &&
                            !wl_busy && !npu_busy_u && native_owner_idle && !native_fault;
    wire npu_start = 1'b0;
    always @(posedge core_clk or negedge core_clk_rst_n) begin
        if (!core_clk_rst_n) cpu_npu_pending <= 1'b0;
        else if (npu_start) cpu_npu_pending <= 1'b0;
        else if (cpu_npu_start) cpu_npu_pending <= 1'b1;
    end

    assign npu_busy_u = 1'b0;
    assign npu_done_raw = 1'b0;
    assign npu_timeout_raw = 1'b0;
    assign npu_cycles_u = 32'd0;
    assign npu_feat_rd_addr = 15'd0;
    assign npu_feat_rd_en_u = 1'b0;
    assign npu_rd_cmd_valid_u = 1'b0;
    assign npu_rd_cmd_u = 37'd0;
    assign act_cmd_valid = 1'b0;
    assign act_cmd_write = 1'b0;
    assign act_cmd_addr = 32'd0;
    assign act_wr_valid = 1'b0;
    assign act_wr_data = 256'd0;
    demo_confidence_player u_demo_player (
        .clk(core_clk), .rst_n(core_clk_rst_n), .key_n(key1_n),
        .probs_valid(npu_probs_valid_raw), .probs_pct(npu_probs_pct_u),
        .probs_idx(npu_probs_idx_u), .top1(npu_top1_u)
    );

    // ---- Debug line formatter (M0: status lines only, no text writer) ----
    uart_debug u_uart_debug (
        .clk            (core_clk),
        .rst_n          (core_clk_rst_n),
        .tx_byte_data   (dbg_tx_data),
        .tx_byte_valid  (dbg_tx_valid),
        .tx_byte_ready  (dbg_tx_ready),
        .rx_byte_data   (rx_byte_data),
        .rx_byte_valid  (rx_byte_valid),
        .dbg_line_wdata (8'd0),
        .dbg_line_wvalid(1'b0),
        .dbg_line_wready(dbg_line_wready),
        .dbg_line_id    (dbg_line_id),
        .dbg_line_arg   (dbg_line_arg),
        .dbg_line_fire  (dbg_line_fire),
        .dbg_busy       (dbg_busy),
        .rx_byte_cnt    (uart_rx_byte_cnt)
    );

    rv32_cpu_subsys #(
        .ENABLE_M         (0),      // RV32I: saves ~600 LUT against the cliff
        .ENABLE_PREDICTOR (0),
        .RESET_VECTOR     (32'h0000_0000),
        .PROG_HEX         ("src/cpu/prog.hex")
    ) u_cpu (
        .clk             (core_clk),
        .rst_n           (core_clk_rst_n),
        .npu_busy        (npu_busy_u),
        .npu_done        (npu_done_u),
        .npu_timeout     (npu_timeout_u),
        .npu_probs_valid (npu_probs_valid_u),
        .npu_probs_pct   (npu_probs_pct_u),
        .npu_probs_idx   (npu_probs_idx_u),
        .npu_top1        (npu_top1_u),
        .npu_cycles      (npu_cycles_u),
        .ddr_ok          (ddr_init_done & st_done & ~st_fail & ~safe_err),
        .ddr_err         (safe_err),
        .ddr_sts         ({8'h00, 8'h00, ddr_cmd_to_err, ddr_to_err,
                           ddr_dbg_to_state, st_fail, st_done, 6'h00}),
        .uart_valid      (cpu_tx_valid),
        .uart_data       (cpu_tx_data),
        .uart_ready      (cpu_tx_ready),
        .cpu_led         (cpu_led),
        .cpu_alive       (cpu_alive),
        .cpu_trap        (cpu_trap),
        .cpu_trap_cause  (cpu_trap_cause),
        .npu_soft_start  (cpu_npu_start)
    );

    // ==================================================================
    // LED assembly (design doc section 2.2.9 / sys_ctrl contract):
    //   led[7:6] self-test stage code
    //   led[5]   CDC FIFO overflow warning (sticky)
    //   led[4]   SAFE_ERR latched state
    //   led[3:1] NPU busy / CPU trap / CPU alive
    //   led[0]   1 Hz heartbeat (active after RUN)
    // ==================================================================
    assign led = {stage_code, overflow_warn, safe_err, npu_busy_u, cpu_trap, cpu_alive, heartbeat};

endmodule
