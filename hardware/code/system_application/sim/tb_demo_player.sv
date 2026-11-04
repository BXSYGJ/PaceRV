`timescale 1ns/1ps
module tb_demo_player;
reg clk=0; always #5 clk=~clk;
reg rst_n=0, key_n=1;
wire valid; wire [7:0] pct; wire [3:0] idx, top1;
demo_confidence_player #(.TICK_CYCLES(100), .DEBOUNCE_CYCLES(3), .SAMPLE_COUNT(3)) dut
(.clk(clk),.rst_n(rst_n),.key_n(key_n),.probs_valid(valid),.probs_pct(pct),.probs_idx(idx),.top1(top1));
integer bundles=0, expected_idx=0;
reg [63:0] observed;
always @(negedge clk) if (valid) begin
    if(idx != expected_idx) $fatal(1,"partial bundle");
    observed[idx*8+:8]=pct;
    if(idx==7) begin bundles=bundles+1; expected_idx=0; end
    else expected_idx=expected_idx+1;
end
task wait_bundle;
integer n;
begin n=bundles; wait(bundles>n); #1; end
endtask
task press;
begin @(negedge clk); key_n=0; repeat(8) @(negedge clk); key_n=1; end
endtask
initial begin
    #1; dut.samples[0]=64'h000000000000000a;
    dut.samples[1]=64'h00000000005a0000;
    dut.samples[2]=64'h5000000000000000;
    repeat(4) @(negedge clk); rst_n=1;
    wait_bundle(); if(observed!==0 || top1!=8) $fatal(1,"idle");
    // A short glitch must not trigger replay.
    key_n=0; @(negedge clk); key_n=1;
    wait_bundle(); if(observed!==0) $fatal(1,"debounce");
    press(); wait_bundle(); if(observed!==64'ha || top1!=0) $fatal(1,"first");
    wait_bundle(); if(observed!==64'h5a0000 || top1!=2) $fatal(1,"second");
    wait_bundle(); if(observed!==64'h5000000000000000 || top1!=7) $fatal(1,"third");
    repeat(3) begin wait_bundle(); if(top1!=7) $fatal(1,"hold"); end
    press(); wait_bundle(); if(observed!==64'ha || top1!=0) $fatal(1,"replay");
    $display("RESULT: PASS demo_player"); $finish;
end
initial begin #100000; $fatal(1,"timeout"); end
endmodule
