`timescale 1ns/1ps
module tb_wbuf_replay;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,grp_start=0,ld_valid=0,rd_ready=0;
reg [15:0] tap_num=0;
reg [127:0] ld_data=0;
wire ld_ready,rd_valid,load_active,load_done;
wire [127:0] rd_data;
wbuf dut(.*);
integer expected=0,tag=0,accepted=0,checks=0;
reg checking=0;
reg [31:0] rng=32'h178456ab;
function [127:0] word(input integer t,input integer i);
word={32'hbabc1234 ^ t,32'h789abcd0 ^ i,32'h45612300 ^ (i*7),32'h13142100 ^ (t*4096+i)};
endfunction
always @(posedge clk) begin
 if(rst_n && load_active && rd_valid)
  $fatal(1,"stale replay valid during load tag=%0d tap_num=%0d",tag,tap_num);
 if(rst_n && checking && rd_valid && rd_ready) begin
  if(rd_data !== word(tag,expected)) $fatal(1,"data mismatch tag=%0d tap_num=%0d accepted=%0d expected=%0d got=%h exp=%h",tag,tap_num,accepted,expected,rd_data,word(tag,expected));
  expected=(expected+1)%tap_num;
  accepted=accepted+1;
  checks=checks+1;
 end
end
task load_group(input integer n,input integer t);
 integer j;
 begin
  @(negedge clk); checking=0; grp_start=1; tap_num=n; rd_ready=1;ld_valid=0;
  #1; if(rd_valid) $fatal(1,"stale replay on grp_start");
  @(negedge clk);grp_start=0;rd_ready=1;
  for(j=0;j<n;j=j+1) begin
   while(!ld_ready) @(negedge clk);
   ld_valid=1;ld_data=word(t,j);
   @(negedge clk);
  end
  ld_valid=0;tag=t;expected=0;accepted=0;checking=1;
 end
endtask
task consume(input integer n,input integer random_stall);
 integer j,target;
 begin
  target=accepted+n;
  while(accepted<target) begin
   @(negedge clk);
   rng=rng ^ (rng<<13);rng=rng ^ (rng>>17);rng=rng ^ (rng<<5);
   rd_ready=random_stall ? (rng[2:0]>2) : 1;
  end
  @(negedge clk);rd_ready=0;
 end
endtask
initial begin
 repeat(4) @(negedge clk);rst_n=1;
 load_group(1,1);consume(40,0);consume(100,1);
 load_group(9,2);consume(100,0);consume(500,1);
 load_group(1728,3);consume(4000,0);consume(6000,1);
 load_group(9,4);consume(25,1);
 load_group(1,5);consume(25,0);
 $display("RESULT: PASS wbuf replay candidate checks=%0d continuous/random stall tap_num=1/9/1728 and group reload",checks);$finish;
end
initial begin repeat(100000) @(negedge clk);$fatal(1,"watchdog");end
endmodule
