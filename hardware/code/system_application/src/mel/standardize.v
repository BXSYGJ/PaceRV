module standardize #(
    parameter integer N_MELS            = 64,
    parameter integer OUT_FRAME_COUNT   = 258,
    parameter integer MEL_ELEMENT_COUNT = 16512,
    parameter integer DB_ADDR_OFFSET    = 64,

    parameter [31:0] INV_S_IN           = 32'd267723430,
    parameter [7:0] ZP_IN               = 8'd49
) (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               start,
    output wire               busy,

    input  wire signed [47:0] sum_db,
    input  wire [47:0]        sum_db_sq,

    output wire               db_rd_en,
    output wire [14:0]        db_rd_addr,
    input  wire signed [15:0] db_rd_data,

    output wire               feat_valid,
    output wire               feat_wr_en,
    output wire [14:0]        feat_wr_addr,
    output wire [7:0]         feat_wr_data,
    output reg                feat_done
);

    localparam [14:0] OUT_ELEM_LAST     = MEL_ELEMENT_COUNT - 1;
    localparam [14:0] DB_ADDR_OFFSET_C  = DB_ADDR_OFFSET;
    localparam [47:0] DIV_N_C           = MEL_ELEMENT_COUNT;
    localparam signed [31:0] INV_S_IN_S = INV_S_IN;
    localparam signed [26:0] ZP_IN_S    = ZP_IN;

    localparam [3:0] S_IDLE     = 4'd0;
    localparam [3:0] S_DIV_MU   = 4'd1;
    localparam [3:0] S_MUL_MU   = 4'd2;
    localparam [3:0] S_DIV_VAR  = 4'd3;
    localparam [3:0] S_SUB_VAR  = 4'd4;
    localparam [3:0] S_SQRT     = 4'd5;
    localparam [3:0] S_SEL_INV  = 4'd6;
    localparam [3:0] S_DIV_INV  = 4'd7;
    localparam [3:0] S_SCAN_RD  = 4'd8;
    localparam [3:0] S_SCAN_Z   = 4'd9;
    localparam [3:0] S_SCAN_Q   = 4'd10;
    localparam [3:0] S_SCAN_D   = 4'd11;
    localparam [3:0] S_SCAN_M   = 4'd12;
    localparam [3:0] S_SCAN_QM  = 4'd13;

    reg [3:0]         state;

    reg signed [15:0] mu_q88;
    reg signed [31:0] mu_sq_s32;
    reg [47:0]        mean_sq_u48;
    reg [31:0]        var_q16_u32;
    reg [23:0]        sigma_u24;
    reg [20:0]        inv_sigma_u21;
    reg signed [15:0] z_reg;
    reg signed [16:0] d_reg;
    reg signed [38:0] z_prod_reg;
    reg signed [47:0] qprod_reg;

    reg [14:0]        scan_cnt;

    reg [47:0] div_n;
    reg [47:0] div_d;
    reg [48:0] div_r;
    reg [47:0] div_q;
    reg [5:0]  div_cnt;
    reg        div_neg;

    wire        div_nbit = div_n[47];
    wire [48:0] div_r_shift = {div_r[47:0], div_nbit};
    wire        div_ge = (div_r_shift >= {1'b0, div_d});
    wire [48:0] div_r_next = div_ge ? (div_r_shift - {1'b0, div_d})
                                    : div_r_shift;
    wire [47:0] div_q_next = {div_q[46:0], div_ge};

    reg [47:0] sqrt_x;
    reg [26:0] sqrt_r;
    reg [23:0] sqrt_rt;
    reg [5:0]  sqrt_cnt;

    wire [1:0]  sqrt_pair = sqrt_x[47:46];
    wire [26:0] sqrt_r_shift = {sqrt_r[24:0], sqrt_pair};
    wire [25:0] sqrt_c_sub = {sqrt_rt[23:0], 2'b01};
    wire        sqrt_ge = (sqrt_r_shift >= {1'b0, sqrt_c_sub});
    wire [26:0] sqrt_r_next = sqrt_ge ? (sqrt_r_shift - {1'b0, sqrt_c_sub})
                                      : sqrt_r_shift;
    wire [23:0] sqrt_rt_next = {sqrt_rt[22:0], sqrt_ge};

    wire signed [31:0] var_sub_s32 = $signed(mean_sq_u48[31:0]) - mu_sq_s32;
    wire [31:0] var_q16_comb = (var_sub_s32 < 32'sd0) ? 32'd0 : var_sub_s32;

    wire [20:0] sigma_eff_w = (sigma_u24 == 24'd0) ? 21'd1 : sigma_u24[20:0];
    wire [21:0] inv_dividend_w = 22'd1048576 + {1'b0, sigma_eff_w[20:1]};

    wire signed [16:0] d_s17 = db_rd_data - mu_q88;
    wire signed [21:0] inv_sigma_s22 = {1'b0, inv_sigma_u21};
    wire signed [38:0] z_prod_s39 = d_reg * inv_sigma_s22;
    wire signed [38:0] z_rhu_s39 = $signed(z_prod_reg + 39'sd128) >>> 8;
    wire signed [15:0] z_sat_s16 =
        (z_rhu_s39 > 39'sd32767)   ? 16'sd32767  :
        (z_rhu_s39 < -39'sd32768)  ? -16'sd32768 :
                                     z_rhu_s39[15:0];

    wire signed [47:0] qprod_s48 = z_reg * INV_S_IN_S;
    wire               q_neg = qprod_reg[47];
    wire [47:0]        q_abs = q_neg ? (~qprod_reg + 48'd1) : qprod_reg;
    wire [23:0]        q_shift = q_abs[47:24];
    wire [23:0]        q_rem = q_abs[23:0];

    wire               rhe_inc = (q_rem > 24'h800000) ||
                                 ((q_rem == 24'h800000) && q_shift[0]);
    wire [24:0]        q_rnd = {1'b0, q_shift} + (rhe_inc ? 25'd1 : 25'd0);
    wire signed [25:0] q_res_s26 = q_neg ? -$signed({1'b0, q_rnd})
                                          : $signed({1'b0, q_rnd});
    wire signed [26:0] x_q_s27 = q_res_s26 + ZP_IN_S;
    wire [7:0]         feat_byte = (x_q_s27 < 27'sd0)   ? 8'd0   :
                                   (x_q_s27 > 27'sd255) ? 8'd255 :
                                                          x_q_s27[7:0];

    assign db_rd_en     = (state == S_SCAN_RD);
    assign db_rd_addr   = scan_cnt + DB_ADDR_OFFSET_C;
    assign feat_wr_en   = (state == S_SCAN_Q);
    assign feat_valid   = feat_wr_en;
    assign feat_wr_addr = scan_cnt;
    assign feat_wr_data = feat_byte;

    assign busy = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            mu_q88       <= 16'sd0;
            mu_sq_s32    <= 32'sd0;
            mean_sq_u48  <= 48'd0;
            var_q16_u32  <= 32'd0;
            sigma_u24    <= 24'd0;
            inv_sigma_u21<= 21'd0;
            z_reg        <= 16'sd0;
            d_reg        <= 17'sd0;
            z_prod_reg   <= 39'sd0;
            qprod_reg    <= 48'sd0;
            scan_cnt     <= 15'd0;
            feat_done    <= 1'b0;
            div_n        <= 48'd0;
            div_d        <= 48'd0;
            div_r        <= 49'd0;
            div_q        <= 48'd0;
            div_cnt      <= 6'd0;
            div_neg      <= 1'b0;
            sqrt_x       <= 48'd0;
            sqrt_r       <= 27'd0;
            sqrt_rt      <= 24'd0;
            sqrt_cnt     <= 6'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    feat_done <= 1'b0;
                    if (start) begin

                        div_n   <= sum_db[47] ? (-sum_db) : sum_db;
                        div_d   <= DIV_N_C;
                        div_neg <= sum_db[47];
                        div_r   <= 49'd0;
                        div_q   <= 48'd0;
                        div_cnt <= 6'd48;
                        scan_cnt<= 15'd0;
                        state   <= S_DIV_MU;
                    end
                end

                S_DIV_MU: begin
                    div_r <= div_r_next;
                    div_q <= div_q_next;
                    div_n <= {div_n[46:0], 1'b0};
                    if (div_cnt == 6'd1) begin
                        mu_q88 <= div_neg ? -$signed(div_q_next[15:0])
                                          : $signed(div_q_next[15:0]);

                        div_n   <= sum_db_sq;
                        div_d   <= DIV_N_C;
                        div_neg <= 1'b0;
                        div_r   <= 49'd0;
                        div_q   <= 48'd0;
                        div_cnt <= 6'd48;
                        state   <= S_MUL_MU;
                    end else begin
                        div_cnt <= div_cnt - 6'd1;
                    end
                end

                S_MUL_MU: begin
                    mu_sq_s32 <= mu_q88 * mu_q88;
                    state     <= S_DIV_VAR;
                end

                S_DIV_VAR: begin
                    div_r <= div_r_next;
                    div_q <= div_q_next;
                    div_n <= {div_n[46:0], 1'b0};
                    if (div_cnt == 6'd1) begin
                        mean_sq_u48 <= div_q_next;
                        state       <= S_SUB_VAR;
                    end else begin
                        div_cnt <= div_cnt - 6'd1;
                    end
                end

                S_SUB_VAR: begin

                    var_q16_u32 <= var_q16_comb;
                    sqrt_x   <= {16'd0, var_q16_comb};
                    sqrt_r   <= 27'd0;
                    sqrt_rt  <= 24'd0;
                    sqrt_cnt <= 6'd24;
                    state    <= S_SQRT;
                end

                S_SQRT: begin
                    sqrt_r  <= sqrt_r_next;
                    sqrt_rt <= sqrt_rt_next;
                    sqrt_x  <= {sqrt_x[45:0], 2'b00};
                    if (sqrt_cnt == 6'd1) begin
                        sigma_u24 <= sqrt_rt_next;
                        state     <= S_SEL_INV;
                    end else begin
                        sqrt_cnt <= sqrt_cnt - 6'd1;
                    end
                end

                S_SEL_INV: begin

                    div_n   <= {26'd0, inv_dividend_w};
                    div_d   <= {27'd0, sigma_eff_w};
                    div_neg <= 1'b0;
                    div_r   <= 49'd0;
                    div_q   <= 48'd0;
                    div_cnt <= 6'd48;
                    state   <= S_DIV_INV;
                end

                S_DIV_INV: begin
                    div_r <= div_r_next;
                    div_q <= div_q_next;
                    div_n <= {div_n[46:0], 1'b0};
                    if (div_cnt == 6'd1) begin
                        inv_sigma_u21 <= div_q_next[20:0];
                        state         <= S_SCAN_RD;
                    end else begin
                        div_cnt <= div_cnt - 6'd1;
                    end
                end

                S_SCAN_RD: begin
                    state <= S_SCAN_D;
                end
                S_SCAN_D: begin
                    d_reg <= d_s17;
                    state <= S_SCAN_M;
                end
                S_SCAN_M: begin
                    z_prod_reg <= z_prod_s39;
                    state <= S_SCAN_Z;
                end

                S_SCAN_Z: begin
                    z_reg <= z_sat_s16;
                    state <= S_SCAN_QM;
                end
                S_SCAN_QM: begin
                    qprod_reg <= qprod_s48;
                    state <= S_SCAN_Q;
                end

                S_SCAN_Q: begin
                    if (scan_cnt == OUT_ELEM_LAST) begin
                        feat_done <= 1'b1;
                        state     <= S_IDLE;
                    end else begin
                        scan_cnt <= scan_cnt + 15'd1;
                        state    <= S_SCAN_RD;
                    end
                end
                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
