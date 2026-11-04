`timescale 1ns/1ps
module tb_db_norm_stats;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0, start = 0;
    wire busy, rd_en, wr_en, stats_valid;
    wire [14:0] rd_addr, wr_addr;
    reg signed [15:0] rd_data = 0;
    wire signed [15:0] wr_data;
    wire signed [47:0] sum_db;
    wire [47:0] sum_sq;
    reg signed [15:0] memory [0:19];
    integer expected [0:19];
    integer run_id, i, maximum, value, writes, cycles;
    reg signed [63:0] expected_sum, expected_sq;
    db_norm #(.N_MELS(4), .SPEC_FRAME_COUNT(5), .OUT_FRAME_COUNT(3)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy),
        .spec_rd_en(rd_en), .spec_rd_addr(rd_addr), .spec_rd_data(rd_data),
        .db_wr_en(wr_en), .db_wr_addr(wr_addr), .db_wr_data(wr_data),
        .sum_db(sum_db), .sum_db_sq(sum_sq), .stats_valid(stats_valid)
    );
    always @(posedge clk) begin
        if (rd_en) rd_data <= memory[rd_addr];
        if (rst_n && wr_en) begin
            if (wr_addr < 8 || wr_data !== 16'(expected[wr_addr]))
                $fatal(1, "dB write mismatch run=%0d addr=%0d", run_id, wr_addr);
            memory[wr_addr] <= wr_data;
            writes = writes + 1;
        end
    end
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        for (run_id = 0; run_id < 6; run_id = run_id + 1) begin
            maximum = -32768;
            for (i = 0; i < 20; i = i + 1) begin
                case (run_id)
                    0: memory[i] = 0;
                    1: memory[i] = -32768;
                    2: memory[i] = 32767;
                    3: memory[i] = -32768 + i * 3449;
                    4: memory[i] = (i == 19) ? 32767 : -32768;
                    5: memory[i] = (i == 0) ? 32767 : -32768;
                endcase
                if ($signed(memory[i]) > maximum) maximum = $signed(memory[i]);
            end
            expected_sum = 0;
            expected_sq = 0;
            for (i = 8; i < 20; i = i + 1) begin
                value = (($signed(memory[i]) - maximum) * 775 + 128) >>> 8;
                if (value < -20480) value = -20480;
                if (value > 0) value = 0;
                expected[i] = value;
                expected_sum = expected_sum + value;
                expected_sq = expected_sq + 64'(value) * 64'(value);
            end
            writes = 0;
            start = 1;
            @(negedge clk);
            start = 0;
            cycles = 0;
            while (!stats_valid && cycles < 200) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!stats_valid || writes != 12 || $signed(sum_db) != expected_sum || sum_sq != expected_sq)
                $fatal(1, "stats mismatch run=%0d writes=%0d sum=%0d/%0d sq=%0d/%0d", run_id, writes, sum_db, expected_sum, sum_sq, expected_sq);
            @(negedge clk);
        end
        $display("RESULT: PASS db_norm_stats: six no-reset windows, tail keep, extrema, final flush");
        $finish;
    end
endmodule
