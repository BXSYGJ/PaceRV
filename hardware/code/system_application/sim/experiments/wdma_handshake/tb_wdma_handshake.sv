`timescale 1ns/1ps
module tb_wdma_handshake;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,start=0;reg [3:0] layer_id=0;
wire rd_cmd_valid,w_valid,grp_start,b_valid,m_valid,s_valid,busy,done;
wire [36:0] rd_cmd;reg [255:0] rd_data=0;
reg rd_valid=0,rd_done=0;wire [127:0] w_data;
reg w_ready=0;wire signed [31:0] bias_s32,m_s32;wire [6:0] shift;
wdma dut(.clk(clk),.rst_n(rst_n),.start(start),.layer_id(layer_id),.rd_cmd_valid(rd_cmd_valid),.rd_cmd(rd_cmd),.rd_ready(1'b1),.rd_data(rd_data),.rd_valid(rd_valid),.rd_done(rd_done),.w_valid(w_valid),.w_data(w_data),.w_ready(w_ready),.grp_advance(1'b1),.grp_start(grp_start),.b_valid(b_valid),.bias_s32(bias_s32),.m_valid(m_valid),.m_s32(m_s32),.s_valid(s_valid),.shift(shift),.busy(busy),.done(done));
reg [7:0] image[0:691039];
integer st=0,addr=0,left=0,k,tap=0,group_no=0,checks=0,hold_cycles=0,base=0,ntaps=0,nbytes=0,ngroups=0,wb=0;
reg [127:0] expected;
reg [31:0] rng=32'h89171ab5;
always @(negedge clk) begin
 rd_valid=0;rd_done=0;
 case(st)
 0:if(rd_cmd_valid)begin addr=rd_cmd[35:8];left=rd_cmd[7:0]+1;st=1;end
 1:st=2;
 2:begin
  for(k=0;k<32;k=k+1)rd_data[k*8+:8]=image[addr+k];
  rd_valid=1;addr=addr+32;left=left-1;
  if(left==0)begin rd_done=1;st=3;end
 end
 3:if(!rd_cmd_valid)st=0;
 endcase
 rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
 if(grp_start)hold_cycles=0;
 if(tap==0 && dut.state==10 && hold_cycles==0)hold_cycles=40;
 if(hold_cycles>0)begin w_ready=0;hold_cycles=(hold_cycles==1)?-1:hold_cycles-1;end
 else w_ready=(rng[2:0]>2);
end
always @(posedge clk)if(rst_n && w_valid && w_ready)begin
 base=wb+(group_no%ngroups)*ntaps*nbytes+tap*nbytes;
 expected=0;
 for(integer j=0;j<nbytes;j=j+1)expected[j*8+:8]=image[base+j];
 if(w_data!==expected)$fatal(1,"weight mismatch layer=%0d group=%0d tap=%0d got=%h exp=%h",layer_id,group_no,tap,w_data,expected);
 checks=checks+1;tap=tap+1;
 if(tap==ntaps)begin tap=0;group_no=group_no+1;end
end
task layer_test(input integer id,input integer g,input integer n,input integer bytes,input integer weightbase,input integer groups_to_check);
begin
 @(negedge clk);rst_n=0;start=0;st=0;tap=0;group_no=0;hold_cycles=0;
 layer_id=id;ngroups=g;ntaps=n;nbytes=bytes;wb=weightbase;
 repeat(3)@(negedge clk);rst_n=1;
 @(negedge clk);start=1;@(negedge clk);start=0;
 wait(group_no>=groups_to_check);
 $display("LAYER PASS %0d groups=%0d checks=%0d",id,group_no,checks);
end endtask
initial begin
 $readmemh("build/sim/wdma_handshake_assets/weights.hex",image);
 layer_test(0,3,9,16,512,7);
 layer_test(1,6,432,16,1376,3);
 layer_test(3,16,1728,16,211328,2);
 layer_test(5,1,128,8,689920,1);
 $display("RESULT: PASS WDMA real image randomized backpressure checks=%0d",checks);$finish;
end
initial begin repeat(200000)@(negedge clk);$fatal(1,"watchdog");end
endmodule
