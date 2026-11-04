// -----------------------------------------------------------------------------
// File    : tb_ddr3_subsys.sv
// Project : InstRec-FPGA / T28 DDR3 subsystem simulation
// Purpose : Direct-drive the DDR3 subsystem (ddr3_ctrl_axi + ddr3_arbiter +
//           self_test) against a behavioral model of the Pango DDR3 hard-IP
//           user-side AXI ports, and answer these questions WITHOUT a build
//           and WITHOUT touching the board:
//
//             * is the subsystem actually passing the 16 self-test commands?
//             * if not, on which handshake phase does it time out
//               (S_AW / S_W / S_DW_AW / S_DW_W / S_AR / S_R)?
//             * does the m0_done wiring fix stop master 3 starvation?
//             * does the known watchdog blind spot (rvalid stuck high, rlast
//               never) really disable the timeout?
//             * what does DUMMY_WSTRB_ALL1=1 actually destroy?
//
// Run (from instrec_fpga/):
//
//   python sim/run_sim.py ddr3_subsys        <- canonical entry, registered
//                                              in sim/run_sim.py (case name
//                                              "ddr3_subsys")
//
// Standalone equivalent (the behavioural IP model lives in sim/, so it is
// resolved by module name with "-y sim"). sim/run_sim.py carries a one-line
// textual override for the historical duplicate `wire [255:0] wdata;` in
// self_test.v; that declaration has since been removed upstream, in which
// case the override becomes a no-op and sim/prep_rtl_sim.py is a plain copy:
//
//   python sim/prep_rtl_sim.py               # -> build/sim_ddr3/self_test_sim.v
//   H:/GG/bin/verilator.bat --binary --timing -j 4 -Wno-fatal -sv \
//       -y sim -y src/ddr3 --top-module tb_ddr3_subsys \
//       -Mdir build/sim_ddr3/obj \
//       sim/ddr3_axi_model.sv sim/tb_ddr3_subsys.sv \
//       build/sim_ddr3/self_test_sim.v
//   build/sim_ddr3/obj/Vtb_ddr3_subsys
//
// Scenarios run CONCURRENTLY, each with its own ddr3_ctrl_axi + IP model
// instance, so the whole run is bounded by the longest single scenario
// (blind spot: 3 x AXI_TO_LIMIT = 12288 cycles). Simulated time is a few
// hundred microseconds; wall time is seconds.
//
// Simulation-only file: not part of src/**, not built by PDS, does not
// modify any RTL.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

// =============================================================================
// Testbench top: clock/reset, scenario instances, verdict table.
// =============================================================================
module tb_ddr3_subsys;

    reg clk;
    reg rst_n;

    initial begin
        clk   = 1'b0;
        rst_n = 1'b0;
    end

    always #5 clk = ~clk;

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
    end

    // ------------------------------------------------------------------
    // Scenario result wires (one bundle per scenario instance)
    // ------------------------------------------------------------------
    wire        c00_done, c00_pass;
    wire [31:0] c00_cyc;
    wire [7:0]  c00_dc0, c00_dc1, c00_dc2, c00_dc3;
    wire        c00_st_done, c00_st_fail;
    wire [27:0] c00_fail_addr;
    wire        c00_to_err;
    wire [3:0]  c00_cte;
    wire [2:0]  c00_dbg;
    wire [7:0]  c00_wmiss;
    wire [3:0]  c00_aerr;
    wire [31:0] c00_len0, c00_strb0, c00_strb1;
    wire [7:0]  c00_seq;

    wire        c01_done, c01_pass;
    wire [31:0] c01_cyc;
    wire [7:0]  c01_dc0, c01_dc1, c01_dc2, c01_dc3;
    wire        c01_st_done, c01_st_fail;
    wire [27:0] c01_fail_addr;
    wire        c01_to_err;
    wire [3:0]  c01_cte;
    wire [2:0]  c01_dbg;
    wire [7:0]  c01_wmiss;
    wire [3:0]  c01_aerr;
    wire [31:0] c01_len0, c01_strb0, c01_strb1;
    wire [7:0]  c01_seq;

    wire        c02_done, c02_pass;
    wire [31:0] c02_cyc;
    wire [7:0]  c02_dc0, c02_dc1, c02_dc2, c02_dc3;
    wire        c02_st_done, c02_st_fail;
    wire [27:0] c02_fail_addr;
    wire        c02_to_err;
    wire [3:0]  c02_cte;
    wire [2:0]  c02_dbg;
    wire [7:0]  c02_wmiss;
    wire [3:0]  c02_aerr;
    wire [31:0] c02_len0, c02_strb0, c02_strb1;
    wire [7:0]  c02_seq;

    wire        c03_done, c03_pass;
    wire [31:0] c03_cyc;
    wire [7:0]  c03_dc0, c03_dc1, c03_dc2, c03_dc3;
    wire        c03_st_done, c03_st_fail;
    wire [27:0] c03_fail_addr;
    wire        c03_to_err;
    wire [3:0]  c03_cte;
    wire [2:0]  c03_dbg;
    wire [7:0]  c03_wmiss;
    wire [3:0]  c03_aerr;
    wire [31:0] c03_len0, c03_strb0, c03_strb1;
    wire [7:0]  c03_seq;

    wire        c04_done, c04_pass;
    wire [31:0] c04_cyc;
    wire [7:0]  c04_dc0, c04_dc1, c04_dc2, c04_dc3;
    wire        c04_st_done, c04_st_fail;
    wire [27:0] c04_fail_addr;
    wire        c04_to_err;
    wire [3:0]  c04_cte;
    wire [2:0]  c04_dbg;
    wire [7:0]  c04_wmiss;
    wire [3:0]  c04_aerr;
    wire [31:0] c04_len0, c04_strb0, c04_strb1;
    wire [7:0]  c04_seq;

    wire        c05_done, c05_pass;
    wire [31:0] c05_cyc;
    wire [7:0]  c05_dc0, c05_dc1, c05_dc2, c05_dc3;
    wire        c05_st_done, c05_st_fail;
    wire [27:0] c05_fail_addr;
    wire        c05_to_err;
    wire [3:0]  c05_cte;
    wire [2:0]  c05_dbg;
    wire [7:0]  c05_wmiss;
    wire [3:0]  c05_aerr;
    wire [31:0] c05_len0, c05_strb0, c05_strb1;
    wire [7:0]  c05_seq;

    wire        c06_done, c06_pass;
    wire [31:0] c06_cyc;
    wire [7:0]  c06_dc0, c06_dc1, c06_dc2, c06_dc3;
    wire        c06_st_done, c06_st_fail;
    wire [27:0] c06_fail_addr;
    wire        c06_to_err;
    wire [3:0]  c06_cte;
    wire [2:0]  c06_dbg;
    wire [7:0]  c06_wmiss;
    wire [3:0]  c06_aerr;
    wire [31:0] c06_len0, c06_strb0, c06_strb1;
    wire [7:0]  c06_seq;

    wire        c07_done, c07_pass;
    wire [31:0] c07_cyc;
    wire [7:0]  c07_dc0, c07_dc1, c07_dc2, c07_dc3;
    wire        c07_st_done, c07_st_fail;
    wire [27:0] c07_fail_addr;
    wire        c07_to_err;
    wire [3:0]  c07_cte;
    wire [2:0]  c07_dbg;
    wire [7:0]  c07_wmiss;
    wire [3:0]  c07_aerr;
    wire [31:0] c07_len0, c07_strb0, c07_strb1;
    wire [7:0]  c07_seq;

    wire        c08_done, c08_pass;
    wire [31:0] c08_cyc;
    wire [7:0]  c08_dc0, c08_dc1, c08_dc2, c08_dc3;
    wire        c08_st_done, c08_st_fail;
    wire [27:0] c08_fail_addr;
    wire        c08_to_err;
    wire [3:0]  c08_cte;
    wire [2:0]  c08_dbg;
    wire [7:0]  c08_wmiss;
    wire [3:0]  c08_aerr;
    wire [31:0] c08_len0, c08_strb0, c08_strb1;
    wire [7:0]  c08_seq;

    wire        c09_done, c09_pass;
    wire [31:0] c09_cyc;
    wire [7:0]  c09_dc0, c09_dc1, c09_dc2, c09_dc3;
    wire        c09_st_done, c09_st_fail;
    wire [27:0] c09_fail_addr;
    wire        c09_to_err;
    wire [3:0]  c09_cte;
    wire [2:0]  c09_dbg;
    wire [7:0]  c09_wmiss;
    wire [3:0]  c09_aerr;
    wire [31:0] c09_len0, c09_strb0, c09_strb1;
    wire [7:0]  c09_seq;

    wire        c10_done, c10_pass;
    wire [31:0] c10_cyc;
    wire [7:0]  c10_dc0, c10_dc1, c10_dc2, c10_dc3;
    wire        c10_st_done, c10_st_fail;
    wire [27:0] c10_fail_addr;
    wire        c10_to_err;
    wire [3:0]  c10_cte;
    wire [2:0]  c10_dbg;
    wire [7:0]  c10_wmiss;
    wire [3:0]  c10_aerr;
    wire [31:0] c10_len0, c10_strb0, c10_strb1;
    wire [7:0]  c10_seq;

    wire        c11_done, c11_pass;
    wire [31:0] c11_cyc;
    wire [7:0]  c11_dc0, c11_dc1, c11_dc2, c11_dc3;
    wire        c11_st_done, c11_st_fail;
    wire [27:0] c11_fail_addr;
    wire        c11_to_err;
    wire [3:0]  c11_cte;
    wire [2:0]  c11_dbg;
    wire [7:0]  c11_wmiss;
    wire [3:0]  c11_aerr;
    wire [31:0] c11_len0, c11_strb0, c11_strb1;
    wire [7:0]  c11_seq;

    wire        c12_done, c12_pass;
    wire [31:0] c12_cyc;
    wire [7:0]  c12_dc0, c12_dc1, c12_dc2, c12_dc3;
    wire        c12_st_done, c12_st_fail;
    wire [27:0] c12_fail_addr;
    wire        c12_to_err;
    wire [3:0]  c12_cte;
    wire [2:0]  c12_dbg;
    wire [7:0]  c12_wmiss;
    wire [3:0]  c12_aerr;
    wire [31:0] c12_len0, c12_strb0, c12_strb1;
    wire [7:0]  c12_seq;

    wire        c13_done, c13_pass;
    wire [31:0] c13_cyc;
    wire [7:0]  c13_dc0, c13_dc1, c13_dc2, c13_dc3;
    wire        c13_st_done, c13_st_fail;
    wire [27:0] c13_fail_addr;
    wire        c13_to_err;
    wire [3:0]  c13_cte;
    wire [2:0]  c13_dbg;
    wire [7:0]  c13_wmiss;
    wire [3:0]  c13_aerr;
    wire [31:0] c13_len0, c13_strb0, c13_strb1;
    wire [7:0]  c13_seq;

    wire        c14_done, c14_pass;
    wire [31:0] c14_cyc;
    wire [7:0]  c14_dc0, c14_dc1, c14_dc2, c14_dc3;
    wire        c14_st_done, c14_st_fail;
    wire [27:0] c14_fail_addr;
    wire        c14_to_err;
    wire [3:0]  c14_cte;
    wire [2:0]  c14_dbg;
    wire [7:0]  c14_wmiss;
    wire [3:0]  c14_aerr;
    wire [31:0] c14_len0, c14_strb0, c14_strb1;
    wire [7:0]  c14_seq;

    // ------------------------------------------------------------------
    // Scenario C00: self_test 16 commands, healthy IP model
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO         (0),
        .AXI_TO_LIMIT     (4096),
        .P3_QUOTA_TIMEOUT (125000),
        .MAX_CYCLES       (20000)
    ) u_c00 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c00_done), .case_pass (c00_pass), .obs_cycles (c00_cyc),
        .obs_done_cnt0 (c00_dc0), .obs_done_cnt1 (c00_dc1),
        .obs_done_cnt2 (c00_dc2), .obs_done_cnt3 (c00_dc3),
        .obs_st_done (c00_st_done), .obs_st_fail (c00_st_fail),
        .obs_st_fail_addr (c00_fail_addr),
        .obs_to_err (c00_to_err), .obs_cmd_to_err (c00_cte),
        .obs_dbg_to_state (c00_dbg), .obs_wlast_miss (c00_wmiss),
        .obs_addr_err (c00_aerr), .obs_len0_wr (c00_len0),
        .obs_wstrb_zero (c00_strb0), .obs_wstrb_all1 (c00_strb1),
        .obs_seq (c00_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C01: m0_done WIRED, audio page writes + self_test on m3
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO         (1),
        .FIX_M0_DONE      (1),
        .AXI_TO_LIMIT     (4096),
        .P3_QUOTA_TIMEOUT (125000),
        .MAX_CYCLES       (20000)
    ) u_c01 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c01_done), .case_pass (c01_pass), .obs_cycles (c01_cyc),
        .obs_done_cnt0 (c01_dc0), .obs_done_cnt1 (c01_dc1),
        .obs_done_cnt2 (c01_dc2), .obs_done_cnt3 (c01_dc3),
        .obs_st_done (c01_st_done), .obs_st_fail (c01_st_fail),
        .obs_st_fail_addr (c01_fail_addr),
        .obs_to_err (c01_to_err), .obs_cmd_to_err (c01_cte),
        .obs_dbg_to_state (c01_dbg), .obs_wlast_miss (c01_wmiss),
        .obs_addr_err (c01_aerr), .obs_len0_wr (c01_len0),
        .obs_wstrb_zero (c01_strb0), .obs_wstrb_all1 (c01_strb1),
        .obs_seq (c01_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C02: m0_done NOT wired (m4 failure mode), self_test on m3
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO         (2),
        .FIX_M0_DONE      (0),
        .AXI_TO_LIMIT     (4096),
        .P3_QUOTA_TIMEOUT (500),
        .MAX_CYCLES       (20000)
    ) u_c02 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c02_done), .case_pass (c02_pass), .obs_cycles (c02_cyc),
        .obs_done_cnt0 (c02_dc0), .obs_done_cnt1 (c02_dc1),
        .obs_done_cnt2 (c02_dc2), .obs_done_cnt3 (c02_dc3),
        .obs_st_done (c02_st_done), .obs_st_fail (c02_st_fail),
        .obs_st_fail_addr (c02_fail_addr),
        .obs_to_err (c02_to_err), .obs_cmd_to_err (c02_cte),
        .obs_dbg_to_state (c02_dbg), .obs_wlast_miss (c02_wmiss),
        .obs_addr_err (c02_aerr), .obs_len0_wr (c02_len0),
        .obs_wstrb_zero (c02_strb0), .obs_wstrb_all1 (c02_strb1),
        .obs_seq (c02_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C03: read command LEVEL-held while the fifo is not drained
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO         (3),
        .PULSE_CMD        (0),
        .AXI_TO_LIMIT     (4096),
        .P3_QUOTA_TIMEOUT (125000),
        .MAX_CYCLES       (20000)
    ) u_c03 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c03_done), .case_pass (c03_pass), .obs_cycles (c03_cyc),
        .obs_done_cnt0 (c03_dc0), .obs_done_cnt1 (c03_dc1),
        .obs_done_cnt2 (c03_dc2), .obs_done_cnt3 (c03_dc3),
        .obs_st_done (c03_st_done), .obs_st_fail (c03_st_fail),
        .obs_st_fail_addr (c03_fail_addr),
        .obs_to_err (c03_to_err), .obs_cmd_to_err (c03_cte),
        .obs_dbg_to_state (c03_dbg), .obs_wlast_miss (c03_wmiss),
        .obs_addr_err (c03_aerr), .obs_len0_wr (c03_len0),
        .obs_wstrb_zero (c03_strb0), .obs_wstrb_all1 (c03_strb1),
        .obs_seq (c03_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C04: read command SINGLE-CYCLE strobe while the fifo is busy
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO         (4),
        .PULSE_CMD        (1),
        .AXI_TO_LIMIT     (4096),
        .P3_QUOTA_TIMEOUT (125000),
        .MAX_CYCLES       (20000)
    ) u_c04 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c04_done), .case_pass (c04_pass), .obs_cycles (c04_cyc),
        .obs_done_cnt0 (c04_dc0), .obs_done_cnt1 (c04_dc1),
        .obs_done_cnt2 (c04_dc2), .obs_done_cnt3 (c04_dc3),
        .obs_st_done (c04_st_done), .obs_st_fail (c04_st_fail),
        .obs_st_fail_addr (c04_fail_addr),
        .obs_to_err (c04_to_err), .obs_cmd_to_err (c04_cte),
        .obs_dbg_to_state (c04_dbg), .obs_wlast_miss (c04_wmiss),
        .obs_addr_err (c04_aerr), .obs_len0_wr (c04_len0),
        .obs_wstrb_zero (c04_strb0), .obs_wstrb_all1 (c04_strb1),
        .obs_seq (c04_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C05: watchdog in S_AW (awready never comes), self_test
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO            (5),
        .AW_READY_AW_COUNT   (0),
        .AXI_TO_LIMIT        (4096),
        .P3_QUOTA_TIMEOUT    (125000),
        .MAX_CYCLES          (20000)
    ) u_c05 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c05_done), .case_pass (c05_pass), .obs_cycles (c05_cyc),
        .obs_done_cnt0 (c05_dc0), .obs_done_cnt1 (c05_dc1),
        .obs_done_cnt2 (c05_dc2), .obs_done_cnt3 (c05_dc3),
        .obs_st_done (c05_st_done), .obs_st_fail (c05_st_fail),
        .obs_st_fail_addr (c05_fail_addr),
        .obs_to_err (c05_to_err), .obs_cmd_to_err (c05_cte),
        .obs_dbg_to_state (c05_dbg), .obs_wlast_miss (c05_wmiss),
        .obs_addr_err (c05_aerr), .obs_len0_wr (c05_len0),
        .obs_wstrb_zero (c05_strb0), .obs_wstrb_all1 (c05_strb1),
        .obs_seq (c05_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C06: watchdog in S_W (wready never comes), self_test
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO              (6),
        .W_READY_BURST_COUNT   (0),
        .AXI_TO_LIMIT          (4096),
        .P3_QUOTA_TIMEOUT      (125000),
        .MAX_CYCLES            (20000)
    ) u_c06 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c06_done), .case_pass (c06_pass), .obs_cycles (c06_cyc),
        .obs_done_cnt0 (c06_dc0), .obs_done_cnt1 (c06_dc1),
        .obs_done_cnt2 (c06_dc2), .obs_done_cnt3 (c06_dc3),
        .obs_st_done (c06_st_done), .obs_st_fail (c06_st_fail),
        .obs_st_fail_addr (c06_fail_addr),
        .obs_to_err (c06_to_err), .obs_cmd_to_err (c06_cte),
        .obs_dbg_to_state (c06_dbg), .obs_wlast_miss (c06_wmiss),
        .obs_addr_err (c06_aerr), .obs_len0_wr (c06_len0),
        .obs_wstrb_zero (c06_strb0), .obs_wstrb_all1 (c06_strb1),
        .obs_seq (c06_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C07: watchdog in S_AR (arready never comes), self_test
    //              (8 writes complete, then the first read's dummy write
    //               succeeds and the AR phase hangs)
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO         (7),
        .AR_NEVER         (1),
        .AXI_TO_LIMIT     (4096),
        .P3_QUOTA_TIMEOUT (125000),
        .MAX_CYCLES       (20000)
    ) u_c07 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c07_done), .case_pass (c07_pass), .obs_cycles (c07_cyc),
        .obs_done_cnt0 (c07_dc0), .obs_done_cnt1 (c07_dc1),
        .obs_done_cnt2 (c07_dc2), .obs_done_cnt3 (c07_dc3),
        .obs_st_done (c07_st_done), .obs_st_fail (c07_st_fail),
        .obs_st_fail_addr (c07_fail_addr),
        .obs_to_err (c07_to_err), .obs_cmd_to_err (c07_cte),
        .obs_dbg_to_state (c07_dbg), .obs_wlast_miss (c07_wmiss),
        .obs_addr_err (c07_aerr), .obs_len0_wr (c07_len0),
        .obs_wstrb_zero (c07_strb0), .obs_wstrb_all1 (c07_strb1),
        .obs_seq (c07_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C08: watchdog in S_DW_AW (dummy-write address), simple read
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO            (8),
        .AW_READY_AW_COUNT   (0),
        .AXI_TO_LIMIT        (4096),
        .P3_QUOTA_TIMEOUT    (125000),
        .MAX_CYCLES          (20000)
    ) u_c08 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c08_done), .case_pass (c08_pass), .obs_cycles (c08_cyc),
        .obs_done_cnt0 (c08_dc0), .obs_done_cnt1 (c08_dc1),
        .obs_done_cnt2 (c08_dc2), .obs_done_cnt3 (c08_dc3),
        .obs_st_done (c08_st_done), .obs_st_fail (c08_st_fail),
        .obs_st_fail_addr (c08_fail_addr),
        .obs_to_err (c08_to_err), .obs_cmd_to_err (c08_cte),
        .obs_dbg_to_state (c08_dbg), .obs_wlast_miss (c08_wmiss),
        .obs_addr_err (c08_aerr), .obs_len0_wr (c08_len0),
        .obs_wstrb_zero (c08_strb0), .obs_wstrb_all1 (c08_strb1),
        .obs_seq (c08_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C09: watchdog in S_DW_W (dummy-write data), simple read
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO              (9),
        .W_READY_BURST_COUNT   (0),
        .AXI_TO_LIMIT          (4096),
        .P3_QUOTA_TIMEOUT      (125000),
        .MAX_CYCLES            (20000)
    ) u_c09 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c09_done), .case_pass (c09_pass), .obs_cycles (c09_cyc),
        .obs_done_cnt0 (c09_dc0), .obs_done_cnt1 (c09_dc1),
        .obs_done_cnt2 (c09_dc2), .obs_done_cnt3 (c09_dc3),
        .obs_st_done (c09_st_done), .obs_st_fail (c09_st_fail),
        .obs_st_fail_addr (c09_fail_addr),
        .obs_to_err (c09_to_err), .obs_cmd_to_err (c09_cte),
        .obs_dbg_to_state (c09_dbg), .obs_wlast_miss (c09_wmiss),
        .obs_addr_err (c09_aerr), .obs_len0_wr (c09_len0),
        .obs_wstrb_zero (c09_strb0), .obs_wstrb_all1 (c09_strb1),
        .obs_seq (c09_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C10: self_test with DUMMY_WSTRB_ALL1 = 1 (demo config)
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO          (10),
        .DUMMY_WSTRB_ALL1  (1),
        .AXI_TO_LIMIT      (4096),
        .P3_QUOTA_TIMEOUT  (125000),
        .MAX_CYCLES        (20000)
    ) u_c10 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c10_done), .case_pass (c10_pass), .obs_cycles (c10_cyc),
        .obs_done_cnt0 (c10_dc0), .obs_done_cnt1 (c10_dc1),
        .obs_done_cnt2 (c10_dc2), .obs_done_cnt3 (c10_dc3),
        .obs_st_done (c10_st_done), .obs_st_fail (c10_st_fail),
        .obs_st_fail_addr (c10_fail_addr),
        .obs_to_err (c10_to_err), .obs_cmd_to_err (c10_cte),
        .obs_dbg_to_state (c10_dbg), .obs_wlast_miss (c10_wmiss),
        .obs_addr_err (c10_aerr), .obs_len0_wr (c10_len0),
        .obs_wstrb_zero (c10_strb0), .obs_wstrb_all1 (c10_strb1),
        .obs_seq (c10_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C11: four masters request simultaneously, quota disabled
    //               (fixed priority order expected: m0, m1, m2, m3)
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO         (11),
        .USE_EXT_M3       (1),
        .AXI_TO_LIMIT     (4096),
        .P3_QUOTA_TIMEOUT (125000),
        .MAX_CYCLES       (20000)
    ) u_c11 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c11_done), .case_pass (c11_pass), .obs_cycles (c11_cyc),
        .obs_done_cnt0 (c11_dc0), .obs_done_cnt1 (c11_dc1),
        .obs_done_cnt2 (c11_dc2), .obs_done_cnt3 (c11_dc3),
        .obs_st_done (c11_st_done), .obs_st_fail (c11_st_fail),
        .obs_st_fail_addr (c11_fail_addr),
        .obs_to_err (c11_to_err), .obs_cmd_to_err (c11_cte),
        .obs_dbg_to_state (c11_dbg), .obs_wlast_miss (c11_wmiss),
        .obs_addr_err (c11_aerr), .obs_len0_wr (c11_len0),
        .obs_wstrb_zero (c11_strb0), .obs_wstrb_all1 (c11_strb1),
        .obs_seq (c11_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C12: WATCHDOG BLIND SPOT - rvalid stuck high, rlast never
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO         (12),
        .R_MODE           (1),
        .AXI_TO_LIMIT     (4096),
        .P3_QUOTA_TIMEOUT (125000),
        .MAX_CYCLES       (20000)
    ) u_c12 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c12_done), .case_pass (c12_pass), .obs_cycles (c12_cyc),
        .obs_done_cnt0 (c12_dc0), .obs_done_cnt1 (c12_dc1),
        .obs_done_cnt2 (c12_dc2), .obs_done_cnt3 (c12_dc3),
        .obs_st_done (c12_st_done), .obs_st_fail (c12_st_fail),
        .obs_st_fail_addr (c12_fail_addr),
        .obs_to_err (c12_to_err), .obs_cmd_to_err (c12_cte),
        .obs_dbg_to_state (c12_dbg), .obs_wlast_miss (c12_wmiss),
        .obs_addr_err (c12_aerr), .obs_len0_wr (c12_len0),
        .obs_wstrb_zero (c12_strb0), .obs_wstrb_all1 (c12_strb1),
        .obs_seq (c12_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C13: P3 starvation quota with m0/m1/m2 continuously busy
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO         (13),
        .USE_EXT_M3       (1),
        .AXI_TO_LIMIT     (4096),
        .P3_QUOTA_TIMEOUT (200),
        .MAX_CYCLES       (20000)
    ) u_c13 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c13_done), .case_pass (c13_pass), .obs_cycles (c13_cyc),
        .obs_done_cnt0 (c13_dc0), .obs_done_cnt1 (c13_dc1),
        .obs_done_cnt2 (c13_dc2), .obs_done_cnt3 (c13_dc3),
        .obs_st_done (c13_st_done), .obs_st_fail (c13_st_fail),
        .obs_st_fail_addr (c13_fail_addr),
        .obs_to_err (c13_to_err), .obs_cmd_to_err (c13_cte),
        .obs_dbg_to_state (c13_dbg), .obs_wlast_miss (c13_wmiss),
        .obs_addr_err (c13_aerr), .obs_len0_wr (c13_len0),
        .obs_wstrb_zero (c13_strb0), .obs_wstrb_all1 (c13_strb1),
        .obs_seq (c13_seq)
    );

    // ------------------------------------------------------------------
    // Scenario C14: recovery after a write-data phase abort. The first read
    // times out in S_DW_W; the second read is then issued and times out in
    // S_DW_AW because the model still holds the unfinished write burst.
    // ------------------------------------------------------------------
    ddr3_subsys_case #(
        .SCENARIO              (14),
        .W_READY_BURST_COUNT   (0),
        .AXI_TO_LIMIT          (4096),
        .P3_QUOTA_TIMEOUT      (125000),
        .MAX_CYCLES            (20000)
    ) u_c14 (
        .clk (clk), .rst_n (rst_n),
        .case_done (c14_done), .case_pass (c14_pass), .obs_cycles (c14_cyc),
        .obs_done_cnt0 (c14_dc0), .obs_done_cnt1 (c14_dc1),
        .obs_done_cnt2 (c14_dc2), .obs_done_cnt3 (c14_dc3),
        .obs_st_done (c14_st_done), .obs_st_fail (c14_st_fail),
        .obs_st_fail_addr (c14_fail_addr),
        .obs_to_err (c14_to_err), .obs_cmd_to_err (c14_cte),
        .obs_dbg_to_state (c14_dbg), .obs_wlast_miss (c14_wmiss),
        .obs_addr_err (c14_aerr), .obs_len0_wr (c14_len0),
        .obs_wstrb_zero (c14_strb0), .obs_wstrb_all1 (c14_strb1),
        .obs_seq (c14_seq)
    );

    // ------------------------------------------------------------------
    // Global termination + report
    // ------------------------------------------------------------------
    wire all_done = c00_done & c01_done & c02_done & c03_done & c04_done &
                    c05_done & c06_done & c07_done & c08_done & c09_done &
                    c10_done & c11_done & c12_done & c13_done & c14_done;

    // Pretty printer for the FSM state id exported by dbg_to_state.
    task show_state_at;
        input [8*30-1:0] label;
        input [2:0]      st;
        begin
            if (st == 3'd0)      $display("  %0s : S_IDLE", label);
            else if (st == 3'd1) $display("  %0s : S_AW", label);
            else if (st == 3'd2) $display("  %0s : S_W", label);
            else if (st == 3'd3) $display("  %0s : S_WLAST", label);
            else if (st == 3'd4) $display("  %0s : S_DW_AW", label);
            else if (st == 3'd5) $display("  %0s : S_DW_W", label);
            else if (st == 3'd6) $display("  %0s : S_AR", label);
            else if (st == 3'd7) $display("  %0s : S_R", label);
            else                 $display("  %0s : ?", label);
        end
    endtask

    task show_verdict;
        input [8*56-1:0] label;
        input            ok;
        begin
            if (ok) $display("  %0s : PASS", label);
            else    $display("  %0s : FAIL", label);
        end
    endtask

    integer wait_cyc;
    integer fail_cnt;

    initial begin
        wait_cyc = 0;
        fail_cnt = 0;
        while ((!all_done) && (wait_cyc < 400000)) begin
            @(posedge clk);
            wait_cyc = wait_cyc + 1;
        end
        repeat (8) @(posedge clk);   // let the per-scenario latches settle

        $display("");
        $display("==============================================================");
        $display(" DDR3 SUBSYSTEM SIMULATION - scenario results");
        $display("==============================================================");

        $display("  C00 self_test healthy        : pass=%0b cyc=%0d",
                 c00_pass, c00_cyc);
        $display("       st_done=%0b st_fail=%0b fail_addr=%h to_err=%0b dbg=%0d",
                 c00_st_done, c00_st_fail, c00_fail_addr, c00_to_err, c00_dbg);
        $display("       done m0/m1/m2/m3=%0d/%0d/%0d/%0d wlast_miss=%0d len0_wr=%0d wstrb0=%0d wstrb1=%0d",
                 c00_dc0, c00_dc1, c00_dc2, c00_dc3, c00_wmiss,
                 c00_len0, c00_strb0, c00_strb1);

        $display("  C01 m0_done WIRED, m0+m3     : pass=%0b cyc=%0d st_done=%0b st_fail=%0b done m0/m3=%0d/%0d to_err=%0b",
                 c01_pass, c01_cyc, c01_st_done, c01_st_fail, c01_dc0, c01_dc3, c01_to_err);

        $display("  C02 m0_done OPEN,  m0+m3     : pass=%0b cyc=%0d st_done=%0b st_fail=%0b done m0/m3=%0d/%0d to_err=%0b",
                 c02_pass, c02_cyc, c02_st_done, c02_st_fail, c02_dc0, c02_dc3, c02_to_err);

        $display("  C03 read cmd LEVEL held      : pass=%0b cyc=%0d dc2=%0d to_err=%0b",
                 c03_pass, c03_cyc, c03_dc2, c03_to_err);
        $display("  C04 read cmd SINGLE pulse    : pass=%0b cyc=%0d dc2=%0d to_err=%0b",
                 c04_pass, c04_cyc, c04_dc2, c04_to_err);

        $display("  C05 watchdog S_AW            : pass=%0b cyc=%0d to_err=%0b cte=%b dbg=%0d dc3=%0d st_fail=%0b",
                 c05_pass, c05_cyc, c05_to_err, c05_cte, c05_dbg, c05_dc3, c05_st_fail);
        $display("  C06 watchdog S_W             : pass=%0b cyc=%0d to_err=%0b cte=%b dbg=%0d dc3=%0d st_fail=%0b",
                 c06_pass, c06_cyc, c06_to_err, c06_cte, c06_dbg, c06_dc3, c06_st_fail);
        $display("  C07 watchdog S_AR            : pass=%0b cyc=%0d to_err=%0b cte=%b dbg=%0d dc3=%0d st_fail=%0b",
                 c07_pass, c07_cyc, c07_to_err, c07_cte, c07_dbg, c07_dc3, c07_st_fail);
        $display("  C08 watchdog S_DW_AW         : pass=%0b cyc=%0d to_err=%0b cte=%b dbg=%0d dc2=%0d",
                 c08_pass, c08_cyc, c08_to_err, c08_cte, c08_dbg, c08_dc2);
        $display("  C09 watchdog S_DW_W          : pass=%0b cyc=%0d to_err=%0b cte=%b dbg=%0d dc2=%0d",
                 c09_pass, c09_cyc, c09_to_err, c09_cte, c09_dbg, c09_dc2);

        $display("  C10 DUMMY_WSTRB_ALL1=1       : pass=%0b st_done=%0b st_fail=%0b fail_addr=%h len0_wr=%0d wstrb1=%0d",
                 c10_pass, c10_st_done, c10_st_fail, c10_fail_addr, c10_len0, c10_strb1);

        $display("  C11 four-master priority     : pass=%0b seq=%b (expect 00011011) done=%0d/%0d/%0d/%0d",
                 c11_pass, c11_seq, c11_dc0, c11_dc1, c11_dc2, c11_dc3);

        $display("  C12 watchdog blind spot      : pass=%0b cyc=%0d to_err=%0b dc2=%0d",
                 c12_pass, c12_cyc, c12_to_err, c12_dc2);

        $display("  C13 P3 quota                 : pass=%0b done m0/m1/m2/m3=%0d/%0d/%0d/%0d",
                 c13_pass, c13_dc0, c13_dc1, c13_dc2, c13_dc3);

        $display("  C14 abort recovery           : pass=%0b cyc=%0d dbg(last)=%0d dc2=%0d to_err=%0b",
                 c14_pass, c14_cyc, c14_dbg, c14_dc2, c14_to_err);

        $display("");
        $display("==============================================================");
        $display(" DDR3 SUBSYS VERDICT");
        $display("==============================================================");

        show_verdict("self_test 16 cmds", c00_pass);
        $display("  st_done / st_fail        : %0d / %0d", c00_st_done, c00_st_fail);
        $display("  to_err / cmd_to_err[3]   : %0d / %0d", c00_to_err, c00_cte[3]);

        if (c05_to_err)      show_state_at("dbg_to_state (timeout at)", c05_dbg);
        else if (c06_to_err) show_state_at("dbg_to_state (timeout at)", c06_dbg);
        else if (c07_to_err) show_state_at("dbg_to_state (timeout at)", c07_dbg);
        else                 $display("  dbg_to_state (timeout at) : none");

        if (c01_pass && c02_pass) begin
            $display("  m0 starvation resolved   : YES (m3 done cyc C01=%0d wired vs C02=%0d quota-only)",
                     c01_cyc, c02_cyc);
        end else if (c01_pass) begin
            $display("  m0 starvation resolved   : PARTIAL (wired path ok, open path not)");
        end else begin
            $display("  m0 starvation resolved   : NO");
        end

        if (c12_pass) $display("  watchdog blind spot      : CONFIRMED");
        else          $display("  watchdog blind spot      : NOT-REPRODUCED");

        $display("==============================================================");
        $display("  T28 item checklist");
        $display("==============================================================");
        show_verdict("1.  self_test 16 cmds all complete       ", c00_pass);
        show_verdict("2.  m0_done fix keeps m3 served          ", c01_pass);
        show_verdict("2b. m0_done open still bounded by quota  ", c02_pass);
        show_verdict("3a. level-held read cmd is safe          ", c03_pass);
        show_verdict("3b. single-cycle read cmd is lost        ", c04_pass);
        show_verdict("4.  watchdog fires in S_AW               ", c05_pass);
        show_verdict("4b. watchdog fires in S_W                ", c06_pass);
        show_verdict("4c. watchdog fires in S_AR               ", c07_pass);
        show_verdict("4d. watchdog fires in S_DW_AW            ", c08_pass);
        show_verdict("4e. watchdog fires in S_DW_W             ", c09_pass);
        show_verdict("5.  watchdog blind spot reproduced       ", c12_pass);
        show_verdict("6a. dummy strobe all-zero is safe        ", c00_pass);
        show_verdict("6b. dummy strobe all-one corrupts read   ", c10_pass);
        show_verdict("7a. fixed priority m0>m1>m2>m3           ", c11_pass);
        show_verdict("7b. P3 quota override works              ", c13_pass);
        show_verdict("x.  abort recovery (IP state polluted)   ", c14_pass);

        fail_cnt = 0;
        if (!c00_pass) fail_cnt = fail_cnt + 1;
        if (!c01_pass) fail_cnt = fail_cnt + 1;
        if (!c02_pass) fail_cnt = fail_cnt + 1;
        if (!c03_pass) fail_cnt = fail_cnt + 1;
        if (!c04_pass) fail_cnt = fail_cnt + 1;
        if (!c05_pass) fail_cnt = fail_cnt + 1;
        if (!c06_pass) fail_cnt = fail_cnt + 1;
        if (!c07_pass) fail_cnt = fail_cnt + 1;
        if (!c08_pass) fail_cnt = fail_cnt + 1;
        if (!c09_pass) fail_cnt = fail_cnt + 1;
        if (!c10_pass) fail_cnt = fail_cnt + 1;
        if (!c11_pass) fail_cnt = fail_cnt + 1;
        if (!c12_pass) fail_cnt = fail_cnt + 1;
        if (!c13_pass) fail_cnt = fail_cnt + 1;
        if (!c14_pass) fail_cnt = fail_cnt + 1;

        $display("");
        $display("  scenarios failed         : %0d / 15", fail_cnt);
        $display("  global wait cycles       : %0d", wait_cyc);
        $display("==============================================================");
        // Machine-readable verdict consumed by sim/run_sim.py
        if (fail_cnt == 0) $display("RESULT: PASS");
        else               $display("RESULT: FAIL (%0d scenarios)", fail_cnt);
        $finish;
    end

endmodule


// =============================================================================
// Scenario harness: one ddr3_ctrl_axi + ddr3_arbiter + self_test + IP model,
// plus the master drivers for the scenario selected by SCENARIO.
// =============================================================================
module ddr3_subsys_case #(
    parameter integer SCENARIO            = 0,
    parameter integer AW_READY_AW_COUNT   = -1,
    parameter integer W_READY_BURST_COUNT = -1,
    parameter integer AR_NEVER            = 0,
    parameter integer R_MODE              = 0,
    parameter integer DUMMY_WSTRB_ALL1    = 0,
    parameter integer AXI_TO_LIMIT        = 4096,
    parameter integer P3_QUOTA_TIMEOUT    = 125000,
    parameter integer FIX_M0_DONE         = 1,
    parameter integer PULSE_CMD           = 0,
    parameter integer USE_EXT_M3          = 0,
    parameter integer MAX_CYCLES          = 200000
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         case_done,
    output reg         case_pass,
    output wire [31:0] obs_cycles,
    output wire [7:0]  obs_done_cnt0,
    output wire [7:0]  obs_done_cnt1,
    output wire [7:0]  obs_done_cnt2,
    output wire [7:0]  obs_done_cnt3,
    output wire        obs_st_done,
    output wire        obs_st_fail,
    output wire [27:0] obs_st_fail_addr,
    output wire        obs_to_err,
    output wire [3:0]  obs_cmd_to_err,
    output wire [2:0]  obs_dbg_to_state,
    output wire [7:0]  obs_wlast_miss,
    output wire [3:0]  obs_addr_err,
    output wire [31:0] obs_len0_wr,
    output wire [31:0] obs_wstrb_zero,
    output wire [31:0] obs_wstrb_all1,
    output wire [7:0]  obs_seq
);

    // ------------------------------------------------------------------
    // Master side registers (m0..m2 driven here, m3 either self_test or
    // an external driver depending on USE_EXT_M3)
    // ------------------------------------------------------------------
    reg  [2:0]   m_cv;
    reg  [36:0]  m0_cmd_r, m1_cmd_r, m2_cmd_r;
    reg  [255:0] m0_wdata_r, m1_wdata_r, m2_wdata_r;
    reg  [2:0]   rd_ready_r;

    reg          m3_cv_ext;
    reg  [36:0]  m3_cmd_ext;
    reg  [255:0] m3_wdata_ext;
    reg          m3_rd_ready_ext;

    // ------------------------------------------------------------------
    // self_test on master 3 (also present when USE_EXT_M3 is set: it is
    // simply not started, st_start stays low and its outputs are ignored)
    // ------------------------------------------------------------------
    reg          st_start;
    wire         st_cv;
    wire [36:0]  st_cmd;
    wire [255:0] st_wdata;
    wire         st_rd_ready;
    wire         st_done_o;
    wire         st_fail_o;
    wire [27:0]  st_fail_addr_o;

    wire         m3_cv        = USE_EXT_M3 ? m3_cv_ext    : st_cv;
    wire [36:0]  m3_cmd       = USE_EXT_M3 ? m3_cmd_ext   : st_cmd;
    wire [255:0] m3_wdata     = USE_EXT_M3 ? m3_wdata_ext : st_wdata;
    wire         m3_rd_ready  = USE_EXT_M3 ? m3_rd_ready_ext : st_rd_ready;

    wire [3:0]   cmd_valid = {m3_cv, m_cv};
    wire [3:0]   rd_ready  = {m3_rd_ready, rd_ready_r};

    // ------------------------------------------------------------------
    // Controller under test
    // ------------------------------------------------------------------
    wire [3:0]   done;
    wire [3:0]   wready_beat;
    wire [3:0]   rd_valid;
    wire [255:0] rd_data_0, rd_data_1, rd_data_2, rd_data_3;
    wire         to_err;
    wire [3:0]   cmd_to_err;
    wire [2:0]   dbg_to_state;
    wire [7:0]   wlast_miss;
    wire [3:0]   addr_err;
    wire [31:0]  wc0, wc1, wc2, wc3;

    // IP-side bundle
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

    ddr3_ctrl_axi #(
        .AXI_USER_AP      (1'b1),
        .DUMMY_WSTRB_ALL1 ((DUMMY_WSTRB_ALL1 != 0)),
        .AXI_TO_LIMIT     (AXI_TO_LIMIT),
        .P3_QUOTA_TIMEOUT (P3_QUOTA_TIMEOUT)
    ) u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .cmd_valid   (cmd_valid),
        .m0_cmd      (m0_cmd_r),
        .m1_cmd      (m1_cmd_r),
        .m2_cmd      (m2_cmd_r),
        .m3_cmd      (m3_cmd),
        .m0_wdata    (m0_wdata_r),
        .m1_wdata    (m1_wdata_r),
        .m2_wdata    (m2_wdata_r),
        .m3_wdata    (m3_wdata),
        .wready_beat (wready_beat),
        .rd_ready    (rd_ready),
        .rd_data_0   (rd_data_0),
        .rd_data_1   (rd_data_1),
        .rd_data_2   (rd_data_2),
        .rd_data_3   (rd_data_3),
        .rd_valid    (rd_valid),
        .done        (done),
        .wait_cnt_0  (wc0),
        .wait_cnt_1  (wc1),
        .wait_cnt_2  (wc2),
        .wait_cnt_3  (wc3),
        .addr_err    (addr_err),
        .to_err      (to_err),
        .cmd_to_err  (cmd_to_err),
        .dbg_to_state(dbg_to_state),
        .wlast_miss_cnt (wlast_miss),
        .axi_awaddr      (axi_awaddr),
        .axi_awuser_ap   (axi_awuser_ap),
        .axi_awuser_id   (axi_awuser_id),
        .axi_awlen       (axi_awlen),
        .axi_awvalid     (axi_awvalid),
        .axi_awready     (axi_awready),
        .axi_wdata       (axi_wdata),
        .axi_wstrb       (axi_wstrb),
        .axi_wready      (axi_wready),
        .axi_wusero_id   (axi_wusero_id),
        .axi_wusero_last (axi_wusero_last),
        .axi_araddr      (axi_araddr),
        .axi_aruser_ap   (axi_aruser_ap),
        .axi_aruser_id   (axi_aruser_id),
        .axi_arlen       (axi_arlen),
        .axi_arvalid     (axi_arvalid),
        .axi_arready     (axi_arready),
        .axi_rdata       (axi_rdata),
        .axi_rid         (axi_rid),
        .axi_rlast       (axi_rlast),
        .axi_rvalid      (axi_rvalid)
    );

    // self_test on master port 3
    self_test u_self_test (
        .clk          (clk),
        .rst_n        (rst_n),
        .st_start     (st_start),
        .cmd_valid    (st_cv),
        .cmd          (st_cmd),
        .wdata        (st_wdata),
        .wready_beat  (wready_beat[3]),
        .rd_ready     (st_rd_ready),
        .rd_data      (rd_data_3),
        .rd_valid     (rd_valid[3]),
        .done         (done[3]),
        .st_done      (st_done_o),
        .st_fail      (st_fail_o),
        .st_fail_addr (st_fail_addr_o)
    );

    // ------------------------------------------------------------------
    // Behavioral DDR3 IP model
    // ------------------------------------------------------------------
    wire [31:0] mobs_aw, mobs_ar, mobs_wb, mobs_rb, mobs_len0, mobs_s0, mobs_s1;

    ddr3_axi_model #(
        .AW_READY_AW_COUNT   (AW_READY_AW_COUNT),
        .W_READY_BURST_COUNT (W_READY_BURST_COUNT),
        .AR_NEVER            (AR_NEVER),
        .R_MODE              (R_MODE),
        .MEM_BEATS           (65536)
    ) u_model (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_awaddr       (axi_awaddr),
        .s_awvalid      (axi_awvalid),
        .s_awlen        (axi_awlen),
        .s_awuser_id    (axi_awuser_id),
        .s_awready      (axi_awready),
        .s_wdata        (axi_wdata),
        .s_wstrb        (axi_wstrb),
        .s_wready       (axi_wready),
        .s_wusero_last  (axi_wusero_last),
        .s_araddr       (axi_araddr),
        .s_arvalid      (axi_arvalid),
        .s_arlen        (axi_arlen),
        .s_aruser_id    (axi_aruser_id),
        .s_arready      (axi_arready),
        .s_rdata        (axi_rdata),
        .s_rid          (axi_rid),
        .s_rlast        (axi_rlast),
        .s_rvalid       (axi_rvalid),
        .obs_aw_hs      (mobs_aw),
        .obs_ar_hs      (mobs_ar),
        .obs_wr_beats   (mobs_wb),
        .obs_rd_beats   (mobs_rb),
        .obs_len0_wr    (mobs_len0),
        .obs_len0_wstrb0(mobs_s0),
        .obs_len0_wstrb1(mobs_s1),
        .obs_last_marker()
    );

    // The unused wusero_id is tied low (the controller does not read it).
    assign axi_wusero_id = 4'd0;

    // ------------------------------------------------------------------
    // Common bookkeeping: cycle counter, per-master done counts, the first
    // four done owners packed into obs_seq (newest in the low 2 bits).
    // ------------------------------------------------------------------
    reg [31:0] cyc;
    reg [7:0]  dc0, dc1, dc2, dc3;
    reg [7:0]  seq_r;
    reg [1:0]  owner_now;

    always @* begin
        if (done[0])      owner_now = 2'd0;
        else if (done[1]) owner_now = 2'd1;
        else if (done[2]) owner_now = 2'd2;
        else              owner_now = 2'd3;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc   <= 32'd0;
            dc0   <= 8'd0;
            dc1   <= 8'd0;
            dc2   <= 8'd0;
            dc3   <= 8'd0;
            seq_r <= 8'd0;
        end else begin
            cyc <= cyc + 32'd1;
            if (done[0]) dc0 <= dc0 + 8'd1;
            if (done[1]) dc1 <= dc1 + 8'd1;
            if (done[2]) dc2 <= dc2 + 8'd1;
            if (done[3]) dc3 <= dc3 + 8'd1;
            if (|done) begin
                seq_r <= {seq_r[5:0], owner_now};
            end
        end
    end

    // ------------------------------------------------------------------
    // Freeze the observation bundle on the cycle the scenario declares
    // itself finished, so the report shows the values AT verdict time and
    // not whatever the idle DUT drifted to afterwards.
    // ------------------------------------------------------------------
    reg [31:0] l_cyc;
    reg [7:0]  l_dc0, l_dc1, l_dc2, l_dc3, l_seq;
    reg        l_st_done, l_st_fail, l_to_err;
    reg [27:0] l_fail_addr;
    reg [3:0]  l_cte, l_aerr;
    reg [2:0]  l_dbg;
    reg [7:0]  l_wmiss;
    reg [31:0] l_len0, l_s0, l_s1;
    reg        latched;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latched     <= 1'b0;
            l_cyc       <= 32'd0;
            l_dc0       <= 8'd0;
            l_dc1       <= 8'd0;
            l_dc2       <= 8'd0;
            l_dc3       <= 8'd0;
            l_seq       <= 8'd0;
            l_st_done   <= 1'b0;
            l_st_fail   <= 1'b0;
            l_to_err    <= 1'b0;
            l_fail_addr <= 28'd0;
            l_cte       <= 4'd0;
            l_aerr      <= 4'd0;
            l_dbg       <= 3'd0;
            l_wmiss     <= 8'd0;
            l_len0      <= 32'd0;
            l_s0        <= 32'd0;
            l_s1        <= 32'd0;
        end else if (case_done && !latched) begin
            latched     <= 1'b1;
            l_cyc       <= cyc;
            l_dc0       <= dc0;
            l_dc1       <= dc1;
            l_dc2       <= dc2;
            l_dc3       <= dc3;
            l_seq       <= seq_r;
            l_st_done   <= st_done_o;
            l_st_fail   <= st_fail_o;
            l_to_err    <= to_err;
            l_fail_addr <= st_fail_addr_o;
            l_cte       <= cmd_to_err;
            l_aerr      <= addr_err;
            l_dbg       <= dbg_to_state;
            l_wmiss     <= wlast_miss;
            l_len0      <= mobs_len0;
            l_s0        <= mobs_s0;
            l_s1        <= mobs_s1;
        end
    end

    assign obs_cycles      = l_cyc;
    assign obs_done_cnt0   = l_dc0;
    assign obs_done_cnt1   = l_dc1;
    assign obs_done_cnt2   = l_dc2;
    assign obs_done_cnt3   = l_dc3;
    assign obs_st_done     = l_st_done;
    assign obs_st_fail     = l_st_fail;
    assign obs_st_fail_addr= l_fail_addr;
    assign obs_to_err      = l_to_err;
    assign obs_cmd_to_err  = l_cte;
    assign obs_dbg_to_state= l_dbg;
    assign obs_wlast_miss  = l_wmiss;
    assign obs_addr_err    = l_aerr;
    assign obs_len0_wr     = l_len0;
    assign obs_wstrb_zero  = l_s0;
    assign obs_wstrb_all1  = l_s1;
    assign obs_seq         = l_seq;

    // ------------------------------------------------------------------
    // Scenario drivers
    // ------------------------------------------------------------------
    generate
        // ----------------------------------------------------------------
        // C00 / C10 (self_test) and C05 / C06 / C07 (self_test + fault):
        // drive st_start once, then wait for st_done / st_fail.
        // ----------------------------------------------------------------
        if ((SCENARIO == 0) || (SCENARIO == 5) || (SCENARIO == 6) ||
            (SCENARIO == 7) || (SCENARIO == 10)) begin : g_self_test
            reg [1:0] s_ph;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    s_ph          <= 2'd0;
                    st_start      <= 1'b0;
                    m_cv          <= 3'd0;
                    rd_ready_r    <= 3'd0;
                    m0_cmd_r      <= 37'd0;
                    m1_cmd_r      <= 37'd0;
                    m2_cmd_r      <= 37'd0;
                    m0_wdata_r    <= 256'd0;
                    m1_wdata_r    <= 256'd0;
                    m2_wdata_r    <= 256'd0;
                    m3_cv_ext     <= 1'b0;
                    m3_cmd_ext    <= 37'd0;
                    m3_wdata_ext  <= 256'd0;
                    m3_rd_ready_ext <= 1'b0;
                    case_done     <= 1'b0;
                    case_pass     <= 1'b0;
                end else begin
                    case (s_ph)
                        2'd0: if (cyc > 32'd8) begin
                            st_start <= 1'b1;
                            s_ph     <= 2'd1;
                        end
                        2'd1: begin
                            st_start <= 1'b0;
                            s_ph     <= 2'd2;
                        end
                        2'd2: begin
                            if (st_done_o || st_fail_o || (cyc > MAX_CYCLES)) begin
                                case_done <= 1'b1;
                                if (SCENARIO == 0) begin
                                    case_pass <= st_done_o && !st_fail_o &&
                                                 (dc3 == 8'd16) && !to_err &&
                                                 (wlast_miss == 8'd0);
                                end else if (SCENARIO == 5) begin
                                    // first write aborts in S_AW
                                    case_pass <= to_err && cmd_to_err[3] &&
                                                 (dbg_to_state == 3'd1) &&
                                                 (dc3 == 8'd1) && st_fail_o;
                                end else if (SCENARIO == 6) begin
                                    // first write aborts in S_W
                                    case_pass <= to_err && cmd_to_err[3] &&
                                                 (dbg_to_state == 3'd2) &&
                                                 (dc3 == 8'd1) && st_fail_o;
                                end else if (SCENARIO == 7) begin
                                    // 8 writes pass, first read aborts in S_AR
                                    case_pass <= to_err && cmd_to_err[3] &&
                                                 (dbg_to_state == 3'd6) &&
                                                 (dc3 == 8'd9) && st_fail_o;
                                end else begin
                                    // dummy strobe all-ones destroys the
                                    // first beat of the region being read
                                    case_pass <= st_fail_o && !st_done_o &&
                                                 (st_fail_addr_o == 28'h0030_0000);
                                end
                                s_ph <= 2'd3;
                            end
                        end
                        default: ;
                    endcase
                end
            end
        end

        // ----------------------------------------------------------------
        // C01 / C02: audio_sink-equivalent master 0 (32-byte page writes,
        // len=0, cmd_valid held until done) plus self_test on master 3.
        // FIX_M0_DONE=1 : done triggers the next page (m4fix behaviour)
        // FIX_M0_DONE=0 : done ignored, request stays high forever (the
        //                 m4 board failure mode that starved master 3)
        // ----------------------------------------------------------------
        if ((SCENARIO == 1) || (SCENARIO == 2)) begin : g_audio
            reg [2:0]  a_ph;
            reg [31:0] a_gap;
            reg        a_started;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    a_ph          <= 3'd0;
                    a_gap         <= 32'd0;
                    a_started     <= 1'b0;
                    st_start      <= 1'b0;
                    m_cv          <= 3'd0;
                    rd_ready_r    <= 3'd0;
                    m0_cmd_r      <= 37'd0;
                    m1_cmd_r      <= 37'd0;
                    m2_cmd_r      <= 37'd0;
                    m0_wdata_r    <= 256'd0;
                    m1_wdata_r    <= 256'd0;
                    m2_wdata_r    <= 256'd0;
                    m3_cv_ext     <= 1'b0;
                    m3_cmd_ext    <= 37'd0;
                    m3_wdata_ext  <= 256'd0;
                    m3_rd_ready_ext <= 1'b0;
                    case_done     <= 1'b0;
                    case_pass     <= 1'b0;
                end else begin
                    // start self_test once
                    if (!a_started && (cyc > 32'd8)) begin
                        st_start  <= 1'b1;
                        a_started <= 1'b1;
                    end else begin
                        st_start <= 1'b0;
                    end

                    // audio_sink write FSM (one 32-byte beat per command)
                    case (a_ph)
                        3'd0: if (cyc > 32'd8) begin
                            m0_cmd_r   <= {1'b1, 28'h0000_0020, 8'd0};
                            m0_wdata_r <= {8{32'h1122_3344}};
                            m_cv[0]    <= 1'b1;
                            a_ph       <= 3'd1;
                        end
                        3'd1: begin
                            if (done[0]) begin
                                if (FIX_M0_DONE != 0) begin
                                    m0_cmd_r <= {1'b1, 28'h0008_4020, 8'd0};
                                    m_cv[0]  <= 1'b1;
                                    a_ph     <= 3'd2;
                                end else begin
                                    m_cv[0] <= 1'b1;   // never released
                                end
                            end
                        end
                        3'd2: begin
                            if (done[0]) begin
                                m_cv[0] <= 1'b0;
                                a_gap   <= 32'd3000;
                                a_ph    <= 3'd3;
                            end
                        end
                        3'd3: begin
                            if (a_gap != 32'd0) a_gap <= a_gap - 32'd1;
                            else                a_ph  <= 3'd0;
                        end
                        default: a_ph <= 3'd0;
                    endcase

                    if (!case_done) begin
                        if (st_done_o || st_fail_o || (cyc > MAX_CYCLES)) begin
                            case_done <= 1'b1;
                            case_pass <= st_done_o && !st_fail_o &&
                                         (dc3 == 8'd16) && !to_err;
                        end
                    end
                end
            end
        end

        // ----------------------------------------------------------------
        // C03 / C04: read command pacing test on master 2.
        // A first read leaves 16 beats in the elastic fifo because m2 keeps
        // rd_ready low. A second read is then issued:
        //   C03 level-held  -> granted after the fifo is drained  (PASS)
        //   C04 single pulse-> dropped while arb_en=0            (PASS)
        // ----------------------------------------------------------------
        if ((SCENARIO == 3) || (SCENARIO == 4)) begin : g_rd_pace
            reg [2:0]  r_ph;
            reg [31:0] r_t;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    r_ph          <= 3'd0;
                    r_t           <= 32'd0;
                    m_cv          <= 3'd0;
                    rd_ready_r    <= 3'd0;
                    m0_cmd_r      <= 37'd0;
                    m1_cmd_r      <= 37'd0;
                    m2_cmd_r      <= 37'd0;
                    m0_wdata_r    <= 256'd0;
                    m1_wdata_r    <= 256'd0;
                    m2_wdata_r    <= 256'd0;
                    st_start      <= 1'b0;
                    m3_cv_ext     <= 1'b0;
                    m3_cmd_ext    <= 37'd0;
                    m3_wdata_ext  <= 256'd0;
                    m3_rd_ready_ext <= 1'b0;
                    case_done     <= 1'b0;
                    case_pass     <= 1'b0;
                end else begin
                    r_t <= r_t + 32'd1;
                    case (r_ph)
                        3'd0: if (cyc > 32'd8) begin
                            m2_cmd_r      <= {1'b0, 28'h0020_0000, 8'd15};
                            m_cv[2]       <= 1'b1;
                            rd_ready_r[2] <= 1'b0;
                            r_t           <= 32'd0;
                            r_ph          <= 3'd1;
                        end
                        3'd1: if (done[2]) begin
                            r_t  <= 32'd0;
                            r_ph <= 3'd2;
                        end
                        3'd2: if (r_t == 32'd8) begin
                            m2_cmd_r <= {1'b0, 28'h0020_0200, 8'd15};
                            m_cv[2]  <= 1'b1;
                            r_t      <= 32'd0;
                            if (PULSE_CMD != 0) r_ph <= 3'd3;
                            else                r_ph <= 3'd4;
                        end
                        3'd3: begin
                            // single-cycle strobe, then abandon
                            m_cv[2] <= 1'b0;
                            if (r_t == 32'd4000) begin
                                case_done <= 1'b1;
                                case_pass <= (dc2 == 8'd1) && !to_err;
                                r_ph      <= 3'd5;
                            end
                        end
                        3'd4: begin
                            // level held until done; drain the fifo later
                            if (r_t == 32'd100) rd_ready_r[2] <= 1'b1;
                            if ((dc2 == 8'd2) || (r_t > 32'd8000)) begin
                                case_done <= 1'b1;
                                case_pass <= (dc2 == 8'd2) && !to_err;
                                r_ph      <= 3'd5;
                            end
                        end
                        default: ;
                    endcase
                end
            end
        end

        // ----------------------------------------------------------------
        // C08 / C09 / C12: a plain single read command on master 2, used
        // with fault injection (dummy-write phase watchdog, blind spot).
        // ----------------------------------------------------------------
        if ((SCENARIO == 8) || (SCENARIO == 9) || (SCENARIO == 12)) begin : g_simple_rd
            reg [1:0]  p_ph;
            reg [31:0] p_t;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    p_ph          <= 2'd0;
                    p_t           <= 32'd0;
                    m_cv          <= 3'd0;
                    rd_ready_r    <= 3'd0;
                    m0_cmd_r      <= 37'd0;
                    m1_cmd_r      <= 37'd0;
                    m2_cmd_r      <= 37'd0;
                    m0_wdata_r    <= 256'd0;
                    m1_wdata_r    <= 256'd0;
                    m2_wdata_r    <= 256'd0;
                    st_start      <= 1'b0;
                    m3_cv_ext     <= 1'b0;
                    m3_cmd_ext    <= 37'd0;
                    m3_wdata_ext  <= 256'd0;
                    m3_rd_ready_ext <= 1'b0;
                    case_done     <= 1'b0;
                    case_pass     <= 1'b0;
                end else begin
                    p_t <= p_t + 32'd1;
                    case (p_ph)
                        2'd0: if (cyc > 32'd8) begin
                            m2_cmd_r      <= {1'b0, 28'h0020_0000, 8'd15};
                            m_cv[2]       <= 1'b1;
                            rd_ready_r[2] <= 1'b1;
                            p_t           <= 32'd0;
                            p_ph          <= 2'd1;
                        end
                        2'd1: begin
                            if (SCENARIO == 12) begin
                                // blind spot: no done ever comes, no timeout
                                // ever fires; observe well past 3 x limit
                                if (cyc > (3 * AXI_TO_LIMIT)) begin
                                    case_done <= 1'b1;
                                    case_pass <= !to_err && (dc2 == 8'd0) &&
                                                 (rd_valid[2] == 1'b1);
                                    p_ph <= 2'd2;
                                end
                            end else begin
                                if (done[2]) begin
                                    m_cv[2] <= 1'b0;
                                    p_t     <= 32'd0;
                                    p_ph    <= 2'd3;   // settle, then judge
                                end else if (cyc > MAX_CYCLES) begin
                                    case_done <= 1'b1;
                                    case_pass <= 1'b0;
                                    p_ph      <= 2'd2;
                                end
                            end
                        end
                        2'd3: if (p_t >= 32'd2) begin
                            case_done <= 1'b1;
                            if (SCENARIO == 8) begin
                                // AW never ready -> dummy-write AW phase
                                case_pass <= to_err && cmd_to_err[2] &&
                                             (dbg_to_state == 3'd4) &&
                                             (dc2 == 8'd1);
                            end else begin
                                // W never ready -> dummy-write data phase
                                case_pass <= to_err && cmd_to_err[2] &&
                                             (dbg_to_state == 3'd5) &&
                                             (dc2 == 8'd1);
                            end
                            p_ph <= 2'd2;
                        end
                        default: ;
                    endcase
                end
            end
        end

        // ----------------------------------------------------------------
        // C11: all four masters request at the same time, quota effectively
        // disabled. Expected grant order m0 -> m1 -> m2 -> m3.
        // ----------------------------------------------------------------
        if (SCENARIO == 11) begin : g_order
            reg [1:0] o_ph;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    o_ph          <= 2'd0;
                    m_cv          <= 3'd0;
                    rd_ready_r    <= 3'd0;
                    m0_cmd_r      <= 37'd0;
                    m1_cmd_r      <= 37'd0;
                    m2_cmd_r      <= 37'd0;
                    m0_wdata_r    <= 256'd0;
                    m1_wdata_r    <= 256'd0;
                    m2_wdata_r    <= 256'd0;
                    st_start      <= 1'b0;
                    m3_cv_ext     <= 1'b0;
                    m3_cmd_ext    <= 37'd0;
                    m3_wdata_ext  <= 256'd0;
                    m3_rd_ready_ext <= 1'b0;
                    case_done     <= 1'b0;
                    case_pass     <= 1'b0;
                end else begin
                    case (o_ph)
                        2'd0: if (cyc > 32'd8) begin
                            m0_cmd_r      <= {1'b1, 28'h0000_0020, 8'd15};
                            m1_cmd_r      <= {1'b0, 28'h0010_0000, 8'd15};
                            m2_cmd_r      <= {1'b0, 28'h0020_0000, 8'd15};
                            m3_cmd_ext    <= {1'b0, 28'h0020_0200, 8'd15};
                            m0_wdata_r    <= {8{32'hA5A5_5A5A}};
                            m_cv          <= 3'b111;
                            m3_cv_ext     <= 1'b1;
                            rd_ready_r    <= 3'b111;
                            m3_rd_ready_ext <= 1'b1;
                            o_ph          <= 2'd1;
                        end
                        2'd1: begin
                            if ((dc0 == 8'd1) && (dc1 == 8'd1) &&
                                (dc2 == 8'd1) && (dc3 == 8'd1)) begin
                                case_done <= 1'b1;
                                case_pass <= (seq_r == 8'h1B);
                                o_ph      <= 2'd2;
                            end else if (cyc > MAX_CYCLES) begin
                                case_done <= 1'b1;
                                case_pass <= 1'b0;
                                o_ph      <= 2'd2;
                            end
                        end
                        default: ;
                    endcase

                    // release each request once its command completed
                    if (done[0]) m_cv[0] <= 1'b0;
                    if (done[1]) m_cv[1] <= 1'b0;
                    if (done[2]) m_cv[2] <= 1'b0;
                    if (done[3]) m3_cv_ext <= 1'b0;
                end
            end
        end

        // ----------------------------------------------------------------
        // C13: P3 quota. m0/m1/m2 keep re-issuing with a two-cycle gap;
        // one m3 read is pending. Without the quota it would never be
        // granted (fixed priority), so a single m3 completion proves the
        // override works.
        // ----------------------------------------------------------------
        if (SCENARIO == 13) begin : g_quota
            reg [2:0] q_ph;
            reg [1:0] q_g0, q_g1, q_g2;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    q_ph          <= 3'd0;
                    q_g0          <= 2'd0;
                    q_g1          <= 2'd0;
                    q_g2          <= 2'd0;
                    m_cv          <= 3'd0;
                    rd_ready_r    <= 3'd0;
                    m0_cmd_r      <= 37'd0;
                    m1_cmd_r      <= 37'd0;
                    m2_cmd_r      <= 37'd0;
                    m0_wdata_r    <= 256'd0;
                    m1_wdata_r    <= 256'd0;
                    m2_wdata_r    <= 256'd0;
                    st_start      <= 1'b0;
                    m3_cv_ext     <= 1'b0;
                    m3_cmd_ext    <= 37'd0;
                    m3_wdata_ext  <= 256'd0;
                    m3_rd_ready_ext <= 1'b0;
                    case_done     <= 1'b0;
                    case_pass     <= 1'b0;
                end else begin
                    case (q_ph)
                        3'd0: if (cyc > 32'd8) begin
                            m0_cmd_r      <= {1'b1, 28'h0000_0020, 8'd15};
                            m1_cmd_r      <= {1'b0, 28'h0010_0000, 8'd15};
                            m2_cmd_r      <= {1'b0, 28'h0020_0000, 8'd15};
                            m3_cmd_ext    <= {1'b0, 28'h0020_0200, 8'd15};
                            m0_wdata_r    <= {8{32'h5A5A_A5A5}};
                            m_cv          <= 3'b111;
                            m3_cv_ext     <= 1'b1;
                            rd_ready_r    <= 3'b111;
                            m3_rd_ready_ext <= 1'b1;
                            q_ph          <= 3'd1;
                        end
                        3'd1: begin
                            // re-issue loop with a 2-cycle gap per master
                            if (done[0]) begin
                                m_cv[0] <= 1'b0;
                                q_g0    <= 2'd2;
                            end else if (q_g0 != 2'd0) begin
                                q_g0 <= q_g0 - 2'd1;
                            end else begin
                                m_cv[0] <= 1'b1;
                            end

                            if (done[1]) begin
                                m_cv[1] <= 1'b0;
                                q_g1    <= 2'd2;
                            end else if (q_g1 != 2'd0) begin
                                q_g1 <= q_g1 - 2'd1;
                            end else begin
                                m_cv[1] <= 1'b1;
                            end

                            if (done[2]) begin
                                m_cv[2] <= 1'b0;
                                q_g2    <= 2'd2;
                            end else if (q_g2 != 2'd0) begin
                                q_g2 <= q_g2 - 2'd1;
                            end else begin
                                m_cv[2] <= 1'b1;
                            end

                            if (done[3]) m3_cv_ext <= 1'b0;

                            if ((dc3 == 8'd1) || (cyc > MAX_CYCLES)) begin
                                case_done <= 1'b1;
                                case_pass <= (dc3 == 8'd1) &&
                                             (dc0 >= 8'd10) &&
                                             (dc1 == 8'd0) && (dc2 == 8'd0);
                                q_ph      <= 3'd2;
                            end
                        end
                        default: ;
                    endcase
                end
            end
        end

        // ----------------------------------------------------------------
        // C14: abort recovery. A read whose write-data phase hangs times out
        // in S_DW_W; the next read is issued afterwards and is expected to
        // time out in S_DW_AW because the IP still tracks the unfinished
        // write burst (model assumption: awready stays low until the hung
        // burst is completed, which the real IP never gets a chance to do).
        // ----------------------------------------------------------------
        if (SCENARIO == 14) begin : g_recover
            reg [2:0]  v_ph;
            reg [31:0] v_t;
            reg [2:0]  v_dbg1;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    v_ph          <= 3'd0;
                    v_t           <= 32'd0;
                    v_dbg1        <= 3'd0;
                    m_cv          <= 3'd0;
                    rd_ready_r    <= 3'd0;
                    m0_cmd_r      <= 37'd0;
                    m1_cmd_r      <= 37'd0;
                    m2_cmd_r      <= 37'd0;
                    m0_wdata_r    <= 256'd0;
                    m1_wdata_r    <= 256'd0;
                    m2_wdata_r    <= 256'd0;
                    st_start      <= 1'b0;
                    m3_cv_ext     <= 1'b0;
                    m3_cmd_ext    <= 37'd0;
                    m3_wdata_ext  <= 256'd0;
                    m3_rd_ready_ext <= 1'b0;
                    case_done     <= 1'b0;
                    case_pass     <= 1'b0;
                end else begin
                    v_t <= v_t + 32'd1;
                    case (v_ph)
                        2'd0: if (cyc > 32'd8) begin
                            m2_cmd_r      <= {1'b0, 28'h0020_0000, 8'd15};
                            m_cv[2]       <= 1'b1;
                            rd_ready_r[2] <= 1'b1;
                            v_t           <= 32'd0;
                            v_ph          <= 3'd1;
                        end
                        2'd1: if (done[2]) begin
                            m_cv[2]  <= 1'b0;
                            v_t      <= 32'd0;
                            v_ph     <= 3'd4;
                        end
                        3'd4: begin
                            // dbg_to_state is valid one cycle after done
                            if (v_t >= 32'd1) begin
                                v_dbg1 <= dbg_to_state;
                                v_t    <= 32'd0;
                                v_ph   <= 3'd2;
                            end
                        end
                        2'd2: if (v_t > 32'd4) begin
                            m2_cmd_r <= {1'b0, 28'h0020_0200, 8'd15};
                            m_cv[2]  <= 1'b1;
                            v_t      <= 32'd0;
                            v_ph     <= 3'd3;
                        end
                        2'd3: begin
                            if (done[2]) begin
                                m_cv[2] <= 1'b0;
                                v_t     <= 32'd0;
                                v_ph    <= 3'd5;
                            end else if (cyc > MAX_CYCLES) begin
                                case_done <= 1'b1;
                                case_pass <= 1'b0;
                                v_ph      <= 3'd6;
                            end
                        end
                        3'd5: if (v_t >= 32'd2) begin
                            case_done  <= 1'b1;
                            case_pass  <= (v_dbg1 == 3'd5) &&
                                          (dbg_to_state == 3'd4) &&
                                          (dc2 == 8'd2);
                            v_ph       <= 3'd6;
                        end
                        default: ;
                    endcase
                end
            end
        end
    endgenerate

endmodule