`timescale 1ns/1ps
// Real npu_top sequencer and softmax. Earlier layers are deliberately skipped;
// Only the sequencer is forced; activation DDR requests are not serviced.
// This is a completion regression, not an end-to-end numerical inference test.
module tb_npu_completion;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg start = 0;
    wire busy, done, timeout_flag, probs_valid;
    wire [31:0] cycles;
    wire [14:0] feat_addr;
    wire feat_en, rd_cmd_valid;
    wire [36:0] rd_cmd;
    wire [7:0] pct;
    wire [3:0] idx, top1;
    wire act_cmd_valid_unused, act_cmd_write_unused, act_wr_valid_unused;
    wire [31:0] act_cmd_addr_unused;
    wire [255:0] act_wr_data_unused;
    integer results = 0;
    integer completions = 0;
    npu_top dut (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
        .npu_cycles(cycles), .timeout_flag(timeout_flag),
        .feat_rd_addr(feat_addr), .feat_rd_data(8'd49), .feat_rd_en(feat_en),
        .rd_cmd_valid(rd_cmd_valid), .rd_cmd(rd_cmd), .rd_ready(1'b0),
        .rd_data(256'd0), .rd_valid(1'b0), .rd_done(1'b0),
        .act_cmd_valid(act_cmd_valid_unused), .act_cmd_write(act_cmd_write_unused),
        .act_cmd_addr(act_cmd_addr_unused), .act_cmd_ready(1'b0),
        .act_wr_valid(act_wr_valid_unused), .act_wr_data(act_wr_data_unused),
        .act_wr_ready(1'b0), .act_rd_valid(1'b0), .act_rd_data(256'd0),
        .probs_valid(probs_valid), .probs_pct(pct), .probs_idx(idx), .top1(top1)
    );
    always @(posedge clk) begin
        if (probs_valid) begin
            results = results + 1;
            if (pct != 8'd12) $fatal(1, "uniform logits percent differs: %0d", pct);
        end
        if (done) completions = completions + 1;
    end
    task run_once;
        integer before_results;
        begin
            before_results = results;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            if (!busy) $fatal(1, "start did not set busy");
            // Skip convolution/FC work, then exercise the actual FC2-to-SM
            // transition. Logits remain the real reset value (all zeros).
            force dut.layer = 4'd10;
            #1;
            release dut.layer;
            force dut.fc2_done = 1'b1;
            @(negedge clk);
            release dut.fc2_done;
            wait (dut.layer == 4'd11);
            wait (done);
            @(negedge clk);
            if (busy || timeout_flag) $fatal(1, "NPU completion status invalid");
            if (results - before_results != 8)
                $fatal(1, "expected eight real softmax results, got %0d", results-before_results);
            repeat (3) @(negedge clk);
            if (done) $fatal(1, "done was not a one-cycle pulse");
        end
    endtask
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        run_once;
        run_once;
        if (completions != 2) $fatal(1, "expected two completions, got %0d", completions);
        $display("RESULT: PASS (two real softmax completions, busy clears, restart works)");
        $finish;
    end
    initial begin
        repeat (2000) @(negedge clk);
        $fatal(1, "watchdog: NPU completion never arrived");
    end
endmodule
