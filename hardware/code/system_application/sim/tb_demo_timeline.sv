`timescale 1ns/1ps
module tb_demo_timeline;
reg clk=0; always #5 clk=~clk;
reg rst_n=0, key_n=1;
wire valid; wire [7:0] pct; wire [3:0] idx, top1;
demo_confidence_player #(.TICK_CYCLES(100), .DEBOUNCE_CYCLES(3)) dut
(.clk(clk),.rst_n(rst_n),.key_n(key_n),.probs_valid(valid),.probs_pct(pct),.probs_idx(idx),.top1(top1));
reg [63:0] expected [0:4095];
reg [63:0] observed;
integer bundles=0, expected_idx=0, n, i, j, best;
reg [7:0] max_pct;
always @(negedge clk) if (valid) begin
    if(idx != expected_idx) $fatal(1,"partial bundle");
    observed[idx*8+:8]=pct;
    if(idx==7) begin bundles=bundles+1; expected_idx=0; end
    else expected_idx=expected_idx+1;
end
task wait_bundle;
integer b; begin b=bundles; wait(bundles>b); #1; end
endtask
task press;
begin @(negedge clk); key_n=0; repeat(8) @(negedge clk); key_n=1; end
endtask
initial begin
    $readmemh("src/ui/demo_confidence.hex",expected);
    repeat(4) @(negedge clk); rst_n=1;
    wait_bundle(); if(observed!==0 || top1!=8) $fatal(1,"idle");
    press();
    for(i=0;i<581;i=i+1) begin
        wait_bundle();
        if(observed!==expected[i]) $fatal(1,"timeline row %0d mismatch",i);
        best=8; max_pct=0;
        for(j=0;j<8;j=j+1) if(expected[i][j*8+:8]>max_pct) begin
            best=j; max_pct=expected[i][j*8+:8];
        end
        if(top1!=best) $fatal(1,"top1 row %0d",i);
    end
    repeat(3) begin wait_bundle(); if(observed!==expected[580]) $fatal(1,"hold"); end
    press(); wait_bundle(); if(observed!==expected[0]) $fatal(1,"replay");
    $display("RESULT: PASS demo_timeline rows=581 hold replay"); $finish;
end
initial begin #1000000; $fatal(1,"timeout"); end
endmodule
