module db_norm #(
    parameter integer N_MELS           = 64,
    parameter integer SPEC_FRAME_COUNT = 259,
    parameter integer OUT_FRAME_COUNT  = 258,
    parameter integer DB_SCALE_NUM     = 775,
    parameter integer DB_TOP_DB_Q88    = -20480
) (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               start,
    output wire               busy,

    output wire               spec_rd_en,
    output wire [14:0]        spec_rd_addr,
    input  wire signed [15:0] spec_rd_data,

    output wire               db_wr_en,
    output wire [14:0]        db_wr_addr,
    output wire signed [15:0] db_wr_data,

    output reg  signed [47:0] sum_db,
    output reg  [47:0]        sum_db_sq,
    output reg                stats_valid
);

    localparam integer HEAD_DROP       = SPEC_FRAME_COUNT - OUT_FRAME_COUNT;
    localparam integer OUT_FIRST       = HEAD_DROP * N_MELS;
    localparam integer SPEC_ELEM_TOTAL = SPEC_FRAME_COUNT * N_MELS;
    localparam [14:0] SPEC_ELEM_LAST   = SPEC_ELEM_TOTAL - 1;
    localparam [14:0] OUT_FIRST_C      = OUT_FIRST;
    localparam signed [15:0] DB_TOP_S  = DB_TOP_DB_Q88;
    localparam signed [10:0] DB_NUM_S   = DB_SCALE_NUM;

    localparam [3:0] S_IDLE      = 4'd0;
    localparam [3:0] S_MAX_RD    = 4'd1;
    localparam [3:0] S_MAX_CALC  = 4'd2;
    localparam [3:0] S_DB_RD     = 4'd3;
    localparam [3:0] S_DB_CALC   = 4'd4;
    localparam [3:0] S_DB_FLUSH  = 4'd5;
    localparam [3:0] S_DB_SQ_FLUSH = 4'd6;
    localparam [3:0] S_DB_SUM_FLUSH = 4'd7;

    localparam [3:0] S_DB_DIFF = 4'd8;
    localparam [3:0] S_DB_MUL = 4'd9;
    reg [3:0]        state;
    reg signed [16:0] diff_pipe;
    reg signed [26:0] mul_pipe;
    reg [14:0]       elem_cnt;
    reg signed [15:0] max_l2;
    reg signed [15:0] db_value_pipe;
    reg               db_value_pipe_valid;
    reg        [31:0] db_sq_pipe;
    reg               db_sq_pipe_valid;

    wire signed [31:0] db_value_ext = {{16{db_value_pipe[15]}}, db_value_pipe};
    wire        [63:0] db_sq_product = db_value_ext * db_value_ext;

    wire signed [16:0] diff_s17 = spec_rd_data - max_l2;
    wire signed [26:0] db_mul_s27 = diff_pipe * DB_NUM_S;

    wire signed [26:0] db_rhu_s27 = $signed(mul_pipe + 27'sd128) >>> 8;

    wire signed [15:0] db_s16 =
        (db_rhu_s27 < $signed({{11{DB_TOP_S[15]}}, DB_TOP_S})) ? DB_TOP_S :
        (db_rhu_s27 > 27'sd0)                                   ? 16'sd0   :
                                                                    db_rhu_s27[15:0];

    wire is_out_now = (elem_cnt >= OUT_FIRST_C);

    assign spec_rd_en   = (state == S_MAX_RD) || (state == S_DB_RD);
    assign spec_rd_addr = elem_cnt;
    assign db_wr_en     = (state == S_DB_CALC) && is_out_now;
    assign db_wr_addr   = elem_cnt;
    assign db_wr_data   = db_s16;

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (state == S_DB_DIFF) diff_pipe <= diff_s17;
        if (state == S_DB_MUL) mul_pipe <= db_mul_s27;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            elem_cnt    <= 15'd0;
            max_l2      <= -16'sd32768;
            sum_db      <= 48'sd0;
            sum_db_sq   <= 48'd0;
            stats_valid <= 1'b0;
            db_value_pipe <= 16'sd0;
            db_value_pipe_valid <= 1'b0;
            db_sq_pipe <= 32'd0;
            db_sq_pipe_valid <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    stats_valid <= 1'b0;
                    if (start) begin
                        elem_cnt  <= 15'd0;
                        max_l2    <= -16'sd32768;
                        sum_db    <= 48'sd0;
                        sum_db_sq <= 48'd0;
                        db_sq_pipe_valid <= 1'b0;
                        db_value_pipe_valid <= 1'b0;
                        state     <= S_MAX_RD;
                    end
                end

                S_MAX_RD: begin
                    state <= S_MAX_CALC;
                end
                S_MAX_CALC: begin
                    if (spec_rd_data > max_l2) begin
                        max_l2 <= spec_rd_data;
                    end
                    if (elem_cnt == SPEC_ELEM_LAST) begin
                        elem_cnt <= 15'd0;
                        state    <= S_DB_RD;
                    end else begin
                        elem_cnt <= elem_cnt + 15'd1;
                        state    <= S_MAX_RD;
                    end
                end

                S_DB_RD: begin

                    if (db_value_pipe_valid) begin
                        sum_db <= sum_db + {{32{db_value_pipe[15]}}, db_value_pipe};
                    end
                    db_sq_pipe <= db_sq_product[31:0];
                    db_sq_pipe_valid <= db_value_pipe_valid;
                    state <= S_DB_DIFF;
                end
                S_DB_DIFF: begin
                    state <= S_DB_MUL;
                end
                S_DB_MUL: begin
                    state <= S_DB_CALC;
                end
                S_DB_CALC: begin
                    if (db_sq_pipe_valid) begin
                        sum_db_sq <= sum_db_sq + {16'd0, db_sq_pipe};
                    end
                    db_value_pipe <= db_s16;
                    db_value_pipe_valid <= is_out_now;
                    if (elem_cnt == SPEC_ELEM_LAST) begin
                        state <= S_DB_FLUSH;
                    end else begin
                        elem_cnt <= elem_cnt + 15'd1;
                        state    <= S_DB_RD;
                    end
                end
                S_DB_FLUSH: begin
                    if (db_value_pipe_valid) begin
                        sum_db <= sum_db + {{32{db_value_pipe[15]}}, db_value_pipe};
                    end
                    db_sq_pipe <= db_sq_product[31:0];
                    db_sq_pipe_valid <= db_value_pipe_valid;
                    state <= S_DB_SUM_FLUSH;
                end
                S_DB_SUM_FLUSH: begin
                    if (db_sq_pipe_valid) begin
                        sum_db_sq <= sum_db_sq + {16'd0, db_sq_pipe};
                    end
                    db_sq_pipe_valid <= 1'b0;
                    db_value_pipe_valid <= 1'b0;
                    stats_valid <= 1'b1;
                    state <= S_IDLE;
                end
                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
