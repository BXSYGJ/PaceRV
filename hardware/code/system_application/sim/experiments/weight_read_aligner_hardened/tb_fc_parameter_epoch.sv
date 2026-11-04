`timescale 1ns/1ps
module tb_fc_parameter_epoch;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,layer_start=0,x_valid=0,w_valid=0,b_valid=0,m_valid=0,s_valid=0;
reg signed [15:0] x_s16=0;
reg signed [31:0] bias_s32=0;
wire w_ready,y_valid,done,grp_advance;
wire [7:0] y_u8;
integer frame=0,outputs=0,expected=0,i;
fc_engine #(.CIN(2),.COUT(16)) dut(
 .clk(clk),.rst_n(rst_n),.layer_start(layer_start),.x_valid(x_valid),.x_s16(x_s16),
 .w_valid(w_valid),.w_data({16{8'd1}}),.w_ready(w_ready),
 .b_valid(b_valid),.bias_s32(bias_s32),.m_valid(m_valid),.m_s32(32'sd1073741824),
 .s_valid(s_valid),.shift(7'd30),.y_valid(y_valid),.y_u8(y_u8),.done(done),.grp_advance(grp_advance));
always @(posedge clk) if(rst_n && y_valid) begin
 if(y_u8!==expected[7:0]) $fatal(1,"frame=%0d output=%0d got=%0d expected=%0d",frame,outputs,y_u8,expected);
 outputs=outputs+1;
end
task hold_unready(input integer n);
 integer j;
 begin for(j=0;j<n;j=j+1) begin
  @(negedge clk); if(w_ready) $fatal(1,"stale/incomplete parameters armed MAC frame=%0d",frame);
 end end
endtask
initial begin
 repeat(3) @(negedge clk);rst_n=1;
 for(frame=0;frame<2;frame=frame+1) begin
  outputs=0;expected=13+14*frame;
  x_valid=1;x_s16=1+2*frame;@(negedge clk);
  x_s16=2+2*frame;@(negedge clk);x_valid=0;
  hold_unready(9);
  layer_start=1;@(negedge clk);layer_start=0;
  hold_unready(7);
  bias_s32=10+10*frame;b_valid=1;repeat(16) @(negedge clk);b_valid=0;
  hold_unready(11);
  m_valid=1;repeat(16) @(negedge clk);m_valid=0;
  hold_unready(13);
  s_valid=1;repeat(16) @(negedge clk);s_valid=0;
  wait(w_ready);@(negedge clk);w_valid=1;repeat(2) @(negedge clk);w_valid=0;
  wait(done);@(negedge clk);
  if(outputs!=16) $fatal(1,"output count %0d",outputs);
  hold_unready(6);
 end
 $display("RESULT: PASS repeated FC preloading with delayed independent parameter streams");$finish;
end
initial begin repeat(2000) @(posedge clk);$fatal(1,"timeout");end
endmodule
