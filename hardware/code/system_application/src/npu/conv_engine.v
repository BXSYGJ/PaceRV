module conv_engine #(

    parameter CIN0  = 1,
    parameter COUT0 = 48,
    parameter H0    = 64,
    parameter W0    = 258,
    parameter CIN1  = 48,
    parameter COUT1 = 96,
    parameter H1    = 32,
    parameter W1    = 129,
    parameter CIN2  = 96,
    parameter COUT2 = 192,
    parameter H2    = 16,
    parameter W2    = 64,
    parameter CIN3  = 192,
    parameter COUT3 = 256,
    parameter H3    = 8,
    parameter W3    = 32
) (

    input  wire               clk,
    input  wire               rst_n,

    input  wire               cfg_valid,
    input  wire        [7:0]  cfg_zp_in,
    input  wire        [7:0]  cfg_zp_out,

    input  wire        [1:0]  conv_sel,

    input  wire               start0,
    input  wire               start1,
    input  wire               start2,
    input  wire               start3,
    output wire               done0,
    output wire               done1,
    output wire               done2,
    output wire               done3,

    output wire [15:0] x0_ingress_max_row,
    input  wire               x0_valid,
    input  wire        [7:0]  x0_u8,
    input  wire               x1_valid,
    input  wire        [7:0]  x1_u8,
    input  wire               x2_valid,
    input  wire        [7:0]  x2_u8,
    input  wire               x3_valid,
    input  wire        [7:0]  x3_u8,

    input  wire               grp_start,
    input  wire               bias_valid,
    input  wire signed [31:0] bias_s32,
    input  wire               mult_valid,
    input  wire signed [31:0] m_s32,
    input  wire               shft_valid,
    input  wire        [6:0]  shift,

    input  wire               w_valid,
    input  wire        [127:0] w_data,
    output wire               w_ready,

    input wire                y_ready,
    output wire               y_valid,
    output wire        [7:0]  y_u8,

    output wire               adv0,
    output wire               adv1,
    output wire               adv2,
    output wire               adv3
);

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
            if (clog2 == 0)
                clog2 = 1;
        end
    endfunction

    function integer MAXI2;
        input integer a;
        input integer b;
        begin
            MAXI2 = (a > b) ? a : b;
        end
    endfunction

    localparam G0_GRP  = COUT0 / 16;
    localparam G1_GRP  = COUT1 / 16;
    localparam G2_GRP  = COUT2 / 16;
    localparam G3_GRP  = COUT3 / 16;
    localparam G0_TAP  = 9 * CIN0;
    localparam G1_TAP  = 9 * CIN1;
    localparam G2_TAP  = 9 * CIN2;
    localparam G3_TAP  = 9 * CIN3;
    localparam G0_LINE = CIN0 * W0;
    localparam G1_LINE = CIN1 * W1;
    localparam G2_LINE = CIN2 * W2;
    localparam G3_LINE = CIN3 * W3;

    localparam CMAX    = MAXI2(MAXI2(CIN0, CIN1), MAXI2(CIN2, CIN3));
    localparam HMAX    = MAXI2(MAXI2(H0,   H1),   MAXI2(H2,   H3));
    localparam WMAX    = MAXI2(MAXI2(W0,   W1),   MAXI2(W2,   W3));
    localparam TAPMAX  = MAXI2(MAXI2(G0_TAP, G1_TAP), MAXI2(G2_TAP, G3_TAP));
    localparam GRPMAX  = MAXI2(MAXI2(G0_GRP, G1_GRP), MAXI2(G2_GRP, G3_GRP));

    localparam AW0     = clog2(G0_LINE);
    localparam AW1     = clog2(G1_LINE);
    localparam AW2     = clog2(G2_LINE);
    localparam AW3     = clog2(G3_LINE);
    localparam RW      = clog2(WMAX);
    localparam RC      = clog2(CMAX);
    localparam RR      = clog2(HMAX + 1);
    localparam RT      = clog2(TAPMAX + 3);
    localparam RG      = clog2(GRPMAX);

    localparam [15:0] W0V = W0;
    localparam [15:0] W1V = W1;
    localparam [15:0] W2V = W2;
    localparam [15:0] W3V = W3;
    localparam [RT-1:0] TAP0V = G0_TAP;
    localparam [RT-1:0] TAP1V = G1_TAP;
    localparam [RT-1:0] TAP2V = G2_TAP;
    localparam [RT-1:0] TAP3V = G3_TAP;
    localparam [RG-1:0] GRPL0 = G0_GRP - 1;
    localparam [RG-1:0] GRPL1 = G1_GRP - 1;
    localparam [RG-1:0] GRPL2 = G2_GRP - 1;
    localparam [RG-1:0] GRPL3 = G3_GRP - 1;

    reg [7:0] zp_in_reg;
    reg [7:0] zp_out_reg;

    localparam PH_LOAD = 2'd0;
    localparam PH_SCAN = 2'd1;
    localparam PH_SNAP = 2'd2;

    reg  [1:0]        sel;
    reg               run_reg;
    assign x0_ingress_max_row = out_row_cnt + 16'd1;
    reg [RR-1:0]      out_row_cnt;
    reg [RG-1:0]      grp_cnt;
    reg [RW-1:0]      out_col_cnt;
    reg [RT-1:0]      tap_cnt;
    reg [RT-1:0]      mac_cnt;
    reg [1:0]         phase_reg;
    reg [1:0]         rd_bank_base;
    reg [1:0]         dy_cnt;
    reg [1:0]         dx_cnt;
    reg [RC-1:0]      cin_cnt;

    wire       any_start  = start0 | start1 | start2 | start3;

    wire [15:0] s_h      = (sel == 2'd0) ? H0 : (sel == 2'd1) ? H1 :
                           (sel == 2'd2) ? H2 : H3;
    wire [15:0] s_w      = (sel == 2'd0) ? W0 : (sel == 2'd1) ? W1 :
                           (sel == 2'd2) ? W2 : W3;
    wire [RT-1:0] s_tap_last = (sel == 2'd0) ? TAP0V : (sel == 2'd1) ? TAP1V :
                               (sel == 2'd2) ? TAP2V : TAP3V;
    wire [RG-1:0] s_grp_last = (sel == 2'd0) ? GRPL0 : (sel == 2'd1) ? GRPL1 :
                               (sel == 2'd2) ? GRPL2 : GRPL3;

    reg [7:0] g0_bank0 [0:G0_LINE-1];
    reg [7:0] g0_bank1 [0:G0_LINE-1];
    reg [7:0] g0_bank2 [0:G0_LINE-1];
    reg [7:0] g1_bank0 [0:G1_LINE-1];
    reg [7:0] g1_bank1 [0:G1_LINE-1];
    reg [7:0] g1_bank2 [0:G1_LINE-1];
    reg [7:0] g2_bank0 [0:G2_LINE-1];
    reg [7:0] g2_bank1 [0:G2_LINE-1];
    reg [7:0] g2_bank2 [0:G2_LINE-1];
    reg [7:0] g3_bank0 [0:G3_LINE-1];
    reg [7:0] g3_bank1 [0:G3_LINE-1];
    reg [7:0] g3_bank2 [0:G3_LINE-1];

    reg [7:0] g0_dout0, g0_dout1, g0_dout2;
    reg [7:0] g1_dout0, g1_dout1, g1_dout2;
    reg [7:0] g2_dout0, g2_dout1, g2_dout2;
    reg [7:0] g3_dout0, g3_dout1, g3_dout2;

    reg [1:0]        g0_wr_bank;
    reg [RR-1:0]     g0_row;
    reg [RC-1:0]     g0_ch;
    reg [RW-1:0]     g0_col;
    reg [HMAX-1:0]   g0_row_done;

    reg [1:0]        g1_wr_bank;
    reg [RR-1:0]     g1_row;
    reg [RC-1:0]     g1_ch;
    reg [RW-1:0]     g1_col;
    reg [HMAX-1:0]   g1_row_done;

    reg [1:0]        g2_wr_bank;
    reg [RR-1:0]     g2_row;
    reg [RC-1:0]     g2_ch;
    reg [RW-1:0]     g2_col;
    reg [HMAX-1:0]   g2_row_done;

    reg [1:0]        g3_wr_bank;
    reg [RR-1:0]     g3_row;
    reg [RC-1:0]     g3_ch;
    reg [RW-1:0]     g3_col;
    reg [HMAX-1:0]   g3_row_done;

    reg signed [31:0] bias_act [0:15];
    reg signed [31:0] bias_shd [0:15];
    reg signed [31:0] m_act     [0:15];
    reg signed [31:0] m_shd     [0:15];
    reg        [6:0]  shft_act  [0:15];
    reg        [6:0]  shft_shd  [0:15];
    reg        [5:0]  cload_cnt;

    reg          rd_pad_q;
    reg [1:0]    rd_bank_q;
    reg [127:0]  w_data_q;
    reg          w_vld_q;

    reg               grp_arm;
    reg               shadow_rdy;

    reg [5:0]         fin_cnt;
    reg               fin_latched;
    reg               done_q;
    reg               advance_q;

    reg signed [31:0] acc_a [0:15];
    reg signed [31:0] acc_b [0:15];
    reg               acc_sel;
    reg signed [31:0] acc_snap [0:15];

    reg signed [31:0] m_drn    [0:15];
    reg        [6:0]  shft_drn [0:15];
    reg [4:0]   rhe_busy_cnt;
    reg [3:0]   rhe_ch;

    wire signed [31:0] rq_acc_s32;
    wire signed [31:0] rq_m_s32;
    wire        [6:0]  rq_shift;
    wire        [7:0]  rq_zp_out;
    wire               rq_in_valid;
    wire        [7:0]  rq_y_u8;
    wire               rq_y_valid;

    requant_unit u_requant (
        .clk       (clk),
        .rst_n     (rst_n),
        .acc_s32   (rq_acc_s32),
        .m_s32     (rq_m_s32),
        .shift     (rq_shift),
        .zp_out    (rq_zp_out),
        .in_valid  (rq_in_valid),
        .y_u8      (rq_y_u8),
        .out_valid (rq_y_valid)
    );

    function [1:0] add3;
        input [1:0] a;
        input [1:0] b;
        reg [2:0] s;
        begin
            s = {1'b0, a} + {1'b0, b};
            add3 = (s >= 3'd3) ? (s - 3'd3) : s[1:0];
        end
    endfunction

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            zp_in_reg  <= 8'd0;
            zp_out_reg <= 8'd0;
        end else if (cfg_valid) begin
            zp_in_reg  <= cfg_zp_in;
            zp_out_reg <= cfg_zp_out;
        end
    end

    wire g0_wr_en = x0_valid && (g0_row != H0);
    wire g1_wr_en = x1_valid && (g1_row != H1);
    wire g2_wr_en = x2_valid && (g2_row != H2);
    wire g3_wr_en = x3_valid && (g3_row != H3);

    wire [15:0] g0_wr_off = {{(16-RC){1'b0}}, g0_ch} * W0V;
    wire [15:0] g1_wr_off = {{(16-RC){1'b0}}, g1_ch} * W1V;
    wire [15:0] g2_wr_off = {{(16-RC){1'b0}}, g2_ch} * W2V;
    wire [15:0] g3_wr_off = {{(16-RC){1'b0}}, g3_ch} * W3V;
    wire [15:0] g0_wr_sum = g0_wr_off + {{(16-RW){1'b0}}, g0_col};
    wire [15:0] g1_wr_sum = g1_wr_off + {{(16-RW){1'b0}}, g1_col};
    wire [15:0] g2_wr_sum = g2_wr_off + {{(16-RW){1'b0}}, g2_col};
    wire [15:0] g3_wr_sum = g3_wr_off + {{(16-RW){1'b0}}, g3_col};
    wire [AW0-1:0] g0_wr_addr = g0_wr_sum[AW0-1:0];
    wire [AW1-1:0] g1_wr_addr = g1_wr_sum[AW1-1:0];
    wire [AW2-1:0] g2_wr_addr = g2_wr_sum[AW2-1:0];
    wire [AW3-1:0] g3_wr_addr = g3_wr_sum[AW3-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g0_row      <= {RR{1'b0}};
            g0_ch       <= {RC{1'b0}};
            g0_col      <= {RW{1'b0}};
            g0_wr_bank  <= 2'd0;
            g0_row_done <= {HMAX{1'b0}};
        end else if (start0) begin
            g0_row      <= {RR{1'b0}};
            g0_ch       <= {RC{1'b0}};
            g0_col      <= {RW{1'b0}};
            g0_wr_bank  <= 2'd0;
            g0_row_done <= {HMAX{1'b0}};
        end else if (g0_wr_en) begin
            if ((g0_ch == CIN0 - 1) && (g0_col == W0 - 1)) begin
                g0_row_done[g0_row & (H0 - 1)] <= 1'b1;
                g0_row     <= g0_row + 1'b1;
                g0_ch      <= {RC{1'b0}};
                g0_col     <= {RW{1'b0}};
                g0_wr_bank <= (g0_wr_bank == 2'd2) ? 2'd0 : g0_wr_bank + 2'd1;
            end else if (g0_ch == CIN0 - 1) begin
                g0_ch  <= {RC{1'b0}};
                g0_col <= g0_col + 1'b1;
            end else begin
                g0_ch <= g0_ch + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g1_row      <= {RR{1'b0}};
            g1_ch       <= {RC{1'b0}};
            g1_col      <= {RW{1'b0}};
            g1_wr_bank  <= 2'd0;
            g1_row_done <= {HMAX{1'b0}};
        end else if (start1) begin
            g1_row      <= {RR{1'b0}};
            g1_ch       <= {RC{1'b0}};
            g1_col      <= {RW{1'b0}};
            g1_wr_bank  <= 2'd0;
            g1_row_done <= {HMAX{1'b0}};
        end else if (g1_wr_en) begin
            if ((g1_ch == CIN1 - 1) && (g1_col == W1 - 1)) begin
                g1_row_done[g1_row & (H1 - 1)] <= 1'b1;
                g1_row     <= g1_row + 1'b1;
                g1_ch      <= {RC{1'b0}};
                g1_col     <= {RW{1'b0}};
                g1_wr_bank <= (g1_wr_bank == 2'd2) ? 2'd0 : g1_wr_bank + 2'd1;
            end else if (g1_ch == CIN1 - 1) begin
                g1_ch  <= {RC{1'b0}};
                g1_col <= g1_col + 1'b1;
            end else begin
                g1_ch <= g1_ch + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g2_row      <= {RR{1'b0}};
            g2_ch       <= {RC{1'b0}};
            g2_col      <= {RW{1'b0}};
            g2_wr_bank  <= 2'd0;
            g2_row_done <= {HMAX{1'b0}};
        end else if (start2) begin
            g2_row      <= {RR{1'b0}};
            g2_ch       <= {RC{1'b0}};
            g2_col      <= {RW{1'b0}};
            g2_wr_bank  <= 2'd0;
            g2_row_done <= {HMAX{1'b0}};
        end else if (g2_wr_en) begin
            if ((g2_ch == CIN2 - 1) && (g2_col == W2 - 1)) begin
                g2_row_done[g2_row & (H2 - 1)] <= 1'b1;
                g2_row     <= g2_row + 1'b1;
                g2_ch      <= {RC{1'b0}};
                g2_col     <= {RW{1'b0}};
                g2_wr_bank <= (g2_wr_bank == 2'd2) ? 2'd0 : g2_wr_bank + 2'd1;
            end else if (g2_ch == CIN2 - 1) begin
                g2_ch  <= {RC{1'b0}};
                g2_col <= g2_col + 1'b1;
            end else begin
                g2_ch <= g2_ch + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g3_row      <= {RR{1'b0}};
            g3_ch       <= {RC{1'b0}};
            g3_col      <= {RW{1'b0}};
            g3_wr_bank  <= 2'd0;
            g3_row_done <= {HMAX{1'b0}};
        end else if (start3) begin
            g3_row      <= {RR{1'b0}};
            g3_ch       <= {RC{1'b0}};
            g3_col      <= {RW{1'b0}};
            g3_wr_bank  <= 2'd0;
            g3_row_done <= {HMAX{1'b0}};
        end else if (g3_wr_en) begin
            if ((g3_ch == CIN3 - 1) && (g3_col == W3 - 1)) begin
                g3_row_done[g3_row & (H3 - 1)] <= 1'b1;
                g3_row     <= g3_row + 1'b1;
                g3_ch      <= {RC{1'b0}};
                g3_col     <= {RW{1'b0}};
                g3_wr_bank <= (g3_wr_bank == 2'd2) ? 2'd0 : g3_wr_bank + 2'd1;
            end else if (g3_ch == CIN3 - 1) begin
                g3_ch  <= {RC{1'b0}};
                g3_col <= g3_col + 1'b1;
            end else begin
                g3_ch <= g3_ch + 1'b1;
            end
        end
    end

    wire [RW+1:0] col_u   = {2'b00, out_col_cnt} + {{RW{1'b0}}, dx_cnt};
    wire          col_pad = (col_u == {(RW+2){1'b0}}) || (col_u > s_w);
    wire [RR+1:0] wy_u    = {2'b00, out_row_cnt} + {{RR{1'b0}}, dy_cnt};
    wire          wy_pad  = (wy_u == {(RR+2){1'b0}}) || (wy_u > s_h);
    wire          rd_pad_c  = wy_pad || col_pad;
    wire [1:0]    rd_bank_c = add3(rd_bank_base, dy_cnt);

    wire [RW-1:0] rd_col_off = col_u[RW-1:0] - 1'b1;

    wire [15:0] g0_rd_off = {{(16-RC){1'b0}}, cin_cnt} * W0V;
    wire [15:0] g1_rd_off = {{(16-RC){1'b0}}, cin_cnt} * W1V;
    wire [15:0] g2_rd_off = {{(16-RC){1'b0}}, cin_cnt} * W2V;
    wire [15:0] g3_rd_off = {{(16-RC){1'b0}}, cin_cnt} * W3V;
    wire [15:0] s_rd_off = (sel == 2'd0) ? g0_rd_off : (sel == 2'd1) ? g1_rd_off :
                           (sel == 2'd2) ? g2_rd_off : g3_rd_off;
    wire [15:0] s_rd_sum = s_rd_off + {{(16-RW){1'b0}}, rd_col_off};
    wire [AW0-1:0] g0_rd_addr = (rd_pad_c || (sel != 2'd0)) ? {AW0{1'b0}} : s_rd_sum[AW0-1:0];
    wire [AW1-1:0] g1_rd_addr = (rd_pad_c || (sel != 2'd1)) ? {AW1{1'b0}} : s_rd_sum[AW1-1:0];
    wire [AW2-1:0] g2_rd_addr = (rd_pad_c || (sel != 2'd2)) ? {AW2{1'b0}} : s_rd_sum[AW2-1:0];
    wire [AW3-1:0] g3_rd_addr = (rd_pad_c || (sel != 2'd3)) ? {AW3{1'b0}} : s_rd_sum[AW3-1:0];

    always @(posedge clk) begin
        if (g0_wr_en && (g0_wr_bank == 2'd0))
            g0_bank0[g0_wr_addr] <= x0_u8;
        g0_dout0 <= g0_bank0[g0_rd_addr];
    end
    always @(posedge clk) begin
        if (g0_wr_en && (g0_wr_bank == 2'd1))
            g0_bank1[g0_wr_addr] <= x0_u8;
        g0_dout1 <= g0_bank1[g0_rd_addr];
    end
    always @(posedge clk) begin
        if (g0_wr_en && (g0_wr_bank == 2'd2))
            g0_bank2[g0_wr_addr] <= x0_u8;
        g0_dout2 <= g0_bank2[g0_rd_addr];
    end
    always @(posedge clk) begin
        if (g1_wr_en && (g1_wr_bank == 2'd0))
            g1_bank0[g1_wr_addr] <= x1_u8;
        g1_dout0 <= g1_bank0[g1_rd_addr];
    end
    always @(posedge clk) begin
        if (g1_wr_en && (g1_wr_bank == 2'd1))
            g1_bank1[g1_wr_addr] <= x1_u8;
        g1_dout1 <= g1_bank1[g1_rd_addr];
    end
    always @(posedge clk) begin
        if (g1_wr_en && (g1_wr_bank == 2'd2))
            g1_bank2[g1_wr_addr] <= x1_u8;
        g1_dout2 <= g1_bank2[g1_rd_addr];
    end
    always @(posedge clk) begin
        if (g2_wr_en && (g2_wr_bank == 2'd0))
            g2_bank0[g2_wr_addr] <= x2_u8;
        g2_dout0 <= g2_bank0[g2_rd_addr];
    end
    always @(posedge clk) begin
        if (g2_wr_en && (g2_wr_bank == 2'd1))
            g2_bank1[g2_wr_addr] <= x2_u8;
        g2_dout1 <= g2_bank1[g2_rd_addr];
    end
    always @(posedge clk) begin
        if (g2_wr_en && (g2_wr_bank == 2'd2))
            g2_bank2[g2_wr_addr] <= x2_u8;
        g2_dout2 <= g2_bank2[g2_rd_addr];
    end
    always @(posedge clk) begin
        if (g3_wr_en && (g3_wr_bank == 2'd0))
            g3_bank0[g3_wr_addr] <= x3_u8;
        g3_dout0 <= g3_bank0[g3_rd_addr];
    end
    always @(posedge clk) begin
        if (g3_wr_en && (g3_wr_bank == 2'd1))
            g3_bank1[g3_wr_addr] <= x3_u8;
        g3_dout1 <= g3_bank1[g3_rd_addr];
    end
    always @(posedge clk) begin
        if (g3_wr_en && (g3_wr_bank == 2'd2))
            g3_bank2[g3_wr_addr] <= x3_u8;
        g3_dout2 <= g3_bank2[g3_rd_addr];
    end

    wire advance_now;

    wire [3:0] cload_idx = cload_cnt[3:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cload_cnt <= 6'd0;
            grp_arm   <= 1'b0;
            shadow_rdy <= 1'b0;
            for (i = 0; i < 16; i = i + 1) begin
                bias_act[i] <= 32'sd0;
                bias_shd[i] <= 32'sd0;
                m_act[i]    <= 32'sd0;
                m_shd[i]    <= 32'sd0;
                shft_act[i] <= 7'd0;
                shft_shd[i] <= 7'd0;
            end
        end else if (any_start) begin
            cload_cnt  <= 6'd0;
            grp_arm    <= 1'b0;
            shadow_rdy <= 1'b0;
        end else begin
            if (bias_valid) begin
                if (!grp_arm) bias_act[cload_idx] <= bias_s32;
                else          bias_shd[cload_idx] <= bias_s32;
            end
            if (mult_valid) begin
                if (!grp_arm) m_act[cload_idx] <= m_s32;
                else          m_shd[cload_idx] <= m_s32;
            end
            if (shft_valid) begin
                if (!grp_arm) shft_act[cload_idx] <= shift;
                else          shft_shd[cload_idx] <= shift;
            end
            if (grp_start) begin
                cload_cnt <= 6'd0;
            end else if (bias_valid || mult_valid || shft_valid) begin
                if (cload_cnt == 6'd47) begin
                    cload_cnt <= 6'd0;
                    if (!grp_arm) grp_arm     <= 1'b1;
                    else          shadow_rdy  <= 1'b1;
                end else begin
                    cload_cnt <= cload_cnt + 6'd1;
                end
            end
            if (advance_now) begin
                shadow_rdy <= 1'b0;
                for (i = 0; i < 16; i = i + 1) begin
                    bias_act[i] <= bias_shd[i];
                    m_act[i]    <= m_shd[i];
                    shft_act[i] <= shft_shd[i];
                end
            end
        end
    end

    wire row_rdy0 = (out_row_cnt == H0 - 1) ? g0_row_done[H0 - 1]
                   : g0_row_done[(out_row_cnt + 1'b1) & (H0 - 1)];
    wire row_rdy1 = (out_row_cnt == H1 - 1) ? g1_row_done[H1 - 1]
                   : g1_row_done[(out_row_cnt + 1'b1) & (H1 - 1)];
    wire row_rdy2 = (out_row_cnt == H2 - 1) ? g2_row_done[H2 - 1]
                   : g2_row_done[(out_row_cnt + 1'b1) & (H2 - 1)];
    wire row_rdy3 = (out_row_cnt == H3 - 1) ? g3_row_done[H3 - 1]
                   : g3_row_done[(out_row_cnt + 1'b1) & (H3 - 1)];
    wire row_ready = (sel == 2'd0) ? row_rdy0 : (sel == 2'd1) ? row_rdy1 :
                     (sel == 2'd2) ? row_rdy2 : row_rdy3;

    wire issue_window = run_reg && (phase_reg == PH_SCAN)
                        && (tap_cnt != s_tap_last);
    wire issue_beat   = issue_window && w_valid;

    wire col_end      = (out_col_cnt == s_w - 1'b1);
    wire grp_end      = col_end && (grp_cnt == s_grp_last);
    wire layer_end    = grp_end && (out_row_cnt == s_h - 1'b1);
    wire need_advance = col_end && !layer_end;
    wire boundary_ok  = !need_advance || shadow_rdy;

    wire snapshot_go  = run_reg && (phase_reg == PH_SNAP)
                        && (rhe_busy_cnt == 5'd0) && boundary_ok && (out_reserved==0);
    assign advance_now = snapshot_go && need_advance;
    wire load_go      = run_reg && (phase_reg == PH_LOAD)
                        && row_ready && grp_arm && !fin_latched;

    wire fin_load     = snapshot_go && layer_end && (fin_cnt == 6'd0);
    wire layer_done_comb = run_reg && (fin_cnt == 6'd1) && (out_reserved==0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_data_q  <= 128'd0;
            w_vld_q   <= 1'b0;
            rd_pad_q  <= 1'b0;
            rd_bank_q <= 2'd0;
        end else begin
            w_vld_q <= issue_beat;
            if (issue_beat) begin
                w_data_q  <= w_data;
                rd_pad_q  <= rd_pad_c;
                rd_bank_q <= rd_bank_c;
            end
        end
    end

    wire [7:0] g0_dout = (rd_bank_q == 2'd0) ? g0_dout0 :
                         (rd_bank_q == 2'd1) ? g0_dout1 : g0_dout2;
    wire [7:0] g1_dout = (rd_bank_q == 2'd0) ? g1_dout0 :
                         (rd_bank_q == 2'd1) ? g1_dout1 : g1_dout2;
    wire [7:0] g2_dout = (rd_bank_q == 2'd0) ? g2_dout0 :
                         (rd_bank_q == 2'd1) ? g2_dout1 : g2_dout2;
    wire [7:0] g3_dout = (rd_bank_q == 2'd0) ? g3_dout0 :
                         (rd_bank_q == 2'd1) ? g3_dout1 : g3_dout2;
    wire [7:0] ram_dout = (sel == 2'd0) ? g0_dout : (sel == 2'd1) ? g1_dout :
                          (sel == 2'd2) ? g2_dout : g3_dout;

    reg  [7:0]   dout_q;
    reg          rd_pad_q2;
    reg  [127:0] w_data_q2;
    reg          w_vld_q2;
    wire         mac_add = run_reg && w_vld_q2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_q    <= 8'd0;
            rd_pad_q2 <= 1'b0;
            w_data_q2 <= 128'd0;
            w_vld_q2  <= 1'b0;
        end else begin
            dout_q    <= ram_dout;
            rd_pad_q2 <= rd_pad_q;
            w_vld_q2  <= w_vld_q;
            if (w_vld_q) w_data_q2 <= w_data_q;
        end
    end

    wire signed [8:0] x_eff = rd_pad_q2 ? 9'sd0 :
            ($signed({1'b0, dout_q}) - $signed({1'b0, zp_in_reg}));

    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : mac_lane
            wire signed [7:0]  w_lane = w_data_q2[8*g +: 8];
            wire signed [16:0] lane_sum = x_eff * w_lane;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    acc_a[g]    <= 32'sd0;
                    acc_b[g]    <= 32'sd0;
                    acc_snap[g] <= 32'sd0;
                end else begin

                    if (snapshot_go) begin
                        acc_snap[g] <= acc_sel ? acc_b[g] : acc_a[g];
                        m_drn[g]    <= m_act[g];
                        shft_drn[g] <= shft_act[g];
                    end

                    if (load_go) begin
                        if (!acc_sel) acc_a[g] <= bias_act[g];
                        else          acc_b[g] <= bias_act[g];
                    end else if (mac_add) begin
                        if (!acc_sel) acc_a[g] <= acc_a[g] + {{15{lane_sum[16]}}, lane_sum};
                        else          acc_b[g] <= acc_b[g] + {{15{lane_sum[16]}}, lane_sum};
                    end
                end
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fin_cnt     <= 6'd0;
            fin_latched <= 1'b0;
        end else if (any_start) begin
            fin_cnt     <= 6'd0;
            fin_latched <= 1'b0;
        end else if (fin_load) begin
            fin_cnt     <= 6'd22;
            fin_latched <= 1'b1;
        end else if (fin_cnt > 6'd1) begin
            fin_cnt <= fin_cnt - 6'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel          <= 2'd0;
            run_reg      <= 1'b0;
            phase_reg    <= PH_LOAD;
            out_row_cnt  <= {RR{1'b0}};
            grp_cnt      <= {RG{1'b0}};
            out_col_cnt  <= {RW{1'b0}};
            tap_cnt      <= {RT{1'b0}};
            mac_cnt      <= {RT{1'b0}};
            dy_cnt       <= 2'd0;
            dx_cnt       <= 2'd0;
            cin_cnt      <= {RC{1'b0}};
            rd_bank_base <= 2'd2;
            rhe_busy_cnt <= 5'd0;
            rhe_ch       <= 4'd0;
            acc_sel      <= 1'b0;
            done_q       <= 1'b0;
            advance_q    <= 1'b0;
        end else begin
            advance_q <= advance_now;
            done_q    <= layer_done_comb;
            if (any_start) begin
                sel          <= conv_sel;
                run_reg      <= 1'b1;
                phase_reg    <= PH_LOAD;
                out_row_cnt  <= {RR{1'b0}};
                grp_cnt      <= {RG{1'b0}};
                out_col_cnt  <= {RW{1'b0}};
                tap_cnt      <= {RT{1'b0}};
                mac_cnt      <= {RT{1'b0}};
                dy_cnt       <= 2'd0;
                dx_cnt       <= 2'd0;
                cin_cnt      <= {RC{1'b0}};
                rd_bank_base <= 2'd2;
                rhe_busy_cnt <= 5'd0;
                rhe_ch       <= 4'd0;
                acc_sel      <= 1'b0;
                done_q       <= 1'b0;
                advance_q    <= 1'b0;
            end else if (run_reg) begin
                if (layer_done_comb)
                    run_reg <= 1'b0;

                if (load_go) begin
                    phase_reg <= PH_SCAN;
                    tap_cnt   <= {RT{1'b0}};
                    mac_cnt   <= {RT{1'b0}};
                    dy_cnt    <= 2'd0;
                    dx_cnt    <= 2'd0;
                    cin_cnt   <= {RC{1'b0}};
                end else if (phase_reg == PH_SCAN) begin
                    if (issue_beat) begin
                        tap_cnt <= tap_cnt + {{(RT-1){1'b0}}, 1'b1};

                        if (dx_cnt == 2'd2) begin
                            dx_cnt <= 2'd0;
                            if (dy_cnt == 2'd2) begin
                                dy_cnt <= 2'd0;
                                cin_cnt <= cin_cnt + 1'b1;
                            end else begin
                                dy_cnt <= dy_cnt + 2'd1;
                            end
                        end else begin
                            dx_cnt <= dx_cnt + 2'd1;
                        end
                    end
                    if (mac_add) begin
                        mac_cnt <= mac_cnt + 1'b1;
                        if (mac_cnt == s_tap_last - 1'b1)
                            phase_reg <= PH_SNAP;
                    end
                end else if (snapshot_go) begin
                    phase_reg    <= PH_LOAD;
                    acc_sel      <= ~acc_sel;
                    rhe_busy_cnt <= 5'd16;
                    rhe_ch       <= 4'd0;

                    if (col_end) begin
                        out_col_cnt <= {RW{1'b0}};
                        if (grp_end) begin
                            grp_cnt <= {RG{1'b0}};
                            if (!layer_end) begin
                                rd_bank_base <= add3(rd_bank_base, 2'd1);
                                out_row_cnt  <= out_row_cnt + 1'b1;
                            end
                        end else begin
                            grp_cnt <= grp_cnt + 1'b1;
                        end
                    end else begin
                        out_col_cnt <= out_col_cnt + 1'b1;
                    end
                end

                if (rhe_busy_cnt != 5'd0) begin
                    rhe_busy_cnt <= rhe_busy_cnt - 5'd1;
                    rhe_ch       <= rhe_ch + 4'd1;
                end
            end
        end
    end

    assign rq_acc_s32  = acc_snap[rhe_ch];
    assign rq_m_s32    = m_drn[rhe_ch];
    assign rq_shift    = shft_drn[rhe_ch];
    assign rq_zp_out   = zp_out_reg;
    assign rq_in_valid = (rhe_busy_cnt != 5'd0);

    reg [7:0] out_fifo [0:15];
    reg [3:0] out_wr, out_rd;
    reg [4:0] out_count;
    reg [5:0] out_reserved;
    wire out_pop=(out_count!=0) && y_ready;
    assign y_valid=(out_count!=0);
    assign y_u8=out_fifo[out_rd];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            out_wr<=0; out_rd<=0; out_count<=0; out_reserved<=0;
        end else if(any_start) begin
            out_wr<=0; out_rd<=0; out_count<=0; out_reserved<=0;
        end else begin
            if(rq_y_valid) begin out_fifo[out_wr]<=rq_y_u8; out_wr<=out_wr+1'b1; end
            if(out_pop) out_rd<=out_rd+1'b1;
            case({rq_y_valid,out_pop})
                2'b10: out_count<=out_count+1'b1;
                2'b01: out_count<=out_count-1'b1;
                default: out_count<=out_count;
            endcase
            case({snapshot_go,out_pop})
                2'b10: out_reserved<=out_reserved+6'd16;
                2'b01: out_reserved<=out_reserved-1'b1;
                2'b11: out_reserved<=out_reserved+6'd15;
                default: out_reserved<=out_reserved;
            endcase
        end
    end
    assign done0       = done_q && (sel == 2'd0);
    assign done1       = done_q && (sel == 2'd1);
    assign done2       = done_q && (sel == 2'd2);
    assign done3       = done_q && (sel == 2'd3);
    assign adv0        = advance_q && (sel == 2'd0);
    assign adv1        = advance_q && (sel == 2'd1);
    assign adv2        = advance_q && (sel == 2'd2);
    assign adv3        = advance_q && (sel == 2'd3);
    assign w_ready     = issue_window;

endmodule
