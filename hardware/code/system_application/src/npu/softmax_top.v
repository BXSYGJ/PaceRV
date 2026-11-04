module softmax_top #(
    parameter signed [31:0] S_Q15 = 32'sd9197
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [255:0] logits,

    output reg         out_valid,
    output reg  [15:0] out_q16,
    output reg  [7:0]  out_pct,
    output reg  [3:0]  out_idx,
    output reg  [3:0]  top1_idx,
    output reg         done
);

    reg [15:0] exp_lut [0:511];

    initial begin
        $readmemh("src/mel/exp_lut.hex", exp_lut);
    end

    localparam [3:0] S_IDLE  = 4'd0;
    localparam [3:0] S_MUL   = 4'd1;
    localparam [3:0] S_MAX1  = 4'd2;
    localparam [3:0] S_MAX2  = 4'd3;
    localparam [3:0] S_MAX3  = 4'd4;
    localparam [3:0] S_DSEL  = 4'd5;
    localparam [3:0] S_IDX   = 4'd6;
    localparam [3:0] S_LUT   = 4'd7;
    localparam [3:0] S_ACC   = 4'd8;
    localparam [3:0] S_DINIT = 4'd9;
    localparam [3:0] S_DIV   = 4'd10;
    localparam [3:0] S_DIVW  = 4'd11;
    localparam [3:0] S_PCT   = 4'd12;

    reg [3:0] state;

    reg signed [31:0] lq [0:7];
    reg signed [31:0] lmax;
    reg signed [31:0] dsel [0:7];
    reg [71:0]        idx_sr;
    reg [15:0]        expv [0:7];
    reg [31:0]        esum;
    reg [15:0]        pq [0:7];

    reg signed [31:0] m_hi;
    reg signed [31:0] m_lo;
    reg signed [31:0] mx01;
    reg signed [31:0] mx23;
    reg signed [31:0] mx45;
    reg signed [31:0] mx67;
    reg signed [31:0] mx03;
    reg signed [31:0] mx47;

    reg [32:0] div_sh;
    reg [20:0] div_rem;
    reg [32:0] div_quo;
    reg [5:0]  bit_cnt;

    reg [3:0] lane;
    reg [2:0] ch;
    reg       mul_phase;
    reg [3:0] best_i;
    reg [15:0] best_p;

    localparam signed [31:0] Q69_SAT = -32'sd16384;

    wire signed [31:0] l0 = $signed(logits[31:0]);
    wire signed [31:0] l1 = $signed(logits[63:32]);
    wire signed [31:0] l2 = $signed(logits[95:64]);
    wire signed [31:0] l3 = $signed(logits[127:96]);
    wire signed [31:0] l4 = $signed(logits[159:128]);
    wire signed [31:0] l5 = $signed(logits[191:160]);
    wire signed [31:0] l6 = $signed(logits[223:192]);
    wire signed [31:0] l7 = $signed(logits[255:224]);

    reg signed [31:0] lsel;
    always @* begin
        case (lane)
            4'd0: lsel = l0;
            4'd1: lsel = l1;
            4'd2: lsel = l2;
            4'd3: lsel = l3;
            4'd4: lsel = l4;
            4'd5: lsel = l5;
            4'd6: lsel = l6;
            default: lsel = l7;
        endcase
    end

    wire signed [31:0] mul_hi_n = (lsel << 13) + (lsel << 10);
    wire signed [31:0] mul_lo_n = (lsel << 4) + (lsel << 1) + lsel;
    wire signed [31:0] mul_n    = m_hi - m_lo;

    wire signed [31:0] dsel_n = lq[lane] - lmax;
    wire signed [31:0] d69_n  = $signed(dsel[lane]) >>> 6;
    wire signed [31:0] d69s_n = (d69_n < Q69_SAT) ? Q69_SAT : d69_n;
    wire signed [31:0] mag_n  = -d69s_n;
    wire [31:0]        magq_n = $signed(mag_n) >>> 4;
    wire [8:0]         idx_n  = (magq_n > 32'd511) ? 9'd511 : magq_n[8:0];

    wire [32:0] div_num_n = ({17'd0, expv[ch]} << 16) + {1'b0, esum >> 1};
    wire [20:0] den_ext   = {2'b00, esum[18:0]};
    wire [20:0] rem_n     = {div_rem[19:0], div_sh[32]};
    wire [20:0] rem_sub   = rem_n - den_ext;
    wire        rem_ge    = (rem_n >= den_ext);

    function [7:0] pct_rhe;
        input [15:0] p;
        reg [31:0] prod;
        reg [31:0] q;
        reg [31:0] rem;
        begin
            prod = {16'd0, p} * 32'd100;
            q    = prod >> 16;
            rem  = prod & 32'hFFFF;
            if (rem > 32'd32768 || (rem == 32'd32768 && q[0]))
                q = q + 32'd1;
            pct_rhe = (q > 32'd100) ? 8'd100 : q[7:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            lane      <= 4'd0;
            ch        <= 3'd0;
            bit_cnt   <= 6'd0;
            mul_phase <= 1'b0;
            esum      <= 32'd0;
            out_valid <= 1'b0;
            out_q16   <= 16'd0;
            out_pct   <= 8'd0;
            out_idx   <= 4'd0;
            top1_idx  <= 4'd0;
            done      <= 1'b0;
            best_i    <= 4'd0;
            best_p    <= 16'd0;
            lmax      <= 32'sd0;
        end else begin
            out_valid <= 1'b0;
            done      <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        lane      <= 4'd0;
                        esum      <= 32'd0;
                        mul_phase <= 1'b0;
                        state     <= S_MUL;
                    end
                end

                S_MUL: begin
                    if (mul_phase == 1'b0) begin
                        m_hi      <= mul_hi_n;
                        m_lo      <= mul_lo_n;
                        mul_phase <= 1'b1;
                    end else begin
                        lq[lane]  <= mul_n;
                        mul_phase <= 1'b0;
                        lane      <= lane + 4'd1;
                        if (lane == 4'd7) begin
                            lane  <= 4'd0;
                            state <= S_MAX1;
                        end
                    end
                end

                S_MAX1: begin
                    mx01  <= (lq[0] > lq[1]) ? lq[0] : lq[1];
                    mx23  <= (lq[2] > lq[3]) ? lq[2] : lq[3];
                    mx45  <= (lq[4] > lq[5]) ? lq[4] : lq[5];
                    mx67  <= (lq[6] > lq[7]) ? lq[6] : lq[7];
                    state <= S_MAX2;
                end

                S_MAX2: begin
                    mx03  <= (mx01 > mx23) ? mx01 : mx23;
                    mx47  <= (mx45 > mx67) ? mx45 : mx67;
                    state <= S_MAX3;
                end

                S_MAX3: begin
                    lmax  <= (mx03 > mx47) ? mx03 : mx47;
                    state <= S_DSEL;
                end

                S_DSEL: begin
                    dsel[lane] <= dsel_n;
                    lane       <= lane + 4'd1;
                    if (lane == 4'd7) begin
                        lane  <= 4'd0;
                        state <= S_IDX;
                    end
                end

                S_IDX: begin
                    idx_sr <= {idx_sr[62:0], idx_n};
                    lane   <= lane + 4'd1;
                    if (lane == 4'd7) begin
                        lane  <= 4'd0;
                        state <= S_LUT;
                    end
                end

                S_LUT: begin
                    expv[lane] <= exp_lut[idx_sr[71:63]];
                    idx_sr     <= {idx_sr[62:0], 9'd0};
                    lane       <= lane + 4'd1;
                    if (lane == 4'd7) begin
                        lane  <= 4'd0;
                        state <= S_ACC;
                    end
                end

                S_ACC: begin
                    esum <= esum + expv[lane];
                    lane <= lane + 4'd1;
                    if (lane == 4'd7) begin
                        lane  <= 4'd0;
                        ch    <= 3'd0;
                        state <= S_DINIT;
                    end
                end

                S_DINIT: begin
                    div_sh  <= div_num_n;
                    div_rem <= 21'd0;
                    div_quo <= 33'd0;
                    bit_cnt <= 6'd0;
                    state   <= S_DIV;
                end

                S_DIV: begin
                    div_sh  <= {div_sh[31:0], 1'b0};
                    bit_cnt <= bit_cnt + 6'd1;
                    if (esum != 32'd0 && rem_ge) begin
                        div_rem <= rem_sub;
                        div_quo <= {div_quo[31:0], 1'b1};
                    end else begin
                        div_rem <= rem_n;
                        div_quo <= {div_quo[31:0], 1'b0};
                    end
                    if (bit_cnt == 6'd32) begin
                        bit_cnt <= 6'd0;
                        state   <= S_DIVW;
                    end
                end

                S_DIVW: begin
                    pq[ch] <= (div_quo > 33'd65535) ? 16'd65535
                                                    : div_quo[15:0];
                    if (ch == 3'd7) begin
                        ch    <= 3'd0;
                        state <= S_PCT;
                    end else begin
                        ch    <= ch + 3'd1;
                        state <= S_DINIT;
                    end
                end

                S_PCT: begin
                    out_valid <= 1'b1;
                    out_q16   <= pq[lane];

                    out_pct   <= pct_rhe(pq[lane]);
                    out_idx   <= lane;
                    if (pq[lane] > best_p) begin
                        best_p <= pq[lane];
                        best_i <= lane;
                    end
                    lane <= lane + 4'd1;
                    if (lane == 4'd7) begin

                        done     <= 1'b1;
                        top1_idx <= (pq[7] > best_p) ? 4'd7 : best_i;
                        state    <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
