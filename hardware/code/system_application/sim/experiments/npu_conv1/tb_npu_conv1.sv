`timescale 1ns/1ps
module tb_npu_conv1;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,start=0;
wire busy,done,timeout_flag,probs_valid,feat_en,cmd_v;
wire [31:0] cycles; wire [14:0] feat_a; wire [36:0] cmd;
wire [7:0] pct; wire [3:0] idx,top1;
reg [7:0] feat_d=0; reg [255:0] rd_data=0;
reg rd_valid=0,rd_done=0;
reg [7:0] weights[0:691039],feat[0:16511];
npu_top dut(.clk(clk),.rst_n(rst_n),.start(start),.busy(busy),.done(done),.npu_cycles(cycles),.timeout_flag(timeout_flag),.feat_rd_addr(feat_a),.feat_rd_en(feat_en),.feat_rd_data(feat_d),.rd_cmd_valid(cmd_v),.rd_cmd(cmd),.rd_ready(1'b1),.rd_data(rd_data),.rd_valid(rd_valid),.rd_done(rd_done),.probs_valid(probs_valid),.probs_pct(pct),.probs_idx(idx),.top1(top1));
always @(posedge clk) if(feat_en) feat_d<=feat[feat_a];
integer st=0,addr=0,left=0,k;
always @(negedge clk) begin
 rd_valid=0; rd_done=0;
 case(st)
 0: if(cmd_v) begin addr=cmd[35:8]; left=cmd[7:0]+1; st=1; end
 1: st=2;
 2: begin
   for(k=0;k<32;k=k+1) rd_data[k*8+:8]=(addr+k<691040)?weights[addr+k]:0;
   rd_valid=1; addr=addr+32; left=left-1;
   if(left==0) begin rd_done=1; st=3; end
 end
 3: if(!cmd_v) st=0;
 endcase
end
integer prev=-1, prob_count=0, tapdbg=0;
always @(posedge clk) if(rst_n) begin
 if(dut.layer!=prev) begin $display("LAYER %0d cycle %0d",dut.layer,cycles); prev=dut.layer; end
 if(cycles!=0 && cycles%1000000==0) $display("PROGRESS %0d layer %0d dma %0d",cycles,dut.layer,dut.u_wdma.state);

 if(timeout_flag) $fatal(1,"timeout layer %0d",dut.layer);
end
initial begin
 $readmemh("build/sim/npu_conv1_assets/weights.hex",weights);
 $readmemh("build/sim/npu_conv1_assets/feat.hex",feat);
 repeat(5) @(negedge clk); rst_n=1;
 repeat(3) @(negedge clk); start=1; @(negedge clk);start=0;
 wait(done); @(negedge clk);
 if(prob_count!=8) $fatal(1,"bad probability count %0d",prob_count);
 $fatal(1,"NPU completed before conv1 output count");
end
initial begin repeat(51000000) @(negedge clk);$fatal(1,"TB watchdog");end
reg [7:0] exp_conv1[0:792575]; integer count_conv1=0;
 initial $readmemh("build/sim/npu_conv1_assets/conv1.hex",exp_conv1);
 always @(posedge clk) if(rst_n && dut.core_y_valid && (dut.layer==0)) begin
 if(count_conv1<792576) begin
 if(dut.core_y_u8 !== exp_conv1[count_conv1]) $fatal(1,"conv1 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_conv1,dut.core_y_u8,exp_conv1[count_conv1],cycles);
 end
 count_conv1=count_conv1+1; if(count_conv1==792576) begin $display("RESULT: PASS conv1 all 792576 outputs golden exact cycles=%0d",cycles); $finish; end
 end
endmodule
