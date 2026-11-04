`timescale 1ns/1ps
module tb_framer_repeat;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 0, start = 0, valid = 0;
    reg [31:0] pcm = 0;
    wire out_ready = (cycle % 37 >= 5);
    wire ready, busy, done, wv, fs, fd, fl;
    wire [16:0] sample_out;
    wire [8:0] frame_idx;
    stft_framer #(.HAN_HEX_FILE("src/mel/hann_q15.hex")) dut(
        .clk(clk),.rst_n(rst),.win_start(start),.busy(busy),.all_done(done),
        .out_ready(out_ready),.pcm_rd_data(pcm),.pcm_rd_valid(valid),.pcm_rd_ready(ready),
        .win_s17(sample_out),.win_valid(wv),.frame_start(fs),.frame_done(fd),
        .frame_last(fl),.frame_idx(frame_idx));
    reg [15:0] hann [0:2047];
    integer window_no = 0, sent = 0, outputs = 0, cycle = 0;
    integer position, index, f, k;
    reg signed [15:0] s, h;
    reg signed [31:0] product;
    reg signed [16:0] expected;
    function automatic [15:0] source_sample(input integer n, w);
        reg [31:0] v;
        begin
            v = n * 32'd1664525 + (w+1) * 32'd1013904223;
            source_sample = v[31:16];
        end
    endfunction
    always @(negedge clk) begin
        valid = rst && busy && sent < 132096 && (cycle % 17 != 0);
        pcm = {16'd0, source_sample(sent,window_no)};
        cycle = cycle + 1;
    end
    always @(posedge clk) begin
        if (valid && ready) sent = sent + 1;
        #1;
        if (wv) begin
            f = outputs / 2048;
            k = outputs % 2048;
            position = f * 512 + k - 1024;
            index = position < 0 ? -position : position >= 132096 ? 264190-position : position;
            s = source_sample(index,window_no);
            h = hann[k];
            product = s * h;
            expected = (product + 32'sd16384) >>> 15;
            if (sample_out !== expected)
                $fatal(1,"Framer mismatch window=%0d f=%0d k=%0d got=%0d expected=%0d",window_no,f,k,$signed(sample_out),expected);
            if (fs !== (k == 0) || fd !== (k == 2047))
                $fatal(1,"Framer marker mismatch");
            outputs = outputs + 1;
        end
    end
    integer w;
    initial begin
        $readmemh("src/mel/hann_q15.hex",hann);
        repeat (5) @(negedge clk);
        #1; rst = 1;
        for (w = 0; w < 2; w = w + 1) begin
            window_no = w; sent = 0; outputs = 0;
            @(negedge clk); #1; start = 1;
            @(negedge clk); #1; start = 0;
            wait (done);
            #2;
            if (sent != 132096 || outputs != 259*2048)
                $fatal(1,"Framer count mismatch sent=%0d out=%0d",sent,outputs);
            repeat (8) @(negedge clk);
            #1;
            if (busy) $fatal(1,"Window did not release");
        end
        $display("RESULT: PASS framer_repeat two different windows, 1060864 exact samples, reflect and ring wrap");
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1,"Framer repeat timeout");
    end
endmodule
