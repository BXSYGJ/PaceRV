`timescale 1ns / 1ps

module ddr3_wrapper (

    input  wire        ref_clk_p,
    input  wire        ref_clk_n,
    input  wire        resetn,

    output wire        core_clk,
    output wire        core_clk_rst_n,
    output wire        ddr_init_done,
    output wire        pll_lock,
    output wire        ddrphy_cpd_lock,

    input  wire [27:0] axi_awaddr,
    input  wire        axi_awuser_ap,
    input  wire [3:0]  axi_awuser_id,
    input  wire [3:0]  axi_awlen,
    input  wire        axi_awvalid,
    output wire        axi_awready,
    input  wire [255:0] axi_wdata,
    input  wire [31:0]  axi_wstrb,
    output wire        axi_wready,
    output wire [3:0]  axi_wusero_id,
    output wire        axi_wusero_last,

    input  wire [27:0] axi_araddr,
    input  wire        axi_aruser_ap,
    input  wire [3:0]  axi_aruser_id,
    input  wire [3:0]  axi_arlen,
    input  wire        axi_arvalid,
    output wire        axi_arready,
    output wire [255:0] axi_rdata,
    output wire [3:0]  axi_rid,
    output wire        axi_rlast,
    output wire        axi_rvalid,

    output wire        mem_cs_n,
    output wire        mem_rst_n,
    output wire        mem_ck,
    output wire        mem_ck_n,
    output wire        mem_cke,
    output wire        mem_ras_n,
    output wire        mem_cas_n,
    output wire        mem_we_n,
    output wire        mem_odt,
    output wire [14:0] mem_a,
    output wire [2:0]  mem_ba,
    inout  wire [3:0]  mem_dqs,
    inout  wire [3:0]  mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [3:0]  mem_dm
);

    wire ref_clk;

    GTP_INBUFDS refclk_inbuf (
        .O  (ref_clk),
        .I  (ref_clk_p),
        .IB (ref_clk_n)
    );

    wire core_clk_rst_n_int;

    ips2l_rst_sync_v1_3 u_core_clk_rst_sync (
        .clk        (core_clk),
        .rst_n      (resetn),
        .sig_async  (1'b1),
        .sig_synced (core_clk_rst_n_int)
    );

    assign core_clk_rst_n = core_clk_rst_n_int;

    ddr3_test I_ips_ddr_top (
        .ref_clk                (ref_clk),
        .resetn                 (resetn),
        .core_clk               (core_clk),
        .pll_lock               (pll_lock),
        .ddrphy_cpd_lock        (ddrphy_cpd_lock),
        .ddr_init_done          (ddr_init_done),

        .axi_awaddr             (axi_awaddr),
        .axi_awuser_ap          (axi_awuser_ap),
        .axi_awuser_id          (axi_awuser_id),
        .axi_awlen              (axi_awlen),
        .axi_awready            (axi_awready),
        .axi_awvalid            (axi_awvalid),

        .axi_wdata              (axi_wdata),
        .axi_wstrb              (axi_wstrb),
        .axi_wready             (axi_wready),
        .axi_wusero_id          (axi_wusero_id),
        .axi_wusero_last        (axi_wusero_last),

        .axi_araddr             (axi_araddr),
        .axi_aruser_ap          (axi_aruser_ap),
        .axi_aruser_id          (axi_aruser_id),
        .axi_arlen              (axi_arlen),
        .axi_arready            (axi_arready),
        .axi_arvalid            (axi_arvalid),

        .axi_rdata              (axi_rdata),
        .axi_rid                (axi_rid),
        .axi_rlast              (axi_rlast),
        .axi_rvalid             (axi_rvalid),

        .apb_clk                (1'b0),
        .apb_rst_n              (1'b0),
        .apb_sel                (1'b0),
        .apb_enable             (1'b0),
        .apb_addr               (8'd0),
        .apb_write              (1'b0),
        .apb_wdata              (16'd0),

        .mem_cs_n               (mem_cs_n),
        .mem_rst_n              (mem_rst_n),
        .mem_ck                 (mem_ck),
        .mem_ck_n               (mem_ck_n),
        .mem_cke                (mem_cke),
        .mem_ras_n              (mem_ras_n),
        .mem_cas_n              (mem_cas_n),
        .mem_we_n               (mem_we_n),
        .mem_odt                (mem_odt),
        .mem_a                  (mem_a),
        .mem_ba                 (mem_ba),
        .mem_dqs                (mem_dqs),
        .mem_dqs_n              (mem_dqs_n),
        .mem_dq                 (mem_dq),
        .mem_dm                 (mem_dm),

        .dbg_gate_start         (1'b0),
        .dbg_cpd_start          (1'b0),
        .dbg_ddrphy_rst_n       (1'b1),
        .dbg_gpll_scan_rst      (1'b0),

        .samp_position_dyn_adj  (1'b0),
        .init_samp_position_even(32'd0),
        .init_samp_position_odd (32'd0),

        .wrcal_position_dyn_adj (1'b0),
        .init_wrcal_position    (32'd0),

        .force_read_clk_ctrl    (1'b0),
        .init_slip_step         (16'd0),
        .init_read_clk_ctrl     (12'd0),

        .debug_cpd_offset_adj   (1'b0),
        .debug_cpd_offset_dir   (1'b0),
        .debug_cpd_offset       (10'd0),

        .ck_dly_en              (1'b1),
        .init_ck_dly_step       (8'd0)

    );

endmodule
