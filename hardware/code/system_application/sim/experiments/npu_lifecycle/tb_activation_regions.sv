module tb_activation_regions;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,arb_en=0;reg[3:0]cmd_valid=0;
reg[36:0]m0_cmd=0,m1_cmd=0,m2_cmd=0,m3_cmd=0;
wire[3:0]grant,addr_err;wire grant_wr;wire[27:0]grant_addr;wire[7:0]grant_len;
wire[31:0]wait_cnt_0,wait_cnt_1,wait_cnt_2,wait_cnt_3;
ddr3_arbiter dut(.*);
task check(input integer owner,input[27:0]addr,input[7:0]len,input bit legal);
begin
 @(negedge clk);rst_n=0;arb_en=0;cmd_valid=0;
 @(negedge clk);rst_n=1;arb_en=1;cmd_valid=1<<owner;
 m0_cmd={1'b1,addr,len};m1_cmd=m0_cmd;m2_cmd=m0_cmd;m3_cmd=m0_cmd;
 @(negedge clk);
 if(addr_err[owner]!==!legal)$fatal(1,"region owner=%d addr=%h len=%d",owner,addr,len);
end endtask
initial begin
 check(1,28'h0400000,0,1);check(1,28'h043ffe0,0,1);
 check(1,28'h0440000,0,1);check(1,28'h045ffe0,0,1);
 check(1,28'h0430800,0,1);check(1,28'h0457fe0,0,1);
 check(1,28'h0460000,0,0);check(1,28'h03fffe0,0,0);
 check(1,28'h0400001,0,0);check(1,28'h043ffe0,1,0);
 check(0,28'h0400000,0,0);check(2,28'h0400000,0,0);check(3,28'h0440000,0,0);
 check(1,28'h0200000,15,1);check(1,28'h0230000,0,0);
 check(1,28'h0100000,15,1);check(0,28'h0000000,15,1);
 $display("RESULT: PASS activation regions 17 cases");$finish;
end
endmodule
