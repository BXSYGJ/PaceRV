wire owner_valid,owner_ready,owner_n_wready,owner_n_rvalid,owner_n_done,owner_n_abort;
wire owner_idle,owner_error,owner_l_wready,owner_l_rvalid,owner_l_done;
wire [36:0] owner_cmd;
wire [255:0] owner_wdata;
npu_m1_owner owner(.clk(clk),.rst_n(rst_n),.loader_allowed(!busy),
 .l_valid(1'b0),.l_cmd(37'd0),.l_wdata(256'd0),.l_rd_ready(1'b1),
 .l_wready(owner_l_wready),.l_rvalid(owner_l_rvalid),.l_done(owner_l_done),
 .n_valid(n_mcmdvalid),.n_cmd(n_mcmd),.n_wdata(n_mwdata),.n_rd_ready(n_mrdready),
 .n_wready(owner_n_wready),.n_rvalid(owner_n_rvalid),.n_done(owner_n_done),.n_abort(owner_n_abort),
 .m_valid(owner_valid),.m_cmd(owner_cmd),.m_wdata(owner_wdata),.m_rd_ready(owner_ready),
 .m_wready(n_wready_beat[1]),.m_rvalid(n_rd_valid_vec[1]),.m_done(n_done_vec[1]),
 .m_abort(n_cmd_to_err[1] || n_addr_err[1]),.idle(owner_idle),.protocol_error(owner_error));
always @(posedge clk) if(rst_n && owner_error) $fatal(1,"native M1 owner error");
