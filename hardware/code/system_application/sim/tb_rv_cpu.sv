// ---------------------------------------------------------------------------
// tb_rv_cpu.sv -- end-to-end testbench for the InstRec RV32 control core
//
// Runs the real firmware image (src/cpu/prog.hex, built by
// scripts/build_rv32_sw.py) on rv32_cpu_subsys and consumes the UART byte
// stream the way the board's uart_tx does.  Then it injects one NPU
// completion event and checks that the firmware reports it through MMIO.
//
// Checks
//   C1  firmware reaches main and prints "RV32 BOOT"
//   C2  MMIO ID read-back prints "RV32 MMIO OK"
//   C3  the RV32I self-test prints "RV32 ISA OK"
//   C4  mcycle/minstret measurement prints "RV32 BENCH cycles=..."
//   C5  an injected probs event prints distinct top1=5 and last_class=3
//   C6  firmware issues a real MMIO NPU start write
//   C7  DDR OK is decoded from the real status register
//   C8  firmware acknowledges and clears the sticky NPU event
//   C9  result cycle count remains associated with the captured event
//   C10 completion acknowledgement queues a second CPU launch
// Self-validation: change a token in main.c (or drop the injected event) and
// the matching check must fail.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_rv_cpu;

    localparam integer CLK_HALF   = 5;             // 100 MHz
    localparam integer MAX_CYCLES = 4_000_000;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    integer cycles = 0;
    always @(posedge clk) cycles <= cycles + 1;

    wire        uart_valid;
    wire [7:0]  uart_data;
    reg         uart_ready = 1'b1;
    wire [7:0]  cpu_led;
    wire        cpu_alive, cpu_trap;
    wire [31:0] cpu_trap_cause;
    wire        npu_soft_start;

    reg         npu_busy = 1'b0;
    reg         npu_done = 1'b0;
    reg         npu_timeout = 1'b0;
    reg         npu_probs_valid = 1'b0;
    reg  [7:0]  npu_probs_pct = 8'd0;
    reg  [3:0]  npu_probs_idx = 4'd0;
    reg  [31:0] npu_cycles = 32'd12345;

    rv32_cpu_subsys #(
        .ENABLE_M         (0),
        .ENABLE_PREDICTOR (0),
        .PROG_HEX         ("src/cpu/prog.hex")
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .npu_busy        (npu_busy),
        .npu_done        (npu_done),
        .npu_timeout     (npu_timeout),
        .npu_probs_valid (npu_probs_valid),
        .npu_probs_pct   (npu_probs_pct),
        .npu_probs_idx   (npu_probs_idx),
        .npu_top1        (4'd5),
        .npu_cycles      (npu_cycles),
        .ddr_ok          (1'b1),
        .ddr_err         (1'b0),
        .ddr_sts         (32'h0000_0001),
        .uart_valid      (uart_valid),
        .uart_data       (uart_data),
        .uart_ready      (uart_ready),
        .cpu_led         (cpu_led),
        .cpu_alive       (cpu_alive),
        .cpu_trap        (cpu_trap),
        .cpu_trap_cause  (cpu_trap_cause),
        .npu_soft_start  (npu_soft_start)
    );

    // ---- UART receiver: one byte every ~20 cycles --------------------
    integer gap = 0;
    always @(posedge clk) begin
        if (uart_valid && uart_ready) gap <= 20;
        else if (gap > 0)            gap <= gap - 1;
        uart_ready <= (gap == 0);
    end

    // ---- line assembly -------------------------------------------------
    string  line_s = "";
    string  log_s  = "";
    integer nline  = 0;

    always @(posedge clk) begin
        if (uart_valid && uart_ready) begin
            if (uart_data == 8'h0a) begin
                log_s  = {log_s, line_s, "\n"};
                line_s = "";
                nline  = nline + 1;
            end else if (uart_data != 8'h0d) begin
                line_s = {line_s, $sformatf("%c", uart_data)};
            end
        end
    end

    function automatic bit starts_with(string s, string p);
        if (s.len() < p.len()) return 1'b0;
        return (s.substr(0, p.len() - 1) == p);
    endfunction

    function automatic bit has_prefix(string pat);
        integer k;
        string cur = "";
        for (k = 0; k < log_s.len(); k = k + 1) begin
            if (log_s.substr(k, k) == "\n") begin
                if (starts_with(cur, pat)) return 1'b1;
                cur = "";
            end else begin
                cur = {cur, log_s.substr(k, k)};
            end
        end
        return starts_with(cur, pat);
    endfunction

    integer nfail = 0;
    reg cpu_triggered = 1'b0;
    reg cpu_acknowledged = 1'b0;

    always @(posedge clk) begin
        if (rst_n && dut.ctrl_clear) cpu_acknowledged <= 1'b1;
    end

    // bring-up trace (cheap, only every 250k cycles)
    always @(posedge clk) begin
        if (cycles != 0 && cycles % 250000 == 0) begin
            $display("dbg t=%0d pc=%h ireq=%b/irdy=%b irsp=%b tr=%b nline=%0d imem0=%h",
                     cycles, dut.u_core.next_pc, dut.i_req_valid, dut.i_req_ready,
                     dut.i_rsp_valid, cpu_trap, nline, dut.imem[0]);
        end
    end

    // ---- stimulus ------------------------------------------------------
    initial begin
        #(CLK_HALF*8) rst_n = 1'b1;

        // Wait until the boot self-tests and the DDR line are out, then the
        // firmware must trigger the NPU itself through CTRL[0] (C6).  Only
        // after that pulse does this testbench answer as the accelerator.
        wait (nline >= 6);      // BOOT / MMIO OK / ISA OK / BENCH / DDR
        wait (npu_soft_start === 1'b1);
        cpu_triggered = 1'b1;
        @(posedge clk);

        npu_busy <= 1'b1;
        repeat (50) @(posedge clk);
        npu_busy <= 1'b0;
        // Present the result payload before asserting valid; the DUT samples
        // all accelerator inputs on the active edge.
        npu_done <= 1'b1;
        npu_probs_pct <= 8'd87;
        npu_probs_idx <= 4'd3;
        npu_probs_valid <= 1'b1;
        // Keep the completion and result valid through a full DUT sampling
        // edge; nonblocking assignments at the same edge otherwise make the
        // CPU-side sticky result capture the old zero value.
        repeat (2) @(posedge clk);
        npu_done <= 1'b0;
        npu_probs_valid <= 1'b0;
        // An accelerator counter may change after completion; software must
        // still read the cycle count belonging to the captured result.
        npu_cycles <= 32'd99999;

        wait (nline >= 8);      // + "NPU GO" + the NPU report
        wait (cpu_acknowledged);
        wait (npu_soft_start === 1'b1);
        $display("CHECK PASS C10 firmware requested next inference after acknowledgement");
        repeat (50) @(posedge clk);

        $display("---- UART log (%0d lines) ----", nline);
        $write("%s", log_s);
        $write("\n");

        if (!has_prefix("RV32 BOOT"))  begin $display("CHECK FAIL C1 no boot banner");  nfail = nfail + 1; end
        else $display("CHECK PASS C1 boot banner");
        if (!has_prefix("RV32 MMIO OK")) begin $display("CHECK FAIL C2 no MMIO OK"); nfail = nfail + 1; end
        else $display("CHECK PASS C2 MMIO ID read-back");
        if (!has_prefix("RV32 ISA OK")) begin $display("CHECK FAIL C3 no ISA OK"); nfail = nfail + 1; end
        else $display("CHECK PASS C3 ISA self-test");
        if (!has_prefix("RV32 BENCH cycles=")) begin $display("CHECK FAIL C4 no BENCH line"); nfail = nfail + 1; end
        else $display("CHECK PASS C4 mcycle/minstret measurement");
        if (!has_prefix("NPU top1=5 last_class=3 last_p=87")) begin $display("CHECK FAIL C5 no NPU event report"); nfail = nfail + 1; end
        else $display("CHECK PASS C5 NPU event surfaced through MMIO");
        if (!cpu_triggered) begin $display("CHECK FAIL C6 firmware never pulsed CTRL[0]"); nfail = nfail + 1; end
        else $display("CHECK PASS C6 CPU-triggered NPU start (CTRL[0])");
        if (!has_prefix("DDR OK STS 0x00000001")) begin $display("CHECK FAIL C7 DDR status read-back"); nfail = nfail + 1; end
        else $display("CHECK PASS C7 DDR status read-back");
        if (!cpu_acknowledged || dut.npu_done_st || dut.npu_probs_st || dut.npu_timeout_st) begin
            $display("CHECK FAIL C8 NPU event acknowledgement/clear"); nfail = nfail + 1;
        end else $display("CHECK PASS C8 firmware acknowledged and cleared NPU event");
        if (!has_prefix("NPU top1=5 last_class=3 last_p=87 c=12345")) begin $display("CHECK FAIL C9 result cycle snapshot"); nfail = nfail + 1; end
        else $display("CHECK PASS C9 result cycle snapshot survives live counter change");

        if (cpu_trap) begin
            $display("CHECK FAIL CPU trap, cause=%08x", cpu_trap_cause);
            nfail = nfail + 1;
        end

        if (nfail == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL (%0d checks)", nfail);
        $finish;
    end

    initial begin
        #(CLK_HALF*2*MAX_CYCLES);
        $display("---- UART log so far (%0d lines) ----", nline);
        $write("%s", log_s);
        $display("CHECK FAIL watchdog expired (%0d cycles)", cycles);
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
