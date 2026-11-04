`timescale 1ns / 1ps

module hdmi_tx_if #(

    parameter [11:0] V_TOTAL = 12'd1125,
    parameter [11:0] V_FP    = 12'd4,
    parameter [11:0] V_BP    = 12'd36,
    parameter [11:0] V_SYNC  = 12'd5,
    parameter [11:0] V_ACT   = 12'd1080,
    parameter [11:0] H_TOTAL = 12'd2200,
    parameter [11:0] H_FP    = 12'd88,
    parameter [11:0] H_BP    = 12'd148,
    parameter [11:0] H_SYNC  = 12'd44,
    parameter [11:0] H_ACT   = 12'd1920,

    parameter [15:0] RSTN_DELAY_CYCLES   = 16'd10_000,

    parameter [22:0] INIT_TIMEOUT_CYCLES = 23'd5_000_000,

    parameter [15:0] RETRY_HOLD_CYCLES   = 16'd20_000,

    parameter [2:0]  INIT_RETRY_MAX      = 3'd3
) (

    input  wire        clk_27m,

    input  wire        rst_n,

    output wire        pix_clk,
    output wire        rst_pix_n,
    output wire [10:0] pix_x,
    output wire [10:0] pix_y,
    output wire        pix_de,
    output wire        pix_hs,
    output wire        pix_vs,

    input  wire [23:0] rgb_in,
    input  wire        de_in,
    input  wire        hs_in,
    input  wire        vs_in,

    output wire        hdmi_rst_n,
    output wire        vout_clk,
    output wire        vout_de,
    output wire        vout_hs,
    output wire        vout_vs,
    output wire [23:0] vout_data,
    output wire        iic_tx_scl,
    inout  wire        iic_tx_sda,

    output wire        hdmi_init_over,
    output wire        hdmi_init_fail,
    output wire        pll_lock
);

    wire pix_clk_w;
    wire cfg_clk;
    wire pll_lock_w;

    pll u_pll (
        .clkin1  ( clk_27m   ),
        .clkout0 ( pix_clk_w ),
        .clkout1 ( cfg_clk   ),
        .lock    ( pll_lock_w)
    );

    assign pix_clk  = pix_clk_w;
    assign pll_lock = pll_lock_w;

    reg rst_n_meta;
    reg rst_n_cfg;

    always @(posedge cfg_clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_n_meta <= 1'b0;
            rst_n_cfg  <= 1'b0;
        end else begin
            rst_n_meta <= 1'b1;
            rst_n_cfg  <= rst_n_meta;
        end
    end

    reg pll_lock_meta;
    reg pll_lock_cfg;

    always @(posedge cfg_clk) begin
        pll_lock_meta <= pll_lock_w;
        pll_lock_cfg  <= pll_lock_meta;
    end

    reg [15:0] rstn_1ms;

    always @(posedge cfg_clk) begin
        if (!pll_lock_cfg || !rst_n_cfg)
            rstn_1ms <= 16'd0;
        else if (rstn_1ms == RSTN_DELAY_CYCLES)
            rstn_1ms <= rstn_1ms;
        else
            rstn_1ms <= rstn_1ms + 16'd1;
    end

    wire cfg_rstn = (rstn_1ms == RSTN_DELAY_CYCLES);

    assign hdmi_rst_n = cfg_rstn;

    reg [22:0] init_wdt_cnt;
    reg [15:0] retry_hold_cnt;
    reg [2:0]  init_retry_cnt;
    reg        retry_rstn;
    reg        init_fail;
    wire       init_over;

    always @(posedge cfg_clk or negedge cfg_rstn) begin
        if (!cfg_rstn) begin
            init_wdt_cnt   <= 23'd0;
            retry_hold_cnt <= 16'd0;
            init_retry_cnt <= 3'd0;
            retry_rstn     <= 1'b1;
            init_fail      <= 1'b0;
        end else if (!retry_rstn) begin

            if (retry_hold_cnt == RETRY_HOLD_CYCLES - 16'd1) begin
                retry_rstn     <= 1'b1;
                retry_hold_cnt <= 16'd0;
                init_wdt_cnt   <= 23'd0;
            end else begin
                retry_hold_cnt <= retry_hold_cnt + 16'd1;
            end
        end else if (init_over || init_fail) begin

            init_wdt_cnt <= 23'd0;
        end else begin

            if (init_wdt_cnt == INIT_TIMEOUT_CYCLES - 23'd1) begin
                init_wdt_cnt <= 23'd0;
                if (init_retry_cnt == INIT_RETRY_MAX) begin
                    init_fail <= 1'b1;
                end else begin
                    init_retry_cnt <= init_retry_cnt + 3'd1;
                    retry_rstn     <= 1'b0;
                end
            end else begin
                init_wdt_cnt <= init_wdt_cnt + 23'd1;
            end
        end
    end

    wire ms_rstn = cfg_rstn & retry_rstn;
    wire init_over_rx_unused;

    ms72xx_ctl u_ms72xx_ctl (
        .clk         ( cfg_clk   ),
        .rst_n       ( ms_rstn   ),
        .init_over_rx ( init_over_rx_unused ),
        .init_over   ( init_over ),
        .iic_scl     ( iic_tx_scl),
        .iic_sda     ( iic_tx_sda)
    );

    assign hdmi_init_over = init_over;
    assign hdmi_init_fail = init_fail;

    reg rstn_pix_meta;
    reg rstn_pix;

    always @(posedge pix_clk_w) begin
        rstn_pix_meta <= cfg_rstn;
        rstn_pix      <= rstn_pix_meta;
    end

    assign rst_pix_n = rstn_pix;

    wire [11:0] act_x;
    wire [11:0] act_y;
    wire        vg_hs;
    wire        vg_vs;
    wire        vg_de;

    sync_vg #(
        .X_BITS  ( 12      ),
        .Y_BITS  ( 12      ),
        .V_TOTAL ( V_TOTAL ),
        .V_FP    ( V_FP    ),
        .V_BP    ( V_BP    ),
        .V_SYNC  ( V_SYNC  ),
        .V_ACT   ( V_ACT   ),
        .H_TOTAL ( H_TOTAL ),
        .H_FP    ( H_FP    ),
        .H_BP    ( H_BP    ),
        .H_SYNC  ( H_SYNC  ),
        .H_ACT   ( H_ACT   )
    ) u_sync_vg (
        .clk    ( pix_clk_w ),
        .rstn   ( rstn_pix  ),
        .vs_out ( vg_vs     ),
        .hs_out ( vg_hs     ),
        .de_out ( vg_de     ),
        .x_act  ( act_x     ),
        .y_act  ( act_y     )
    );

    assign pix_x  = act_x[10:0];
    assign pix_y  = act_y[10:0];
    assign pix_de = vg_de;
    assign pix_hs = vg_hs;
    assign pix_vs = vg_vs;

    reg [23:0] vout_data_r;
    reg        vout_hs_r;
    reg        vout_vs_r;
    reg        vout_de_r;

    always @(negedge pix_clk_w) begin
        if (!rstn_pix) begin
            vout_data_r <= 24'h00_00_00;
            vout_hs_r   <= 1'b0;
            vout_vs_r   <= 1'b0;
            vout_de_r   <= 1'b0;
        end else begin
            vout_data_r <= rgb_in;
            vout_hs_r   <= hs_in;
            vout_vs_r   <= vs_in;
            vout_de_r   <= de_in;
        end
    end

    assign vout_data = vout_data_r;
    assign vout_hs   = vout_hs_r;
    assign vout_vs   = vout_vs_r;
    assign vout_de   = vout_de_r;
    assign vout_clk  = pix_clk_w;

endmodule
