`timescale 1ns/1ps
module tb_npu_pingpong_native;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,start=0;
wire busy,done,timeout_flag,probs_valid,feat_en,cmd_v;
wire [31:0] cycles; wire [14:0] feat_a; wire [36:0] cmd;
wire [7:0] pct; wire [3:0] idx,top1;
reg [7:0] feat_d=0; wire [255:0] rd_data;
wire rd_valid,rd_done;
reg [7:0] weights[0:691039],feat[0:16511];
wire acv,acw,awv;wire [31:0] aca;wire [255:0] awd;
wire acr,awr,arv;wire [255:0] ard;
npu_top dut(.clk(clk),.rst_n(rst_n),.start(start),.busy(busy),.done(done),.npu_cycles(cycles),.timeout_flag(timeout_flag),.feat_rd_addr(feat_a),.feat_rd_en(feat_en),.feat_rd_data(feat_d),.rd_cmd_valid(cmd_v),.rd_cmd(cmd),.rd_ready(1'b1),.rd_data(rd_data),.rd_valid(rd_valid),.rd_done(rd_done),.act_cmd_valid(acv),.act_cmd_write(acw),.act_cmd_addr(aca),.act_cmd_ready(acr),.act_wr_valid(awv),.act_wr_data(awd),.act_wr_ready(awr),.act_rd_valid(arv),.act_rd_data(ard),.probs_valid(probs_valid),.probs_pct(pct),.probs_idx(idx),.top1(top1));
always @(posedge clk) if(feat_en) feat_d<=feat[feat_a];
integer prev=-1, prob_count=0, tapdbg=0;
always @(posedge clk) if(rst_n) begin
 if(dut.layer!=prev) begin $display("LAYER %0d cycle %0d",dut.layer,cycles); prev=dut.layer; end
 if(cycles!=0 && cycles%1000000==0) $display("PROGRESS %0d layer %0d dma %0d",cycles,dut.layer,dut.u_wdma.state);

 if(timeout_flag) $fatal(1,"timeout layer %0d",dut.layer);
end
initial begin
 $readmemh("build/npu_full/weights.hex",weights);
 $readmemh("build/npu_full/feat.hex",feat);
 repeat(5) @(negedge clk); rst_n=1;
 repeat(3) @(negedge clk); start=1; @(negedge clk);start=0;
 wait(done); @(negedge clk);
 if(prob_count!=8) $fatal(1,"bad probability count %0d",prob_count);
 $display("RESULT: PASS full npu_top golden inference cycles=%0d",cycles);$finish;
end
initial begin repeat(51000000) @(negedge clk);$fatal(1,"TB watchdog");end
reg [7:0] exp_conv1[0:792575]; integer count_conv1=0;
 initial $readmemh("build/npu_full/conv1.hex",exp_conv1);
 always @(posedge clk) if(rst_n && dut.core_y_valid && dut.pool_y_ready && (dut.layer==0)) begin
 if(count_conv1<792576) begin
 if(dut.core_y_u8 !== exp_conv1[count_conv1]) $fatal(1,"conv1 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_conv1,dut.core_y_u8,exp_conv1[count_conv1],cycles);
 end
 count_conv1=count_conv1+1; if(count_conv1==792576) begin $display("RESULT: PASS conv1 all 792576 outputs golden exact cycles=%0d",cycles); end
 end
reg [7:0] exp_conv2[0:396287]; integer count_conv2=0;
 initial $readmemh("build/npu_full/conv2.hex",exp_conv2);
 always @(posedge clk) if(rst_n && dut.core_y_valid && dut.pool_y_ready && (dut.layer==2)) begin
 if(count_conv2<396288) begin
 if(dut.core_y_u8 !== exp_conv2[count_conv2]) $fatal(1,"conv2 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_conv2,dut.core_y_u8,exp_conv2[count_conv2],cycles);
 end
 count_conv2=count_conv2+1;
 end
reg [7:0] exp_conv3[0:196607]; integer count_conv3=0;
 initial $readmemh("build/npu_full/conv3.hex",exp_conv3);
 always @(posedge clk) if(rst_n && dut.core_y_valid && dut.pool_y_ready && (dut.layer==4)) begin
 if(count_conv3<196608) begin
 if(dut.core_y_u8 !== exp_conv3[count_conv3]) $fatal(1,"conv3 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_conv3,dut.core_y_u8,exp_conv3[count_conv3],cycles);
 end
 count_conv3=count_conv3+1;
 end
reg [7:0] exp_conv4[0:65535]; integer count_conv4=0;
 initial $readmemh("build/npu_full/conv4.hex",exp_conv4);
 always @(posedge clk) if(rst_n && dut.core_y_valid && dut.pool_y_ready && (dut.layer==6)) begin
 if(count_conv4<65536) begin
 if(dut.core_y_u8 !== exp_conv4[count_conv4]) $fatal(1,"conv4 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_conv4,dut.core_y_u8,exp_conv4[count_conv4],cycles);
 end
 count_conv4=count_conv4+1; if(count_conv4==65536) begin $display("NATIVE_FINAL first=%h last=%h min=%h max=%h Amax=%h Bmax=%h",wfirst,wlast,wmin,wmax,amax,bmax); $display("RESULT: PASS native controller four convs and DDR activation replay golden exact cycles=%0d",cycles); $finish; end
 end
reg [7:0] exp_pool1[0:198143]; integer count_pool1=0;
 initial $readmemh("build/npu_full/pool1.hex",exp_pool1);
 always @(posedge clk) if(rst_n && dut.pool_p_valid && ((dut.pool_sel1 || dut.pool_sel3) ? dut.s0_in_ready : dut.pool_sel2 ? dut.s1_in_ready : 1'b1) && (dut.pool_sel1)) begin
 if(count_pool1<198144) begin
 if(dut.pool_p_u8 !== exp_pool1[count_pool1]) $fatal(1,"pool1 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_pool1,dut.pool_p_u8,exp_pool1[count_pool1],cycles);
 end
 count_pool1=count_pool1+1;
 end
reg [7:0] exp_pool2[0:98303]; integer count_pool2=0;
 initial $readmemh("build/npu_full/pool2.hex",exp_pool2);
 always @(posedge clk) if(rst_n && dut.pool_p_valid && ((dut.pool_sel1 || dut.pool_sel3) ? dut.s0_in_ready : dut.pool_sel2 ? dut.s1_in_ready : 1'b1) && (dut.pool_sel2)) begin
 if(count_pool2<98304) begin
 if(dut.pool_p_u8 !== exp_pool2[count_pool2]) $fatal(1,"pool2 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_pool2,dut.pool_p_u8,exp_pool2[count_pool2],cycles);
 end
 count_pool2=count_pool2+1;
 end
reg [7:0] exp_pool3[0:49151]; integer count_pool3=0;
 initial $readmemh("build/npu_full/pool3.hex",exp_pool3);
 always @(posedge clk) if(rst_n && dut.pool_p_valid && ((dut.pool_sel1 || dut.pool_sel3) ? dut.s0_in_ready : dut.pool_sel2 ? dut.s1_in_ready : 1'b1) && (dut.pool_sel3)) begin
 if(count_pool3<49152) begin
 if(dut.pool_p_u8 !== exp_pool3[count_pool3]) $fatal(1,"pool3 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_pool3,dut.pool_p_u8,exp_pool3[count_pool3],cycles);
 end
 count_pool3=count_pool3+1;
 end
reg [7:0] exp_pool4[0:16383]; integer count_pool4=0;
 initial $readmemh("build/npu_full/pool4.hex",exp_pool4);
 always @(posedge clk) if(rst_n && dut.pool_p_valid && ((dut.pool_sel1 || dut.pool_sel3) ? dut.s0_in_ready : dut.pool_sel2 ? dut.s1_in_ready : 1'b1) && (dut.pool_sel4)) begin
 if(count_pool4<16384) begin
 if(dut.pool_p_u8 !== exp_pool4[count_pool4]) $fatal(1,"pool4 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_pool4,dut.pool_p_u8,exp_pool4[count_pool4],cycles);
 end
 count_pool4=count_pool4+1;
 end
reg [31:0] exp_gap[0:255]; integer count_gap=0;
 initial $readmemh("build/npu_full/gap.hex",exp_gap);
 always @(posedge clk) if(rst_n && dut.gap_we && (1)) begin
 if(count_gap<256) begin
 if(dut.gap_wdata !== exp_gap[count_gap]) $fatal(1,"gap mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_gap,dut.gap_wdata,exp_gap[count_gap],cycles);
 end
 count_gap=count_gap+1;
 end
reg [7:0] exp_fc1[0:127]; integer count_fc1=0;
 initial $readmemh("build/npu_full/fc1.hex",exp_fc1);
 always @(posedge clk) if(rst_n && dut.fc1_y_valid && (1)) begin
 if(count_fc1<128) begin
 if(dut.fc1_y !== exp_fc1[count_fc1]) $fatal(1,"fc1 mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_fc1,dut.fc1_y,exp_fc1[count_fc1],cycles);
 end
 count_fc1=count_fc1+1;
 end
reg [7:0] exp_fc2_logits[0:7]; integer count_fc2_logits=0;
 initial $readmemh("build/npu_full/fc2_logits.hex",exp_fc2_logits);
 always @(posedge clk) if(rst_n && dut.fc2_y_valid && (1)) begin
 if(count_fc2_logits<8) begin
 if(dut.fc2_y !== exp_fc2_logits[count_fc2_logits]) $fatal(1,"fc2_logits mismatch index=%0d got=%0d exp=%0d cycle=%0d",count_fc2_logits,dut.fc2_y,exp_fc2_logits[count_fc2_logits],cycles);
 end
 count_fc2_logits=count_fc2_logits+1;
 end
reg [15:0] exp_probs[0:7];
initial $readmemh("build/npu_full/probs.hex",exp_probs);
always @(posedge clk) if(probs_valid) begin
if(dut.sm_q16!==exp_probs[idx]) $fatal(1,"prob mismatch idx=%0d",idx);
prob_count=prob_count+1;
end
integer replay0=0,replay1=0,rr0,cc0,ch0,ix0,rr1,cc1,ch1,ix1;
always @(posedge clk) if(rst_n) begin
 if(dut.conv2_start || dut.conv4_start) replay0=0;
 if(dut.conv3_start) replay1=0;
 if(dut.s0_out_valid) begin
  if(dut.layer==2) begin
   rr0=replay0/6192;cc0=(replay0%6192)/48;ch0=replay0%48;
   ix0=((rr0*3+ch0/16)*129+cc0)*16+ch0%16;
   if(dut.s0_out_data!==exp_pool1[ix0]) $fatal(1,"pool1 replay mismatch %d",replay0);
  end else if(dut.layer==6) begin
   rr0=replay0/6144;cc0=(replay0%6144)/192;ch0=replay0%192;
   ix0=((rr0*12+ch0/16)*32+cc0)*16+ch0%16;
   if(dut.s0_out_data!==exp_pool3[ix0]) $fatal(1,"pool3 replay mismatch %d",replay0);
  end else $fatal(1,"store0 output in wrong layer");
  replay0=replay0+1;
 end
 if(dut.s1_out_valid) begin
  rr1=replay1/6144;cc1=(replay1%6144)/96;ch1=replay1%96;
  ix1=((rr1*6+ch1/16)*64+cc1)*16+ch1%16;
  if(dut.s1_out_data!==exp_pool2[ix1]) $fatal(1,"pool2 replay mismatch %d",replay1);
  replay1=replay1+1;
 end
 if(dut.s0_cmd_valid && dut.s0_cmd_ready && !dut.s0_cmd_write && dut.s0_replay_row>dut.conv1_ingress_max_row) $fatal(1,"store0 credit");
 if(dut.s1_cmd_valid && dut.s1_cmd_ready && !dut.s1_cmd_write && dut.s1_replay_row>dut.conv1_ingress_max_row) $fatal(1,"store1 credit");
end
wire weight_ready=1'b1;
wire [36:0] native_weight_cmd;wire aligned_valid,aligned_rdvalid,aligned_done;wire[255:0]aligned_data;
weight_read_aligner aligner(.clk(clk),.rst_n(rst_n),.up_valid(cmd_v),.up_cmd(cmd),.up_data(rd_data),.up_rd_valid(rd_valid),.up_done(rd_done),.dn_valid(aligned_valid),.dn_cmd(native_weight_cmd),.dn_data(aligned_data),.dn_rd_valid(aligned_rdvalid),.dn_done(aligned_done));

    wire [255:0] n_mwdata;
    wire n_mcmdvalid, n_mrdready;
    wire [36:0] n_mcmd;
    wire n_protocol_error, n_failed;
    wire [3:0] n_cmd_to_err;
    wire [3:0] n_cmd_valid = {2'b00,n_mcmdvalid,1'b0};
    wire [3:0] n_rd_ready = {2'b00,n_mrdready,1'b0};
    wire [3:0] n_wready_beat, n_done_vec, n_rd_valid_vec;
    wire [255:0] n_rd0, n_rd1, n_rd2, n_rd3;
    wire [31:0] n_wc0,n_wc1,n_wc2,n_wc3;
    wire [3:0] n_addr_err;
    wire n_to_err;
    wire [2:0] n_dbg;
    wire [7:0] n_wmiss;
    wire [27:0] n_awaddr,n_araddr;
    wire n_awap,n_arap,n_awvalid,n_arvalid,n_awready,n_arready;
    wire [3:0] n_awid,n_arid,n_awlen,n_arlen,n_rid;
    wire [255:0] n_axi_wdata,n_axi_rdata;
    wire [31:0] n_axi_wstrb;
    wire n_axi_wready,n_wlast,n_rvalid_axi,n_rlast;

    npu_m1_bridge n_bridge(
        .clk(clk),.rst_n(rst_n),.wgt_cmd_valid(aligned_valid),.wgt_cmd(native_weight_cmd),
        .wgt_rd_ready(weight_ready),.wgt_rd_data(aligned_data),.wgt_rd_valid(aligned_rdvalid),
        .wgt_done(aligned_done),.act_cmd_valid(acv),.act_cmd_write(acw),.act_cmd_addr(aca),
        .act_cmd_ready(acr),.act_wr_valid(awv),.act_wr_data(awd),
        .act_wr_ready(awr),.act_rd_valid(arv),.act_rd_data(ard),
        .m1_cmd_valid(n_mcmdvalid),.m1_cmd(n_mcmd),.m1_wdata(n_mwdata),
        .m1_rd_ready(n_mrdready),.m1_wready(n_wready_beat[1]),.m1_rdata(n_rd1),
        .m1_rvalid(n_rd_valid_vec[1]),.m1_done(n_done_vec[1]),.m1_abort(n_cmd_to_err[1] || n_addr_err[1]),
        .protocol_error(n_protocol_error),.transaction_failed(n_failed));

    ddr3_ctrl_axi #(.AXI_TO_LIMIT(64),.P3_QUOTA_TIMEOUT(32)) n_ctrl(
        .clk(clk),.rst_n(rst_n),.cmd_valid(n_cmd_valid),
        .m0_cmd(37'd0),.m1_cmd(n_mcmd),.m2_cmd(37'd0),.m3_cmd(37'd0),
        .m0_wdata(256'd0),.m1_wdata(n_mwdata),.m2_wdata(256'd0),.m3_wdata(256'd0),
        .wready_beat(n_wready_beat),.rd_ready(n_rd_ready),.rd_data_0(n_rd0),.rd_data_1(n_rd1),
        .rd_data_2(n_rd2),.rd_data_3(n_rd3),.rd_valid(n_rd_valid_vec),.done(n_done_vec),
        .wait_cnt_0(n_wc0),.wait_cnt_1(n_wc1),.wait_cnt_2(n_wc2),.wait_cnt_3(n_wc3),
        .addr_err(n_addr_err),.to_err(n_to_err),.cmd_to_err(n_cmd_to_err),.dbg_to_state(n_dbg),
        .wlast_miss_cnt(n_wmiss),.axi_awaddr(n_awaddr),.axi_awuser_ap(n_awap),.axi_awuser_id(n_awid),
        .axi_awlen(n_awlen),.axi_awvalid(n_awvalid),.axi_awready(n_awready),.axi_wdata(n_axi_wdata),
        .axi_wstrb(n_axi_wstrb),.axi_wready(n_axi_wready),.axi_wusero_id(4'd0),.axi_wusero_last(n_wlast),
        .axi_araddr(n_araddr),.axi_aruser_ap(n_arap),.axi_aruser_id(n_arid),.axi_arlen(n_arlen),
        .axi_arvalid(n_arvalid),.axi_arready(n_arready),.axi_rdata(n_axi_rdata),.axi_rid(n_rid),
        .axi_rlast(n_rlast),.axi_rvalid(n_rvalid_axi));

    ddr3_axi_model_full #(.MEM_BEATS(262144)) n_model(
        .clk(clk),.rst_n(rst_n),.s_awaddr(n_awaddr),.s_awvalid(n_awvalid),.s_awlen(n_awlen),
        .s_awuser_id(n_awid),.s_awready(n_awready),.s_wdata(n_axi_wdata),.s_wstrb(n_axi_wstrb),
        .s_wready(n_axi_wready),.s_wusero_last(n_wlast),.s_araddr(n_araddr),.s_arvalid(n_arvalid),
        .s_arlen(n_arlen),.s_aruser_id(n_arid),.s_arready(n_arready),.s_rdata(n_axi_rdata),
        .s_rid(n_rid),.s_rlast(n_rlast),.s_rvalid(n_rvalid_axi),.obs_aw_hs(),.obs_ar_hs(),
        .obs_wr_beats(),.obs_rd_beats(),.obs_len0_wr(),.obs_len0_wstrb0(),.obs_len0_wstrb1(),.obs_last_marker());


integer preload_i,preload_k;
initial begin
 #1; for(preload_i=0;preload_i<21595;preload_i=preload_i+1) begin
 for(preload_k=0;preload_k<32;preload_k=preload_k+1) n_model.mem[32768+preload_i][preload_k*8+:8]=weights[preload_i*32+preload_k];
 end
end
always @(posedge clk) if(rst_n && (n_protocol_error || n_failed || n_to_err || n_addr_err!=0 || dut.s0_error || dut.s1_error || dut.mux_error)) $fatal(1,"native DDR protocol error bridge=%b timeout=%b address=%b",n_protocol_error,n_to_err,n_addr_err);

integer wfirst=-1,wlast=0,wmin=268435455,wmax=0,amax=0,bmax=0;
always @(posedge clk) if(rst_n)begin
 if(n_mcmdvalid && n_bridge.state==1)begin
 if(wfirst<0)wfirst=n_mcmd[35:8];wlast=n_mcmd[35:8];
 if(n_mcmd[35:8]<wmin)wmin=n_mcmd[35:8];if(n_mcmd[35:8]>wmax)wmax=n_mcmd[35:8];
 if(n_mcmd[35:8]<28'h100000 || n_mcmd[35:8]>=28'h1b8000)$fatal(1,"weight range");end
 if(acv && acr)begin
 if(aca>=32'h440000)begin if(aca>bmax)bmax=aca;end else if(aca>amax)amax=aca;
 if((aca>>5)==(native_weight_cmd[35:8]>>5))$fatal(1,"weight activation alias");end
 if(dut.conv1_start || dut.conv2_start || dut.conv3_start || dut.conv4_start)$display("NATIVE_MAP first=%h last=%h min=%h max=%h Amax=%h Bmax=%h",wfirst,wlast,wmin,wmax,amax,bmax);
end
endmodule
