module tb_pool_store;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,layer_start=0,y_valid=0; wire p_ready;
reg [7:0] y_u8=0;
wire y_ready,p_valid,p_last; wire [7:0] p_u8;
pool_engine dut(.clk(clk),.rst_n(rst_n),.layer_start(layer_start),
 .cin(16'd32),.w_in(16'd5),.h_in(16'd4),.y_valid(y_valid),.y_ready(y_ready),
 .y_u8(y_u8),.p_ready(p_ready),.p_valid(p_valid),.p_u8(p_u8),.p_last(p_last));
integer cyc=0,n=0,r,g,c,l,ch,rr,cc,gg,ll,ex,v,i,j;
reg stalled=0; reg [8:0] held;
always @(negedge clk) begin
 cyc=cyc+1;
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
 @(negedge clk); layer_start=1; store_start=1;
 @(negedge clk); layer_start=0; store_start=0;
 for(r=0;r<4;r=r+1) for(g=0;g<2;g=g+1)
  for(c=0;c<5;c=c+1) for(l=0;l<16;l=l+1) begin
   y_valid=1; y_u8=(r*41+c*5+(g*16+l)*7)%256;
   @(posedge clk); while(!y_ready) @(posedge clk);
   @(negedge clk); y_valid=0;
  end
 wait(store_done); @(negedge clk); read_mode=1; store_start=1;
 @(negedge clk); store_start=0;
 wait(read_count==128); @(negedge clk);
 if(writes!=4 || reads!=4) $fatal(1,"wrong DDR counts");
 $display("RESULT: PASS pool DDR canonical replay 128 golden bytes"); $finish;
end

reg store_start=0,read_mode=0;
wire cmd_valid,cmd_write,wr_valid,store_done,store_error,out_valid;
wire[31:0] cmd_addr; wire[255:0] wr_data; wire[7:0] out_data;
reg cmd_ready=0,wr_ready=0,rd_valid=0,out_ready=0;
reg[255:0] rd_data=0,ddr[0:7];
wire row_done;
activation_row_store #(.WIDTH(2),.CHANNELS(32),.HEIGHT(2)) store(
 .clk(clk),.rst_n(rst_n),.start(store_start),.read_mode(read_mode),.row_credit(1'b1),
 .in_valid(p_valid),.in_data(p_u8),.in_ready(p_ready),
 .cmd_valid(cmd_valid),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_ready(cmd_ready),
 .wr_valid(wr_valid),.wr_data(wr_data),.wr_ready(wr_ready),
 .rd_valid(rd_valid),.rd_data(rd_data),.out_valid(out_valid),.out_data(out_data),
 .out_ready(out_ready),.row_done(row_done),.done(store_done),.protocol_error(store_error));
integer delay_r=-1,addr=0,read_count=0,writes=0,reads=0;
integer er,ec,eh,ei,ej,ev,expected;
reg pending_write=0;
always @(negedge clk) begin
 cmd_ready=(cyc%7==0); wr_ready=(cyc%101<5); out_ready=(cyc%3!=0);
 rd_valid=0;
 if(delay_r==0) begin rd_valid=1;rd_data=ddr[addr/32];delay_r=-1;end
 else if(delay_r>0) delay_r=delay_r-1;
end
always @(posedge clk) begin
 if(cmd_valid&&cmd_ready) begin
  addr=cmd_addr;
  if(cmd_write) pending_write=1;
  else begin delay_r=4;reads=reads+1;end
 end
 if(wr_valid&&wr_ready) begin
  if(!pending_write) $fatal(1,"no write command");
  ddr[addr/32]=wr_data;pending_write=0;writes=writes+1;
 end
 if(store_error) $fatal(1,"R protocol");
 if(out_valid&&out_ready) begin
  er=read_count/64;ec=(read_count%64)/32;eh=read_count%32;expected=0;
  for(ei=0;ei<2;ei=ei+1) for(ej=0;ej<2;ej=ej+1) begin
   ev=((er*2+ei)*41+(ec*2+ej)*5+eh*7)%256;
   if(ev>expected) expected=ev;
  end
  if(out_data!==expected[7:0]) $fatal(1,"canonical DDR mismatch at %d",read_count);
  read_count=read_count+1;
 end
end
endmodule
