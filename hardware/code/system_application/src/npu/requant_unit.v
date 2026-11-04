module requant_unit (

    input  wire               clk,
    input  wire               rst_n,

    input  wire signed [31:0] acc_s32,
    input  wire signed [31:0] m_s32,
    input  wire        [6:0]  shift,
    input  wire        [7:0]  zp_out,
    input  wire               in_valid,

    output reg         [7:0]  y_u8,
    output reg                out_valid
);

    reg signed [31:0] p11_q;
    reg signed [31:0] p10_q;
    reg signed [31:0] p01_q;
    reg        [31:0] p00_q;
    reg        [6:0]  shift_q;
    reg        [7:0]  zp_q;
    reg        [6:0]  shift_q2;
    reg        [7:0]  zp_q2;
    reg        [7:0]  zp_q3;
    reg               v1_q;

    reg signed [63:0] prod_q;
    reg               v2_q;

    reg signed [63:0] rhe_q;
    reg               v3_q;

    wire signed [15:0] a1_c = acc_s32[31:16];
    wire        [15:0] a0_c = acc_s32[15:0];
    wire signed [15:0] b1_c = m_s32[31:16];
    wire        [15:0] b0_c = m_s32[15:0];
    wire signed [16:0] a0s_c = $signed({1'b0, a0_c});
    wire signed [16:0] b0s_c = $signed({1'b0, b0_c});

    wire signed [32:0] mid_c  = {{1{p10_q[31]}}, p10_q} +
                                {{1{p01_q[31]}}, p01_q};
    wire signed [63:0] prod_c = ({{32{p11_q[31]}}, p11_q} << 32) +
                                ({{31{mid_c[32]}}, mid_c} << 16) +
                                {{32{1'b0}}, p00_q};

    wire shift_zero = (shift_q2 == 7'd0);

    wire signed [63:0] q0 = shift_zero ? prod_q : (prod_q >>> shift_q2);

    wire [63:0] rem_mask = ~(~64'd0 << shift_q2);
    wire [63:0] rem      = prod_q & rem_mask;

    wire [63:0] half     = 64'd1 << (shift_q2 - 7'd1);

    wire [63:0] rem_d    = rem - half;
    wire        rem_lt   = rem_d[63];
    wire        rem_eq   = (rem_d == 64'd0);
    wire        rem_gt   = ~rem_lt & ~rem_eq;

    wire        inc      = ~shift_zero &
                           (rem_gt | (rem_eq & q0[0]));

    wire signed [63:0] rhe_c = q0 + {{63{1'b0}}, inc};

    wire signed [64:0] y_sum  = {rhe_q[63], rhe_q} +
                                $signed({{57{1'b0}}, zp_q3});

    wire y_lt0   = y_sum[64];
    wire y_gt255 = (~y_sum[64]) & (|y_sum[62:8]);
    wire [7:0] y_sat_c = y_lt0   ? 8'd0   :
                         y_gt255 ? 8'd255 :
                                   y_sum[7:0];

    always @(posedge clk) begin
        p11_q <= a1_c * b1_c;
        p10_q <= a1_c * b0s_c;
        p01_q <= a0s_c * b1_c;
        p00_q <= a0_c * b0_c;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_q   <= 7'd0;
            zp_q      <= 8'd0;
            shift_q2  <= 7'd0;
            zp_q2     <= 8'd0;
            zp_q3     <= 8'd0;
            v1_q      <= 1'b0;
            prod_q    <= 64'sd0;
            v2_q      <= 1'b0;
            rhe_q     <= 64'sd0;
            v3_q      <= 1'b0;
            y_u8      <= 8'd0;
            out_valid <= 1'b0;
        end else begin

            shift_q <= shift;
            zp_q    <= zp_out;
            v1_q    <= in_valid;

            prod_q  <= prod_c;
            shift_q2 <= shift_q;
            zp_q2   <= zp_q;
            zp_q3   <= zp_q2;
            v2_q    <= v1_q;

            rhe_q   <= rhe_c;
            v3_q    <= v2_q;

            y_u8    <= y_sat_c;
            out_valid <= v3_q;
        end
    end

endmodule
