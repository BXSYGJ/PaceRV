module tb_activation_row_store;
localparam C=48, W=3, H=2;
localparam RB=C*W, RS=((RB+31)/32)*32;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,start=0,read_mode=0,row_credit=0,in_valid=0;
reg[7:0] in_data=0; wire in_ready,cmd_valid,cmd_write,wr_valid;
wire[31:0] cmd_addr; wire[255:0] wr_data;
reg cmd_ready=0,wr_ready=0,rd_valid=0,out_ready=0;
reg[255:0] rd_data=0;
wire out_valid,row_done,done,protocol_error; wire[7:0] out_data;
reg[255:0] ddr[0:31];
integer cycle=0,pending_addr=0,delay_r=-1,received=0,writes=0,reads=0;
reg write_pending=0;
activation_row_store #(.WIDTH(W),.CHANNELS(C),.HEIGHT(H)) dut(.*);
always @(negedge clk) begin
 cycle=cycle+1;
 cmd_ready=(cycle%4!=0); wr_ready=(cycle%5!=0);
 out_ready=(cycle%3!=0); rd_valid=0;
 if(delay_r==0) begin rd_valid=1; rd_data=ddr[pending_addr/32]; delay_r=-1; end
 else if(delay_r>0) delay_r=delay_r-1;
 if(cycle>10000) $fatal(1,"timeout");
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
  if(out_data!==((received/RB)*73+((received%RB)/C)*19+(received%C)*7)%256)
   $fatal(1,"reorder mismatch at %d got %d",received,out_data);
  received=received+1;
 end
 if(protocol_error) $fatal(1,"unexpected R response");
end
integer row,grp,col,lane;
initial begin
 #21; rst_n=1;
 @(negedge clk); start=1;
 @(negedge clk); start=0;
 for(row=0;row<H;row=row+1)
  for(grp=0;grp<C/16;grp=grp+1)
   for(col=0;col<W;col=col+1)
    for(lane=0;lane<16;lane=lane+1) begin
     while(!in_ready) @(negedge clk);
     in_valid=1; in_data=(row*73+col*19+(grp*16+lane)*7)%256;
     @(negedge clk); in_valid=0;
    end
 wait(done); @(negedge clk); read_mode=1; start=1;
 @(negedge clk); start=0;
 repeat(7) @(negedge clk);
 if(reads!=0) $fatal(1,"read without row credit");
 row_credit=1;
 wait(done); @(negedge clk);
 if(received!=H*RB || writes!=H*RS/32 || reads!=H*RS/32) $fatal(1,"count mismatch");
 $display("PASS activation DDR row reorder: writes=%0d reads=%0d bytes=%0d",writes,reads,received);
 $finish;
end
endmodule
