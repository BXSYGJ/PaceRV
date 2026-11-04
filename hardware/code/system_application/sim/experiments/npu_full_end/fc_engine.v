// ---------------------------------------------------------------------------
// fc_engine.v -- INT8 fully-connected layer (fc1 ReLU / fc2 logits)
//
// Bit truth: golden_pipeline.fc_int8() + requant_u8().
//   acc[c] = sum_k (x[k] - zp_in) * w[c][k] + bias[c]
//   y_u8[c] = sat_u8(rhe_shift(acc[c] * M[c], shift[c]) + zp_out)
// fc1 uses zp_out == 0, which is the fused ReLU rail in the quint8 domain.
// fc2 uses zp_out == 57; the downstream softmax consumes (y_u8 - 57) as the
// int32 logits container (design.md 4.3/4.5).
//
// Architecture: 16 output channels per group, one shared input value per
// beat broadcast to 16 s8 weights (128-bit w_data), CIN beats per group.
// The input vector is buffered (CIN x s16) so every group re-reads it.
// After each group the 16 s32 accumulators drain through the shared
// time-multiplexed requant_unit (16 beats).
//
// Weight stream contract (wdma alignment point):
//   one beat per (group, k), lane i = w[group*16+i][k], 16 lanes s8.
//   Group order is the natural output-channel order.
// Contract stream: c_valid + m_s32 + shift, one beat per output channel,
//   loaded before the first group (COUT beats).
// ---------------------------------------------------------------------------

module fc_engine #(
    parameter CIN    = 256,
    parameter COUT   = 128,
    parameter [7:0] ZP_IN  = 8'd0,
    parameter [7:0] ZP_OUT = 8'd0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        layer_start,

    // input vector stream (CIN beats)
    input  wire        x_valid,
    input  wire signed [15:0] x_s16,

    // weight stream: 16 lanes per beat, CIN beats per group
    input  wire        w_valid,
    input  wire [127:0] w_data,
    output wire        w_ready,

    // per-output-channel bias/M/shift contract, three independent streams
    // (COUT beats each, before the groups; design.md 4.3).
    input  wire        b_valid,
    input  wire signed [31:0] bias_s32,
    input  wire        m_valid,
    input  wire signed [31:0] m_s32,
    input  wire        s_valid,
    input  wire [6:0]  shift,

    // requantised result stream (16 beats per group, lane order)
    output reg         y_valid,
    output reg  [7:0]  y_u8,
    output reg         done,
    output wire        grp_advance
);

    localparam GRP_NUM = (COUT + 15) / 16;   // fc2 = 8 channels -> 1 group
    localparam [7:0] GRP_LAST = GRP_NUM - 1;

    reg signed [15:0] x_buf [0:CIN-1];
    (* syn_ramstyle = "registers" *) reg signed [31:0] b_ram [0:GRP_NUM*16-1];
    (* syn_ramstyle = "registers" *) reg signed [31:0] m_ram [0:GRP_NUM*16-1];
    (* syn_ramstyle = "registers" *) reg        [6:0]  s_ram [0:GRP_NUM*16-1];

    reg signed [31:0] acc [0:15];
    reg [7:0]  x_cnt;
    reg [7:0]  b_cnt;
    reg [7:0]  m_cnt;
    reg [7:0]  s_cnt;
    reg [7:0]  grp_cnt;
    reg [7:0]  k_cnt;
    reg [4:0]  rq_cnt;
    reg [4:0]  rq_out_cnt;

    localparam [2:0] S_X    = 3'd0;
    localparam [2:0] S_C    = 3'd1;
    localparam [2:0] S_MAC  = 3'd2;
    localparam [2:0] S_RQ   = 3'd3;
    localparam [2:0] S_NEXT = 3'd4;
    localparam [2:0] S_DONE = 3'd5;
    reg [2:0] state;

    // requant_unit instance (shared, 1 channel per cycle, 16 per group)
    wire signed [31:0] rq_acc;
    wire signed [31:0] rq_m;
    wire        [6:0]  rq_shift;
    wire               rq_in;
    wire        [7:0]  rq_y;
    wire               rq_ok;

    assign rq_acc   = acc[rq_cnt[3:0]];
    assign rq_m     = m_ram[grp_cnt * 16 + rq_cnt[3:0]];
    assign rq_shift = s_ram[grp_cnt * 16 + rq_cnt[3:0]];
    assign rq_in    = (state == S_RQ) && (rq_cnt < 5'd16);
    assign w_ready  = (state == S_MAC);
    assign grp_advance = (state == S_NEXT) && (grp_cnt != GRP_LAST);

    requant_unit u_rq (
        .clk       (clk),
        .rst_n     (rst_n),
        .acc_s32   (rq_acc),
        .m_s32     (rq_m),
        .shift     (rq_shift),
        .zp_out    (ZP_OUT),
        .in_valid  (rq_in),
        .y_u8      (rq_y),
        .out_valid (rq_ok)
    );

    // 16-lane MAC: lane i is output channel (group*16+i).
    wire signed [15:0] x_eff = $signed(x_buf[k_cnt]) - $signed({7'd0, ZP_IN});

    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : mac_lane
            wire signed [7:0] w_lane = w_data[8*g +: 8];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) acc[g] <= 32'sd0;
                else if (state == S_MAC && w_valid) begin
                    // First beat of a group seeds the accumulator with bias.
                    if (k_cnt == 8'd0)
                        acc[g] <= b_ram[grp_cnt * 16 + g] + x_eff * w_lane;
                    else
                        acc[g] <= acc[g] + x_eff * w_lane;
                end
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_X;
            x_cnt    <= 8'd0;
            b_cnt    <= 8'd0;
            m_cnt    <= 8'd0;
            s_cnt    <= 8'd0;
            grp_cnt  <= 8'd0;
            k_cnt    <= 8'd0;
            rq_cnt   <= 5'd0;
            y_valid  <= 1'b0;
            y_u8     <= 8'd0;
            done     <= 1'b0;
        end else begin
            y_valid <= 1'b0;
            done    <= 1'b0;

            if (layer_start) begin
                b_cnt <= 0; m_cnt <= 0; s_cnt <= 0;
            end else begin
                if (b_valid && b_cnt < COUT) begin b_ram[b_cnt] <= bias_s32; b_cnt <= b_cnt + 1; end
                if (m_valid && m_cnt < COUT) begin m_ram[m_cnt] <= m_s32; m_cnt <= m_cnt + 1; end
                if (s_valid && s_cnt < COUT) begin s_ram[s_cnt] <= shift; s_cnt <= s_cnt + 1; end
            end
            case (state)
                S_X: begin
                    if (layer_start) x_cnt <= 8'd0;
                    if (x_valid) begin
                        x_buf[x_cnt] <= x_s16;
                        if (x_cnt == CIN - 1) begin
                            x_cnt <= 8'd0;
                            state <= S_C;
                        end else begin
                            x_cnt <= x_cnt + 8'd1;
                        end
                    end
                end

                S_C: begin
                    if ((b_cnt == COUT) && (m_cnt == COUT) &&
                        (s_cnt == COUT)) begin
                        grp_cnt <= 8'd0;
                        k_cnt   <= 8'd0;
                        state   <= S_MAC;
                    end
                end

                S_MAC: begin
                    if (w_valid) begin
                        if (k_cnt == CIN - 1) begin
                            k_cnt      <= 8'd0;
                            rq_cnt     <= 5'd0;
                            rq_out_cnt <= 5'd0;
                            state      <= S_RQ;
                        end else begin
                            k_cnt <= k_cnt + 8'd1;
                        end
                    end
                end

                S_RQ: begin
                    // Present 16 channels (rq_cnt 0..15); the unit has a
                    // 4-cycle latency and 1/cycle throughput, so collect
                    // 16 out_valid pulses before advancing.
                    if (rq_cnt < 5'd16) rq_cnt <= rq_cnt + 5'd1;
                    if (rq_ok) begin
                        y_valid    <= 1'b1;
                        y_u8       <= rq_y;
                        rq_out_cnt <= rq_out_cnt + 5'd1;
                        if (rq_out_cnt == 5'd15) state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    if (grp_cnt == GRP_LAST) begin
                        state <= S_DONE;
                    end else begin
                        grp_cnt <= grp_cnt + 8'd1;
                        k_cnt   <= 8'd0;
                        state   <= S_MAC;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_X;
                end

                default: state <= S_X;
            endcase
        end
    end

endmodule
