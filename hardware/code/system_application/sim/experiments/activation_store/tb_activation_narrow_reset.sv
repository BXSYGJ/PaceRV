module tb_activation_narrow_reset;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,start=0,read_mode=0,row_credit=0,in_valid=0;
reg [1:0] cfg_layer=0;
reg [31:0] cfg_base=0;
reg [7:0] in_data=0;
reg cmd_ready=1,wr_ready=1,rd_valid=0,out_ready=1;
reg [255:0] rd_data=0;
wire [15:0] replay_row;
wire in_ready,cmd_valid,cmd_write,wr_valid,out_valid,row_done,done,protocol_error;
wire [31:0] cmd_addr;
wire [255:0] wr_data;
wire [7:0] out_data;
activation_row_store_narrow dut(.*);
reg [255:0] ddr[0:32767];
integer pending_addr=0,delay_r=-1,latency=2;
reg write_pending=0,checking=0;
integer C=48,W=129,H=32,RB=6192,RS=6208,epoch=0;
integer received=0,writes=0,reads=0,cycle=0;
function automatic [7:0] value(input integer r,x,c);
 value=(epoch*41+r*73+x*19+c*7)%256;
endfunction
always @(negedge clk) begin
 cycle=cycle+1;rd_valid=0;
 if(!rst_n) begin delay_r=-1;write_pending=0;end
 else if(delay_r==0) begin rd_valid=1;rd_data=ddr[pending_addr/32];delay_r=-1;end
 else if(delay_r>0) delay_r=delay_r-1;
 if(cycle>12000000)$fatal(1,"timeout");
end
always @(posedge clk) if(rst_n) begin
 if(cmd_valid && cmd_ready)begin
  if(write_pending || delay_r>=0)$fatal(1,"overlap");
  pending_addr=cmd_addr;
  if(cmd_write)write_pending=1;
  else begin delay_r=latency;reads=reads+1;end
 end
 if(wr_valid && wr_ready)begin
  if(!write_pending)$fatal(1,"write without command");
  ddr[pending_addr/32]=wr_data;write_pending=0;writes=writes+1;
 end
 if(checking && out_valid && out_ready)begin
  if(replay_row!==16'(received/RB))$fatal(1,"stale/wrong row");
  if(out_data!==value(received/RB,(received%RB)/C,received%C))
   $fatal(1,"stale/wrong payload epoch=%0d byte=%0d got=%0d",epoch,received,out_data);
  received=received+1;
 end
 if(protocol_error)$fatal(1,"unexpected response");
end
task automatic launch(input integer mode,input bit reading);
 begin
  case(mode)
   0:begin C=48;W=129;H=32;end
   1:begin C=96;W=64;H=16;end
   2:begin C=192;W=32;H=8;end
  endcase
  RB=C*W;RS=((RB+31)/32)*32;
  @(negedge clk);cfg_layer=mode;cfg_base=mode*262144;read_mode=reading;start=1;
  @(negedge clk);start=0;cfg_layer=3;cfg_base=32'hffffffe1;
 end
endtask
task automatic fill_row(input integer r);
 integer g,x,l;
 begin
  for(g=0;g<C/16;g=g+1)for(x=0;x<W;x=x+1)for(l=0;l<16;l=l+1)begin
   while(!in_ready)@(negedge clk);
   in_valid=1;in_data=value(r,x,g*16+l);
   @(negedge clk);in_valid=0;
  end
 end
endtask
task automatic reset_and_check;
 begin
  // DDR memory persists, but the system also cancels outstanding model traffic.
  @(negedge clk);rst_n=0;start=0;in_valid=0;row_credit=0;checking=0;
  repeat(3)@(negedge clk);
  if(cmd_valid || wr_valid || out_valid || row_done || done || protocol_error || in_ready || replay_row!=0)
   $fatal(1,"outputs/state not reset");
  rst_n=1;cmd_ready=1;wr_ready=1;out_ready=1;latency=2;
  repeat(7)@(negedge clk);
  if(cmd_valid || wr_valid || out_valid || done)$fatal(1,"ghost transaction after reset");
 end
endtask
task automatic fresh_round(input integer mode);
 integer r,before_reads;
 begin
  epoch=epoch+1;writes=0;reads=0;received=0;
  launch(mode,0);
  for(r=0;r<H;r=r+1)fill_row(r);
  wait(done);@(negedge clk);
  if(writes!=H*RS/32)$fatal(1,"fresh write count");
  launch(mode,1);checking=1;
  repeat(9)@(negedge clk);
  if(reads!=0 || out_valid)$fatal(1,"old credit reused after reset");
  row_credit=1;@(negedge clk);row_credit=0;
  wait(row_done);@(negedge clk);before_reads=reads;
  repeat(9)@(negedge clk);
  if(reads!=before_reads || received!=RB)$fatal(1,"single credit leaked into next row");
  row_credit=1;wait(done);@(negedge clk);row_credit=0;checking=0;
  if(received!=H*RB || reads!=H*RS/32)$fatal(1,"fresh replay counts");
 end
endtask
integer phase,r;
initial begin
 #21;rst_n=1;
 for(phase=0;phase<8;phase=phase+1)begin
  if(phase<3)begin
   cmd_ready=(phase==2);wr_ready=0;launch(phase%3,0);
   if(phase==0)begin
    repeat(101)begin in_valid=1;in_data=8'ha5;@(negedge clk);end
    in_valid=0;wait(dut.state==1);
   end else begin fill_row(0);wait(dut.state==(phase==1 ? 2 : 3));end
  end else begin
   cmd_ready=(phase!=4);out_ready=0;latency=(phase==5 ? 40 : 2);
   row_credit=0;launch(phase%3,1);
   if(phase==3)wait(dut.state==4);
   else begin
    row_credit=1;@(negedge clk);row_credit=0;
    case(phase)
     4:wait(dut.state==5);
     5:wait(dut.state==6);
     6:wait(dut.state==8);
     7:wait(dut.state==7);
    endcase
   end
  end
  $display("RESET phase=%0d old_layer=%0d state=%0d",phase,phase%3,dut.state);
  reset_and_check;
  fresh_round((phase+1)%3);
  $display("PASS reset phase=%0d fresh_layer=%0d bytes=%0d writes=%0d reads=%0d",phase,(phase+1)%3,received,writes,reads);
 end
 $display("RESULT: PASS narrow reset FILL/WCMD/WDATA/CREDIT/RCMD/RDATA/PREFETCH/EMIT, new geometry and fresh row credit");
 $finish;
end
endmodule
