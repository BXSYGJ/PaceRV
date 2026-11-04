// -----------------------------------------------------------------------------
// File    : top_ddr3_diag.v
// Module  : top_ddr3_diag
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Contract: C-TOP-DDR3-DIAG@1 (plan revision P1, section 2.2.4)
//
// Purpose : Minimal DDR3 diagnostic top level (B line of the DDR3 unblock
//           plan). It contains ONLY the DDR3 hard IP wrapper, two
//           ddr3_ctrl_axi instances that differ in the two board bring-up
//           knobs, one self_test master and the diagnostic UART frame
//           generator. A single bitstream therefore answers BOTH bring-up
//           configurations independently (R1.2) and streams the AXI
//           handshake counters plus the timeout state to the serial port
//           (R1.1, R1.3).
//
//           Round 1 (round_cnt=0) runs with cfg_demo=0: the design-doc
//           configuration (AXI_USER_AP=1, dummy strobes masked).
//           Round 2 (round_cnt=1) runs with cfg_demo=1: the official demo
//           configuration (AXI_USER_AP=0, dummy strobes all ones).
//           Every round is preceded by a 16-cycle local reset of both
//           controllers so no AXI transaction can be in flight when the
//           configuration is switched (G2).
//
// Diagnostic frame fields (tag 0 = DDR3DIAG, 2 = DDR3SW, 3 = DDR3RS):
//   A = aw_hit_cnt        (axi_awvalid & axi_awready cycles, IP side)
//   B = wready_cnt        (axi_wready cycles, IP side)
//   C = done_cnt          (selected controller done[3] pulses)
//   D = rvalid_cnt        (axi_rvalid cycles, IP side)
//   E = packed status, bit positions identical to DDR3_E_BITS of
//       scripts/diag_frames.py:
//         bit0     to_err                  bit1     cmd_to_err[3]
//         bit4:2   dbg_to_state            bit5     addr_err[3]
//         bit6     st_done                 bit7     st_fail
//         bit9:8   result_a                bit11:10 result_b
//         bit15:12 round_cnt               bit16    cfg_demo
//         bit18:17 cfg_stage (low 2 bits)  bit31:24 wlast_miss_cnt
//       all undefined bits are zero
//   F = fail address of the current round (28-bit zero extended, 0 on pass)
//   G = {4'd0, dbg_to_state, 1'b0}       (selected controller timeout state)
//   H = {3'd0, st_done, st_fail, st_cv, st_wbe_q, st_rd_valid}
//
// Task T4 acceptance checklist (plan section 3.1), verified statically here:
//   1. Port set identical to the contract table; mem_dq / mem_dqs /
//      mem_dqs_n are declared inout.
//   2. The DDR3 wrapper instance is named ddr3_wrapper (the generated
//      clock constraints reference ddr3_wrapper.I_ips_ddr_top.*).
//   3. u_ctrl_design = (AXI_USER_AP=1, DUMMY_WSTRB_ALL1=0);
//      u_ctrl_demo   = (AXI_USER_AP=0, DUMMY_WSTRB_ALL1=1).
//   4. All 12 controller-to-IP mux assigns and all 9 IP-to-controller
//      broadcast connections are present (see the mux section below).
//   5. cmd_valid of the deselected controller is tied to 4'b0000, so it
//      can never grant a command and never raises a spurious timeout.
//   6. ctrl_rst_n = core_clk_rst_n & ~ctrl_reset_req, where
//      ctrl_reset_req is a 16-cycle registered pulse; self_test.rst_n is
//      driven from the same net.
//   7. Five-state orchestration FSM plus the three period constants
//      25 ms = 3125000, 100 ms = 12500000, 250 ms = 31250000 cycles.
//   8. Frame fields A..H follow the contract table, E bit-for-bit
//      compatible with DDR3_E_BITS.
//   9. The companion constraint file holds only the four local pin
//      groups plus create_clock on clk and does not include
//      ddr3_100h.fdc.
//  10. check_rtl.py reports zero violations for src/diag/*.v.
//  11. This file contains no double-quoted string literal; all text is
//      generated from ASCII case tables inside diag_uart_report.
//  12. Resource estimate and the reason this bitstream is not limited by
//      the LUT 53.6 percent routing critical point (see below).
//  13. Invariant (regression guard for the T4 rework, defects D-01/D-02):
//      the set bit of cmd_valid MUST use the same index as the done /
//      wready_beat / rd_valid / rd_data taps. This design always uses
//      bit3 = master 3: st_cmd_valid = {st_cv, 3'b000}. Board round 1
//      proved the earlier {3'b000, st_cv} form routed a 37-bit
//      m0_cmd = 0 read to master 0, so done[3] never pulsed while the
//      controller kept completing 1-beat transactions (A==B==D, C=0,
//      to_err=0, self_test stuck in ST_WDATA, top watchdog TIMEOUT).
//  14. ST_WAIT_INIT emits a tag 0 frame at reset release and then one
//      every 25 ms (busy-gated) until ST_RUN, and ST_RUN is not entered
//      before three frames have been emitted, so every capture window
//      contains at least three DDR3DIAG frames (defect D-02).
//
// Resource estimate (relative to the full m3d build, 34327 LUT):
//   * 2 x ddr3_ctrl_axi  ~ 2 x 1.2 k LUT (four-master arbiter, 16 x 256
//         elastic read fifo, watchdog state machines)
//   * self_test          ~ 0.4 k LUT (pattern generation and compare)
//   * diag_uart_report   ~ 0.2 k LUT + one 96-byte frame buffer
//   * uart_tx            ~ 0.05 k LUT
//   * orchestration FSM,
//     counters, muxes    ~ 0.3 k LUT
//   total user logic     ~ 3.0 k LUT on top of the DDR3 IP hard blocks,
//   i.e. under 10 percent of the device. The full build spends its 1.5 h
//   in the placer iterating over 34 k user LUT plus the mel/NPU/HDMI
//   logic; here the user logic is roughly one eleventh of that and its
//   only timing-critical nets are the IP-side AXI handshakes and the
//   125 MHz counter cones, so placement converges in minutes instead of
//   hours. The DDR3 PHY region is fixed by the IP, not by this logic.
//
// All orchestration logic runs in the core_clk (125 MHz) domain. The 27 MHz
// board clock only drives the led[0] heartbeat, which is the sole reason the
// clk port exists (ddr3_100h.fdc line 26 references get_clocks {clk}).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module top_ddr3_diag (
    // ---- board pins owned by this top level ----
    input  wire        clk,          // 27 MHz board clock (D18), led heartbeat
    input  wire        rst_n,        // board reset, active low (C22)
    output wire [7:0]  led,          // stage / result / timeout / heartbeat
    output wire        uart_tx,      // 115200 8N1 diagnostic frames (C24)
    // ---- DDR3 125 MHz differential reference ----
    input  wire        ref_clk_p,    // N3
    input  wire        ref_clk_n,    // N2
    // ---- DDR3 physical side, mirrored one-to-one from the wrapper ----
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
    output wire [3:0]  mem_dm,
    inout  wire [3:0]  mem_dqs,
    inout  wire [3:0]  mem_dqs_n,
    inout  wire [31:0] mem_dq
);

    // ------------------------------------------------------------------
    // Period constants (core_clk = 125 MHz)
    // ------------------------------------------------------------------
    localparam [31:0] FRAME_TICKS_25MS    = 32'd3125000;   // 25 ms
    localparam [31:0] TIMEOUT_TICKS_100MS = 32'd12500000;  // 100 ms
    localparam [31:0] FRAME_TICKS_250MS   = 32'd31250000;  // 250 ms

    // Round result codes (E field bits 9:8 and 11:10).
    localparam [1:0] RESULT_NONE    = 2'd0;
    localparam [1:0] RESULT_PASS    = 2'd1;
    localparam [1:0] RESULT_FAIL    = 2'd2;
    localparam [1:0] RESULT_TIMEOUT = 2'd3;

    // Orchestration FSM states (cfg_stage = {1'b0, state}).
    localparam [2:0] ST_WAIT_INIT = 3'd0;  // wait for DDR3 init, tag 0 frames
    localparam [2:0] ST_RUN       = 3'd1;  // one self-test run, 100 ms wdog
    localparam [2:0] ST_NEXT      = 3'd2;  // record result, emit tag 2 frame
    localparam [2:0] ST_SWITCH    = 3'd3;  // 16-cycle local reset, cfg flip
    localparam [2:0] ST_DONE      = 3'd4;  // tag 3 conclusion frames

    // ------------------------------------------------------------------
    // DDR3 wrapper status and IP-side AXI buses
    // ------------------------------------------------------------------
    wire         core_clk;
    wire         core_clk_rst_n;
    wire         ddr_init_done;
    wire         pll_lock;
    wire         ddrphy_cpd_lock;

    wire         axi_awready;
    wire         axi_wready;
    wire [3:0]   axi_wusero_id;
    wire         axi_wusero_last;
    wire         axi_arready;
    wire [255:0] axi_rdata;
    wire [3:0]   axi_rid;
    wire         axi_rlast;
    wire         axi_rvalid;

    // ------------------------------------------------------------------
    // Controller side AXI buses, design configuration (suffix _a)
    // ------------------------------------------------------------------
    wire [27:0]  axi_awaddr_a;
    wire         axi_awuser_ap_a;
    wire [3:0]   axi_awuser_id_a;
    wire [3:0]   axi_awlen_a;
    wire         axi_awvalid_a;
    wire [255:0] axi_wdata_a;
    wire [31:0]  axi_wstrb_a;
    wire [27:0]  axi_araddr_a;
    wire         axi_aruser_ap_a;
    wire [3:0]   axi_aruser_id_a;
    wire [3:0]   axi_arlen_a;
    wire         axi_arvalid_a;

    wire [3:0]   wready_beat_a;
    wire [3:0]   rd_valid_a;
    wire [3:0]   done_a;
    wire [255:0] rd_data_3_a;
    wire [3:0]   addr_err_a;
    wire         to_err_a;
    wire [3:0]   cmd_to_err_a;
    wire [2:0]   dbg_to_state_a;
    wire [7:0]   wlast_miss_cnt_a;

    // ------------------------------------------------------------------
    // Controller side AXI buses, demo configuration (suffix _b)
    // ------------------------------------------------------------------
    wire [27:0]  axi_awaddr_b;
    wire         axi_awuser_ap_b;
    wire [3:0]   axi_awuser_id_b;
    wire [3:0]   axi_awlen_b;
    wire         axi_awvalid_b;
    wire [255:0] axi_wdata_b;
    wire [31:0]  axi_wstrb_b;
    wire [27:0]  axi_araddr_b;
    wire         axi_aruser_ap_b;
    wire [3:0]   axi_aruser_id_b;
    wire [3:0]   axi_arlen_b;
    wire         axi_arvalid_b;

    wire [3:0]   wready_beat_b;
    wire [3:0]   rd_valid_b;
    wire [3:0]   done_b;
    wire [255:0] rd_data_3_b;
    wire [3:0]   addr_err_b;
    wire         to_err_b;
    wire [3:0]   cmd_to_err_b;
    wire [2:0]   dbg_to_state_b;
    wire [7:0]   wlast_miss_cnt_b;

    // ------------------------------------------------------------------
    // Self-test master port (master 3 of the selected controller)
    // ------------------------------------------------------------------
    wire         st_cv;          // self_test cmd_valid, master 3 only
    wire [36:0]  st_cmd;         // {wr, addr[27:0], len[7:0]}
    wire [255:0] st_wdata;
    wire         st_done;
    wire         st_fail;
    wire [27:0]  st_fail_addr;

    // ------------------------------------------------------------------
    // Diagnostic frame generator handshake
    // ------------------------------------------------------------------
    wire         report_busy;
    wire [7:0]   tx_byte_data;
    wire         tx_byte_valid;
    wire         tx_byte_ready;

    // ------------------------------------------------------------------
    // Orchestration state and counters (all core_clk domain)
    // ------------------------------------------------------------------
    reg  [2:0]   state;
    reg          cfg_demo;
    reg  [3:0]   round_cnt;
    reg  [1:0]   result_a;
    reg  [1:0]   result_b;
    reg  [27:0]  fail_addr_a;
    reg  [27:0]  fail_addr_b;
    reg  [27:0]  fail_addr_cur;

    reg          ctrl_reset_req;
    reg  [3:0]   ctrl_rst_cnt;

    reg  [31:0]  tick_cnt;
    reg  [3:0]   res_frame_cnt;
    reg  [1:0]   frame_tag;
    reg          report_fire;
    reg          start_pending;
    reg          run_active;
    reg          st_start_r;
    reg          next_sent;
    reg  [3:0]   init_frame_cnt;

    reg  [31:0]  aw_hit_cnt;
    reg  [31:0]  wready_cnt;
    reg  [31:0]  done_cnt;
    reg  [31:0]  rvalid_cnt;
    reg          st_wbe_q;

    // ------------------------------------------------------------------
    // Derived combinational nets
    // ------------------------------------------------------------------
    // G1: local reset of both controllers and the self-test.
    wire         ctrl_rst_n = core_clk_rst_n & ~ctrl_reset_req;
    wire         ddr_ready  = pll_lock & ddr_init_done & ddrphy_cpd_lock;
    wire [3:0]   cfg_stage  = {1'b0, state};

    // Upstream gating: the deselected controller never sees a command (G5).
    // self_test occupies master 3 only: the set bit MUST be bit3 so it
    // matches done[3] / wready_beat[3] / rd_valid[3] / rd_data_3_* below.
    wire [3:0]   st_cmd_valid = {st_cv, 3'b000};
    wire [3:0]   cmd_valid_a  = cfg_demo ? 4'b0000 : st_cmd_valid;
    wire [3:0]   cmd_valid_b  = cfg_demo ? st_cmd_valid : 4'b0000;
    wire         st_done_in   = cfg_demo ? done_b[3]        : done_a[3];
    wire         st_wbe_in    = cfg_demo ? wready_beat_b[3] : wready_beat_a[3];
    wire [255:0] st_rd_data   = cfg_demo ? rd_data_3_b      : rd_data_3_a;
    wire         st_rd_valid  = cfg_demo ? rd_valid_b[3]    : rd_valid_a[3];

    // Selected controller observation exports.
    wire         to_err_sel         = cfg_demo ? to_err_b         : to_err_a;
    wire [3:0]   cmd_to_err_sel     = cfg_demo ? cmd_to_err_b     : cmd_to_err_a;
    wire [2:0]   dbg_to_state_sel   = cfg_demo ? dbg_to_state_b   : dbg_to_state_a;
    wire [7:0]   wlast_miss_cnt_sel = cfg_demo ? wlast_miss_cnt_b : wlast_miss_cnt_a;
    wire [3:0]   addr_err_sel       = cfg_demo ? addr_err_b       : addr_err_a;

    // ------------------------------------------------------------------
    // Controller to IP mux, 12 assigns (cfg_demo=1 selects _b / demo)
    // ------------------------------------------------------------------
    wire [27:0]  axi_awaddr     = cfg_demo ? axi_awaddr_b    : axi_awaddr_a;
    wire         axi_awuser_ap  = cfg_demo ? axi_awuser_ap_b : axi_awuser_ap_a;
    wire [3:0]   axi_awuser_id  = cfg_demo ? axi_awuser_id_b : axi_awuser_id_a;
    wire [3:0]   axi_awlen      = cfg_demo ? axi_awlen_b     : axi_awlen_a;
    wire         axi_awvalid    = cfg_demo ? axi_awvalid_b   : axi_awvalid_a;
    wire [255:0] axi_wdata      = cfg_demo ? axi_wdata_b     : axi_wdata_a;
    wire [31:0]  axi_wstrb      = cfg_demo ? axi_wstrb_b     : axi_wstrb_a;
    wire [27:0]  axi_araddr     = cfg_demo ? axi_araddr_b    : axi_araddr_a;
    wire         axi_aruser_ap  = cfg_demo ? axi_aruser_ap_b : axi_aruser_ap_a;
    wire [3:0]   axi_aruser_id  = cfg_demo ? axi_aruser_id_b : axi_aruser_id_a;
    wire [3:0]   axi_arlen      = cfg_demo ? axi_arlen_b     : axi_arlen_a;
    wire         axi_arvalid    = cfg_demo ? axi_arvalid_b   : axi_arvalid_a;

    // ------------------------------------------------------------------
    // Diagnostic frame payload (fields are live in every state)
    // ------------------------------------------------------------------
    wire [31:0]  frm_a = aw_hit_cnt;
    wire [31:0]  frm_b = wready_cnt;
    wire [31:0]  frm_c = done_cnt;
    wire [31:0]  frm_d = rvalid_cnt;
    wire [31:0]  frm_e = {
        wlast_miss_cnt_sel,   // [31:24]
        5'd0,                 // [23:19] reserved, always zero
        cfg_stage[1:0],       // [18:17]
        cfg_demo,             // [16]
        round_cnt,            // [15:12]
        result_b,             // [11:10]
        result_a,             // [9:8]
        st_fail,              // [7]
        st_done,              // [6]
        addr_err_sel[3],      // [5]
        dbg_to_state_sel,     // [4:2]
        cmd_to_err_sel[3],    // [1]
        to_err_sel            // [0]
    };
    wire [31:0]  frm_f = {4'd0, fail_addr_cur};
    wire [7:0]   frm_g = {4'd0, dbg_to_state_sel, 1'b0};
    wire [7:0]   frm_h = {3'd0, st_done, st_fail, st_cv, st_wbe_q, st_rd_valid};

    // ------------------------------------------------------------------
    // DDR3 wrapper (instance name is part of the constraint contract)
    // ------------------------------------------------------------------
    ddr3_wrapper ddr3_wrapper (
        .ref_clk_p      (ref_clk_p),
        .ref_clk_n      (ref_clk_n),
        .resetn         (rst_n),
        .core_clk       (core_clk),
        .core_clk_rst_n (core_clk_rst_n),
        .ddr_init_done  (ddr_init_done),
        .pll_lock       (pll_lock),
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

    // ------------------------------------------------------------------
    // Design-doc controller configuration (round 1)
    // ------------------------------------------------------------------
    ddr3_ctrl_axi #(
        .AXI_USER_AP     (1'b1),
        .DUMMY_WSTRB_ALL1(1'b0)
    ) u_ctrl_design (
        .clk            (core_clk),
        .rst_n          (ctrl_rst_n),
        .cmd_valid      (cmd_valid_a),
        .m0_cmd         (37'd0),
        .m1_cmd         (37'd0),
        .m2_cmd         (37'd0),
        .m3_cmd         (st_cmd),
        .m0_wdata       (256'd0),
        .m1_wdata       (256'd0),
        .m2_wdata       (256'd0),
        .m3_wdata       (st_wdata),
        .wready_beat    (wready_beat_a),
        .rd_ready       (4'b1111),
        .rd_data_3      (rd_data_3_a),
        .rd_valid       (rd_valid_a),
        .done           (done_a),
        .addr_err       (addr_err_a),
        .to_err         (to_err_a),
        .cmd_to_err     (cmd_to_err_a),
        .dbg_to_state   (dbg_to_state_a),
        .wlast_miss_cnt (wlast_miss_cnt_a),
        .axi_awaddr     (axi_awaddr_a),
        .axi_awuser_ap  (axi_awuser_ap_a),
        .axi_awuser_id  (axi_awuser_id_a),
        .axi_awlen      (axi_awlen_a),
        .axi_awvalid    (axi_awvalid_a),
        .axi_wdata      (axi_wdata_a),
        .axi_wstrb      (axi_wstrb_a),
        .axi_araddr     (axi_araddr_a),
        .axi_aruser_ap  (axi_aruser_ap_a),
        .axi_aruser_id  (axi_aruser_id_a),
        .axi_arlen      (axi_arlen_a),
        .axi_arvalid    (axi_arvalid_a),
        .axi_awready    (axi_awready),
        .axi_wready     (axi_wready),
        .axi_wusero_id  (axi_wusero_id),
        .axi_wusero_last(axi_wusero_last),
        .axi_arready    (axi_arready),
        .axi_rdata      (axi_rdata),
        .axi_rid        (axi_rid),
        .axi_rlast      (axi_rlast),
        .axi_rvalid     (axi_rvalid)
    );

    // ------------------------------------------------------------------
    // Official demo controller configuration (round 2)
    // ------------------------------------------------------------------
    ddr3_ctrl_axi #(
        .AXI_USER_AP     (1'b0),
        .DUMMY_WSTRB_ALL1(1'b1)
    ) u_ctrl_demo (
        .clk            (core_clk),
        .rst_n          (ctrl_rst_n),
        .cmd_valid      (cmd_valid_b),
        .m0_cmd         (37'd0),
        .m1_cmd         (37'd0),
        .m2_cmd         (37'd0),
        .m3_cmd         (st_cmd),
        .m0_wdata       (256'd0),
        .m1_wdata       (256'd0),
        .m2_wdata       (256'd0),
        .m3_wdata       (st_wdata),
        .wready_beat    (wready_beat_b),
        .rd_ready       (4'b1111),
        .rd_data_3      (rd_data_3_b),
        .rd_valid       (rd_valid_b),
        .done           (done_b),
        .addr_err       (addr_err_b),
        .to_err         (to_err_b),
        .cmd_to_err     (cmd_to_err_b),
        .dbg_to_state   (dbg_to_state_b),
        .wlast_miss_cnt (wlast_miss_cnt_b),
        .axi_awaddr     (axi_awaddr_b),
        .axi_awuser_ap  (axi_awuser_ap_b),
        .axi_awuser_id  (axi_awuser_id_b),
        .axi_awlen      (axi_awlen_b),
        .axi_awvalid    (axi_awvalid_b),
        .axi_wdata      (axi_wdata_b),
        .axi_wstrb      (axi_wstrb_b),
        .axi_araddr     (axi_araddr_b),
        .axi_aruser_ap  (axi_aruser_ap_b),
        .axi_aruser_id  (axi_aruser_id_b),
        .axi_arlen      (axi_arlen_b),
        .axi_arvalid    (axi_arvalid_b),
        .axi_awready    (axi_awready),
        .axi_wready     (axi_wready),
        .axi_wusero_id  (axi_wusero_id),
        .axi_wusero_last(axi_wusero_last),
        .axi_arready    (axi_arready),
        .axi_rdata      (axi_rdata),
        .axi_rid        (axi_rid),
        .axi_rlast      (axi_rlast),
        .axi_rvalid     (axi_rvalid)
    );

    // ------------------------------------------------------------------
    // Pattern self-test, master 3 of the selected controller
    // ------------------------------------------------------------------
    self_test u_self_test (
        .clk         (core_clk),
        .rst_n       (ctrl_rst_n),
        .st_start    (st_start_r),
        .cmd_valid   (st_cv),
        .cmd         (st_cmd),
        .wdata       (st_wdata),
        .wready_beat (st_wbe_in),
        .rd_data     (st_rd_data),
        .rd_valid    (st_rd_valid),
        .done        (st_done_in),
        .st_done     (st_done),
        .st_fail     (st_fail),
        .st_fail_addr(st_fail_addr)
    );

    // ------------------------------------------------------------------
    // Diagnostic frame generator and 115200 8N1 transmitter
    // ------------------------------------------------------------------
    diag_uart_report #(
        .BAUD_DIV(1085)
    ) u_report (
        .clk          (core_clk),
        .rst_n        (core_clk_rst_n),
        .fire         (report_fire),
        .frame_tag    (frame_tag),
        .f_a          (frm_a),
        .f_b          (frm_b),
        .f_c          (frm_c),
        .f_d          (frm_d),
        .f_e          (frm_e),
        .f_f          (frm_f),
        .f_g          (frm_g),
        .f_h          (frm_h),
        .busy         (report_busy),
        .tx_byte_data (tx_byte_data),
        .tx_byte_valid(tx_byte_valid),
        .tx_byte_ready(tx_byte_ready)
    );

    uart_tx #(
        .BAUD_DIV(1085)
    ) u_uart_tx (
        .clk        (core_clk),
        .rst_n      (core_clk_rst_n),
        .byte_wdata (tx_byte_data),
        .byte_wvalid(tx_byte_valid),
        .byte_wready(tx_byte_ready),
        .uart_txd   (uart_tx)
    );

    // ------------------------------------------------------------------
    // Orchestration FSM, handshake counters, frame firing
    //
    // G1: ctrl_reset_req is a 16-cycle registered pulse; ctrl_rst_n above
    //     gates both controllers and the self-test.
    // G2: cfg_demo flips only on the cycle the pulse starts, so nothing
    //     can be in flight when the selected controller changes.
    // G3: self_test shares ctrl_rst_n and is therefore restarted.
    // G4: each cfg_demo value is used for exactly one st_start: entering
    //     ST_RUN sets start_pending, and the single cycle that asserts
    //     st_start_r clears it.
    // ------------------------------------------------------------------
    always @(posedge core_clk or negedge core_clk_rst_n) begin
        if (!core_clk_rst_n) begin
            state           <= ST_WAIT_INIT;
            cfg_demo        <= 1'b0;
            round_cnt       <= 4'd0;
            result_a        <= RESULT_NONE;
            result_b        <= RESULT_NONE;
            fail_addr_a     <= 28'd0;
            fail_addr_b     <= 28'd0;
            fail_addr_cur   <= 28'd0;
            ctrl_reset_req  <= 1'b0;
            ctrl_rst_cnt    <= 4'd0;
            tick_cnt        <= 32'd0;
            res_frame_cnt   <= 4'd0;
            frame_tag       <= 2'd0;
            report_fire     <= 1'b0;
            start_pending   <= 1'b0;
            run_active      <= 1'b0;
            st_start_r      <= 1'b0;
            next_sent       <= 1'b0;
            init_frame_cnt  <= 4'd0;
            aw_hit_cnt      <= 32'd0;
            wready_cnt      <= 32'd0;
            done_cnt        <= 32'd0;
            rvalid_cnt      <= 32'd0;
            st_wbe_q        <= 1'b0;
        end else begin
            // Single-cycle defaults for the registered pulse outputs.
            report_fire <= 1'b0;
            st_start_r  <= 1'b0;

            // One-cycle write-beat history for the H field.
            st_wbe_q <= st_wbe_in;

            // A..D counters, gated to the selected controller run only.
            if (run_active) begin
                if (axi_awvalid && axi_awready) begin
                    aw_hit_cnt <= aw_hit_cnt + 32'd1;
                end
                if (axi_wready) begin
                    wready_cnt <= wready_cnt + 32'd1;
                end
                if (st_done_in) begin
                    done_cnt <= done_cnt + 32'd1;
                end
                if (axi_rvalid) begin
                    rvalid_cnt <= rvalid_cnt + 32'd1;
                end
            end

            case (state)
                ST_WAIT_INIT: begin
                    // Periodic tag 0 frame every 25 ms until the round
                    // starts, gated by the reporter busy flag (D1: a fire
                    // while busy is dropped, so fire only when idle).
                    // ST_RUN is entered only after at least three frames
                    // have been emitted, so every capture window sees
                    // DDR3DIAG at least three times.
                    if ((init_frame_cnt >= 4'd3) && ddr_ready) begin
                        // Hand over to ST_RUN; the single st_start is
                        // emitted on the next cycle via start_pending.
                        state         <= ST_RUN;
                        start_pending <= 1'b1;
                        tick_cnt      <= 32'd0;
                        fail_addr_cur <= 28'd0;
                        aw_hit_cnt    <= 32'd0;
                        wready_cnt    <= 32'd0;
                        done_cnt      <= 32'd0;
                        rvalid_cnt    <= 32'd0;
                    end else if (init_frame_cnt == 4'd0) begin
                        // First frame immediately after reset release.
                        if (!report_busy) begin
                            report_fire    <= 1'b1;
                            frame_tag      <= 2'd0;
                            init_frame_cnt <= 4'd1;
                            tick_cnt       <= 32'd0;
                        end
                    end else if (tick_cnt >= (FRAME_TICKS_25MS - 32'd1)) begin
                        tick_cnt <= 32'd0;
                        if (!report_busy) begin
                            report_fire <= 1'b1;
                            frame_tag   <= 2'd0;
                            if (init_frame_cnt < 4'd3) begin
                                init_frame_cnt <= init_frame_cnt + 4'd1;
                            end
                        end
                    end else begin
                        tick_cnt <= tick_cnt + 32'd1;
                    end
                end

                ST_RUN: begin
                    if (start_pending) begin
                        // The self-test reset has been released for at
                        // least one cycle at this point (G4).
                        start_pending <= 1'b0;
                        st_start_r    <= 1'b1;
                        run_active    <= 1'b1;
                        tick_cnt      <= 32'd0;
                    end else if (st_fail) begin
                        // Failure wins over a stale done in the same round
                        // (F7: the two flags are mutually exclusive).
                        run_active    <= 1'b0;
                        fail_addr_cur <= st_fail_addr;
                        if (round_cnt == 4'd0) begin
                            result_a    <= RESULT_FAIL;
                            fail_addr_a <= st_fail_addr;
                        end else begin
                            result_b    <= RESULT_FAIL;
                            fail_addr_b <= st_fail_addr;
                        end
                        next_sent <= 1'b0;
                        state    <= ST_NEXT;
                        tick_cnt <= 32'd0;
                    end else if (st_done) begin
                        run_active    <= 1'b0;
                        fail_addr_cur <= 28'd0;
                        if (round_cnt == 4'd0) begin
                            result_a    <= RESULT_PASS;
                            fail_addr_a <= 28'd0;
                        end else begin
                            result_b    <= RESULT_PASS;
                            fail_addr_b <= 28'd0;
                        end
                        next_sent <= 1'b0;
                        state    <= ST_NEXT;
                        tick_cnt <= 32'd0;
                    end else if (tick_cnt >= (TIMEOUT_TICKS_100MS - 32'd1)) begin
                        // 100 ms watchdog: neither done nor fail arrived.
                        run_active    <= 1'b0;
                        fail_addr_cur <= 28'd0;
                        if (round_cnt == 4'd0) begin
                            result_a    <= RESULT_TIMEOUT;
                            fail_addr_a <= 28'd0;
                        end else begin
                            result_b    <= RESULT_TIMEOUT;
                            fail_addr_b <= 28'd0;
                        end
                        next_sent <= 1'b0;
                        state    <= ST_NEXT;
                        tick_cnt <= 32'd0;
                    end else begin
                        tick_cnt <= tick_cnt + 32'd1;
                    end
                end

                ST_NEXT: begin
                    // Two beats per round. Beat 1 emits the switch frame
                    // (DDR3SW) while cfg_demo and round_cnt still describe
                    // the round that just finished, so the E field of that
                    // frame is unambiguous. Beat 2 performs the switch (or
                    // enters the conclusion state).
                    if (!next_sent) begin
                        if (!report_busy) begin
                            report_fire <= 1'b1;
                            frame_tag   <= 2'd2;
                            next_sent   <= 1'b1;
                        end
                    end else if (round_cnt == 4'd0) begin
                        // Round 1 done: start the 16-cycle local reset and
                        // flip to the demo configuration.
                        round_cnt      <= 4'd1;
                        ctrl_reset_req <= 1'b1;
                        ctrl_rst_cnt   <= 4'd0;
                        cfg_demo       <= ~cfg_demo;
                        state          <= ST_SWITCH;
                    end else begin
                        // Round 2 done: hold the conclusion.
                        round_cnt     <= 4'd2;
                        res_frame_cnt <= 4'd0;
                        tick_cnt      <= 32'd0;
                        state         <= ST_DONE;
                    end
                end

                ST_SWITCH: begin
                    // ctrl_reset_req stays high for counter values 0..15,
                    // i.e. exactly 16 core_clk cycles ctrl_reset_req.
                    if (ctrl_rst_cnt == 4'd15) begin
                        ctrl_reset_req <= 1'b0;
                        ctrl_rst_cnt   <= 4'd0;
                        state          <= ST_RUN;
                        start_pending  <= 1'b1;
                        tick_cnt       <= 32'd0;
                        fail_addr_cur  <= 28'd0;
                        aw_hit_cnt     <= 32'd0;
                        wready_cnt     <= 32'd0;
                        done_cnt       <= 32'd0;
                        rvalid_cnt     <= 32'd0;
                    end else begin
                        ctrl_rst_cnt <= ctrl_rst_cnt + 4'd1;
                    end
                end

                ST_DONE: begin
                    // First conclusion frame immediately, then one every
                    // 250 ms, eight frames in total, then silence.
                    if (res_frame_cnt == 4'd0) begin
                        if (!report_busy) begin
                            report_fire   <= 1'b1;
                            frame_tag     <= 2'd3;
                            res_frame_cnt <= 4'd1;
                            tick_cnt      <= 32'd0;
                        end
                    end else if (res_frame_cnt < 4'd8) begin
                        if (tick_cnt >= (FRAME_TICKS_250MS - 32'd1)) begin
                            tick_cnt <= 32'd0;
                            if (!report_busy) begin
                                report_fire   <= 1'b1;
                                frame_tag     <= 2'd3;
                                res_frame_cnt <= res_frame_cnt + 4'd1;
                            end
                        end else begin
                            tick_cnt <= tick_cnt + 32'd1;
                        end
                    end
                end

                default: begin
                    state <= ST_WAIT_INIT;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 27 MHz heartbeat for led[0]: toggle rate 27e6 / 2^24 = 1.6 Hz
    // ------------------------------------------------------------------
    reg [23:0] hb_tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hb_tick <= 24'd0;
        end else begin
            hb_tick <= hb_tick + 24'd1;
        end
    end

    // ------------------------------------------------------------------
    // LED encoding: stage / result flags / timeout / heartbeat
    // ------------------------------------------------------------------
    assign led[7:4] = cfg_stage;
    assign led[3]   = st_done;
    assign led[2]   = st_fail;
    assign led[1]   = to_err_sel;
    assign led[0]   = hb_tick[23];

endmodule