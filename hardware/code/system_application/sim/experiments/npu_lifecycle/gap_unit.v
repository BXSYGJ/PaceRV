// ---------------------------------------------------------------------------
// gap_unit.v -- global average pooling for the InstRec NPU (T-M2-05)
//
// Bit truth: golden_pipeline.gap_s32():
//   total[c] = sum over the 4x16 spatial map of the u8 container values
//   gap[c]   = round_half_even_shift(total[c], 6)
// The sum is taken on the raw uint8 values (no zero-point subtraction);
// the fc1 input quantization is applied later by fc_engine.
//
// Input stream (from pool4): one beat per cycle, order
// (row, grp, col, lane 0..15); 4 rows x 16 groups x 16 cols x 16 lanes.
//
// Storage: 256 x s32 accumulators (8,192 FF), then a 256 x 16 result RAM
// written one channel per cycle after the last beat. The fc stage reads
// the RAM through the exported read port.
// ---------------------------------------------------------------------------

module gap_unit #(
    parameter CIN  = 256,
    parameter H_IN = 4,
    parameter W_IN = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        layer_start,

    input  wire        y_valid,
    input  wire [7:0]  y_u8,

    // result RAM read port (for the fc stage)
    input  wire [7:0]  g_raddr,
    output reg  [15:0] g_rdata,

    output reg         gap_done,     // pulse after all 256 results are stored

    // streaming status for the downstream fc stage
    output reg  [7:0]  gap_waddr,
    output reg         gap_we,
    output reg  [15:0] gap_wdata
);

    localparam [7:0] GRP_LAST = (CIN / 16) - 1;

    reg signed [31:0] acc [0:255];
    reg [15:0]        result [0:255];

    reg [1:0]  row_cnt;
    reg [3:0]  grp_cnt;
    reg [3:0]  col_cnt;
    reg [3:0]  lane_cnt;
    reg        busy;
    reg [8:0]  conv_cnt;

    localparam [1:0] S_ACC  = 2'd0;
    localparam [1:0] S_CONV = 2'd1;
    localparam [1:0] S_DONE = 2'd2;
    reg [1:0] state;

    wire [7:0] ch = {grp_cnt, lane_cnt};
    wire       last_beat = y_valid && (row_cnt == H_IN - 1) &&
                           (grp_cnt == GRP_LAST) && (col_cnt == W_IN - 1) &&
                           (lane_cnt == 4'd15);

    // round-half-even divide by 64 for a non-negative s32 value.
    function [15:0] rhe_shift6;
        input signed [31:0] v;
        reg signed [31:0] q;
        reg [5:0] rem;
        begin
            q   = v >>> 6;
            rem = v[5:0];
            if (rem > 6'd32) q = q + 1;
            else if (rem == 6'd32 && q[0]) q = q + 1;
            rhe_shift6 = q[15:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt  <= 2'd0;
            grp_cnt  <= 4'd0;
            col_cnt  <= 4'd0;
            lane_cnt <= 4'd0;
            busy     <= 1'b0;
            state    <= S_ACC;
            conv_cnt <= 9'd0;
            gap_done <= 1'b0;
            gap_we   <= 1'b0;
            gap_waddr<= 8'd0;
            gap_wdata<= 16'd0;
            g_rdata  <= 16'd0;
        end else begin
            gap_done <= 1'b0;
            gap_we   <= 1'b0;

            if(layer_start) begin
                state<=S_ACC;row_cnt<=0;grp_cnt<=0;col_cnt<=0;lane_cnt<=0;
                conv_cnt<=0;busy<=1;
            end else case (state)
                S_ACC: begin
                    busy <= 1'b1;
                    if (y_valid) begin
                        if (row_cnt == 2'd0 && col_cnt == 4'd0)
                            acc[ch] <= {{24{1'b0}}, y_u8};   // first visit
                        else
                            acc[ch] <= acc[ch] + {{24{1'b0}}, y_u8};
                        if (lane_cnt == 4'd15) begin
                            lane_cnt <= 4'd0;
                            if (col_cnt == W_IN - 1) begin
                                col_cnt <= 4'd0;
                                if (grp_cnt == GRP_LAST) begin
                                    grp_cnt <= 4'd0;
                                    row_cnt <= row_cnt + 2'd1;
                                end else begin
                                    grp_cnt <= grp_cnt + 4'd1;
                                end
                            end else begin
                                col_cnt <= col_cnt + 4'd1;
                            end
                        end else begin
                            lane_cnt <= lane_cnt + 4'd1;
                        end
                        if (last_beat) begin
                            conv_cnt <= 9'd0;
                            state    <= S_CONV;
                        end
                    end
                end

                S_CONV: begin
                    // 256 cycles: store one channel result per cycle.
                    result[conv_cnt[7:0]] <= rhe_shift6(acc[conv_cnt[7:0]]);
                    gap_we    <= 1'b1;
                    gap_waddr <= conv_cnt[7:0];
                    gap_wdata <= rhe_shift6(acc[conv_cnt[7:0]]);
                    if (conv_cnt == 9'd255) begin
                        gap_done <= 1'b1;
                        state    <= S_DONE;
                    end else begin
                        conv_cnt <= conv_cnt + 9'd1;
                    end
                end

                S_DONE: begin
                    busy <= 1'b0;
                    if (layer_start) state <= S_ACC;
                end

                default: state <= S_ACC;
            endcase

            // result RAM read port (1-cycle synchronous read)
            g_rdata <= result[g_raddr];
        end
    end

endmodule