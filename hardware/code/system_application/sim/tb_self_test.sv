// ---------------------------------------------------------------------------
// tb_self_test.sv -- direct-drive testbench for src/ctrl/self_test.v
//
// Replaces the *scaffolding* that produced the 2026-10-31 board FAILs with a
// deterministic, cycle-accurate DDR3 stub.  The stub is a 4 KB word memory and
// a small responder FSM; it never models the real DDR3 IP, only the four
// contract events self_test consumes:
//
//   write burst  : wready_beat pulses for 16 beats, the 16th one on the SAME
//                  cycle as `done` (C-SELFTEST F2 / S1 / S2)
//   read burst   : rd_valid + rd_data beats paced by self_test's rd_ready,
//                  the 16th beat on the same cycle as `done`
//   aborts       : `done` with no beat handshake (AXI watchdog abort), both
//                  in the write phase (F1 path) and in the read phase, where
//                  done_q (one-cycle delayed) is the abort witness (F4)
//
// Checks (each prints CHECK PASS/FAIL, the run ends with RESULT: PASS/FAIL):
//   T1  full 4 KB write+read-back with identical data  -> st_done, no st_fail
//   T1  16 commands issued, each cmd_valid LEVEL-held at least 10 cycles
//   T2  write aborted after 5 beats                    -> st_fail, addr base
//   T3  read aborted (done, never any rd_valid)        -> st_fail, addr base
//   T4  recover after abort without reset              -> st_done again
//   T5  final read beat high-bit corruption             -> sticky fail
//   T6  recover from corruption without reset          -> st_done again
//
// Self-validation: set `wb_abort_at = 3` (or `rb_abort = 1`) and T1 *must*
// fail; the abort checks then prove the checker itself can see a broken FSM.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_self_test;

    localparam integer CLK_HALF = 5;                 // 100 MHz
    localparam [27:0]  BASE     = 28'h0030_0000;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    // -----------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------
    reg         st_start = 1'b0;
    wire        cmd_valid;
    wire [36:0] cmd;
    wire [255:0] wdata;
    reg         wready_beat = 1'b0;
    wire        rd_ready;
    reg  [255:0] rd_data = 256'd0;
    reg         rd_valid = 1'b0;
    reg         done = 1'b0;
    wire        st_done;
    wire        st_fail;
    wire [27:0] st_fail_addr;

    self_test dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .st_start     (st_start),
        .cmd_valid    (cmd_valid),
        .cmd          (cmd),
        .wdata        (wdata),
        .wready_beat  (wready_beat),
        .rd_ready     (rd_ready),
        .rd_data      (rd_data),
        .rd_valid     (rd_valid),
        .done         (done),
        .st_done      (st_done),
        .st_fail      (st_fail),
        .st_fail_addr (st_fail_addr)
    );

    // -----------------------------------------------------------------
    // DDR3 stub: 4 KB of address-tagged 32-bit words
    // -----------------------------------------------------------------
    reg [31:0] mem32 [0:1023];

    // responder knobs (set by the test sequence)
    integer wb_abort_at = -1;    // >=0: stop after this many write beats
    integer corrupt_last = 0;
    integer rb_abort    = 0;     // 1: never return read data
    integer rsp_delay   = 3;     // command -> first beat latency
    integer k;

    localparam integer R_IDLE = 0;
    localparam integer R_DLY  = 1;
    localparam integer R_WB   = 2;
    localparam integer R_RB   = 3;

    reg [2:0]  rsp_state = R_IDLE;
    reg [36:0] c_cmd  = 37'd0;
    reg [27:0] c_addr = 28'd0;
    reg [4:0]  consumed = 5'd0;
    integer    dly = 0;
    integer    nxt = 0;

    always @(posedge clk) begin
        // default: all handshake pulses are single-cycle
        done        <= 1'b0;
        wready_beat <= 1'b0;
        rd_valid    <= 1'b0;

        if (!rst_n) begin
            rsp_state <= R_IDLE;
            consumed  <= 5'd0;
            dly       <= 0;
        end else begin
            case (rsp_state)
                R_IDLE: begin
                    // Do not regrant the just-completed held command on done.
                    if (cmd_valid && !done) begin
                        c_cmd     <= cmd;
                        c_addr    <= cmd[35:8];
                        consumed  <= 5'd0;
                        dly       <= rsp_delay;
                        rsp_state <= R_DLY;
                    end
                end
                R_DLY: begin
                    if (dly > 0) begin
                        dly <= dly - 1;
                    end else begin
                        rsp_state <= c_cmd[36] ? R_WB : R_RB;
                        if (!c_cmd[36]) begin
                            // read: first beat is presented now so self_test
                            // samples it on the next posedge
                            rd_data  <= mem_beat(c_addr);
                            rd_valid <= 1'b1;
                        end
                        wready_beat <= c_cmd[36];   // write: first beat next
                    end
                end
                R_WB: begin
                    if (wb_abort_at >= 0 && consumed >= wb_abort_at) begin
                        // watchdog abort: done with no beat handshake
                        done      <= 1'b1;
                        rsp_state <= R_IDLE;
                    end else begin
                        mem32[{(c_addr[11:0] >> 2)} + {consumed, 3'b000}]      <= wdata[31:0];
                        mem32[{(c_addr[11:0] >> 2)} + {consumed, 3'b000} + 1]  <= wdata[63:32];
                        mem32[{(c_addr[11:0] >> 2)} + {consumed, 3'b000} + 2]  <= wdata[95:64];
                        mem32[{(c_addr[11:0] >> 2)} + {consumed, 3'b000} + 3]  <= wdata[127:96];
                        mem32[{(c_addr[11:0] >> 2)} + {consumed, 3'b000} + 4]  <= wdata[159:128];
                        mem32[{(c_addr[11:0] >> 2)} + {consumed, 3'b000} + 5]  <= wdata[191:160];
                        mem32[{(c_addr[11:0] >> 2)} + {consumed, 3'b000} + 6]  <= wdata[223:192];
                        mem32[{(c_addr[11:0] >> 2)} + {consumed, 3'b000} + 7]  <= wdata[255:224];
                        consumed <= consumed + 5'd1;
                        if (consumed == 5'd14) begin
                            // the 16th beat and done must be sampled together
                            done <= 1'b1;
                        end
                        if (consumed == 5'd15) begin
                            wready_beat <= 1'b0;
                            rsp_state   <= R_IDLE;
                        end else begin
                            wready_beat <= 1'b1;
                        end
                    end
                end
                R_RB: begin
                    if (rb_abort) begin
                        // done with no read beat: self_test must use done_q
                        done      <= 1'b1;
                        rd_valid  <= 1'b0;
                        rsp_state <= R_IDLE;
                    end else begin
                        // rd_data is a REGISTER: the beat presented now is
                        // sampled by self_test on the NEXT posedge, so the
                        // address must lead the consumed counter by one.
                        nxt = (consumed + 5'd1) * 32;
                        rd_data  <= mem_beat(c_addr + nxt);
                        rd_valid <= 1'b1;
                        consumed <= consumed + 5'd1;
                        if (consumed == 5'd14)
                            done <= 1'b1;
                        if (consumed == 5'd15) begin
                            rd_valid  <= 1'b0;
                            rsp_state <= R_IDLE;
                        end
                    end
                end
                default: rsp_state <= R_IDLE;
            endcase
        end
    end

    // One 256-bit beat (8 words, big-endian packing, mirror of self_test)
    function [255:0] mem_beat;
        input [27:0] addr;
        integer base;
        begin
            base = {20'd0, addr[11:0]} >> 2;
            mem_beat = {mem32[base + 7], mem32[base + 6], mem32[base + 5],
                        mem32[base + 4], mem32[base + 3], mem32[base + 2],
                        mem32[base + 1], mem32[base + 0]};
            if (corrupt_last && addr == BASE + 28'd4064)
                mem_beat[255] = ~mem_beat[255];
        end
    endfunction

    // -----------------------------------------------------------------
    // cmd_valid hold observation (F1: level, never a one-cycle strobe)
    // -----------------------------------------------------------------
    integer cmd_rises  = 0;
    integer hold_now   = 0;
    integer hold_min   = 1000000;
    reg     cmd_prev   = 1'b0;

    always @(posedge clk) begin
        if (cmd_valid && !cmd_prev) begin
            cmd_rises <= cmd_rises + 1;
            hold_now  <= 1;
        end else if (cmd_valid) begin
            hold_now <= hold_now + 1;
        end else if (cmd_prev) begin
            if (hold_now < hold_min)
                hold_min <= hold_now;
            hold_now <= 0;
        end
        cmd_prev <= cmd_valid;
    end

    // -----------------------------------------------------------------
    // Test sequence
    // -----------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;

    // NOTE: Verilator 5.050 + gcc 16.2 miscompiles $sformatf output, so every
    // observation is printed with a plain $display immediately before the
    // boolean check.  That keeps the failure text fully diagnosable.
    task automatic check;
        input [511:0] name;
        input         ok;
        begin
            checks = checks + 1;
            if (ok) begin
                $display("CHECK PASS: %0s", name);
            end else begin
                errors = errors + 1;
                $display("CHECK FAIL: %0s", name);
            end
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n       <= 1'b0;
            st_start    <= 1'b0;
            wready_beat <= 1'b0;
            rd_valid    <= 1'b0;
            done        <= 1'b0;
            repeat (5) @(posedge clk);
            rst_n       <= 1'b1;
            repeat (3) @(posedge clk);
        end
    endtask

    task automatic start_test;
        begin
            @(posedge clk);
            st_start <= 1'b1;
            @(posedge clk);
            st_start <= 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic wait_result;
        input integer limit;
        integer waited;
        begin
            waited = 0;
            while (!st_done && !st_fail && waited < limit) begin
                @(posedge clk);
                waited = waited + 1;
            end
            if (waited >= limit) begin
                errors = errors + 1;
                $display("ERROR: self_test did not finish within %0d cycles (state stuck)",
                         limit);
            end
        end
    endtask

    initial begin
        $display("=== tb_self_test start ===");

        // -------------------------------------------------------------
        // T1: normal 8 write + 8 read commands, level-held cmd_valid
        // -------------------------------------------------------------
        wb_abort_at = -1;
        rb_abort    = 0;
        reset_dut();
        cmd_rises = 0;
        hold_min  = 1000000;
        start_test();
        wait_result(20000);

        $display("OBS T1: st_done=%0b st_fail=%0b fail_addr=%08h cmd_rises=%0d hold_min=%0d",
                 st_done, st_fail, st_fail_addr, cmd_rises, hold_min);
        check("T1 full 4KB write+read-back passes", st_done === 1'b1 && st_fail === 1'b0);
        check("T1 16 commands issued", cmd_rises == 16);
        check("T1 cmd_valid held (level, >=10 cycles)", hold_min >= 10);

        // -------------------------------------------------------------
        // T2: write-phase watchdog abort after 5 beats
        // -------------------------------------------------------------
        wb_abort_at = 5;
        rb_abort    = 0;
        reset_dut();
        start_test();
        wait_result(5000);
        $display("OBS T2: st_done=%0b st_fail=%0b fail_addr=%08h (expected %08h)",
                 st_done, st_fail, st_fail_addr, BASE);
        check("T2 write abort -> st_fail", st_fail === 1'b1 && st_done === 1'b0);
        check("T2 write abort fail addr", st_fail_addr == BASE);

        // -------------------------------------------------------------
        // T3: read-phase abort (done, never a read beat -> done_q path)
        // -------------------------------------------------------------
        wb_abort_at = -1;
        rb_abort    = 1;
        reset_dut();
        start_test();
        wait_result(50000);
        $display("OBS T3: st_done=%0b st_fail=%0b fail_addr=%08h (expected %08h)",
                 st_done, st_fail, st_fail_addr, BASE);
        check("T3 read abort -> st_fail", st_fail === 1'b1 && st_done === 1'b0);
        check("T3 read abort fail addr", st_fail_addr == BASE);

        // -------------------------------------------------------------
        // T4: recover from ST_END with a fresh st_start
        // -------------------------------------------------------------
        wb_abort_at = -1;
        rb_abort    = 0;
        start_test();
        wait_result(20000);
        $display("OBS T4: st_done=%0b st_fail=%0b", st_done, st_fail);
        check("T4 re-run after abort passes", st_done === 1'b1 && st_fail === 1'b0);

        // A final-beat error must win over the otherwise successful finish.
        corrupt_last = 1;
        start_test();
        wait_result(20000);
        check("T5 final read beat corruption fails", st_fail && !st_done);
        check("T5 failing command address", st_fail_addr == BASE + 28'd3584);
        repeat (8) @(posedge clk);
        check("T5 failure stays sticky", st_fail && !st_done);
        corrupt_last = 0;
        start_test();
        wait_result(20000);
        check("T6 recover from corrupt read without reset", st_done && !st_fail);

        $display("=== tb_self_test done: %0d checks, %0d errors ===", checks, errors);
        if (errors == 0) begin
            $display("RESULT: PASS tb_self_test");
            $finish;
        end else begin
            $display("RESULT: FAIL tb_self_test (%0d errors)", errors);
            $fatal(1, "tb_self_test failed");
        end
    end

endmodule