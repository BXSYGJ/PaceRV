`timescale 1ns/1ps
module tb_npu_m1_bridge;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,wgt_cmd_valid=0,wgt_rd_ready=1;
reg [36:0] wgt_cmd=0;
wire [255:0] wgt_rd_data;wire wgt_rd_valid,wgt_done;
reg act_cmd_valid=0,act_cmd_write=0,act_wr_valid=0;
reg [31:0] act_cmd_addr=0;
reg [255:0] act_wr_data=0;
wire act_cmd_ready,act_wr_ready,act_rd_valid;
wire [255:0] act_rd_data;
wire m1_cmd_valid;wire [36:0] m1_cmd;wire [255:0] m1_wdata;
wire m1_rd_ready;reg m1_wready=0,m1_rvalid=0,m1_done=0;
reg [255:0] m1_rdata=0;
wire protocol_error,transaction_failed;
reg m1_abort=0;
npu_m1_bridge dut(.*);
integer native_state=0,beats=0,beat=0,wait_cycles=0,transactions=0,wgt_words=0,act_reads=0,act_writes=0;
integer act_wait=0,wgt_wait=0,same_cycle_reads=0,delayed_done_reads=0,early_done_reads=0;
integer native_writes=0, writes_before_abort=0;
reg early_sent=0;
reg [36:0] native_cmd;
reg [255:0] memory[0:31];
reg [31:0] rng=32'h314ab782;
function [255:0] pattern(input integer a);
 for(integer j=0;j<32;j=j+1)pattern[j*8+:8]=(a+j)^((a+j)>>8)^8'hc3;
endfunction
always @(negedge clk)begin
 m1_wready=0;m1_rvalid=0;m1_done=0;
 rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
 if(!rst_n || m1_abort)native_state=0;
 else case(native_state)
 0:if(m1_cmd_valid)begin
  native_cmd=m1_cmd;beats=m1_cmd[7:0]+1;beat=0;wait_cycles=2+rng[2:0];native_state=1;transactions=transactions+1;early_sent=0;
 end
 1:begin
  if(!early_sent && (!m1_cmd_valid || m1_cmd!==native_cmd))$fatal(1,"native command changed before completion");
  if(wait_cycles>0)wait_cycles=wait_cycles-1;
  else if(native_cmd[36])begin
   if(native_cmd[35:8]<28'h400000 || beats!=1)$fatal(1,"bad activation write command");
   memory[(native_cmd[35:8]-28'h400000)>>5]=m1_wdata;
   native_writes=native_writes+1;
   m1_wready=1;m1_done=1;native_state=2;
  end else if(transactions%3==0 && !early_sent)begin
   m1_done=1;early_sent=1;early_done_reads=early_done_reads+1;wait_cycles=2;
  end else begin
   m1_rdata=native_cmd[35:8]>=28'h400000 ? memory[(native_cmd[35:8]-28'h400000)>>5] : pattern(native_cmd[35:8]+beat*32);
   m1_rvalid=1;beat=beat+1;wait_cycles=rng[1:0];
   if(beat==beats)begin
    if(early_sent)native_state=2;
    else if(transactions%2==0)begin m1_done=1;native_state=2;same_cycle_reads=same_cycle_reads+1;end
    else begin native_state=3;wait_cycles=3;delayed_done_reads=delayed_done_reads+1;end
   end
  end
 end
 2:if(!m1_cmd_valid)native_state=0;
 3:begin
  if(!m1_cmd_valid || m1_cmd!==native_cmd)$fatal(1,"command dropped before delayed done");
  if(wait_cycles>0)wait_cycles=wait_cycles-1;
  else begin m1_done=1;native_state=2;end
 end
 endcase
end
always @(posedge clk)if(rst_n)begin
 if(m1_rvalid && native_cmd[35:8]<28'h400000)begin
  if(!wgt_rd_valid || act_rd_valid)$fatal(1,"weight route failure");
 end
 if(m1_rvalid && native_cmd[35:8]>=28'h400000)begin
  if(!act_rd_valid || wgt_rd_valid)$fatal(1,"activation route failure");
 end
 // act_wr_ready is a level handshake indication, not an acknowledgement;
 // it may remain high while the client prepares its data beat.  The actual
 // transfer is only act_wr_ready && act_wr_valid, so a ready-only cycle is
 // legal and must not be treated as a bridge error.
 if(act_cmd_valid && !act_cmd_ready)act_wait=act_wait+1;else act_wait=0;
 if(wgt_cmd_valid && !wgt_rd_valid && !wgt_done)wgt_wait=wgt_wait+1;else wgt_wait=0;
 if(act_wait>500 || wgt_wait>500)$fatal(1,"client starved actwait=%0d wgtwait=%0d",act_wait,wgt_wait);
end
task weight_client;
 integer t,n,base;
 begin
  for(t=0;t<30;t=t+1)begin
   @(negedge clk);base=28'h100000+t*512;wgt_cmd={1'b0,base[27:0],8'd15};wgt_cmd_valid=1;n=0;
   begin:wait_weight
    forever begin
     @(posedge clk);
     if(wgt_rd_valid)begin
      if(wgt_rd_data!==pattern(base+n*32))$fatal(1,"weight data mismatch t=%0d beat=%0d",t,n);
      n=n+1;wgt_words=wgt_words+1;
     end
     if(wgt_done)begin
      if(n!=16)$fatal(1,"weight truncated");
      disable wait_weight;
     end
    end
   end
   @(negedge clk);wgt_cmd_valid=0;
   repeat(2)@(negedge clk);
  end
 end
endtask
task activation_client;
 integer t;
 begin
  for(t=0;t<20;t=t+1)begin
   @(negedge clk);act_cmd_addr=32'h400000+t*32;act_cmd_write=1;act_cmd_valid=1;
   do @(posedge clk);while(!act_cmd_ready);
   @(negedge clk);act_cmd_valid=0;
   repeat(7)@(negedge clk);
   if(m1_cmd_valid && m1_cmd[36])$fatal(1,"write issued before data is available");
   act_wr_data=pattern(32'h500000+t*32);act_wr_valid=1;
   do @(posedge clk);while(!act_wr_ready);
   act_writes=act_writes+1;
   @(negedge clk);act_wr_valid=0;
   act_cmd_write=0;act_cmd_valid=1;
   do @(posedge clk);while(!act_cmd_ready);
   @(negedge clk);act_cmd_valid=0;
   do @(posedge clk);while(!act_rd_valid);
   if(act_rd_data!==pattern(32'h500000+t*32))$fatal(1,"activation readback mismatch t=%0d",t);
   act_reads=act_reads+1;
  end
 end
endtask
initial begin
 repeat(5)@(negedge clk);rst_n=1;
 fork weight_client;activation_client;join
 repeat(10)@(negedge clk);
 if(protocol_error || transactions!=70 || act_writes!=20 || act_reads!=20 || wgt_words!=480 || same_cycle_reads==0 || delayed_done_reads==0 || early_done_reads==0)$fatal(1,"bad counts or protocol_error tx=%0d",transactions);
 $display("NORMAL PASS native m1 bridge transactions=%0d weight_words=%0d activation_writes=%0d activation_reads=%0d same_done_r=%0d delayed_done_r=%0d early_done_r=%0d",transactions,wgt_words,act_writes,act_reads,same_cycle_reads,delayed_done_reads,early_done_reads);
 @(negedge clk);wgt_cmd={1'b0,28'h100000,8'd15};wgt_cmd_valid=1;
 wait(m1_cmd_valid);
 @(negedge clk);m1_abort=1;m1_done=1;
 @(posedge clk);#1;
 if(!transaction_failed || !protocol_error || wgt_done || m1_cmd_valid)$fatal(1,"abort did not produce explicit failure without success");
 @(negedge clk);m1_abort=0;wgt_cmd_valid=0;
 repeat(4)@(negedge clk);
 if(m1_cmd_valid || !protocol_error || transaction_failed)$fatal(1,"fault did not remain quiescent/sticky");
 $display("READ ABORT PASS explicit failure with sticky quiescent fault");
 // Reset the fault, accept a write into the bridge buffer, then abort before
 // the native controller commits it.  Client acceptance is not DDR success.
 writes_before_abort=native_writes;
 rst_n=0;act_cmd_valid=0;act_wr_valid=0;
 repeat(3)@(negedge clk);rst_n=1;
 @(negedge clk);act_cmd_addr=32'h4003e0;act_cmd_write=1;act_cmd_valid=1;
 do @(posedge clk);while(!act_cmd_ready);
 @(negedge clk);act_cmd_valid=0;act_wr_data=pattern(32'h556677);act_wr_valid=1;
 do @(posedge clk);while(!act_wr_ready);
 #1;
 if(!m1_cmd_valid || m1_wdata!==pattern(32'h556677))$fatal(1,"accepted write not staged for native submission");
 @(negedge clk);act_wr_valid=0;m1_abort=1;
 @(posedge clk);#1;
 if(!transaction_failed || !protocol_error || m1_cmd_valid || act_wr_ready || act_rd_valid)
  $fatal(1,"buffered write abort did not produce explicit sticky fault");
 @(negedge clk);m1_abort=0;act_cmd_valid=1;
 repeat(4)@(negedge clk);
 if(m1_cmd_valid || act_cmd_ready || !protocol_error || transaction_failed)
  $fatal(1,"buffered write fault accepted more work without reset");
 if(native_writes!=writes_before_abort)$fatal(1,"aborted cached write reached DDR commit");
 $display("RESULT: PASS native m1 bridge 70 normal transactions plus read abort and buffered-write abort; cache acceptance is not DDR commit");$finish;
end
initial begin repeat(200000)@(negedge clk);$fatal(1,"watchdog");end
endmodule
