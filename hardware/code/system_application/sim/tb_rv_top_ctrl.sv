// Tests the exact control blocks extracted from top_rv_core by run_sim.py.
// Real uart_tx is used; vendor DDR/audio IP and NPU arithmetic are excluded.
`timescale 1ns/1ps
module tb_rv_top_ctrl;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg wl_valid = 0, dbg_valid = 0, cpu_valid = 0;
    wire wl_ready, dbg_ready, cpu_ready, serial;
    reg sys_run = 0, st_done = 0, st_fail = 0, safe_err = 0;
    reg ddr_ready = 0, weight_ok = 0, weight_err = 0, wl_busy = 0;
    reg npu_busy = 0, mel_start = 0, cpu_start = 0;
    reg native_owner_idle = 1, native_fault = 0;
    wire launch, pending;
    integer cpu_pops = 0, dbg_pops = 0, wl_pops = 0;
    integer errors = 0;
    rv_top_ctrl_slice dut (
        .core_clk(clk), .core_clk_rst_n(rst_n),
        .wl_tx_valid(wl_valid), .dbg_tx_valid(dbg_valid), .cpu_tx_valid(cpu_valid),
        .wl_tx_data(8'h57), .dbg_tx_data(8'h44), .cpu_tx_data(8'h43),
        .wl_tx_ready(wl_ready), .dbg_tx_ready(dbg_ready),
        .cpu_tx_ready(cpu_ready), .uart_tx(serial),
        .sys_run(sys_run), .st_done(st_done), .st_fail(st_fail),
        .safe_err(safe_err), .ddr_init_done(ddr_ready),
        .weight_ok(weight_ok), .weight_err(weight_err), .wl_busy(wl_busy),
        .native_owner_idle(native_owner_idle), .native_fault(native_fault),
        .npu_busy_u(npu_busy), .mel_npu_start(mel_start),
        .cpu_npu_start(cpu_start), .launch_out(launch), .pending_out(pending)
    );
    always @(posedge clk) begin
        if (wl_valid && wl_ready) begin wl_pops <= wl_pops + 1; wl_valid <= 0; end
        if (dbg_valid && dbg_ready) begin dbg_pops <= dbg_pops + 1; dbg_valid <= 0; end
        if (cpu_valid && cpu_ready) begin cpu_pops <= cpu_pops + 1; cpu_valid <= 0; end
    end
    task check(input string label_, input bit ok);
        if (ok) $display("CHECK PASS %s", label_);
        else begin $display("CHECK FAIL %s", label_); errors = errors + 1; end
    endtask
    task receive_byte(input [7:0] expected);
        reg [7:0] value;
        integer bitno;
        @(negedge serial);
        repeat (1627) @(posedge clk);
        for (bitno = 0; bitno < 8; bitno = bitno + 1) begin
            value[bitno] = serial;
            repeat (1085) @(posedge clk);
        end
        check("physical UART decoded expected source byte", value == expected);
        check("physical UART stop bit", serial == 1);
    endtask
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (3) @(negedge clk);
        wl_valid = 1; dbg_valid = 1; cpu_valid = 1;
        receive_byte(8'h57);
        receive_byte(8'h44);
        receive_byte(8'h43);
        repeat (2200) @(posedge clk);
        check("three producers popped exactly once", wl_pops == 1 && dbg_pops == 1 && cpu_pops == 1);

        @(negedge clk); cpu_start = 1;
        @(negedge clk); cpu_start = 0;
        check("CPU request queued while system unready", pending && !launch);
        sys_run = 1; st_done = 1; ddr_ready = 1; weight_ok = 1;
        #1; check("ready without complete Mel window cannot launch", !launch);
        wl_busy = 1; mel_start = 1;
        #1; check("weight upload blocks complete-window launch", !launch);
        @(negedge clk); wl_busy = 0; npu_busy = 1;
        #1; check("busy accelerator blocks launch", !launch);
        @(negedge clk); npu_busy = 0; st_fail = 1;
        #1; check("failed DDR self-test blocks launch", !launch);
        @(negedge clk); st_fail = 0; native_owner_idle = 0;
        #1; check("owned native master blocks launch", !launch && pending);
        native_owner_idle = 1; native_fault = 1;
        #1; check("native fault blocks launch", !launch && pending);
        native_fault = 0;
        #1; check("pending CPU request launches on safe complete window", launch);
        @(negedge clk); mel_start = 0;
        #1; check("successful launch consumes pending request", !pending && !launch);
        @(negedge clk); mel_start = 1;
        #1; check("CPU-only mode does not repeat without new request", !launch);
        if (errors == 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL errors=%0d", errors);
        $finish;
    end
    initial begin
        #2000000;
        $display("CHECK FAIL top control watchdog");
        $display("RESULT: FAIL timeout");
        $finish;
    end
endmodule
