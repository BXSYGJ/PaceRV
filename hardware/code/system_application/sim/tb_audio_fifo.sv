`timescale 1ns/1ps
module tb_audio_fifo;
    reg wc = 0, rc = 0;
    always #2 wc = ~wc;
    always #5 rc = ~rc;
    reg wn = 0, rn = 0, valid = 0, lrck = 0, rd_en = 0;
    reg [15:0] l = 0, r = 0;
    wire [31:0] data;
    wire dv, empty, full;
    wire [15:0] overflow;
    audio_cdc_fifo #(.ADDR_W(3)) dut (
        .clk_nco(wc), .wr_rst_n(wn), .pcm_valid(valid),
        .pcm_l(l), .pcm_r(r), .i2s_lrck(lrck),
        .clk_core(rc), .rd_rst_n(rn), .rd_en(rd_en),
        .rd_data(data), .rd_valid(dv), .empty(empty), .full(full),
        .overflow_cnt(overflow)
    );
    integer expected, received, i, round_no;
    reg stream_check = 0;
    always @(posedge rc) begin
        #1;
        if (stream_check && dv) begin
            if (data !== {16'(expected), 16'(~expected)})
                $fatal(1, "FIFO order: got %h expected %h", data,
                       {16'(expected), 16'(~expected)});
            expected = expected + 1;
            received = received + 1;
        end
    end
    task send(input integer n);
        @(negedge wc);
        l = n; r = ~n; valid = 1;
        @(negedge wc);
        valid = 0;
    endtask
    task reset_all;
        @(negedge wc); wn = 0; rn = 0; valid = 0; rd_en = 0;
        repeat (5) @(negedge wc);
        wn = 1; rn = 1;
        repeat (5) @(negedge rc);
        if (full || !empty || overflow != 0 || dv)
            $fatal(1, "Reset state invalid");
    endtask
    initial begin
        expected = 0; received = 0;
        reset_all();
        // Left-channel word is not a complete stereo pair.
        lrck = 1; send(123); lrck = 0;
        repeat (5) @(negedge rc);
        if (!empty) $fatal(1, "Left word incorrectly enqueued");
        stream_check = 1;
        // Fill exactly to capacity, reject extra writes, drain, and wrap.
        for (round_no = 0; round_no < 4; round_no = round_no + 1) begin
            for (i = 0; i < 8; i = i + 1) send(round_no*8 + i);
            if (!full) $fatal(1, "Full missing after eighth write");
            send(999); send(999);
            if (overflow != (round_no+1)*2) $fatal(1, "Drop count invalid");
            @(negedge rc); rd_en = 1;
            wait (received == (round_no+1)*8);
            @(negedge rc); rd_en = 0;
            repeat (6) @(negedge rc);
            if (!empty || full) $fatal(1, "Drain flags invalid");
        end
        // Empty reads cannot fabricate data.
        @(negedge rc); rd_en = 1;
        repeat (5) @(negedge rc);
        if (dv || received != 32) $fatal(1, "Empty read returned data");
        rd_en = 0;
        // Continuous reader, asynchronous slower producer, many pointer wraps.
        fork
            begin
                for (i = 32; i < 232; i = i + 1) begin
                    send(i);
                    repeat (6) @(negedge wc);
                end
            end
            begin
                @(negedge rc); rd_en = 1;
                wait (received == 232);
                @(negedge rc); rd_en = 0;
            end
        join
        if (overflow != 8) $fatal(1, "Unexpected streaming overflow");
        // Saturating drop counter and a reset of a full FIFO.
        stream_check = 0;
        for (i = 0; i < 8; i = i + 1) send(i);
        for (i = 0; i < 65540; i = i + 1) send(999);
        if (overflow != 16'hffff) $fatal(1, "Overflow failed saturation");
        reset_all();
        expected = 500; received = 0; stream_check = 1;
        send(500);
        @(negedge rc); rd_en = 1;
        wait (received == 1);
        @(negedge rc); rd_en = 0;
        $display("RESULT: PASS audio_fifo capacity, drops, saturation, wrap, concurrent clocks, reset");
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "FIFO timeout");
    end
endmodule
