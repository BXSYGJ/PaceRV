    // Snapshot-only native NPU integration. Owner locks each transaction.
    wire wl_busy;
    wire native_owner_idle,native_owner_error,native_fault;
    wire loader_m1_wready,loader_m1_rvalid,loader_m1_done;
    wire native_m1_valid,native_m1_rd_ready;
    wire [36:0] native_m1_cmd;
    wire [255:0] native_m1_wdata;
    wire bridge_mvalid,bridge_mready,bridge_wready,bridge_rvalid,bridge_done,bridge_abort;
    wire [36:0] bridge_mcmd;
    wire [255:0] bridge_mwdata;
    wire bridge_error,bridge_failed,aligner_error,aligner_failed;
    wire aligned_valid,aligned_rdvalid,aligned_done;
    wire [36:0] aligned_cmd;
    wire [255:0] aligned_data,npu_weight_data;
    wire npu_weight_valid,npu_weight_done;
    wire act_cmd_valid,act_cmd_write,act_cmd_ready,act_wr_valid,act_wr_ready,act_rd_valid;
    wire [31:0] act_cmd_addr;
    wire [255:0] act_wr_data,act_rd_data;
    wire npu_done_raw,npu_timeout_raw,npu_probs_valid_raw;
    assign npu_done_u=npu_done_raw && !native_fault;
    assign npu_timeout_u=npu_timeout_raw || native_fault;
    assign npu_probs_valid_u=npu_probs_valid_raw && !native_fault;
    assign native_fault=native_owner_error || bridge_error || aligner_error || ddr_addr_err[1] || ddr_cmd_to_err[1];
    assign npu_rd_ready_u=1'b1;
    assign ddr_cmd_valid={st_cmd_valid,mel_m2_cmd_valid,native_m1_valid,m0_cmd_valid};
    assign m1_cmd=native_m1_cmd;
    assign m1_wdata=native_m1_wdata;
    weight_read_aligner_hardened u_weight_read_aligner(
        .clk(core_clk),.rst_n(core_clk_rst_n),.up_valid(npu_rd_cmd_valid_u),.up_cmd(npu_rd_cmd_u),
        .up_data(npu_weight_data),.up_rd_valid(npu_weight_valid),.up_done(npu_weight_done),.up_rd_ready(npu_rd_ready_u),
        .dn_valid(aligned_valid),.dn_cmd(aligned_cmd),.dn_data(aligned_data),.dn_rd_valid(aligned_rdvalid),.dn_done(aligned_done),
        .dn_abort(bridge_abort || bridge_failed || ddr_addr_err[1]),.protocol_error(aligner_error),.transaction_failed(aligner_failed));
    npu_m1_bridge u_npu_m1_bridge(
        .clk(core_clk),.rst_n(core_clk_rst_n),.wgt_cmd_valid(aligned_valid),.wgt_cmd(aligned_cmd),.wgt_rd_ready(1'b1),
        .wgt_rd_data(aligned_data),.wgt_rd_valid(aligned_rdvalid),.wgt_done(aligned_done),
        .act_cmd_valid(act_cmd_valid),.act_cmd_write(act_cmd_write),.act_cmd_addr(act_cmd_addr),.act_cmd_ready(act_cmd_ready),
        .act_wr_valid(act_wr_valid),.act_wr_data(act_wr_data),.act_wr_ready(act_wr_ready),.act_rd_valid(act_rd_valid),.act_rd_data(act_rd_data),
        .m1_cmd_valid(bridge_mvalid),.m1_cmd(bridge_mcmd),.m1_wdata(bridge_mwdata),.m1_rd_ready(bridge_mready),
        .m1_wready(bridge_wready),.m1_rdata(rd_data_1),.m1_rvalid(bridge_rvalid),.m1_done(bridge_done),.m1_abort(bridge_abort),
        .protocol_error(bridge_error),.transaction_failed(bridge_failed));
    npu_m1_owner u_npu_m1_owner(
        .clk(core_clk),.rst_n(core_clk_rst_n),.loader_allowed(!npu_busy_u && !npu_start && !native_fault),
        .l_valid(wl_cmd_valid),.l_cmd(wl_cmd),.l_wdata(wl_wdata),.l_rd_ready(wl_rd_ready),
        .l_wready(loader_m1_wready),.l_rvalid(loader_m1_rvalid),.l_done(loader_m1_done),
        .n_valid(bridge_mvalid),.n_cmd(bridge_mcmd),.n_wdata(bridge_mwdata),.n_rd_ready(bridge_mready),
        .n_wready(bridge_wready),.n_rvalid(bridge_rvalid),.n_done(bridge_done),.n_abort(bridge_abort),
        .m_valid(native_m1_valid),.m_cmd(native_m1_cmd),.m_wdata(native_m1_wdata),.m_rd_ready(native_m1_rd_ready),
        .m_wready(ddr_wready_beat[1]),.m_rvalid(ddr_rd_valid[1]),.m_done(ddr_done[1]),.m_abort(ddr_cmd_to_err[1] || ddr_addr_err[1]),
        .idle(native_owner_idle),.protocol_error(native_owner_error));
