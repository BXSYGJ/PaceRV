// -----------------------------------------------------------------------------
// File    : top_rv_core.v
// Module  : top_rv_core
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Purpose : top_core_only (DDR3 + NPU + Mel + weight loader + system control)
//           PLUS the RV32IM control core -- the competition "RISC-V CPU + AI
//           acceleration" fusion build.
//
// DERIVED COPY - the body below is top_core_only.v byte-for-byte except for
// three marked blocks: (a) the rv32_cpu_subsys instance, (b) the shared UART
// transmitter third source, (c) led[0] = cpu_alive / CPU-owned LED bar.
// Keeping the body identical keeps the board-proven DDR3 hierarchy
// (ddr3_wrapper.I_ips_ddr_top, addressed by path in constraints/ddr3_100h.fdc)
// and the proven datapath untouched.  The original header of the derived
// top_core_only.v file follows.
//
// Why this build set exists
//   The full top-level needs 34960 LUT (52.49%).  This device stops routing
//   above ~34600 LUT: the m4fix bitstream fits at 34561 (routed, "All
//   Constraints Met") while 34960 stalls with 4000+ unrouted nets forever.
//   The UI half is already board-proven as its own bitstream (top_ui_demo,
//   reports/ui_demo_conclusion.md), so it does not have to occupy LUT here.
//   Removing it brings the core design back under the routing cliff
//   (measured: LUT 32615, placed and routed, WNS +3.862 ns).
//
// Kept     : ddr3_wrapper, ddr3_ctrl_axi, sys_ctrl (incl. the T21 ST_DDREP
//            result latch and the three DDR3 AXI diagnostic inputs),
//            uart_debug, uart_tx, uart_rx, weight_loader, mel_engine,
//            npu_top (conv / pool / gap / fc / softmax), self_test,
//            audio_sink, audio_pll, and the PCM capture path
//            (i2s_clk_gen / i2s_rx / audio_cdc_fifo).
// Dropped  : ui_renderer, bars_data / bars_disp, text_disp, spectrum_disp,
//            waveform drawing, ui_coord_delay, feat_copy_engine,
//            feat_page_buf, hdmi_tx_if, the whole pix_clk / cfg_clk domain,
//            and the iic_* / vout_* / I2S pads.
//
// Clock domains
//   clk      27 MHz board crystal (D18), audio PLL reference
//   clk_nco  216 MHz audio time base (audio_pll), drives the I2S bit clock
//   core_clk 125 MHz DDR3 controller user clock (ddr3_wrapper output); every
//            functional register of this build set lives here
//
// Short-circuited inputs (documented tie-offs, all in one block below)
//   * I2S  : i2s_sd tied to 0 and no I2S pads, so the receiver emits
//            zero-valued stereo frames at the normal 44.1 kHz frame rate.
//   * PCM  : audio_sink only sees the FIFO flags while sys_run is high, so
//            master 0 stays quiet during the DDR3 self-test.  Without this
//            gate the audio page writes starve master 3 (measured on board:
//            "DDR3 ERR @00300000" + "DDR3 STS 26", to_err = 1 in state S_W:
//            fixed priority P0 > P3 with a 1 ms P3 quota against a 32.8 us
//            AXI timeout).
//   * HDMI : hdmi_init_over = 1 / hdmi_init_fail = 0, so sys_ctrl's PLL_WAIT
//            stage no longer waits for an I2C configuration that does not
//            exist here.  Ddrphy CPD lock and ddr_init_done stay real DDR3 IP
//            signals, so DDROK still requires a real DDR3 initialisation plus
//            a real 4 KB write / read-back self-test.
//   * KEY1 : tied high (no re-trigger pin in this build set).
//
// LED map: led[5] = sticky uart_rx_seen, led[3] = npu_busy, led[2:1] =
// npu_top1[1:0].  The last two keep the Mel -> NPU chain and the argmax
// visible to the optimiser and to the board.
//
// Artifact: build/top_core_only-latest.sbit (see scripts/build_sets.json).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module top_rv_core #(
    // 0 = the CPU must request inference; 1 = automatic Mel-window launch.
    // The default retains the real CPU-to-NPU control path in the netlist.
    parameter NPU_ENABLE = 0
) (
    // ---- board pins ----
    input  wire        clk,          // 27 MHz crystal (D18), audio PLL ref
    input  wire        rst_n,        // KEY0, active low (C22)
    output wire [7:0]  led,          // status LEDs (A20..B17)
    input  wire        uart_rx,      // CP2102 RX (B24), weight upload
    output wire        uart_tx,      // CP2102 TX (C24)
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
    wire clk_nco;            // 216 MHz NCO time base
    wire pll_audio_locked;   // audio GPLL lock
    wire rst_sync_nco;       // clk_nco domain reset (lock gated)
    wire core_clk;           // 125 MHz DDR3 user clock
    wire core_clk_rst_n;     // core_clk domain reset
    wire ddr_init_done;      // DDR3 initialization done
    wire ddr_pll_lock;       // DDR3 controller PLL lock
    wire ddrphy_cpd_lock;    // DDR3 PHY CPD lock

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
    // Audio chain (clk_nco capture side + core_clk FIFO side).
    // The audio_sink data valid/empty inputs are the run-gated versions
    // (fifo_rd_valid_run / fifo_empty_run, driven once sys_run exists), so
    // the DDR3 master-0 page writes only start after the self-test result
    // has been printed.  See the header note "Why the PCM stream is gated".
    // ==================================================================
    wire [4:0]  bck_phase;
    wire        bck_tick;
    wire [15:0] pcm_l;
    wire [15:0] pcm_r;
    wire        pcm_valid;
    wire        sd_idle;
    wire        fifo_rd_en;
    wire [31:0] fifo_rd_data;
    wire        fifo_rd_valid;
    wire        fifo_empty;
    wire        fifo_full;       // observation tap
    wire [15:0] overflow_cnt;
    wire        m0_cmd_valid;
    wire [36:0] m0_cmd;
    wire [255:0] m0_wdata;
    wire        m0_done;
    wire        win_tick;        // window pulse: mel start
    wire [15:0] win_id;          // observation tap
    wire        mute_flag;       // observation tap
    wire [15:0] audio_err_cnt;   // observation tap
    // Parked I2S pad outputs: no board pin in this build set, but the bit
    // generator keeps driving them, which keeps the clk_nco domain (and
    // therefore the frame cadence that feeds win_tick) alive.
    wire        i2s_bck_unused;
    wire        i2s_lrck_unused;
    // Parked waveform outputs of audio_sink (the waveform layer is gone).
    wire        mute_flag_sync_unused;
    wire [15:0] wave_min_unused;
    wire [15:0] wave_max_unused;
    wire        wave_valid_unused;
    // NPU argmax: consumed by led[2:1] so the softmax chain cannot be pruned
    wire [3:0]  npu_top1;

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
    // T36 run gate: the PCM stream (and therefore DDR3 master 0) is only
    // presented to audio_sink after sys_run rises, i.e. after sys_ctrl has
    // printed the DDR3 result and entered RUN.  See the header note
    // "Why the PCM stream is gated with sys_run".
    // ==================================================================
    wire fifo_rd_valid_run;
    wire fifo_empty_run;

    assign fifo_rd_valid_run = fifo_rd_valid & sys_run;
    assign fifo_empty_run    = sys_run ? fifo_empty : 1'b0;

    // ==================================================================
    // Module instances
    // ==================================================================

    // ---- 216 MHz audio time base (clk_nco domain reset included) ----
    audio_pll u_audio_pll (
        .clk_27m     (clk),
        .rst_n       (rst_n),
        .clk_nco     (clk_nco),
        .pll_locked  (pll_audio_locked),
        .rst_sync_nco(rst_sync_nco)
    );

    // ---- I2S clock generator (clk_nco domain) ----
    i2s_clk_gen u_i2s_clk_gen (
        .clk_nco   (clk_nco),
        .rst_n     (rst_sync_nco),
        .bck_phase (bck_phase),
        .bck_tick  (bck_tick),
        .i2s_bck   (i2s_bck_unused),
        .i2s_lrck  (i2s_lrck_unused)
    );

    // ---- I2S receiver (clk_nco domain, SD 2FF synchronized inside) ----
    i2s_rx u_i2s_rx (
        .clk_nco   (clk_nco),
        .rst_n     (rst_sync_nco),
        .i2s_sd    (1'b0),
        .bck_tick  (bck_tick),
        .bck_phase (bck_phase),
        .i2s_lrck  (i2s_lrck_unused),
        .pcm_l     (pcm_l),
        .pcm_r     (pcm_r),
        .pcm_valid (pcm_valid),
        .sd_idle   (sd_idle)
    );

    // ---- 216 MHz -> 125 MHz stereo sample CDC FIFO ----
    audio_cdc_fifo u_audio_cdc_fifo (
        .clk_nco     (clk_nco),
        .wr_rst_n    (rst_sync_nco),
        .pcm_valid   (pcm_valid),
        .pcm_l       (pcm_l),
        .pcm_r       (pcm_r),
        .i2s_lrck    (i2s_lrck_unused),
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
        .pix_clk       (core_clk),
        .vsync_pulse   (1'b0),
        .wave_rd_addr  (11'd0),
        .wave_min      (wave_min_unused),
        .wave_max      (wave_max_unused),
        .wave_valid    (wave_valid_unused),
        .mute_flag_sync(mute_flag_sync_unused)
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

    // ---- Mel feature read port: the NPU owns it in this build set ----
    // The copy engine and the spectrogram page buffer are gone with the UI
    // half, so the feature address is the NPU request with no multiplexer.
    wire [14:0] npu_feat_rd_addr;
    assign mel_feat_rd_addr = npu_feat_rd_addr;
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
    wire dbg_tx_ready;
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
    assign ddr_cmd_valid={st_cmd_valid,mel_m2_cmd_valid,native_m1_valid,m0_cmd_valid};
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
        .axi_rvalid     (axi_rvalid)
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
        .weight_ok    (weight_ok),
        .weight_err   (weight_err),
        .weight_start (weight_start_unused),
        .clk             (core_clk),
        .rst_n           (core_clk_rst_n),
        .pll_locked      (pll_audio_locked),
        .ddrphy_cpd_lock (ddrphy_cpd_lock),
        .ddr_init_done   (ddr_init_done),
        .hdmi_init_over  (1'b1),
        .hdmi_init_fail  (1'b0),
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

    // uart_tx registers ready, leaving it high one cycle after acceptance.
    // Suppress that stale-ready cycle for every producer, including the CPU
    // FIFO which otherwise pops two bytes for one serialized character.
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
    // Queue the firmware request until a complete Mel feature window exists.
    // The one-cycle Mel completion pulse is the safe boundary: starting on
    // an arbitrary CPU write could read uninitialized or partially rewritten
    // features. Weight upload, DDR self-test and an active NPU block launch.
    reg cpu_npu_pending;
    wire npu_launch_ready = sys_run && st_done && !st_fail && !safe_err &&
                            ddr_init_done && weight_ok && !weight_err &&
                            !wl_busy && !npu_busy_u && native_owner_idle && !native_fault;
    wire npu_start = mel_npu_start && npu_launch_ready &&
                     (NPU_ENABLE || cpu_npu_pending || cpu_npu_start);
    always @(posedge core_clk or negedge core_clk_rst_n) begin
        if (!core_clk_rst_n) cpu_npu_pending <= 1'b0;
        else if (npu_start) cpu_npu_pending <= 1'b0;
        else if (cpu_npu_start) cpu_npu_pending <= 1'b1;
    end

    npu_top #(.FEATURE_FRAME_MAJOR(1)) u_npu (
        .clk          (core_clk),
        .rst_n        (core_clk_rst_n),
        .start        (npu_start),
        .busy         (npu_busy_u),
        .done         (npu_done_raw),
        .npu_cycles   (npu_cycles_u),
        .timeout_flag (npu_timeout_raw),
        .feat_rd_addr (npu_feat_rd_addr),
        .feat_rd_data (mel_feat_rd_data),
        .feat_rd_en   (npu_feat_rd_en_u),
        .rd_cmd_valid (npu_rd_cmd_valid_u),
        .rd_cmd       (npu_rd_cmd_u),
        .rd_ready     (npu_rd_ready_u),
        .rd_data      (npu_weight_data),
        .rd_valid     (npu_weight_valid),
        .rd_done      (npu_weight_done),
        .act_cmd_valid(act_cmd_valid), .act_cmd_write(act_cmd_write), .act_cmd_addr(act_cmd_addr),
        .act_cmd_ready(act_cmd_ready), .act_wr_valid(act_wr_valid), .act_wr_data(act_wr_data),
        .act_wr_ready(act_wr_ready), .act_rd_valid(act_rd_valid), .act_rd_data(act_rd_data),
        .probs_valid  (npu_probs_valid_raw),
        .probs_pct    (npu_probs_pct_u),
        .probs_idx    (npu_probs_idx_u),
        .top1         (npu_top1)
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

    // ==================================================================
    // RV32IM control core.
    //
    // Firmware (sw/rv32/main.c, built by scripts/build_rv32_sw.py) runs from
    // the 8 KiB ROM, publishes "RV32 BOOT / ISA OK / BENCH" over the shared
    // UART, then supervises the NPU: every finished inference is read back
    // (top-1 + percentage) through MMIO and printed, and the DDR3 self-test
    // verdict reported by sys_ctrl is echoed as well.
    // ==================================================================
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
        .npu_top1        (npu_top1),
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
    // T36 harness + LED assembly.
    //
    // led[7:6] self-test stage code            (unchanged)
    // led[5]   uart_rx_seen: sticky "any UART byte received since reset".
    //          This separates a dead PC -> FPGA path from a loader /
    //          protocol problem without an ILA (see the WOK note above).
    // led[4]   SAFE_ERR latched state          (unchanged)
    // led[3]   npu_busy: rises once mel has fired npu_start (first audio
    //          window after RUN) - the cheapest "the NPU really started"
    //          proof, visible without an ILA.
    // led[2:1] npu_top1[1:0]: the argmax consumer that keeps the
    //          conv -> pool -> gap -> fc -> softmax chain from being
    //          optimised away.
    // led[0]   1 Hz heartbeat (active after RUN)
    //
    // Two fields are repurposed relative to instrec_top: led[5] used to be
    // the CDC-FIFO overflow warning (no I2S pad here, so overflow cannot
    // occur) and led[3:1] used to be a constant 0.
    // ==================================================================
    reg uart_rx_seen;

    always @(posedge core_clk or negedge core_clk_rst_n) begin
        if (!core_clk_rst_n) begin
            uart_rx_seen <= 1'b0;
        end else if (rx_byte_valid) begin
            uart_rx_seen <= 1'b1;
        end
    end

    // led[0] is now "the RV32 core has written its LED register", which is a
    // stronger bring-up signal than the 1 Hz heartbeat it replaces.
    // Once the core has written its LED register it owns the bar; before that
    // the pre-CPU bring-up pattern stays visible (a hung CPU is still readable).
    assign led = cpu_alive ? cpu_led :
                 {stage_code, uart_rx_seen, safe_err, npu_busy_u,
                  npu_top1[1:0], heartbeat};

endmodule
