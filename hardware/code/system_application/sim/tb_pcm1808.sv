`timescale 1ns/1ps
module tb_pcm1808 #(
    parameter real CLK_HALF_NS = 2.315,
    parameter integer RX_TIMEOUT = 16000,
    parameter integer STUCK_SLOTS = 8,
    parameter integer LOSS_WAIT_NS = 100000,
    parameter integer DRAIN_NS = 3000
);
    reg clk=0;
    always #(CLK_HALF_NS) clk=~clk;
    reg rst_n=0, bck=0, lrck=0, sd=0;
    wire [15:0] captured_l, captured_r, out_l, out_r;
    wire captured_valid, idle, out_valid, overrun;
    reg [31:0] source [0:2047];
    reg [31:0] expected [0:1880];
    integer captures=0, outputs=0, fifo_outputs=0, epoch=0;
    reg core_clk=0;
    always #4 core_clk=~core_clk;
    wire [31:0] fifo_data;
    wire fifo_valid, fifo_empty, fifo_full;
    wire [15:0] overflow;
    audio_cdc_fifo u_fifo (
        .clk_nco(clk), .wr_rst_n(rst_n), .pcm_valid(out_valid),
        .pcm_l(out_l), .pcm_r(out_r), .i2s_lrck(1'b0),
        .clk_core(core_clk), .rd_rst_n(rst_n), .rd_en(1'b1),
        .rd_data(fifo_data), .rd_valid(fifo_valid),
        .empty(fifo_empty), .full(fifo_full), .overflow_cnt(overflow));
    always @(negedge core_clk) begin
        if (fifo_valid) begin
            if (fifo_outputs >= 1881 || fifo_data !== expected[fifo_outputs])
                $fatal(1,"CDC frame mismatch %0d: %h", fifo_outputs, fifo_data);
            fifo_outputs=fifo_outputs+1;
        end
        if (overflow != 0) $fatal(1,"CDC overflow");
    end
    i2s_slave_rx #(.TIMEOUT_CYCLES(RX_TIMEOUT)) u_rx (
        .clk_nco(clk), .rst_n(rst_n), .i2s_bck(bck), .i2s_lrck(lrck),
        .i2s_sd(sd), .pcm_l(captured_l), .pcm_r(captured_r),
        .pcm_valid(captured_valid), .sd_idle(idle));
    pcm1808_resampler u_fir (
        .clk(clk), .rst_n(rst_n), .stream_idle(idle),
        .in_valid(captured_valid), .in_l(captured_l), .in_r(captured_r),
        .out_valid(out_valid), .out_l(out_l), .out_r(out_r), .overrun(overrun));
    always @(negedge clk) begin
        if (captured_valid) begin
            if (captures >= 2048 || {captured_l,captured_r} !== source[captures])
                $fatal(1,"capture epoch %0d frame %0d got %h expected %h", epoch,
                       captures, {captured_l,captured_r}, source[captures]);
            captures=captures+1;
        end
        if (out_valid) begin
            if (outputs >= 1881 || {out_l,out_r} !== expected[outputs])
                $fatal(1,"FIR epoch %0d sample %0d got %h expected %h", epoch,
                       outputs, {out_l,out_r}, expected[outputs]);
            outputs=outputs+1;
        end
        if (overrun) $fatal(1,"unexpected overrun");
    end
    task slot(input bit channel, input [23:0] word_value);
        integer bit_no;
        begin
            for (bit_no=0; bit_no<32; bit_no=bit_no+1) begin
                bck=0; lrck=channel;
                if (bit_no>0 && bit_no<=24) sd=word_value[24-bit_no];
                else sd=1;
                #163; bck=1; #163;
            end
        end
    endtask
    integer n, e;
    initial begin
        $readmemh("build/sim/pcm1808/input.hex", source);
        $readmemh("build/sim/pcm1808/expected.hex", expected);
        #137; rst_n=1;
        for (e=0; e<2; e=e+1) begin
            epoch=e; captures=0; outputs=0; fifo_outputs=0;
            slot(1,24'h123456);
            for (n=0; n<2048; n=n+1) begin
                slot(0,{source[n][31:16],8'hd3});
                slot(1,{source[n][15:0],8'h6b});
            end
            bck=0; #(DRAIN_NS);
            if (captures!=2048 || outputs!=1881 || fifo_outputs!=1881)
                $fatal(1,"count mismatch %0d/%0d",captures,outputs);
            repeat (STUCK_SLOTS) slot(1,24'h555555);
            if (!idle) $fatal(1,"stuck LRCK not detected");
            #(LOSS_WAIT_NS);
            if (!idle || captures!=2048 || outputs!=1881 || fifo_outputs!=1881)
                $fatal(1,"unexpected samples after clock loss");
        end
        rst_n=0; #100; rst_n=1; #(LOSS_WAIT_NS);
        if (!idle || captured_valid || out_valid) $fatal(1,"reset/clock loss failure");
        $display("RESULT: PASS pcm1808: two no-reset epochs, 4096 serial stereo pairs, 3762 FIR/CDC golden outputs, clock loss/recovery");
        $finish;
    end
    initial begin #100000000; $fatal(1,"timeout"); end
endmodule
