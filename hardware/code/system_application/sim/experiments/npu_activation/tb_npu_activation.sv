`timescale 1ns/1ps
module tb_npu_activation;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,start=0;
wire busy,done,timeout_flag,probs_valid,feat_en,cmd_v;
wire [31:0] cycles; wire [14:0] feat_a; wire [36:0] cmd;
wire [7:0] pct; wire [3:0] idx,top1;
reg [7:0] feat_d=0; reg [255:0] rd_data=0;
reg rd_valid=0,rd_done=0;
reg [7:0] weights[0:691039],feat[0:16511];
wire acv,acw,awv;wire [31:0] aca;wire [255:0] awd;
reg acr=0,awr=0,arv=0;reg [255:0] ard=0;
npu_top dut(.clk(clk),.rst_n(rst_n),.start(start),.busy(busy),.done(done),.npu_cycles(cycles),.timeout_flag(timeout_flag),.feat_rd_addr(feat_a),.feat_rd_en(feat_en),.feat_rd_data(feat_d),.rd_cmd_valid(cmd_v),.rd_cmd(cmd),.rd_ready(1'b1),.rd_data(rd_data),.rd_valid(rd_valid),.rd_done(rd_done),.act_cmd_valid(acv),.act_cmd_write(acw),.act_cmd_addr(aca),.act_cmd_ready(acr),.act_wr_valid(awv),.act_wr_data(awd),.act_wr_ready(awr),.act_rd_valid(arv),.act_rd_data(ard),.probs_valid(probs_valid),.probs_pct(pct),.probs_idx(idx),.top1(top1));
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
 $readmemh("build/sim/npu_activation_assets/weights.hex",weights);
 $readmemh("build/sim/npu_activation_assets/feat.hex",feat);
 repeat(5) @(negedge clk); rst_n=1;
 repeat(3) @(negedge clk); start=1; @(negedge clk);start=0;
 wait(done); @(negedge clk);
 if(prob_count!=8) $fatal(1,"bad probability count %0d",prob_count);
 $display("RESULT: PASS full npu_top golden inference cycles=%0d",cycles);$finish;
end
initial begin repeat(51000000) @(negedge clk);$fatal(1,"TB watchdog");end
reg [7:0] exp_conv1[0:792575]; integer count_conv1=0;
 initial $readmemh("build/sim/npu_activation_assets/conv1.hex",exp_conv1);
 always @(posedge clk) if(rst_n && dut.core_y_valid && dut.pool_y_ready && (dut.layer==0)) begin
 if(count_conv1<792576) begin
 if(dut.core_y_u8 !== exp_conv1[count_conv1]) $fatal(1,"conv1 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_conv1,dut.core_y_u8,exp_conv1[count_conv1],cycles);
 end
 count_conv1=count_conv1+1; if(count_conv1==792576) begin $display("RESULT: PASS conv1 all 792576 outputs golden exact cycles=%0d",cycles); end
 end
reg [7:0] exp_conv2[0:396287]; integer count_conv2=0;
 initial $readmemh("build/sim/npu_activation_assets/conv2.hex",exp_conv2);
 always @(posedge clk) if(rst_n && dut.core_y_valid && dut.pool_y_ready && (dut.layer==2)) begin
 if(count_conv2<396288) begin
 if(dut.core_y_u8 !== exp_conv2[count_conv2]) $fatal(1,"conv2 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_conv2,dut.core_y_u8,exp_conv2[count_conv2],cycles);
 end
 count_conv2=count_conv2+1; if(count_conv2==396288) begin $display("RESULT: PASS conv1 pool1 DDR conv2 golden exact cycles=%0d",cycles); $finish; end
 end
reg [7:0] exp_pool1[0:198143]; integer count_pool1=0;
 initial $readmemh("build/sim/npu_activation_assets/pool1.hex",exp_pool1);
 always @(posedge clk) if(rst_n && dut.pool_p_valid && (dut.pool_sel1 ? dut.act_in_ready : 1'b1) && (dut.pool_sel1)) begin
 if(count_pool1<198144) begin
 if(dut.pool_p_u8 !== exp_pool1[count_pool1]) $fatal(1,"pool1 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_pool1,dut.pool_p_u8,exp_pool1[count_pool1],cycles);
 end
 count_pool1=count_pool1+1;
 end
reg [7:0] exp_pool2[0:98303]; integer count_pool2=0;
 initial $readmemh("build/sim/npu_activation_assets/pool2.hex",exp_pool2);
 always @(posedge clk) if(rst_n && dut.pool_p_valid && (dut.pool_sel1 ? dut.act_in_ready : 1'b1) && (dut.pool_sel2)) begin
 if(count_pool2<98304) begin
 if(dut.pool_p_u8 !== exp_pool2[count_pool2]) $fatal(1,"pool2 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_pool2,dut.pool_p_u8,exp_pool2[count_pool2],cycles);
 end
 count_pool2=count_pool2+1;
 end
reg [255:0] act_mem[0:6207];
integer act_addr=0,act_delay=-1,act_cycles=0,act_writes=0,act_reads=0;
reg act_pending=0;
always @(negedge clk) begin
 act_cycles=act_cycles+1;
 acr=(act_cycles%5!=0); awr=(act_cycles%7!=0); arv=0;
 if(act_delay==0) begin ard=act_mem[act_addr];arv=1;act_delay=-1;end
 else if(act_delay>0) act_delay=act_delay-1;
end
always @(posedge clk) if(rst_n) begin
 if(acv && acr) begin
  if(aca<32'h400000 || aca>=32'h430800) $fatal(1,"activation address out of range %h",aca);
  act_addr=(aca-32'h400000)/32;
  if(acw) act_pending=1;
  else begin act_delay=3;act_reads=act_reads+1;end
 end
 if(awv && awr) begin
  if(!act_pending) $fatal(1,"activation write without command");
  act_mem[act_addr]=awd;act_pending=0;act_writes=act_writes+1;
 end
 if(dut.act_error) $fatal(1,"activation protocol error");
end
integer replay_count=0, erow,ecol,echan,egroup,elane,ei;
always @(posedge clk) if(rst_n && dut.act_out_valid) begin
 erow=replay_count/(129*48);ecol=(replay_count%(129*48))/48;echan=replay_count%48;
 egroup=echan/16;elane=echan%16;
 ei=((erow*3+egroup)*129+ecol)*16+elane;
 if(dut.act_out_data!==exp_pool1[ei]) $fatal(1,"canonical replay mismatch idx=%0d row=%0d col=%0d ch=%0d got=%0d exp=%0d",replay_count,erow,ecol,echan,dut.act_out_data,exp_pool1[ei]);
 replay_count=replay_count+1;
end
always @(posedge clk) if(rst_n && acv && acr && !acw) begin
 if(dut.act_replay_row>dut.conv1_ingress_max_row) $fatal(1,"row credit violated actual=%0d limit=%0d",dut.act_replay_row,dut.conv1_ingress_max_row);
end
endmodule
