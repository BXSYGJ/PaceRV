// -----------------------------------------------------------------------------
// File    : tb_ddr3_aw_timeout.sv
// Project : InstRec-FPGA / T37 multi-master AW starvation investigation
// Purpose : Answer, by simulation only (no build, no board), why the core-only
//           bitstream reports DDR3 STS 26 (st_fail=1, dbg_to_state=001 => S_AW,
//           to_err=1, cmd_to_err[3]=1) once master 0 (audio page writes) and
//           master 2 (mel PCM reads) are alive, while the same controller and
//           the same 0x0030_0000 self-test address pass when both are tied off.
//
// The measurement is split into the two independent quantities that the
// board report cannot distinguish:
//
//   QUEUE  : cycles from "m3 cmd_valid high" to "m3 granted"  (S_IDLE wait)
//   AWWAIT : cycles from "m3 granted" to "m3 axi_awready"     (S_AW wait)
//
// Only the second one is counted by the AXI watchdog (ddr3_ctrl_axi resets
// axi_to_cnt in S_IDLE), so a huge QUEUE alone can never raise to_err.
//
// Scenarios (all run concurrently, one behavioural IP model each):
//   A0 : m0 8256 audio pages + m2 516 mel reads + self_test on m3, healthy
//        model (AW_DELAY = 2), P3 quota = 125000 (production value). Stops
//        after the first m3 AW handshake, i.e. it measures the queue time
//        and the AW wait of the very first self-test write command.
//   A1 : m0 one audio page + m2 three mel reads + self_test, quota 200, and
//        the model stops accepting write beats after the first burst
//        (W_READY_BURST_COUNT = 0). That is what a full write FIFO inside the
//        hard IP looks like from the controller side. It reproduces the
//        STS 26 chain and records which master aborted FIRST.
//   A2 : self_test alone, healthy model (reference AW latency).
//   A3 : m0 400 pages + m2 516 reads + self_test, quota 2000, healthy model:
//        all 16 self-test commands must still complete under load.
//
// Run (from instrec_fpga/):
//   python sim/run_sim.py ddr3_aw_timeout
//
// Simulation-only file: not part of src/**, not built by PDS, no product RTL
// is modified.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

// =============================================================================
// Testbench top: clock/reset, four scenario instances, verdict table.
// =============================================================================
module tb_ddr3_aw_timeout;

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
    // A0: full load, production quota, stop after the first m3 AW
    // ------------------------------------------------------------------
    wire        a0_done, a0_pass;
    wire [31:0] a0_cyc, a0_req2aw, a0_aw_wait, a0_wait3_max, a0_aw3_max;
    wire [3:0]  a0_cte, a0_abort_done;
    wire [2:0]  a0_dbg, a0_abort_dbg;
    wire        a0_to_err, a0_st_done, a0_st_fail;
    wire [27:0] a0_fail_addr;
    wire [7:0]  a0_dc0, a0_dc2, a0_dc3;
    wire [31:0] a0_awc0, a0_awc2, a0_awc3, a0_ovl;
    wire        a0_never;

    // ------------------------------------------------------------------
    // A1: full-ish load, write-beat starvation -> IP state pollution
    // ------------------------------------------------------------------
    wire        a1_done, a1_pass;
    wire [31:0] a1_cyc, a1_req2aw, a1_aw_wait, a1_wait3_max, a1_aw3_max;
    wire [3:0]  a1_cte, a1_abort_done;
    wire [2:0]  a1_dbg, a1_abort_dbg;
    wire        a1_to_err, a1_st_done, a1_st_fail;
    wire [27:0] a1_fail_addr;
    wire [7:0]  a1_dc0, a1_dc2, a1_dc3;
    wire [31:0] a1_awc0, a1_awc2, a1_awc3, a1_ovl;
    wire        a1_never;

    // ------------------------------------------------------------------
    // A2: reference, self_test alone
    // ------------------------------------------------------------------
    wire        a2_done, a2_pass;
    wire [31:0] a2_cyc, a2_req2aw, a2_aw_wait, a2_wait3_max, a2_aw3_max;
    wire [3:0]  a2_cte, a2_abort_done;
    wire [2:0]  a2_dbg, a2_abort_dbg;
    wire        a2_to_err, a2_st_done, a2_st_fail;
    wire [27:0] a2_fail_addr;
    wire [7:0]  a2_dc0, a2_dc2, a2_dc3;
    wire [31:0] a2_awc0, a2_awc2, a2_awc3, a2_ovl;
    wire        a2_never;

    // ------------------------------------------------------------------
    // A3: all 16 commands under load
    // ------------------------------------------------------------------
    wire        a3_done, a3_pass;
    wire [31:0] a3_cyc, a3_req2aw, a3_aw_wait, a3_wait3_max, a3_aw3_max;
    wire [3:0]  a3_cte, a3_abort_done;
    wire [2:0]  a3_dbg, a3_abort_dbg;
    wire        a3_to_err, a3_st_done, a3_st_fail;
    wire [27:0] a3_fail_addr;
    wire [7:0]  a3_dc0, a3_dc2, a3_dc3;
    wire [31:0] a3_awc0, a3_awc2, a3_awc3, a3_ovl;
    wire        a3_never;

    // ------------------------------------------------------------------
    // A4: m0 saturated (cmd_valid never drops), quota = 125000.
    //     This is the worst case the arbiter can ever face and it measures
    //     the queue time along the P3 quota path.
    // ------------------------------------------------------------------
    wire        a4_done, a4_pass;
    wire [31:0] a4_cyc, a4_req2aw, a4_aw_wait, a4_wait3_max, a4_aw3_max;
    wire [3:0]  a4_cte, a4_abort_done;
    wire [2:0]  a4_dbg, a4_abort_dbg;
    wire        a4_to_err, a4_st_done, a4_st_fail;
    wire [27:0] a4_fail_addr;
    wire [7:0]  a4_dc0, a4_dc2, a4_dc3;
    wire [31:0] a4_awc0, a4_awc2, a4_awc3, a4_ovl;
    wire        a4_never;

    // ------------------------------------------------------------------
    // A5: bit-exact reproduction of the board STS byte 0x26.
    //     self_test runs ALONE first (16 commands, no AXI timeout) but with a
    //     strobe-blind IP model, so its data compare fails; then audio traffic
    //     starts and its first write address never gets awready, producing
    //     to_err=1 with dbg_to_state=S_AW and cmd_to_err[3]=0.
    // ------------------------------------------------------------------
    wire        a5_done, a5_pass;
    wire [31:0] a5_cyc, a5_req2aw, a5_aw_wait, a5_wait3_max, a5_aw3_max;
    wire [3:0]  a5_cte, a5_abort_done;
    wire [2:0]  a5_dbg, a5_abort_dbg;
    wire        a5_to_err, a5_st_done, a5_st_fail;
    wire [27:0] a5_fail_addr;
    wire [7:0]  a5_dc0, a5_dc2, a5_dc3;
    wire [31:0] a5_awc0, a5_awc2, a5_awc3, a5_ovl;
    wire        a5_never;
    wire [7:0]  a5_sts;

    // ------------------------------------------------------------------
    // A0: 8256 audio pages (one full 2.995 s window) + 516 mel reads,
    //     quarantine value 125000, stop right after the first m3 AW.
    // ------------------------------------------------------------------
    aw_case #(
        .M0_PAGES          (8256),
        .M2_CMDS           (516),
        .M3_START_CYCLE    (3000),
        .AW_DELAY          (2),
        .P3_QUOTA_TIMEOUT  (125000),
        .MAX_CYCLES        (300000),
        .EXPECT            (0)
    ) u_a0 (
        .clk (clk), .rst_n (rst_n),
        .case_done (a0_done), .case_pass (a0_pass), .o_cyc (a0_cyc),
        .o_req2aw (a0_req2aw), .o_aw_wait (a0_aw_wait),
        .o_wait3_max (a0_wait3_max), .o_aw3_max_wait (a0_aw3_max),
        .o_cmd_to_err (a0_cte), .o_first_abort_done (a0_abort_done),
        .o_first_abort_dbg (a0_abort_dbg),
        .o_dbg_to_state (a0_dbg), .o_to_err (a0_to_err),
        .o_st_done (a0_st_done), .o_st_fail (a0_st_fail),
        .o_st_fail_addr (a0_fail_addr),
        .o_done_cnt0 (a0_dc0), .o_done_cnt2 (a0_dc2), .o_done_cnt3 (a0_dc3),
        .o_aw_cnt0 (a0_awc0), .o_aw_cnt2 (a0_awc2), .o_aw_cnt3 (a0_awc3),
        .o_aw_overlap_w (a0_ovl), .o_m3_aw_never (a0_never)
    );

    // ------------------------------------------------------------------
    // A1: the poisoning experiment. Only a few commands are needed: the
    //     first m0 write burst has no wready, so the controller aborts it
    //     in S_W and leaves the IP holding an unfinished burst.
    // ------------------------------------------------------------------
    aw_case #(
        .M0_PAGES          (1),
        .M0_SINGLE         (1),
        .M2_CMDS           (1),
        .M3_START_CYCLE    (9000),
        .AW_DELAY          (2),
        .W_READY_BURST_COUNT (0),
        .P3_QUOTA_TIMEOUT  (200),
        .MAX_CYCLES        (40000),
        .EXPECT            (1)
    ) u_a1 (
        .clk (clk), .rst_n (rst_n),
        .case_done (a1_done), .case_pass (a1_pass), .o_cyc (a1_cyc),
        .o_req2aw (a1_req2aw), .o_aw_wait (a1_aw_wait),
        .o_wait3_max (a1_wait3_max), .o_aw3_max_wait (a1_aw3_max),
        .o_cmd_to_err (a1_cte), .o_first_abort_done (a1_abort_done),
        .o_first_abort_dbg (a1_abort_dbg),
        .o_dbg_to_state (a1_dbg), .o_to_err (a1_to_err),
        .o_st_done (a1_st_done), .o_st_fail (a1_st_fail),
        .o_st_fail_addr (a1_fail_addr),
        .o_done_cnt0 (a1_dc0), .o_done_cnt2 (a1_dc2), .o_done_cnt3 (a1_dc3),
        .o_aw_cnt0 (a1_awc0), .o_aw_cnt2 (a1_awc2), .o_aw_cnt3 (a1_awc3),
        .o_aw_overlap_w (a1_ovl), .o_m3_aw_never (a1_never)
    );

    // ------------------------------------------------------------------
    // A2: reference run
    // ------------------------------------------------------------------
    aw_case #(
        .M0_PAGES          (0),
        .M2_CMDS           (0),
        .AW_DELAY          (2),
        .P3_QUOTA_TIMEOUT  (125000),
        .MAX_CYCLES        (8000),
        .EXPECT            (0)
    ) u_a2 (
        .clk (clk), .rst_n (rst_n),
        .case_done (a2_done), .case_pass (a2_pass), .o_cyc (a2_cyc),
        .o_req2aw (a2_req2aw), .o_aw_wait (a2_aw_wait),
        .o_wait3_max (a2_wait3_max), .o_aw3_max_wait (a2_aw3_max),
        .o_cmd_to_err (a2_cte), .o_first_abort_done (a2_abort_done),
        .o_first_abort_dbg (a2_abort_dbg),
        .o_dbg_to_state (a2_dbg), .o_to_err (a2_to_err),
        .o_st_done (a2_st_done), .o_st_fail (a2_st_fail),
        .o_st_fail_addr (a2_fail_addr),
        .o_done_cnt0 (a2_dc0), .o_done_cnt2 (a2_dc2), .o_done_cnt3 (a2_dc3),
        .o_aw_cnt0 (a2_awc0), .o_aw_cnt2 (a2_awc2), .o_aw_cnt3 (a2_awc3),
        .o_aw_overlap_w (a2_ovl), .o_m3_aw_never (a2_never)
    );

    // ------------------------------------------------------------------
    // A3: healthy model, full 16-command self-test under load
    // ------------------------------------------------------------------
    aw_case #(
        .M0_PAGES          (400),
        .M2_CMDS           (516),
        .AW_DELAY          (2),
        .P3_QUOTA_TIMEOUT  (2000),
        .MAX_CYCLES        (60000),
        .EXPECT            (0)
    ) u_a3 (
        .clk (clk), .rst_n (rst_n),
        .case_done (a3_done), .case_pass (a3_pass), .o_cyc (a3_cyc),
        .o_req2aw (a3_req2aw), .o_aw_wait (a3_aw_wait),
        .o_wait3_max (a3_wait3_max), .o_aw3_max_wait (a3_aw3_max),
        .o_cmd_to_err (a3_cte), .o_first_abort_done (a3_abort_done),
        .o_first_abort_dbg (a3_abort_dbg),
        .o_dbg_to_state (a3_dbg), .o_to_err (a3_to_err),
        .o_st_done (a3_st_done), .o_st_fail (a3_st_fail),
        .o_st_fail_addr (a3_fail_addr),
        .o_done_cnt0 (a3_dc0), .o_done_cnt2 (a3_dc2), .o_done_cnt3 (a3_dc3),
        .o_aw_cnt0 (a3_awc0), .o_aw_cnt2 (a3_awc2), .o_aw_cnt3 (a3_awc3),
        .o_aw_overlap_w (a3_ovl), .o_m3_aw_never (a3_never)
    );

    // ------------------------------------------------------------------
    // A4: saturated m0, production quota, stop after the first m3 AW
    // ------------------------------------------------------------------
    aw_case #(
        .M0_SAT            (1),
        .M2_CMDS           (0),
        .M3_START_CYCLE    (16),
        .AW_DELAY          (2),
        .P3_QUOTA_TIMEOUT  (125000),
        .MAX_CYCLES        (400000),
        .STOP_AFTER_FIRST_AW (1),
        .EXPECT            (2)
    ) u_a4 (
        .clk (clk), .rst_n (rst_n),
        .case_done (a4_done), .case_pass (a4_pass), .o_cyc (a4_cyc),
        .o_req2aw (a4_req2aw), .o_aw_wait (a4_aw_wait),
        .o_wait3_max (a4_wait3_max), .o_aw3_max_wait (a4_aw3_max),
        .o_cmd_to_err (a4_cte), .o_first_abort_done (a4_abort_done),
        .o_first_abort_dbg (a4_abort_dbg),
        .o_dbg_to_state (a4_dbg), .o_to_err (a4_to_err),
        .o_st_done (a4_st_done), .o_st_fail (a4_st_fail),
        .o_st_fail_addr (a4_fail_addr),
        .o_done_cnt0 (a4_dc0), .o_done_cnt2 (a4_dc2), .o_done_cnt3 (a4_dc3),
        .o_aw_cnt0 (a4_awc0), .o_aw_cnt2 (a4_awc2), .o_aw_cnt3 (a4_awc3),
        .o_aw_overlap_w (a4_ovl), .o_m3_aw_never (a4_never)
    );

    // ------------------------------------------------------------------
    // A5: self_test first (strobe-blind model), audio traffic afterwards
    // ------------------------------------------------------------------
    aw_case #(
        .M0_PAGES            (1),
        .M0_SINGLE           (1),
        .M0_START_CYCLE      (1000),
        .M2_CMDS             (0),
        .M3_START_CYCLE      (8),
        .AW_DELAY            (2),
        // m3 consumes exactly 9 AW bursts (8 write commands + the dummy write
        // of the first read command, which already fails the data compare);
        // the 10th AW of the run therefore belongs to m0 and is refused.
        .AW_READY_AW_COUNT   (9),
        .WSTRB_IGNORE        (1),
        .P3_QUOTA_TIMEOUT    (125000),
        .MAX_CYCLES          (20000),
        .EXPECT              (3)
    ) u_a5 (
        .clk (clk), .rst_n (rst_n),
        .case_done (a5_done), .case_pass (a5_pass), .o_cyc (a5_cyc),
        .o_req2aw (a5_req2aw), .o_aw_wait (a5_aw_wait),
        .o_wait3_max (a5_wait3_max), .o_aw3_max_wait (a5_aw3_max),
        .o_cmd_to_err (a5_cte), .o_first_abort_done (a5_abort_done),
        .o_first_abort_dbg (a5_abort_dbg),
        .o_dbg_to_state (a5_dbg), .o_to_err (a5_to_err),
        .o_st_done (a5_st_done), .o_st_fail (a5_st_fail),
        .o_st_fail_addr (a5_fail_addr),
        .o_done_cnt0 (a5_dc0), .o_done_cnt2 (a5_dc2), .o_done_cnt3 (a5_dc3),
        .o_aw_cnt0 (a5_awc0), .o_aw_cnt2 (a5_awc2), .o_aw_cnt3 (a5_awc3),
        .o_aw_overlap_w (a5_ovl), .o_m3_aw_never (a5_never),
        .o_sts_byte (a5_sts)
    );

    // ------------------------------------------------------------------
    // Report
    // ------------------------------------------------------------------
    wire all_done = a0_done & a1_done & a2_done & a3_done &
                    a4_done & a5_done;

    integer wait_cyc;
    integer fail_cnt;

    task state_name;
        input [2:0] st;
        begin
            if (st == 3'd0)      $display("S_IDLE");
            else if (st == 3'd1) $display("S_AW");
            else if (st == 3'd2) $display("S_W");
            else if (st == 3'd3) $display("S_WLAST");
            else if (st == 3'd4) $display("S_DW_AW");
            else if (st == 3'd5) $display("S_DW_W");
            else if (st == 3'd6) $display("S_AR");
            else if (st == 3'd7) $display("S_R");
            else                 $display("?");
        end
    endtask

    task verdict;
        input [8*44-1:0] label;
        input            ok;
        begin
            if (ok) $display("  %0s : PASS", label);
            else    $display("  %0s : FAIL", label);
        end
    endtask

    initial begin
        wait_cyc = 0;
        while ((!all_done) && (wait_cyc < 400000)) begin
            @(posedge clk);
            wait_cyc = wait_cyc + 1;
        end
        repeat (8) @(posedge clk);

        $display("");
        $display("==============================================================");
        $display(" T37 MULTI-MASTER AW TIMEOUT - measurements");
        $display("==============================================================");
        $display("  A0 real load  : cyc=%0d QUEUE(m3 req->grant)=%0d AWWAIT(grant->awready)=%0d",
                 a0_cyc, a0_req2aw, a0_aw_wait);
        $display("                  wait_cnt_3 PEAK=%0d  max m3 AW wait=%0d  to_err=%0b cte=%b",
                 a0_wait3_max, a0_aw3_max, a0_to_err, a0_cte);
        $display("                  st_done=%0b dc3=%0d aw_hs m0/m2/m3=%0d/%0d/%0d aw&&wbeat=%0d",
                 a0_st_done, a0_dc3, a0_awc0, a0_awc2, a0_awc3, a0_ovl);
        $display("  A1 wbeat starve: cyc=%0d to_err=%0b cte=%b dbg=%0d st_fail=%0b fail_addr=%h",
                 a1_cyc, a1_to_err, a1_cte, a1_dbg, a1_st_fail, a1_fail_addr);
        $display("                  FIRST abort: done=%b at state=%0d  m3 awready EVER seen=%0b",
                 a1_abort_done, a1_abort_dbg, ~a1_never);
        $display("                  aw_hs m0/m2/m3=%0d/%0d/%0d  done m0/m2/m3=%0d/%0d/%0d",
                 a1_awc0, a1_awc2, a1_awc3, a1_dc0, a1_dc2, a1_dc3);
        $display("  A2 m3 alone    : cyc=%0d QUEUE=%0d AWWAIT=%0d max m3 AW wait=%0d st_done=%0b to_err=%0b",
                 a2_cyc, a2_req2aw, a2_aw_wait, a2_aw3_max, a2_st_done, a2_to_err);
        $display("  A3 16 cmds load: cyc=%0d QUEUE=%0d AWWAIT=%0d max m3 AW wait=%0d",
                 a3_cyc, a3_req2aw, a3_aw_wait, a3_aw3_max);
        $display("                  st_done=%0b st_fail=%0b dc3=%0d to_err=%0b cte=%b PEAK wait3=%0d",
                 a3_st_done, a3_st_fail, a3_dc3, a3_to_err, a3_cte, a3_wait3_max);
        $display("  A4 m0 SATURATED: cyc=%0d QUEUE=%0d AWWAIT=%0d PEAK wait3=%0d (quota=%0d)",
                 a4_cyc, a4_req2aw, a4_aw_wait, a4_wait3_max, 125000);
        $display("                  aw_hs m0/m3=%0d/%0d to_err=%0b st_fail=%0b aw&&wbeat=%0d",
                 a4_awc0, a4_awc3, a4_to_err, a4_st_fail, a4_ovl);

        $display("  A5 STS REPRO   : STS byte=0x%h (board 0x26) to_err=%0b cte=%b dbg=%0d",
                 a5_sts, a5_to_err, a5_cte, a5_dbg);
        $display("                  st_fail=%0b st_done=%0b fail_addr=%h FIRST abort done=%b state=%0d",
                 a5_st_fail, a5_st_done, a5_fail_addr, a5_abort_done, a5_abort_dbg);
        $display("                  aw_hs m0/m3=%0d/%0d (m3 must use 9 AW bursts)",
                 a5_awc0, a5_awc3);

        $display("");
        $display("--------------------------------------------------------------");
        $display(" ANSWER KEY");
        $display("--------------------------------------------------------------");
        $display("  Q1 m3 write command latency:");
        $display("     real traffic A0/A3 : QUEUE first=%0d PEAK=%0d / %0d, AWWAIT=%0d",
                 a0_req2aw, a0_wait3_max, a3_wait3_max, a0_aw_wait);
        $display("     m0 saturated  A4   : QUEUE PEAK=%0d (quota path), AWWAIT=%0d",
                 a4_wait3_max, a4_aw_wait);
        $display("     => queue time is S_IDLE time and is NEVER watchdog counted;");
        $display("        the AW itself is served in <= 8 cycles in every healthy run.");
        $display("  Q2 grant vs AW occupancy:");
        $display("     aw_valid high while a write beat is taken = %0d / %0d / %0d / %0d cycles",
                 a0_ovl, a1_ovl, a2_ovl, a4_ovl);
        $display("     (AW and W can never overlap: axi_awvalid is only active in");
        $display("      S_AW/S_DW_AW and arb_en only in S_IDLE, so only ONE command");
        $display("      is ever in flight and the AW channel belongs to it alone)");
        $display("  Q3 to_err attribution:");
        $display("     A1 first abort owner done=%b state=%0d ; m3 awready ever=%0b",
                 a1_abort_done, a1_abort_dbg, ~a1_never);
        $display("     A1 final cmd_to_err[3:0]=%b (the STS byte carries only [3])", a1_cte);
        $display("     => any m3 AXI timeout MUST set cmd_to_err[3] (same branch),");
        $display("        so board STS 0x26 (bit6=0) means m3 itself never timed out.");
        $display("     same address 0x300000 in A2/A0: AW served, 16/16 commands done");

        $display("");
        $display("==============================================================");
        $display(" T37 VERDICT");
        $display("==============================================================");
        verdict("A0 real load, 16 cmds pass, AW fast  ", a0_pass);
        verdict("A1 write-beat starve -> S_AW timeout  ", a1_pass);
        verdict("A2 self_test alone passes             ", a2_pass);
        verdict("A3 16 commands complete under load    ", a3_pass);
        verdict("A4 saturated m0 bypassed by quota     ", a4_pass);
        verdict("A5 board STS 0x26 reproduced bit-exact", a5_pass);

        fail_cnt = 0;
        if (!a0_pass) fail_cnt = fail_cnt + 1;
        if (!a1_pass) fail_cnt = fail_cnt + 1;
        if (!a2_pass) fail_cnt = fail_cnt + 1;
        if (!a3_pass) fail_cnt = fail_cnt + 1;
        if (!a4_pass) fail_cnt = fail_cnt + 1;
        if (!a5_pass) fail_cnt = fail_cnt + 1;

        $display("");
        $display("  scenarios failed         : %0d / 6", fail_cnt);
        $display("  global wait cycles       : %0d", wait_cyc);
        $display("==============================================================");
        if (fail_cnt == 0) $display("RESULT: PASS");
        else               $display("RESULT: FAIL (%0d scenarios)", fail_cnt);
        $finish;
    end

endmodule


// =============================================================================
// Scenario harness: ddr3_ctrl_axi + ddr3_arbiter + self_test + IP model plus
// master drivers that reproduce the REAL upstream behaviour of audio_sink
// (m0) and mel_engine (m2):
//
//   m0 audio page write: {wr=1, addr, len=0}, cmd_valid held from issue until
//       done, two back-to-back commands per page (left window, then the right
//       archive mirror), 16 frame-times of aggregator fill between pages.
//   m2 mel PCM read: {wr=0, addr, len=15}, cmd_valid held until done, then 16
//       beats drained at one beat per cycle, then the next command.
//   m3 self_test: the real RTL instance.
// =============================================================================
module aw_case #(
    parameter integer M0_PAGES             = 0,
    // 1 = saturate master 0: cmd_valid stays high and a new len=0 write is
    //     issued on every done, with no aggregator gap at all. This is the
    //     worst case the arbiter can ever see (it is stricter than the real
    //     audio_sink, which leaves 16 frame-times between pages).
    parameter integer M0_SAT               = 0,
    // 1 = issue only the left page command (no right-archive mirror); used by
    //     the poisoning experiment so the LAST AXI timeout belongs to m3.
    parameter integer M0_SINGLE            = 0,
    // Cycle at which the first audio page command is issued (lets A5 run the
    // whole self-test BEFORE any audio traffic exists).
    parameter integer M0_START_CYCLE       = 8,
    parameter integer M2_CMDS              = 0,
    // Delay the self-test start so the measurement happens once m0/m2 have
    // reached their steady-state request pattern.
    parameter integer M3_START_CYCLE       = 8,
    // Give up waiting for the 16 read beats after this many cycles (the real
    // mel engine has its own guard; the TB only needs to keep moving on).
    parameter integer M2_BEAT_GIVEUP       = 64,
    parameter integer AW_DELAY             = 2,
    parameter integer AW_READY_AW_COUNT    = -1,
    parameter integer W_READY_BURST_COUNT  = -1,
    parameter integer WSTRB_IGNORE         = 0,
    parameter integer AXI_TO_LIMIT         = 4096,
    parameter integer P3_QUOTA_TIMEOUT     = 125000,
    parameter integer MAX_CYCLES           = 200000,
    // 1 = declare the scenario finished right after the first m3 AW handshake
    parameter integer STOP_AFTER_FIRST_AW  = 0,
    // 0 = all 16 commands must pass (healthy model)
    // 1 = write-beat starvation must poison the IP (STS 26 shape)
    // 2 = saturated m0 must be bypassed by the P3 quota (queue == quota)
    // 3 = the reproduction of the board STS byte 0x26 (see A5 comments)
    parameter integer EXPECT               = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         case_done,
    output reg         case_pass,
    output wire [31:0] o_cyc,
    output wire [31:0] o_req2aw,
    output wire [31:0] o_aw_wait,
    output wire [31:0] o_wait3_max,
    output wire [31:0] o_aw3_max_wait,
    output wire        o_m3_aw_never,
    output wire [3:0]  o_cmd_to_err,
    output wire [3:0]  o_first_abort_done,
    output wire [2:0]  o_first_abort_dbg,
    output wire [2:0]  o_dbg_to_state,
    output wire        o_to_err,
    output wire        o_st_done,
    output wire        o_st_fail,
    output wire [27:0] o_st_fail_addr,
    output wire [7:0]  o_done_cnt0,
    output wire [7:0]  o_done_cnt2,
    output wire [7:0]  o_done_cnt3,
    output wire [31:0] o_aw_cnt0,
    output wire [31:0] o_aw_cnt2,
    output wire [31:0] o_aw_cnt3,
    output wire [31:0] o_aw_overlap_w,
    // The exact byte sys_ctrl puts on the "DDR3 STS <hex8>" line
    // ({1'b0, cmd_to_err[3], to_err, dbg_to_state[2:0], st_fail, st_done})
    output wire [7:0]  o_sts_byte
);

    // ------------------------------------------------------------------
    // Master side registers
    // ------------------------------------------------------------------
    reg  [2:0]   m_cv;              // {m2, m1, m0}
    reg  [36:0]  m0_cmd_r, m1_cmd_r, m2_cmd_r;
    reg  [255:0] m0_wdata_r, m1_wdata_r, m2_wdata_r;
    reg  [2:0]   rd_ready_r;        // {m2, m1, m0}

    // m3 = the real self_test
    reg          st_start;
    wire         st_cv;
    wire [36:0]  st_cmd;
    wire [255:0] st_wdata;
    wire         st_rd_ready;
    wire         st_done_o, st_fail_o;
    wire [27:0]  st_fail_addr_o;

    wire [3:0]   cmd_valid = {st_cv, m_cv};
    wire [3:0]   rd_ready  = {st_rd_ready, rd_ready_r};

    // ------------------------------------------------------------------
    // Controller under test
    // ------------------------------------------------------------------
    wire [3:0]   done, wready_beat, rd_valid;
    wire [255:0] rd_data_0, rd_data_1, rd_data_2, rd_data_3;
    wire [31:0]  wait_cnt_0, wait_cnt_1, wait_cnt_2, wait_cnt_3;
    wire         to_err;
    wire [3:0]   cmd_to_err;
    wire [2:0]   dbg_to_state;
    wire [7:0]   wlast_miss;
    wire [3:0]   addr_err;

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
        .DUMMY_WSTRB_ALL1 (1'b0),
        .AXI_TO_LIMIT     (AXI_TO_LIMIT),
        .P3_QUOTA_TIMEOUT (P3_QUOTA_TIMEOUT)
    ) u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .cmd_valid   (cmd_valid),
        .m0_cmd      (m0_cmd_r),
        .m1_cmd      (m1_cmd_r),
        .m2_cmd      (m2_cmd_r),
        .m3_cmd      (st_cmd),
        .m0_wdata    (m0_wdata_r),
        .m1_wdata    (m1_wdata_r),
        .m2_wdata    (m2_wdata_r),
        .m3_wdata    (st_wdata),
        .wready_beat (wready_beat),
        .rd_ready    (rd_ready),
        .rd_data_0   (rd_data_0),
        .rd_data_1   (rd_data_1),
        .rd_data_2   (rd_data_2),
        .rd_data_3   (rd_data_3),
        .rd_valid    (rd_valid),
        .done        (done),
        .wait_cnt_0  (wait_cnt_0),
        .wait_cnt_1  (wait_cnt_1),
        .wait_cnt_2  (wait_cnt_2),
        .wait_cnt_3  (wait_cnt_3),
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
    // Behavioural DDR3 IP model
    // ------------------------------------------------------------------
    wire [31:0] m_aw_hs, m_ar_hs, m_wr_beats, m_rd_beats;
    wire [31:0] m_len0, m_s0, m_s1;

    ddr3_axi_model #(
        .AW_READY_AW_COUNT   (AW_READY_AW_COUNT),
        .W_READY_BURST_COUNT (W_READY_BURST_COUNT),
        .AW_DELAY            (AW_DELAY),
        .MEM_BEATS           (65536),
        .WSTRB_IGNORE        (WSTRB_IGNORE)
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
        .obs_aw_hs      (m_aw_hs),
        .obs_ar_hs      (m_ar_hs),
        .obs_wr_beats   (m_wr_beats),
        .obs_rd_beats   (m_rd_beats),
        .obs_len0_wr    (m_len0),
        .obs_len0_wstrb0(m_s0),
        .obs_len0_wstrb1(m_s1),
        .obs_last_marker()
    );

    assign axi_wusero_id = 4'd0;

    // ------------------------------------------------------------------
    // Bookkeeping: cycle counter, per-master done counters, AW probes
    // ------------------------------------------------------------------
    reg [31:0] cyc;
    reg [7:0]  dc0, dc1, dc2, dc3;

    reg [31:0] m3_req_cyc;     // st_cv first high
    reg [31:0] m3_aw_cyc;      // first axi_awvalid with id 3 (= granted + 1)
    reg [31:0] m3_awhs_cyc;    // first axi_awready with awvalid/id 3
    reg [31:0] wait3_max;
    reg [31:0] aw3_cur, aw3_max;
    reg [31:0] awc0, awc2, awc3;
    reg [31:0] aw_ovl;
    reg        seen_abort;
    reg [3:0]  last_done_d;
    reg [3:0]  first_abort_done_r;
    reg [2:0]  first_abort_dbg_r;
    reg        to_err_d;

    wire m3_aw_sel = axi_awvalid && (axi_awuser_id == 4'd3);

    // Frozen copy of the cycle counter at verdict time
    reg [31:0] cyc_l;

    // Scenario stop conditions (STOP_AFTER_FIRST_AW trims the long runs)
    wire stop_now   = (STOP_AFTER_FIRST_AW != 0) &&
                      (m3_awhs_cyc != 32'hFFFF_FFFF) &&
                      (cyc > (m3_awhs_cyc + 32'd32));
    // EXPECT 3 needs two sequential events (m3 fails first, then m0 times
    // out), so the early st_fail must NOT end the scenario.
    wire finish_now = (EXPECT == 3) ? (to_err || (cyc > MAX_CYCLES))
                                    : (st_done_o || st_fail_o ||
                                       (cyc > MAX_CYCLES));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc    <= 32'd0;
            cyc_l  <= 32'd0;
            dc0    <= 8'd0;
            dc1    <= 8'd0;
            dc2    <= 8'd0;
            dc3    <= 8'd0;
            m3_req_cyc        <= 32'hFFFF_FFFF;
            m3_aw_cyc         <= 32'hFFFF_FFFF;
            m3_awhs_cyc       <= 32'hFFFF_FFFF;
            wait3_max         <= 32'd0;
            aw3_cur           <= 32'd0;
            aw3_max           <= 32'd0;
            awc0              <= 32'd0;
            awc2              <= 32'd0;
            awc3              <= 32'd0;
            aw_ovl            <= 32'd0;
            seen_abort        <= 1'b0;
            last_done_d       <= 4'd0;
            first_abort_done_r<= 4'd0;
            first_abort_dbg_r <= 3'd0;
            to_err_d          <= 1'b0;
        end else begin
            cyc <= cyc + 32'd1;
            if (done[0]) dc0 <= dc0 + 8'd1;
            if (done[1]) dc1 <= dc1 + 8'd1;
            if (done[2]) dc2 <= dc2 + 8'd1;
            if (done[3]) dc3 <= dc3 + 8'd1;

            // m3 request / grant / AW probes
            if ((m3_req_cyc == 32'hFFFF_FFFF) && st_cv)
                m3_req_cyc <= cyc;
            if ((m3_aw_cyc == 32'hFFFF_FFFF) && m3_aw_sel)
                m3_aw_cyc <= cyc;
            if ((m3_awhs_cyc == 32'hFFFF_FFFF) && m3_aw_sel && axi_awready)
                m3_awhs_cyc <= cyc;

            if (wait_cnt_3 > wait3_max) wait3_max <= wait_cnt_3;

            // max AW (address phase) wait inside S_AW for master 3
            if (m3_aw_sel && !axi_awready)
                aw3_cur <= aw3_cur + 32'd1;
            else if (m3_aw_sel && axi_awready) begin
                if (aw3_cur > aw3_max) aw3_max <= aw3_cur;
                aw3_cur <= 32'd0;
            end

            // AW handshake histogram (which master owns the address channel)
            if (axi_awvalid && axi_awready) begin
                if (axi_awuser_id == 4'd0) awc0 <= awc0 + 32'd1;
                if (axi_awuser_id == 4'd2) awc2 <= awc2 + 32'd1;
                if (axi_awuser_id == 4'd3) awc3 <= awc3 + 32'd1;
            end

            // Structural check: can an AW coexist with a write-data beat?
            // axi_awvalid is only high in S_AW/S_DW_AW and wready_beat is only
            // non-zero in S_W, so this must stay 0 for the whole run.
            if (axi_awvalid && (wready_beat != 4'd0))
                aw_ovl <= aw_ovl + 32'd1;

            // Which master aborted first (done is asserted on the abort cycle)
            if (done != 4'd0) last_done_d <= done;
            if (to_err && !to_err_d && !seen_abort) begin
                seen_abort         <= 1'b1;
                first_abort_done_r <= last_done_d;
                first_abort_dbg_r  <= dbg_to_state;
            end
            to_err_d <= to_err;
        end
    end

    // ------------------------------------------------------------------
    // Master drivers (all in one block: each writes its own registers)
    //   m0 phases: 0 issue left, 1 wait done -> issue right, 2 wait done
    //              -> idle 16 cycles -> next page
    //   m2 phases: 0 issue read, 1 wait done -> drain beats, 2 drain,
    //              3 inter-command gap, 4 finished
    // ------------------------------------------------------------------
    reg [2:0]  p0;
    reg [2:0]  p2;
    reg [31:0] page;
    reg [31:0] m2_cmd_i;
    reg [31:0] fill;
    reg [31:0] drain;
    reg [31:0] gap;
    reg [31:0] m2_giveup;
    reg        started0, started2, started3, sat_started;

    wire [27:0] page_off = page[13:0] << 5;
    // Next saturated page address (page wraps inside the PCM left window)
    wire [13:0] sat_page_nxt = (page[13:0] + 14'd1) & 14'd8191;
    wire [27:0] sat_off_nxt  = {14'd0, sat_page_nxt} << 5;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p0            <= 3'd0;
            p2            <= 3'd0;
            page          <= 32'd0;
            m2_cmd_i      <= 32'd0;
            fill          <= 32'd0;
            drain         <= 32'd0;
            gap           <= 32'd0;
            m2_giveup     <= 32'd0;
            started0      <= 1'b0;
            started2      <= 1'b0;
            started3      <= 1'b0;
            sat_started   <= 1'b0;
            st_start      <= 1'b0;
            m_cv          <= 3'd0;
            rd_ready_r    <= 3'd0;
            m0_cmd_r      <= 37'd0;
            m1_cmd_r      <= 37'd0;
            m2_cmd_r      <= 37'd0;
            m0_wdata_r    <= 256'd0;
            m1_wdata_r    <= 256'd0;
            m2_wdata_r    <= 256'd0;
            case_done     <= 1'b0;

        end else begin
            // -------- self_test kick (delayed to reach steady state) --------
            if (!started3 && (cyc > M3_START_CYCLE)) begin
                st_start  <= 1'b1;
                started3  <= 1'b1;
            end else begin
                st_start  <= 1'b0;
            end

            // -------- m0 saturated writes (worst case: zero request gap) ----
            if (M0_SAT != 0) begin
                if (!sat_started && (cyc > 32'd8)) begin
                    m0_cmd_r    <= {1'b1, 28'h0000_000, 8'd0};
                    m0_wdata_r  <= {8{32'h1122_3344}};
                    m_cv[0]     <= 1'b1;
                    sat_started <= 1'b1;
                end else if (sat_started && done[0]) begin
                    // cmd_valid never drops: highest-priority request forever
                    m0_cmd_r <= {1'b1, 28'h0000_000 + sat_off_nxt, 8'd0};
                    page     <= page + 32'd1;
                end
            end
            // -------- m0: real audio page writes --------
            else if (M0_PAGES > 0) begin
                case (p0)
                    3'd0: if (cyc > M0_START_CYCLE) begin
                        m0_cmd_r   <= {1'b1, 28'h0000_000 + page_off, 8'd0};
                        m0_wdata_r <= {8{32'h1122_3344}};
                        m_cv[0]    <= 1'b1;
                        p0         <= 3'd1;
                    end
                    3'd1: if (done[0]) begin
                        if (M0_SINGLE != 0) begin
                            m_cv[0] <= 1'b0;
                            p0      <= 3'd4;
                        end else begin
                            // left page accepted; issue the right archive
                            // mirror with cmd_valid still held (audio_sink)
                            m0_cmd_r <= {1'b1, 28'h0008_4000 + page_off, 8'd0};
                            m0_wdata_r <= {8{32'h5566_7788}};
                            p0       <= 3'd2;
                        end
                    end
                    3'd2: if (done[0]) begin
                        m_cv[0] <= 1'b0;
                        page    <= page + 32'd1;
                        fill    <= 32'd0;
                        p0      <= 3'd3;
                    end
                    3'd3: begin
                        // 16 frame-times of aggregator fill before the next
                        // page becomes available (audio_sink agg_freeze model)
                        if (fill == 32'd15) begin
                            if (page >= M0_PAGES) p0 <= 3'd4;
                            else                  p0 <= 3'd0;
                        end else begin
                            fill <= fill + 32'd1;
                        end
                    end
                    default: ;   // 4 = finished
                endcase
            end

            // -------- m2: mel PCM window reads (516 x len=15) --------
            if (M2_CMDS > 0) begin
                case (p2)
                    3'd0: if (cyc > 32'd8) begin
                        m2_cmd_r  <= {1'b0, 28'h0000_000 + (m2_cmd_i << 9), 8'd15};
                        m_cv[2]   <= 1'b1;
                        rd_ready_r[2] <= 1'b0;
                        drain     <= 32'd0;
                        p2        <= 3'd1;
                    end
                    3'd1: if (done[2]) begin
                        m_cv[2]        <= 1'b0;
                        rd_ready_r[2]  <= 1'b1;
                        drain          <= 32'd0;
                        m2_giveup      <= 32'd0;
                        p2             <= 3'd2;
                    end
                    3'd2: begin
                        // Drain the 16 captured beats (rd_valid paces the fifo)
                        if (rd_valid[2]) begin
                            drain <= drain + 32'd1;
                        end
                        if (drain >= 32'd16) begin
                            rd_ready_r[2] <= 1'b0;
                            m2_cmd_i      <= m2_cmd_i + 32'd1;
                            gap           <= 32'd0;
                            p2            <= 3'd3;
                        end else if (m2_giveup == M2_BEAT_GIVEUP) begin
                            // no data ever came (aborted command): move on
                            rd_ready_r[2] <= 1'b0;
                            m2_cmd_i      <= m2_cmd_i + 32'd1;
                            gap           <= 32'd0;
                            p2            <= 3'd3;
                        end else begin
                            m2_giveup <= m2_giveup + 32'd1;
                        end
                    end
                    3'd3: begin
                        if (gap == 32'd1) begin
                            if (m2_cmd_i >= M2_CMDS) p2 <= 3'd4;
                            else                     p2 <= 3'd0;
                        end else begin
                            gap <= gap + 32'd1;
                        end
                    end
                    default: ;   // 4 = finished
                endcase
            end

            // -------- completion --------
            if (!case_done && (stop_now || finish_now)) begin
                case_done <= 1'b1;
                cyc_l     <= cyc + 32'd1;
            end

            // Everything is measured at verdict time: stop generating traffic
            // so the observation counters cannot drift afterwards.
            if (case_done) begin
                m_cv       <= 3'd0;
                rd_ready_r <= 3'd0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Verdict (combinational on the frozen observations)
    // ------------------------------------------------------------------
    wire [31:0] req2aw = (m3_req_cyc == 32'hFFFF_FFFF) ? 32'd0 :
                         ((m3_aw_cyc  == 32'hFFFF_FFFF) ? 32'd0 :
                          (m3_aw_cyc - m3_req_cyc));
    wire [31:0] aw_wait = (m3_aw_cyc == 32'hFFFF_FFFF) ? 32'd0 :
                          ((m3_awhs_cyc == 32'hFFFF_FFFF) ? 32'd0 :
                           (m3_awhs_cyc - m3_aw_cyc));

    // EXPECT 0: healthy model, all 16 self-test commands pass and every m3 AW
    //           handshake is served within 8 cycles no matter how busy m0/m2
    //           are. The queue peak must stay far below the watchdog limit.
    // EXPECT 1: write-beat starvation poisons the IP: the FIRST abort belongs
    //           to a write master (m0 or m2) in S_W, and the m3 command that
    //           follows times out in S_AW without ever seeing awready.
    // EXPECT 2: saturated m0 is bypassed by the P3 quota, so the queue time
    //           equals the quota value and the AW itself is still served fast.
    reg case_pass_r;

    wire [7:0] sts_byte = {1'b0, cmd_to_err[3], to_err, dbg_to_state,
                           st_fail_o, st_done_o};

    always @* begin
        if (!case_done) begin
            case_pass_r = 1'b0;
        end else if (EXPECT == 1) begin
            case_pass_r = to_err && cmd_to_err[3] &&
                          (cmd_to_err[0] || cmd_to_err[2]) &&
                          (dbg_to_state == 3'd1) && st_fail_o &&
                          (first_abort_done_r[0] == 1'b1) &&
                          (first_abort_dbg_r == 3'd2) &&
                          (m3_awhs_cyc == 32'hFFFF_FFFF);
        end else if (EXPECT == 3) begin
            // Board STS 0x26 means all of: to_err=1, dbg=S_AW, cte[3]=0,
            // st_fail=1, st_done=0. Reproducing it needs two independent
            // events: m3 finishes without any AXI timeout but with corrupt
            // data, and a real write master then times out in S_AW.
            case_pass_r = (sts_byte == 8'h26);
        end else if (EXPECT == 2) begin
            case_pass_r = (m3_awhs_cyc != 32'hFFFF_FFFF) && (aw_wait <= 32'd8) &&
                          !to_err && !st_fail_o &&
                          (wait3_max >= (P3_QUOTA_TIMEOUT - 256)) &&
                          (wait3_max <= (P3_QUOTA_TIMEOUT + 1024));
        end else begin
            case_pass_r = st_done_o && !st_fail_o && !to_err &&
                          (dc3 == 8'd16) && (aw3_max <= 32'd8) &&
                          (wait3_max < AXI_TO_LIMIT);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) case_pass <= 1'b0;
        else        case_pass <= case_pass_r;
    end

    assign o_cyc             = cyc_l;
    assign o_req2aw          = req2aw;
    assign o_aw_wait         = aw_wait;
    assign o_m3_aw_never     = (m3_awhs_cyc == 32'hFFFF_FFFF);
    assign o_wait3_max       = wait3_max;
    assign o_aw3_max_wait    = aw3_max;
    assign o_cmd_to_err      = cmd_to_err;
    assign o_first_abort_done= first_abort_done_r;
    assign o_first_abort_dbg = first_abort_dbg_r;
    assign o_dbg_to_state    = dbg_to_state;
    assign o_to_err          = to_err;
    assign o_st_done         = st_done_o;
    assign o_st_fail         = st_fail_o;
    assign o_st_fail_addr    = st_fail_addr_o;
    assign o_done_cnt0       = dc0;
    assign o_done_cnt2       = dc2;
    assign o_done_cnt3       = dc3;
    assign o_aw_cnt0         = awc0;
    assign o_aw_cnt2         = awc2;
    assign o_aw_cnt3         = awc3;
    assign o_aw_overlap_w    = aw_ovl;
    assign o_sts_byte        = {1'b0, cmd_to_err[3], to_err, dbg_to_state,
                                st_fail_o, st_done_o};

endmodule