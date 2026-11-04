module tb_gap_lifecycle;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,early_start=0,late_start=0,y_valid=0;reg[7:0]y_u8=0;
wire[15:0]old_rd,new_rd,old_data,new_data;
wire old_done,new_done,old_we,new_we;wire[7:0]old_addr,new_addr;
gap_unit_original original(.clk(clk),.rst_n(rst_n),.layer_start(late_start),
 .y_valid(y_valid),.y_u8(y_u8),.g_raddr(8'd0),.g_rdata(old_rd),
 .gap_done(old_done),.gap_we(old_we),.gap_waddr(old_addr),.gap_wdata(old_data));
gap_unit fixed(.clk(clk),.rst_n(rst_n),.layer_start(early_start),
 .y_valid(y_valid),.y_u8(y_u8),.g_raddr(8'd0),.g_rdata(new_rd),
 .gap_done(new_done),.gap_we(new_we),.gap_waddr(new_addr),.gap_wdata(new_data));
integer old_count=0,new_count=0,old_dones=0,new_dones=0,frame=0,k;
always @(posedge clk) begin
 if(old_we) begin
  if(old_data!==16'd31)$fatal(1,"original first result mismatch");
  old_count=old_count+1;
 end
 if(new_we) begin
  if(new_data!==(new_count<256 ? 16'd31 : 16'd79))$fatal(1,"fixed GAP mismatch");
  if(new_addr!==8'(new_count%256))$fatal(1,"result channel lifecycle");
  new_count=new_count+1;
 end
 if(old_done)old_dones=old_dones+1;
 if(new_done)new_dones=new_dones+1;
end
initial begin
 #21;rst_n=1;
 for(frame=0;frame<2;frame=frame+1)begin
  @(negedge clk);early_start=1;
  @(negedge clk);early_start=0;
  for(k=0;k<16384;k=k+1)begin
   y_valid=1;y_u8=frame==0 ? 31 : 79;@(negedge clk);
  end
  y_valid=0;late_start=1;
  @(negedge clk);late_start=0;
  repeat(300)@(negedge clk);
 end
 if(old_count!=256||old_dones!=1)$fatal(1,"late-arm counterexample changed");
 if(new_count!=512||new_dones!=2)$fatal(1,"early-arm repeated frames failed");
 $display("RESULT: PASS GAP lifecycle: late-arm loses frame2, early-arm 512 exact results");
 $finish;
end
endmodule
