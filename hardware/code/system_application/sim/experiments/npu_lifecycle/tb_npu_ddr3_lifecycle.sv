`timescale 1ns/1ps

module tb_npu_ddr3_lifecycle;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    function [255:0] pattern(input integer a);
        integer j;
        begin
            for (j = 0; j < 32; j = j + 1)
                pattern[j*8 +: 8] = (a+j) ^ ((a+j)>>8) ^ 8'hc3;
        end
    endfunction

    // Normal controller and its bridge.
    reg n_wvalid = 0, n_wready = 1;
    reg [36:0] n_wcmd = 0;
    reg n_av = 0, n_aw = 0, n_wrvalid = 0;
    reg [31:0] n_aaddr = 0;
    reg [255:0] n_wrdata = 0;
    wire n_acmd_ready, n_wrready, n_rvalid, n_wrdvalid, n_done;
    wire [255:0] n_wrdata_o, n_rdata, n_mwdata;
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
        .clk(clk),.rst_n(rst_n),.wgt_cmd_valid(n_wvalid),.wgt_cmd(n_wcmd),
        .wgt_rd_ready(n_wready),.wgt_rd_data(n_wrdata_o),.wgt_rd_valid(n_wrdvalid),
        .wgt_done(n_done),.act_cmd_valid(n_av),.act_cmd_write(n_aw),.act_cmd_addr(n_aaddr),
        .act_cmd_ready(n_acmd_ready),.act_wr_valid(n_wrvalid),.act_wr_data(n_wrdata),
        .act_wr_ready(n_wrready),.act_rd_valid(n_rvalid),.act_rd_data(n_rdata),
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

    ddr3_axi_model #(.MEM_BEATS(65536)) n_model(
        .clk(clk),.rst_n(rst_n),.s_awaddr(n_awaddr),.s_awvalid(n_awvalid),.s_awlen(n_awlen),
        .s_awuser_id(n_awid),.s_awready(n_awready),.s_wdata(n_axi_wdata),.s_wstrb(n_axi_wstrb),
        .s_wready(n_axi_wready),.s_wusero_last(n_wlast),.s_araddr(n_araddr),.s_arvalid(n_arvalid),
        .s_arlen(n_arlen),.s_aruser_id(n_arid),.s_arready(n_arready),.s_rdata(n_axi_rdata),
        .s_rid(n_rid),.s_rlast(n_rlast),.s_rvalid(n_rvalid_axi),.obs_aw_hs(),.obs_ar_hs(),
        .obs_wr_beats(),.obs_rd_beats(),.obs_len0_wr(),.obs_len0_wstrb0(),.obs_len0_wstrb1(),.obs_last_marker());

    // Fault instance: read address never returns, so controller timeout must
    // become bridge failure through cmd_to_err[1].
    reg f_wvalid = 0, f_wready = 1;
    reg [36:0] f_wcmd = {1'b0,28'h100000,8'd0};
    wire f_wrdvalid,f_done,f_mcmdvalid,f_mrdready,f_protocol_error,f_failed;
    wire [255:0] f_wrdata,f_mwdata,f_rd1,f_axi_rdata;
    wire [36:0] f_mcmd;
    wire [3:0] f_cmd_to_err,f_cmd_valid={2'b00,f_mcmdvalid,1'b0},f_rd_ready={2'b00,f_mrdready,1'b0};
    wire [3:0] f_wready_beat,f_done_vec,f_rd_valid_vec;
    wire [27:0] f_awaddr,f_araddr;
    wire f_awap,f_arap,f_awvalid,f_arvalid,f_awready,f_arready;
    wire [3:0] f_awid,f_arid,f_awlen,f_arlen,f_rid;
    wire [255:0] f_axi_wdata;
    wire [31:0] f_axi_wstrb;
    wire f_axi_wready,f_wlast,f_rvalid_axi,f_rlast;
    wire [31:0] f_wc0,f_wc1,f_wc2,f_wc3; wire [3:0] f_addr_err; wire f_to_err; wire [2:0] f_dbg; wire [7:0] f_wmiss;
    npu_m1_bridge f_bridge(
        .clk(clk),.rst_n(rst_n),.wgt_cmd_valid(f_wvalid),.wgt_cmd(f_wcmd),.wgt_rd_ready(f_wready),
        .wgt_rd_data(f_wrdata),.wgt_rd_valid(f_wrdvalid),.wgt_done(f_done),.act_cmd_valid(1'b0),
        .act_cmd_write(1'b0),.act_cmd_addr(32'd0),.act_cmd_ready(),.act_wr_valid(1'b0),.act_wr_data(256'd0),
        .act_wr_ready(),.act_rd_valid(),.act_rd_data(),.m1_cmd_valid(f_mcmdvalid),.m1_cmd(f_mcmd),
        .m1_wdata(f_mwdata),.m1_rd_ready(f_mrdready),.m1_wready(f_wready_beat[1]),.m1_rdata(f_rd1),
        .m1_rvalid(f_rd_valid_vec[1]),.m1_done(f_done_vec[1]),.m1_abort(f_cmd_to_err[1]),
        .protocol_error(f_protocol_error),.transaction_failed(f_failed));
    ddr3_ctrl_axi #(.AXI_TO_LIMIT(8),.P3_QUOTA_TIMEOUT(32)) f_ctrl(
        .clk(clk),.rst_n(rst_n),.cmd_valid(f_cmd_valid),.m0_cmd(37'd0),.m1_cmd(f_mcmd),.m2_cmd(37'd0),.m3_cmd(37'd0),
        .m0_wdata(256'd0),.m1_wdata(f_mwdata),.m2_wdata(256'd0),.m3_wdata(256'd0),.wready_beat(f_wready_beat),.rd_ready(f_rd_ready),
        .rd_data_0(),.rd_data_1(f_rd1),.rd_data_2(),.rd_data_3(),.rd_valid(f_rd_valid_vec),.done(f_done_vec),
        .wait_cnt_0(f_wc0),.wait_cnt_1(f_wc1),.wait_cnt_2(f_wc2),.wait_cnt_3(f_wc3),.addr_err(f_addr_err),.to_err(f_to_err),
        .cmd_to_err(f_cmd_to_err),.dbg_to_state(f_dbg),.wlast_miss_cnt(f_wmiss),.axi_awaddr(f_awaddr),.axi_awuser_ap(f_awap),
        .axi_awuser_id(f_awid),.axi_awlen(f_awlen),.axi_awvalid(f_awvalid),.axi_awready(f_awready),.axi_wdata(f_axi_wdata),
        .axi_wstrb(f_axi_wstrb),.axi_wready(f_axi_wready),.axi_wusero_id(4'd0),.axi_wusero_last(f_wlast),.axi_araddr(f_araddr),
        .axi_aruser_ap(f_arap),.axi_aruser_id(f_arid),.axi_arlen(f_arlen),.axi_arvalid(f_arvalid),.axi_arready(f_arready),
        .axi_rdata(f_axi_rdata),.axi_rid(f_rid),.axi_rlast(f_rlast),.axi_rvalid(f_rvalid_axi));
    ddr3_axi_model #(.AR_NEVER(1),.MEM_BEATS(65536)) f_model(
        .clk(clk),.rst_n(rst_n),.s_awaddr(f_awaddr),.s_awvalid(f_awvalid),.s_awlen(f_awlen),.s_awuser_id(f_awid),.s_awready(f_awready),
        .s_wdata(f_axi_wdata),.s_wstrb(f_axi_wstrb),.s_wready(f_axi_wready),.s_wusero_last(f_wlast),.s_araddr(f_araddr),.s_arvalid(f_arvalid),
        .s_arlen(f_arlen),.s_aruser_id(f_arid),.s_arready(f_arready),.s_rdata(f_axi_rdata),.s_rid(f_rid),.s_rlast(f_rlast),.s_rvalid(f_rvalid_axi),
        .obs_aw_hs(),.obs_ar_hs(),.obs_wr_beats(),.obs_rd_beats(),.obs_len0_wr(),.obs_len0_wstrb0(),.obs_len0_wstrb1(),.obs_last_marker());

    integer i, weight_count, act_wcount, act_rcount, cycles;
    reg [31:0] rng = 32'h7134a55d;
    reg [255:0] saved_act;
    always @(negedge clk) begin
        rng = rng ^ (rng << 13); rng = rng ^ (rng >> 17); rng = rng ^ (rng << 5);
        if (rst_n) n_wready = rng[2] | rng[5];
    end
    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if ((cycles < 60) && (cycles > 24))
                $display("N cyc=%0d av=%b wrv=%b ac_rdy=%b aw=%b bridge=%0d cmdv=%b cmd=%h ctrl=%0d awv=%b awr=%b wready=%b wb=%b act_rdy=%b done=%b", cycles,n_av,n_wrvalid,n_acmd_ready,n_aw,n_bridge.state,n_mcmdvalid,n_mcmd,n_ctrl.state,n_awvalid,n_awready,n_axi_wready,n_wready_beat[1],n_wrready,n_done);
            if (n_wrdvalid && n_wready) begin
                weight_count = weight_count + 1;
                if (n_wrdata_o !== pattern(28'h100000 + (weight_count-1)*32)) $fatal(1,"weight mismatch %0d got=%h exp=%h",weight_count,n_wrdata_o,pattern(28'h100000 + (weight_count-1)*32));
            end
            if (n_rvalid) begin
                if (n_rdata !== saved_act) $fatal(1,"activation readback mismatch got=%h exp=%h",n_rdata,saved_act);
                act_rcount = act_rcount + 1;
            end
            if (cycles > 2000) $fatal(1,"normal lifecycle watchdog weight=%0d ctrl=%0d bridge=%0d cmd=%h fifo=%0d av=%0d wrv=%0d aw=%b done=%b m1w=%h",weight_count,n_ctrl.state,n_bridge.state,n_mcmd,n_ctrl.rd_fifo_count,n_av,n_wrvalid,n_awvalid,n_done_vec,n_mwdata);
        end
    end

    initial begin
        for (i = 0; i < 16; i = i + 1) n_model.mem[16'h8000+i] = pattern(28'h100000 + i*32);
        repeat (5) @(negedge clk); rst_n = 1'b1;
        // Complete a native 16-beat weight read, then issue an activation
        // write. Concurrent request arbitration is covered by the bridge TB.
        @(negedge clk); n_wcmd = {1'b0,28'h100000,8'd15}; n_wvalid = 1'b1;
        wait (n_done); @(negedge clk); n_wvalid = 1'b0;
        wait (n_bridge.state == 3'd0);
        for (i = 0; i < 4; i = i + 1) begin
            @(negedge clk); n_aaddr = 32'h00400000 + i*32; n_aw = 1'b1; n_av = 1'b1;
            wait (n_acmd_ready); @(posedge clk); #1; n_av = 1'b0;
            saved_act = pattern(32'h00500000 + i*32); n_wrdata = saved_act; n_wrvalid = 1'b1;
            wait (n_wrready); @(posedge clk); #1; n_wrvalid = 1'b0; act_wcount = act_wcount + 1;
            wait (n_bridge.state == 3'd0);
            @(negedge clk); n_aw = 1'b0; n_av = 1'b1;
            wait (n_acmd_ready); @(posedge clk); #1; n_av = 1'b0;
            wait (n_rvalid); wait (n_bridge.state == 3'd0);
        end
        if (n_protocol_error || weight_count != 16 || act_wcount != 4 || act_rcount != 4)
            $fatal(1,"normal lifecycle failed weight=%0d aw=%0d ar=%0d protocol=%0d addr_err=%b",weight_count,act_wcount,act_rcount,n_protocol_error,n_addr_err);
        if (n_addr_err != 4'b0000) $fatal(1,"candidate arbiter rejected activation regions: %b",n_addr_err);
        // Fault instance is independent and must explicitly fail.
        @(negedge clk); f_wvalid = 1'b1;
        wait (f_failed); @(negedge clk); f_wvalid = 1'b0;
        if (!f_protocol_error || f_done || f_wrdvalid || f_mcmdvalid)
            $fatal(1,"timeout was not isolated as bridge failure");
        // The arbiter address flag is diagnostic, not a traffic firewall.
        // Feed it into bridge abort and retain the sticky protocol fault so
        // an invalid submitted command can never certify an inference.
        @(negedge clk); n_wcmd = {1'b0,28'h1c0000,8'd0}; n_wvalid = 1'b1;
        wait (n_failed); @(negedge clk); n_wvalid = 1'b0;
        if (!n_addr_err[1] || !n_protocol_error || n_done || n_wrdvalid || n_mcmdvalid)
            $fatal(1,"address diagnostic did not invalidate bridge transaction");
        repeat (4) @(negedge clk);
        if (!n_protocol_error || n_mcmdvalid || n_acmd_ready || n_failed)
            $fatal(1,"address failure did not remain sticky and quiescent");
        $display("RESULT: PASS npu DDR3 lifecycle weight16 activation read/write addr-clean normal traffic, timeout abort and sticky address-error failure");
        $finish;
    end
    initial begin cycles = 0; weight_count = 0; act_wcount = 0; act_rcount = 0; repeat (5000) @(negedge clk); $fatal(1,"global watchdog"); end
endmodule
