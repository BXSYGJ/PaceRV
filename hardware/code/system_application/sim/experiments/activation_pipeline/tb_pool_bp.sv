module tb_pool_bp;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,layer_start=0,y_valid=0,p_ready=0;
reg [7:0] y_u8=0;
wire y_ready,p_valid,p_last; wire [7:0] p_u8;
pool_engine dut(.clk(clk),.rst_n(rst_n),.layer_start(layer_start),
 .cin(16'd32),.w_in(16'd5),.h_in(16'd4),.y_valid(y_valid),.y_ready(y_ready),
 .y_u8(y_u8),.p_ready(p_ready),.p_valid(p_valid),.p_u8(p_u8),.p_last(p_last));
integer cyc=0,n=0,r,g,c,l,ch,rr,cc,gg,ll,ex,v,i,j;
reg stalled=0; reg [8:0] held;
always @(negedge clk) begin
 cyc=cyc+1; p_ready=(cyc%101<19) && (cyc%4!=0);
 if(cyc>20000) $fatal(1,"timeout");
end
always @(posedge clk) begin
 if(stalled && (!p_valid || {p_last,p_u8}!==held)) $fatal(1,"unstable pool output");
 stalled<=p_valid && !p_ready; held<={p_last,p_u8};
 if(dut.fifo_count>8 || dut.reserved>8 || dut.fifo_count>dut.reserved) $fatal(1,"pool overflow");
 if(p_valid && p_ready) begin
  rr=n/64; gg=(n%64)/32; cc=(n%32)/16; ll=n%16;
  ex=0;
  for(i=0;i<2;i=i+1) for(j=0;j<2;j=j+1) begin
   v=((rr*2+i)*41+(cc*2+j)*5+(gg*16+ll)*7)%256;
   if(v>ex) ex=v;
  end
  if(p_u8!==ex[7:0]) $fatal(1,"pool mismatch n=%d got=%d exp=%d",n,p_u8,ex);
  if(p_last!==(n==127)) $fatal(1,"bad last");
  n=n+1;
 end
end
initial begin
 #21; rst_n=1;
 @(negedge clk); layer_start=1;
 @(negedge clk); layer_start=0;
 for(r=0;r<4;r=r+1) for(g=0;g<2;g=g+1)
  for(c=0;c<5;c=c+1) for(l=0;l<16;l=l+1) begin
   y_valid=1; y_u8=(r*41+c*5+(g*16+l)*7)%256;
   @(posedge clk); while(!y_ready) @(posedge clk);
   @(negedge clk); y_valid=0;
  end
 wait(n==128); @(negedge clk);
 $display("RESULT: PASS pool backpressure 128 golden bytes"); $finish;
end
endmodule
