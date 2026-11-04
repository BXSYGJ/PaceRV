`timescale 1ns/1ps
module tb_i2s_capture;
    reg clk=0;
    always #2.315 clk=~clk;
    reg rst_n=0;
    reg sd=0;
    wire tick,bck,lrck,valid,idle;
    wire [4:0] phase;
    wire [15:0] left_pcm,right_pcm;
    reg [15:0] words[0:7];
    integer tx_bit=15;
    integer tx_word=0;
    integer received=0;
    reg prev_valid=0;
    i2s_clk_gen clocks(.clk_nco(clk),.rst_n(rst_n),.bck_phase(phase),
        .bck_tick(tick),.i2s_bck(bck),.i2s_lrck(lrck));
    i2s_rx receiver(.clk_nco(clk),.rst_n(rst_n),.i2s_sd(sd),
        .bck_tick(tick),.bck_phase(phase),.i2s_lrck(lrck),
        .pcm_l(left_pcm),.pcm_r(right_pcm),.pcm_valid(valid),.sd_idle(idle));
    // External Philips-I2S source: change SD on physical BCK falling edges.
    // MSB follows the LRCK boundary by one complete BCK period; LSB spans it.
    always @(negedge bck) begin
        if (rst_n && tx_word<8) begin
            sd=words[tx_word][tx_bit];
            if (tx_bit==0) begin tx_bit=15; tx_word=tx_word+1; end
            else tx_bit=tx_bit-1;
        end
    end
    always @(negedge clk) begin
        if (rst_n) begin
            if (valid && prev_valid) $fatal(1,"pcm_valid held longer than one cycle");
            prev_valid=valid;
            if (valid) begin
                // The first startup pulse contains an incomplete previous word.
                if (received>0 && received<=8) begin
                    if (((received-1)%2)==0) begin
                        if (left_pcm!==words[received-1])
                            $fatal(1,"LEFT word %0d got %04x expected %04x",received-1,left_pcm,words[received-1]);
                    end else if (right_pcm!==words[received-1])
                        $fatal(1,"RIGHT word %0d got %04x expected %04x",received-1,right_pcm,words[received-1]);
                end
                received=received+1;
            end
        end
    end
    initial begin
        words[0]=16'h1235; words[1]=16'hABCD; words[2]=16'h8001; words[3]=16'h7FFE;
        words[4]=16'h0000; words[5]=16'hFFFF; words[6]=16'hA55A; words[7]=16'h5AA5;
        repeat(5) @(negedge clk);
        rst_n=1;
        wait(received==9);
        // Stop the source: static SD must eventually assert idle.
        repeat(160) @(posedge tick);
        repeat(4) @(negedge clk);
        if (!idle) $fatal(1,"static SD did not assert idle");
        sd=~sd;
        repeat(6) @(negedge clk);
        if (idle) $fatal(1,"SD activity did not clear idle");
        // Begin a partial frame, then reset and verify a fresh full stream.
        rst_n=0; sd=0; tx_word=0; tx_bit=15; received=0; prev_valid=0;
        repeat(5) @(negedge clk);
        rst_n=1;
        repeat(400) @(negedge clk);
        rst_n=0; sd=0; tx_word=0; tx_bit=15; received=0; prev_valid=0;
        repeat(5) @(negedge clk);
        if (valid || left_pcm || right_pcm) $fatal(1,"reset did not clear PCM");
        rst_n=1;
        wait(received==9);
        $display("RESULT: PASS physical I2S capture 16 words, idle/activity and mid-frame reset");
        $finish;
    end
    initial begin #1000000; $fatal(1,"I2S timeout"); end
endmodule
