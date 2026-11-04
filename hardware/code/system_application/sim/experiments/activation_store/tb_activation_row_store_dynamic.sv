module tb_activation_row_store_dynamic;
integer C=48,W=129,H=32,RB=6192,RS=6208,mode;
reg[1:0]cfg_layer=0;reg[31:0]cfg_base=0;wire[15:0]replay_row;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,start=0,read_mode=0,row_credit=0,in_valid=0;
reg[7:0] in_data=0; wire in_ready,cmd_valid,cmd_write,wr_valid;
wire[31:0] cmd_addr; wire[255:0] wr_data;
reg cmd_ready=0,wr_ready=0,rd_valid=0,out_ready=0;
reg[255:0] rd_data=0;
wire out_valid,row_done,done,protocol_error; wire[7:0] out_data;
reg[255:0] ddr[0:20000];
integer cycle=0,pending_addr=0,delay_r=-1,received=0,writes=0,reads=0;
reg write_pending=0;
activation_row_store_dynamic dut(.*);
always @(negedge clk) begin
 cycle=cycle+1;
 cmd_ready=(cycle%4!=0); wr_ready=(cycle%5!=0);
 out_ready=(cycle%3!=0); rd_valid=0;
 if(delay_r==0) begin rd_valid=1; rd_data=ddr[pending_addr/32]; delay_r=-1; end
 else if(delay_r>0) delay_r=delay_r-1;
 if(cycle>5000000) $fatal(1,"timeout");
end
always @(posedge clk) begin
 if(cmd_valid && cmd_ready) begin
  if(write_pending || delay_r>=0) $fatal(1,"overlapping transaction");
  pending_addr=cmd_addr;
  if(cmd_write) write_pending=1;
  else begin delay_r=2; reads=reads+1; end
 end
 if(wr_valid && wr_ready) begin
  if(!write_pending) $fatal(1,"write without command");
  ddr[pending_addr/32]=wr_data; write_pending=0; writes=writes+1;
 end
 if(out_valid && out_ready) begin
  if(replay_row!==16'(received/RB)) $fatal(1,"wrong replay row");
  if(out_data!==((received/RB)*73+((received%RB)/C)*19+(received%C)*7)%256)
   $fatal(1,"reorder mismatch at %d got %d",received,out_data);
  received=received+1;
 end
 if(protocol_error) $fatal(1,"unexpected R response");
end
integer row,grp,col,lane;
initial begin
 #21; rst_n=1;
 for(mode=0;mode<3;mode=mode+1) begin
  case(mode)
   0:begin C=48;W=129;H=32;end
   1:begin C=96;W=64;H=16;end
   2:begin C=192;W=32;H=8;end
  endcase
  RB=C*W;RS=((RB+31)/32)*32;
  received=0;writes=0;reads=0;read_mode=0;row_credit=0;
  cfg_layer=mode;cfg_base=mode*262144;
  @(negedge clk); start=1;
  @(negedge clk); start=0;
  // Change live configuration after start: active geometry must stay latched.
  cfg_layer=3;cfg_base=32'hffffffe1;
  for(row=0;row<H;row=row+1)
   for(grp=0;grp<C/16;grp=grp+1)
    for(col=0;col<W;col=col+1)
     for(lane=0;lane<16;lane=lane+1) begin
      while(!in_ready) @(negedge clk);
      in_valid=1;in_data=(row*73+col*19+(grp*16+lane)*7)%256;
      @(negedge clk);in_valid=0;
     end
  wait(done);@(negedge clk);
  cfg_layer=mode;cfg_base=mode*262144;read_mode=1;start=1;
  @(negedge clk);start=0;cfg_layer=3;cfg_base=32'hffffffe1;
  repeat(7)@(negedge clk);
  if(reads!=0)$fatal(1,"read without credit");
  row_credit=1;
  wait(done);@(negedge clk);
  if(received!=H*RB||writes!=H*RS/32||reads!=H*RS/32)$fatal(1,"count mismatch");
  $display("PASS dynamic geometry %d: writes=%d reads=%d bytes=%d",mode,writes,reads,received);
 end
 $display("RESULT: PASS activation dynamic true geometries");
 $finish;
end
endmodule
