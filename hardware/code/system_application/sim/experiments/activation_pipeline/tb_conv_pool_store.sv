module tb_conv_pool_store;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,layer_start=0; wire y_valid,p_ready;
wire [7:0] y_u8;
wire y_ready,p_valid,p_last; wire [7:0] p_u8;
pool_engine dut(.clk(clk),.rst_n(rst_n),.layer_start(layer_start),
 .cin(16'd16),.w_in(16'd6),.h_in(16'd4),.y_valid(y_valid),.y_ready(y_ready),
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
  rr=n/48; cc=(n%48)/16; ll=n%16;
  ex=pool_truth(rr,cc,ll);
  if(p_u8!==ex[7:0]) $fatal(1,"pool mismatch n=%d got=%d exp=%d",n,p_u8,ex);
  if(p_last!==(n==95)) $fatal(1,"bad last");
  n=n+1;
 end
end
initial begin
 #21; rst_n=1;
 @(negedge clk); layer_start=1; store_start=1;
 @(negedge clk); layer_start=0; store_start=0;
 for(r=0;r<4;r=r+1) begin
  while(r>=2 && conv_count<(r-1)*6*16) @(negedge clk);
  for(c=0;c<6;c=c+1) begin
   x_valid=1; x_u8=(r*6+c)%4;
   @(negedge clk); x_valid=0;
  end
 end
 wait(store_done); @(negedge clk); read_mode=1; store_start=1;
 @(negedge clk); store_start=0;
 wait(read_count==96); @(negedge clk);
 if(conv_count!=384 || n!=96 || writes!=4 || reads!=4) $fatal(1,"wrong DDR counts");
 $display("RESULT: PASS conv pool DDR canonical replay 384 conv + 96 pool bytes"); $finish;
end

reg store_start=0,read_mode=0;
wire cmd_valid,cmd_write,wr_valid,store_done,store_error,out_valid;
wire[31:0] cmd_addr; wire[255:0] wr_data; wire[7:0] out_data;
reg cmd_ready=0,wr_ready=0,rd_valid=0,out_ready=0;
reg[255:0] rd_data=0,ddr[0:7];
wire row_done;
activation_row_store #(.WIDTH(3),.CHANNELS(16),.HEIGHT(2)) store(
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
  er=read_count/48;ec=(read_count%48)/16;eh=read_count%16;
  expected=pool_truth(er,ec,eh);
  if(out_data!==expected[7:0]) $fatal(1,"canonical DDR mismatch at %d",read_count);
  read_count=read_count+1;
 end
end

function integer conv_truth(input integer r,input integer c,input integer ch);
 integer dy,dx,ar,ac,total;
 begin
 total=ch;
 for(dy=-1;dy<=1;dy=dy+1) for(dx=-1;dx<=1;dx=dx+1) begin
  ar=r+dy;ac=c+dx;
  if(ar>=0&&ar<4&&ac>=0&&ac<6) total=total+(ar*6+ac)%4;
 end
 conv_truth=total;
 end
endfunction
function integer pool_truth(input integer r,input integer c,input integer ch);
 integer dy,dx,v,m;
 begin
 m=0;
 for(dy=0;dy<2;dy=dy+1) for(dx=0;dx<2;dx=dx+1) begin
  v=conv_truth(r*2+dy,c*2+dx,ch);if(v>m)m=v;
 end
 pool_truth=m;
 end
endfunction
reg x_valid=0;reg[7:0]x_u8=0;
reg grp_start=0,b_valid=0,m_valid=0,s_valid=0;
reg signed[31:0]bias=0;
wire w_ready,conv_done,adv,ud1,ud2,ud3,ua1,ua2,ua3;
conv_engine #(.CIN0(1),.COUT0(16),.H0(4),.W0(6)) conv(
 .clk(clk),.rst_n(rst_n),.cfg_valid(1'b1),.cfg_zp_in(8'd0),.cfg_zp_out(8'd0),
 .conv_sel(2'd0),.start0(layer_start),.start1(1'b0),.start2(1'b0),.start3(1'b0),
 .done0(conv_done),.done1(ud1),.done2(ud2),.done3(ud3),
 .x0_valid(x_valid),.x0_u8(x_u8),.x1_valid(1'b0),.x1_u8(8'd0),
 .x2_valid(1'b0),.x2_u8(8'd0),.x3_valid(1'b0),.x3_u8(8'd0),
 .grp_start(grp_start),.bias_valid(b_valid),.bias_s32(bias),
 .mult_valid(m_valid),.m_s32(32'sd1073741824),.shft_valid(s_valid),.shift(7'd30),
 .w_valid(w_ready),.w_data({16{8'd1}}),.w_ready(w_ready),
 .y_ready(y_ready),.y_valid(y_valid),.y_u8(y_u8),.adv0(adv),.adv1(ua1),.adv2(ua2),.adv3(ua3));
integer conv_count=0,cr,ccol,clane,cv;
always @(posedge clk) if(y_valid&&y_ready) begin
 cr=conv_count/96;ccol=(conv_count%96)/16;clane=conv_count%16;
 cv=conv_truth(cr,ccol,clane);
 if(y_u8!==cv[7:0]) $fatal(1,"conv chain mismatch at %d got=%d exp=%d",conv_count,y_u8,cv);
 conv_count=conv_count+1;
end
task contract_load;
 integer k;
 begin
 @(negedge clk);grp_start=1;
 @(negedge clk);grp_start=0;b_valid=1;
 for(k=0;k<16;k=k+1) begin bias=k;@(negedge clk);end
 b_valid=0;m_valid=1;
 repeat(16)@(negedge clk);
 m_valid=0;s_valid=1;
 repeat(16)@(negedge clk);
 s_valid=0;
 end
endtask
initial begin
 wait(layer_start);@(negedge clk);
 contract_load();contract_load();
 forever begin @(posedge adv); contract_load();end
end

endmodule
