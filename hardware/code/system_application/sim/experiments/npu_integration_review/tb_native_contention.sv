`timescale 1ns/1ps
module tb_native_contention;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,inject_m1_aw_timeout=0;
reg [3:0] client_valid=0,client_ready=15;
reg [36:0] client_cmd[0:3];
reg [255:0] client_wdata[0:3];
wire [3:0] client_wready,client_rvalid,client_done;
wire [255:0] client_rdata[0:3];
wire owner_idle,owner_error,owner_abort;
// NATIVE_HARDWARE
reg all_pending_seen=0;
integer native_completions[0:3];
integer obs_m;
always @(posedge clk)if(rst_n)begin
 if(n_cmd_valid==4'b1111)all_pending_seen<=1;
 for(obs_m=0;obs_m<4;obs_m=obs_m+1)if(n_done_vec[obs_m])native_completions[obs_m]<=native_completions[obs_m]+1;
 if((n_done_vec & (n_done_vec-4'd1))!=0 || (n_rd_valid_vec & (n_rd_valid_vec-4'd1))!=0 || (n_wready_beat & (n_wready_beat-4'd1))!=0)$fatal(1,"native routing not onehot");
end

task automatic issue(input integer m,input bit wr,input [27:0] addr,input integer len,input [31:0] seed,input bit expect_abort);
 integer wcount,rcount,watch;
 bit done_seen,abort_seen;
 begin
  wcount=0;rcount=0;watch=0;done_seen=0;abort_seen=0;
  @(negedge clk);client_cmd[m]={wr,addr,len[7:0]};client_wdata[m]={8{seed}};client_valid[m]=1;
  while((expect_abort || !(done_seen && (wr || rcount==len+1))) && !abort_seen)begin
   @(posedge clk);
   if(client_wready[m])wcount=wcount+1;
   if(client_rvalid[m] && client_ready[m])begin
    if(client_rdata[m] !== {8{seed+32'(rcount)}})$fatal(1,"read owner/data mismatch m=%0d beat=%0d got=%h seed=%h",m,rcount,client_rdata[m],seed);
    rcount=rcount+1;
   end
   if(client_done[m])done_seen=1;
   if(m==1 && owner_abort)abort_seen=1;
   watch=watch+1;if(watch>4000)$fatal(1,"transaction watchdog m=%0d",m);
   @(negedge clk);
   client_wdata[m]={8{seed+32'(wcount)}};
   if(done_seen || abort_seen)client_valid[m]=0;
  end
  if(expect_abort)begin
   if(!abort_seen)$fatal(1,"missing isolated m1 abort");
  end else if(abort_seen || (wr && wcount!=len+1) || (!wr && rcount!=len+1))$fatal(1,"transaction count m=%0d w=%0d r=%0d",m,wcount,rcount);
  repeat(4)@(negedge clk);
 end
endtask

integer k;
initial begin
 for(k=0;k<4;k=k+1)begin client_cmd[k]=0;client_wdata[k]=0;native_completions[k]=0;end
 repeat(4)@(negedge clk);rst_n=1;
 // Concurrent PCM write, NPU activation write, Mel read and self-test write.
 for(k=0;k<4;k=k+1)n_model.mem[(28'h400>>5)+k]={8{32'h22000000+32'(k)}};
 for(k=0;k<4;k=k+1)n_model.mem[(28'h100000>>5)+k]={8{32'h11000000+32'(k)}};
 fork
  begin issue(0,1,28'h100,3,32'ha0000000,0);issue(0,0,28'h100,3,32'ha0000000,0);end
  begin issue(1,1,28'h400000,0,32'hb0000000,0);issue(1,0,28'h100000,3,32'h11000000,0);issue(1,0,28'h400000,0,32'hb0000000,0);end
  begin issue(2,0,28'h400,3,32'h22000000,0);issue(2,0,28'h100,3,32'ha0000000,0);end
  begin issue(3,1,28'h300000,3,32'hd0000000,0);issue(3,0,28'h300000,3,32'hd0000000,0);end
 join
 if(n_addr_err!=0 || n_cmd_to_err!=0 || owner_error)$fatal(1,"normal contention fault");
 // Starvation override is active (quota 32 cycles) during this traffic.
 // Timeout only m1's AW; other masters must complete and remain clean.
 inject_m1_aw_timeout=1;
 fork
  begin issue(0,1,28'h200,3,32'ha1000000,0);issue(0,0,28'h200,3,32'ha1000000,0);end
  begin issue(1,1,28'h400020,0,32'hb1000000,1);end
  begin issue(2,0,28'h400,3,32'h22000000,0);end
  begin issue(3,1,28'h300100,3,32'hd1000000,0);issue(3,0,28'h300100,3,32'hd1000000,0);end
 join
 if(n_cmd_to_err!==4'b0010 || !owner_error || owner_idle || n_addr_err!=0)$fatal(1,"timeout isolation failed");
 if(n_model.mem[28'h400000>>5] !== {8{32'hb0000000}})$fatal(1,"activation corrupted");
 if(n_model.mem[28'h100000>>5] !== {8{32'h11000000}})$fatal(1,"weights corrupted");
 if(n_model.mem[28'h400020>>5] !== 256'd0)$fatal(1,"timed-out m1 wrote memory");
 if(!all_pending_seen || native_completions[0]!=4 || native_completions[1]!=4 || native_completions[2]!=3 || native_completions[3]!=4)$fatal(1,"contention coverage/counts");
 $display("NATIVE_COMPLETIONS m0=%0d m1=%0d m2=%0d m3=%0d all_pending=%b",native_completions[0],native_completions[1],native_completions[2],native_completions[3],all_pending_seen);
 $display("RESULT: PASS native four-master contention PCM/Mel/NPU-weights-activation/selftest + isolated-m1-AW-timeout");$finish;
end
initial begin #200us;$fatal(1,"global watchdog");end
endmodule
