`timescale 1ns / 1ps

module audio_sink #(

    parameter [4:0] AGG_FRAMES = 5'd16,

    parameter [13:0] INJECT_GAP_CYCLES = 14'd2834,

    parameter [13:0] ZERO_SUSTAIN_FRAMES = 14'd4096,

    parameter [13:0] EMPTY_SUSTAIN_CYCLES = 14'd4096,

    parameter [22:0] WR_TIMEOUT_CYCLES = 23'd4_194_304
) (

    input  wire        clk,
    input  wire        rst_n,

    output wire        fifo_rd_en,
    input  wire [31:0] fifo_rd_data,
    input  wire        fifo_rd_valid,
    input  wire        fifo_empty,

    input  wire        sd_idle,

    output reg         m0_cmd_valid,
    output reg  [36:0] m0_cmd,
    output reg  [255:0] m0_wdata,
    input  wire        m0_done,

    output reg         win_tick,
    output reg  [15:0] win_id,
    output reg         mute_flag,
    output wire [15:0] err_cnt,

    input  wire        pix_clk,

    input  wire        vsync_pulse,

    input  wire [10:0] wave_rd_addr,
    output reg  [15:0] wave_min,
    output reg  [15:0] wave_max,

    output wire        wave_valid,

    output wire        mute_flag_sync
);

    localparam [27:0] PCM_L_BASE   = 28'h0000_000;
    localparam [27:0] PCM_R_BASE   = 28'h0008_4000;
    localparam [27:0] WIN_BYTES    = 28'h0004_2000;

    localparam [17:0] WIN_FRAMES   = 18'd132_096;

    localparam [13:0] PAGES_PER_WIN = 14'd8256;

    localparam [8:0] GRP_BOUND_0 = 9'd69;
    localparam [8:0] GRP_BOUND_1 = 9'd138;
    localparam [8:0] GRP_BOUND_2 = 9'd207;
    localparam [8:0] GRP_BOUND_3 = 9'd276;
    localparam [8:0] GRP_LAST    = 9'd343;
    localparam [10:0] COLS_PER_PAGE = 11'd1920;

    reg sd_idle_meta;
    reg sd_idle_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_idle_meta <= 1'b0;
            sd_idle_sync <= 1'b0;
        end else begin
            sd_idle_meta <= sd_idle;
            sd_idle_sync <= sd_idle_meta;
        end
    end

    wire agg_freeze;
    assign fifo_rd_en = ~fifo_empty & ~agg_freeze;

    reg [13:0] empty_gap_cnt;
    wire inject_tick = fifo_empty & ~agg_freeze
                     & (empty_gap_cnt == INJECT_GAP_CYCLES - 14'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            empty_gap_cnt <= 14'd0;
        else if (fifo_empty & ~agg_freeze)
            empty_gap_cnt <= empty_gap_cnt + 14'd1;
        else
            empty_gap_cnt <= 14'd0;
    end

    wire frame_event = fifo_rd_valid | inject_tick;

    wire [15:0] frame_l = fifo_rd_valid ? fifo_rd_data[31:16] : 16'h0000;
    wire [15:0] frame_r = fifo_rd_valid ? fifo_rd_data[15:0]  : 16'h0000;

    reg [13:0] zero_run_cnt;
    reg        all_zero_sustain;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            zero_run_cnt     <= 14'd0;
            all_zero_sustain <= 1'b0;
        end else if (!frame_event) begin
            zero_run_cnt     <= zero_run_cnt;
            all_zero_sustain <= all_zero_sustain;
        end else if ((frame_l == 16'h0000) && (frame_r == 16'h0000)) begin
            zero_run_cnt <= zero_run_cnt + 14'd1;
            if (zero_run_cnt == ZERO_SUSTAIN_FRAMES - 14'd1)
                all_zero_sustain <= 1'b1;
        end else begin
            zero_run_cnt     <= 14'd0;
            all_zero_sustain <= 1'b0;
        end
    end

    reg [13:0] empty_run_cnt;
    reg        empty_sustain;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            empty_run_cnt <= 14'd0;
            empty_sustain <= 1'b0;
        end else if (fifo_empty) begin
            empty_run_cnt <= empty_run_cnt + 14'd1;
            if (empty_run_cnt == EMPTY_SUSTAIN_CYCLES - 14'd1)
                empty_sustain <= 1'b1;
        end else begin
            empty_run_cnt <= 14'd0;
            empty_sustain <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mute_flag <= 1'b0;
        else
            mute_flag <= sd_idle_sync | all_zero_sustain | empty_sustain;
    end

    reg [255:0] agg_l_shift;
    reg [255:0] agg_r_shift;
    reg [4:0]   agg_cnt;
    reg [13:0]  page_no;
    reg         page_go;

    wire page_full = frame_event & (agg_cnt == AGG_FRAMES - 5'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            agg_l_shift <= 256'h0;
            agg_r_shift <= 256'h0;
            agg_cnt     <= 5'd0;
            page_go     <= 1'b0;
        end else begin
            page_go <= 1'b0;
            if (frame_event) begin
                agg_l_shift <= {agg_l_shift[239:0], frame_l};
                agg_r_shift <= {agg_r_shift[239:0], frame_r};
                if (agg_cnt == AGG_FRAMES - 5'd1) begin
                    agg_cnt <= 5'd0;
                    page_go <= 1'b1;
                end else begin
                    agg_cnt <= agg_cnt + 5'd1;
                end
            end
        end
    end

    reg [13:0] page_no_wr;
    reg        page_win_wr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page_no_wr  <= 14'd0;
            page_win_wr <= 1'b0;
        end else if (page_full) begin
            page_no_wr  <= page_no;
            page_win_wr <= win_id[0];
        end
    end

    wire [27:0] page_off = {page_no_wr[13:0], 5'b00000};

    reg [17:0] win_frame_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_frame_cnt <= 18'd0;
            win_tick      <= 1'b0;
            win_id        <= 16'd0;
            page_no       <= 14'd0;
        end else begin
            win_tick <= 1'b0;
            if (frame_event) begin
                if (win_frame_cnt == WIN_FRAMES - 18'd1) begin
                    win_frame_cnt <= 18'd0;
                    win_tick      <= 1'b1;
                    win_id        <= win_id + 16'd1;
                    page_no       <= 14'd0;
                end else begin
                    win_frame_cnt <= win_frame_cnt + 18'd1;

                    if (page_full) begin
                        if (page_no == PAGES_PER_WIN - 14'd1)
                            page_no <= 14'd0;
                        else
                            page_no <= page_no + 14'd1;
                    end
                end
            end
        end
    end

    localparam [1:0] ST_IDLE = 2'b00;
    localparam [1:0] ST_WL   = 2'b01;
    localparam [1:0] ST_WR   = 2'b10;

    reg [1:0]  wr_state;
    reg [22:0] wr_timeout_cnt;
    reg [15:0] err_cnt_r;

    wire [27:0] addr_left = PCM_L_BASE
                          + (page_win_wr ? WIN_BYTES : 28'h0)
                          + page_off;
    wire [27:0] addr_right = PCM_R_BASE + page_off;

    assign err_cnt = err_cnt_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state        <= ST_IDLE;
            m0_cmd_valid    <= 1'b0;
            m0_cmd          <= 37'h0;
            m0_wdata        <= 256'h0;
            wr_timeout_cnt  <= 23'd0;
            err_cnt_r       <= 16'd0;
        end else begin
            wr_timeout_cnt <= wr_timeout_cnt + 23'd1;
            case (wr_state)
                ST_IDLE: begin
                    if (page_go) begin
                        wr_state      <= ST_WL;
                        m0_cmd_valid  <= 1'b1;
                        m0_cmd        <= {1'b1, addr_left, 8'd0};
                        m0_wdata      <= agg_l_shift;
                        wr_timeout_cnt <= 23'd0;
                    end
                end
                ST_WL: begin
                    if (m0_done) begin
                        wr_state       <= ST_WR;
                        m0_cmd         <= {1'b1, addr_right, 8'd0};
                        m0_wdata       <= agg_r_shift;
                        wr_timeout_cnt <= 23'd0;
                    end else if (wr_timeout_cnt == WR_TIMEOUT_CYCLES - 23'd1) begin

                        wr_timeout_cnt <= 23'd0;
                        if (err_cnt_r != 16'hFFFF)
                            err_cnt_r <= err_cnt_r + 16'd1;
                    end
                end
                ST_WR: begin
                    if (m0_done) begin
                        wr_state      <= ST_IDLE;
                        m0_cmd_valid  <= 1'b0;
                        wr_timeout_cnt <= 23'd0;
                    end else if (wr_timeout_cnt == WR_TIMEOUT_CYCLES - 23'd1) begin

                        wr_timeout_cnt <= 23'd0;
                        if (err_cnt_r != 16'hFFFF)
                            err_cnt_r <= err_cnt_r + 16'd1;
                    end
                end
                default: begin
                    wr_state      <= ST_IDLE;
                    m0_cmd_valid  <= 1'b0;
                end
            endcase
        end
    end

    reg agg_freeze_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            agg_freeze_r <= 1'b0;
        else if (page_go)
            agg_freeze_r <= 1'b1;
        else if ((wr_state == ST_WR) && m0_done)
            agg_freeze_r <= 1'b0;
    end

    assign agg_freeze = agg_freeze_r;

    reg [8:0]  grp_cnt;
    reg [10:0] col_cnt;
    reg [15:0] cur_min;
    reg [15:0] cur_max;
    reg        page_wr;
    reg        page_done;
    reg        pending_page;

    wire col_end = (grp_cnt == GRP_BOUND_0 - 9'd1)
                || (grp_cnt == GRP_BOUND_1 - 9'd1)
                || (grp_cnt == GRP_BOUND_2 - 9'd1)
                || (grp_cnt == GRP_BOUND_3 - 9'd1)
                || (grp_cnt == GRP_LAST);

    wire sample_lt_min = ($signed(frame_l) < $signed(cur_min));
    wire sample_gt_max = ($signed(frame_l) > $signed(cur_max));

    wire page_complete = col_end & (col_cnt == COLS_PER_PAGE - 11'd1);

    reg [15:0] col_min_mem [0:3839];
    reg [15:0] col_max_mem [0:3839];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grp_cnt      <= 9'd0;
            col_cnt      <= 11'd0;
            cur_min      <= 16'h7FFF;
            cur_max      <= 16'h8000;
            page_wr      <= 1'b0;
            page_done    <= 1'b0;
            pending_page <= 1'b0;
        end else if (frame_event) begin

            if (sample_lt_min)
                cur_min <= frame_l;
            if (sample_gt_max)
                cur_max <= frame_l;
            if (grp_cnt == GRP_LAST)
                grp_cnt <= 9'd0;
            else
                grp_cnt <= grp_cnt + 9'd1;
            if (col_end) begin

                col_min_mem[{page_wr, col_cnt}] <= cur_min;
                col_max_mem[{page_wr, col_cnt}] <= cur_max;

                cur_min <= 16'h7FFF;
                cur_max <= 16'h8000;
                if (col_cnt == COLS_PER_PAGE - 11'd1) begin

                    col_cnt      <= 11'd0;
                    pending_page <= page_wr;
                    page_done    <= 1'b1;
                    page_wr      <= ~page_wr;
                end else begin
                    col_cnt <= col_cnt + 11'd1;
                end
            end
        end
    end

    reg vsync_meta;
    reg vsync_sync;
    reg vsync_sync_d;
    wire vsync_edge = vsync_sync & ~vsync_sync_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_meta   <= 1'b0;
            vsync_sync   <= 1'b0;
            vsync_sync_d <= 1'b0;
        end else begin
            vsync_meta   <= vsync_pulse;
            vsync_sync   <= vsync_meta;
            vsync_sync_d <= vsync_sync;
        end
    end

    reg page_rd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            page_rd <= 1'b0;
        else if (vsync_edge)
            page_rd <= pending_page;
    end

    always @(posedge pix_clk) begin
        wave_min <= col_min_mem[{page_rd, wave_rd_addr}];
        wave_max <= col_max_mem[{page_rd, wave_rd_addr}];
    end

    reg wave_valid_meta;
    reg wave_valid_pix;

    always @(posedge pix_clk) begin
        wave_valid_meta <= page_done;
        wave_valid_pix  <= wave_valid_meta;
    end

    assign wave_valid = wave_valid_pix;

    reg mute_sync_meta;
    reg mute_sync_pix;

    always @(posedge pix_clk) begin
        mute_sync_meta  <= mute_flag;
        mute_sync_pix   <= mute_sync_meta;
    end

    assign mute_flag_sync = mute_sync_pix;

endmodule
