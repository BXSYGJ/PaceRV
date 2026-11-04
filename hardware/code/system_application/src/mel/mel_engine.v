`timescale 1ns / 1ps

module mel_engine #(

    parameter         HAN_HEX_FILE = "hann_q15.hex",
    parameter         COO_HEX_FILE = "mel_coo.hex",
    parameter         LUT_HEX_FILE = "log2_lut.hex",

    parameter [27:0]  SPEC_EX_BASE = 28'h0020_0000,

    parameter integer WATCHDOG_LIMIT = 25_000_000
) (

    input  wire        clk,
    input  wire        rst_n,

    input  wire        win_tick,
    input  wire [15:0] win_id,

    output reg         m2_cmd_valid,
    output reg  [36:0] m2_cmd,
    output reg  [255:0] m2_wdata,
    input  wire        m2_wready,
    input  wire        m2_rd_valid,
    output wire        m2_rd_ready,
    input  wire [255:0] m2_rd_data,
    input  wire        m2_done,

    output reg         npu_start,
    output reg         feat_page,
    input  wire [14:0] feat_rd_addr,
    output wire [7:0]  feat_rd_data,

    output reg         mel_done,
    output reg  [31:0] mel_cycles,
    output reg         mel_timeout,
    output reg         win_miss,
    output wire        busy
);

    localparam integer PCM_WIN_SAMPLES = 132096;
    localparam integer PCM_SAMPLE_BYTES = 2;
    localparam integer PCM_CMD_SAMPLES = 256;
    localparam integer PCM_CMD_COUNT   = 516;
    localparam [27:0]  PCM_WIN_STRIDE = 28'h0008_4000;
    localparam integer FILL_CREDIT    = 1280;
    localparam integer HOP_CREDIT     = 512;
    localparam integer SPEC_ELEMS     = 16512;
    localparam integer SPEC_PHYS_BASE = 64;
    localparam [14:0]  SPEC_LAST_WORD = 15'd16575;

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_RUN    = 3'd1;
    localparam [2:0] ST_DB     = 3'd2;
    localparam [2:0] ST_SPECEX = 3'd3;
    localparam [2:0] ST_STD    = 3'd4;
    localparam [2:0] ST_DONE   = 3'd5;

    reg [2:0]  state;
    reg [27:0] win_base;
    reg [8:0]  frm_out;
    reg        stats_seen;

    wire run_active   = (state == ST_RUN);
    wire db_active    = (state == ST_DB);
    wire ex_active    = (state == ST_SPECEX);
    wire std_active   = (state == ST_STD);

    assign busy = (state != ST_IDLE);

    wire        fr_busy, fr_all_done, fr_frame_last;
    wire [16:0] fr_win_s17;
    wire        fr_win_valid, fr_frame_start, fr_frame_done;
    wire [8:0]  fr_frame_idx;

    reg         pcm_feed_valid;
    reg  [31:0] pcm_feed_data;
    wire        pcm_feed_ready;

    stft_framer #(
        .HAN_HEX_FILE (HAN_HEX_FILE)
    ) u_stft_framer (
        .clk           (clk),
        .rst_n         (rst_n),
        .win_start     (win_start_pulse),
        .busy          (fr_busy),
        .all_done      (fr_all_done),
        .out_ready     (fft_idle),
        .pcm_rd_data   (pcm_feed_data),
        .pcm_rd_valid  (pcm_feed_valid),
        .pcm_rd_ready  (pcm_feed_ready),
        .win_s17       (fr_win_s17),
        .win_valid     (fr_win_valid),
        .frame_start   (fr_frame_start),
        .frame_done    (fr_frame_done),
        .frame_last    (fr_frame_last),
        .frame_idx     (fr_frame_idx)
    );

    wire        fft_in_ready;
    wire        bin_valid;
    wire [10:0] bin_idx;
    wire [26:0] bin_re_s27, bin_im_s27;
    wire        frame_fft_done;

    reg fft_busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              fft_busy <= 1'b0;
        else if (frame_fft_done) fft_busy <= 1'b0;
        else if (fr_frame_start) fft_busy <= 1'b1;
    end
    wire fft_idle = !fft_busy;

    reg        win_v_d;
    reg [16:0] win_s17_d;
    always @(posedge clk) begin
        win_v_d   <= fr_win_valid;
        win_s17_d <= fr_win_s17;
    end

    fft2048_sdf u_fft2048_sdf (
        .clk           (clk),
        .rst_n         (rst_n),
        .frame_start   (fr_frame_start),
        .in_ready      (fft_in_ready),
        .in_valid      (win_v_d),
        .in_s17        (win_s17_d),
        .bin_valid     (bin_valid),
        .bin_idx       (bin_idx),
        .bin_re_s27    (bin_re_s27),
        .bin_im_s27    (bin_im_s27),
        .frame_fft_done(frame_fft_done)
    );

    wire        mel_valid;
    wire [5:0]  mel_ch;
    wire signed [15:0] mel_q88;
    wire        frame_mel_done;

    mel_filter #(
        .COO_HEX_FILE  (COO_HEX_FILE),
        .LUT_HEX_FILE  (LUT_HEX_FILE)
    ) u_mel_filter (
        .clk           (clk),
        .rst_n         (rst_n),
        .bin_valid     (bin_valid),
        .bin_idx       (bin_idx),
        .bin_re_s27    (bin_re_s27),
        .bin_im_s27    (bin_im_s27),
        .frame_fft_done(frame_fft_done),
        .mel_valid     (mel_valid),
        .mel_ch        (mel_ch),
        .mel_q88       (mel_q88),
        .frame_mel_done(frame_mel_done)
    );

    wire        db_busy, db_stats_valid;
    wire        db_spec_rd_en;
    wire [14:0] db_spec_rd_addr;
    wire        db_wr_en;
    wire [14:0] db_wr_addr;
    wire signed [15:0] db_wr_data;
    wire signed [47:0] sum_db;
    wire [47:0]  sum_db_sq;

    db_norm u_db_norm (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (db_start_pulse),
        .busy          (db_busy),
        .spec_rd_en    (db_spec_rd_en),
        .spec_rd_addr  (db_spec_rd_addr),
        .spec_rd_data  (bank_q),
        .db_wr_en      (db_wr_en),
        .db_wr_addr    (db_wr_addr),
        .db_wr_data    (db_wr_data),
        .sum_db        (sum_db),
        .sum_db_sq     (sum_db_sq),
        .stats_valid   (db_stats_valid)
    );

    wire        std_busy, std_feat_done;
    wire        std_db_rd_en;
    wire [14:0] std_db_rd_addr;
    wire        std_feat_wr_en;
    wire [14:0] std_feat_wr_addr;
    wire [7:0]  std_feat_wr_data;

    wire        std_feat_valid;

    standardize u_standardize (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (std_start_pulse),
        .busy          (std_busy),
        .sum_db        (sum_db),
        .sum_db_sq     (sum_db_sq),
        .db_rd_en      (std_db_rd_en),
        .db_rd_addr    (std_db_rd_addr),
        .db_rd_data    (bank_q),
        .feat_valid    (std_feat_valid),
        .feat_wr_en    (std_feat_wr_en),
        .feat_wr_addr  (std_feat_wr_addr),
        .feat_wr_data  (std_feat_wr_data),
        .feat_done     (std_feat_done)
    );

    reg [15:0] spec_bank_lo [0:16383];
    reg [15:0] spec_bank_hi [0:191];
    reg [15:0] bank_q_lo, bank_q_hi;
    reg bank_hi_q;
    wire [15:0] bank_q = bank_hi_q ? bank_q_hi : bank_q_lo;
    reg bank_we;
    reg [14:0] bank_wa;
    reg [15:0] bank_wd;

    reg [14:0] bank_ra;

    always @* begin
        bank_ra = 15'd0;
        if (db_active)
            bank_ra = db_spec_rd_addr;
        else if (std_active)
            bank_ra = std_db_rd_addr;
        else if (ex_active)
            bank_ra = ex_rd_addr;
        else
            bank_ra = {1'b0, feat_rd_addr} + 15'd64;
    end

    always @(posedge clk) begin
        bank_q_lo <= spec_bank_lo[bank_ra[13:0]];
        bank_q_hi <= spec_bank_hi[bank_ra[7:0]];
        bank_hi_q <= bank_ra[14];
    end

    always @* begin
        bank_we = 1'b0;
        bank_wa = 15'd0;
        bank_wd = 16'd0;
        if (run_active && mel_valid) begin
            bank_we = 1'b1;
            bank_wa = {frm_out, mel_ch};
            bank_wd = mel_q88;
        end else if (db_active && db_wr_en) begin
            bank_we = 1'b1;
            bank_wa = db_wr_addr;
            bank_wd = db_wr_data;
        end else if (std_active && std_feat_wr_en) begin
            bank_we = 1'b1;
            bank_wa = {1'b0, std_feat_wr_addr} + 15'd64;
            bank_wd = {8'h00, std_feat_wr_data};
        end
    end
    always @(posedge clk) begin
        if (bank_we && !bank_wa[14])
            spec_bank_lo[bank_wa[13:0]] <= bank_wd;
        if (bank_we && bank_wa[14])
            spec_bank_hi[bank_wa[7:0]] <= bank_wd;
    end

    assign feat_rd_data = bank_q[7:0];

    reg win_start_pulse, db_start_pulse, std_start_pulse;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_start_pulse <= 1'b0;
            db_start_pulse  <= 1'b0;
            std_start_pulse <= 1'b0;
        end else begin
            win_start_pulse <= (state == ST_IDLE) && win_tick;

            db_start_pulse  <= run_active && frame_mel_done
                               && (frm_out == 9'd258);

            std_start_pulse <= ex_active && ex_fin;
        end
    end

    localparam [1:0] PC_IDLE = 2'd0;
    localparam [1:0] PC_CMD  = 2'd1;
    localparam [1:0] PC_BEAT = 2'd2;
    localparam [1:0] PC_FEED = 2'd3;

    reg [1:0]     pc_state;
    reg [9:0]     pc_cmd_cnt;
    reg [4:0]     pc_beat_cnt;
    reg [255:0]   pc_beat_buf;
    reg [3:0]     pc_samp_ph;
    reg [18:0]    pc_credit;

    wire pc_issue = run_active && (pc_state == PC_IDLE)
                    && (pc_cmd_cnt < PCM_CMD_COUNT)
                    && (pc_credit >= PCM_CMD_SAMPLES);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_credit <= 19'd0;
        end else if ((state == ST_IDLE) && win_tick) begin
            pc_credit <= FILL_CREDIT[18:0];
        end else begin
            pc_credit <= pc_credit + (frame_fft_done ? HOP_CREDIT[18:0] : 19'd0)
                              - (pc_issue ? PCM_CMD_SAMPLES[18:0] : 19'd0);
        end
    end

    wire [27:0] pc_cmd_addr = win_base + {18'd0, pc_cmd_cnt, 9'd0};

    wire [15:0] pc_lane = pc_beat_buf[{pc_samp_ph, 4'd0} +: 16];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_state    <= PC_IDLE;
            pc_cmd_cnt  <= 10'd0;
            pc_beat_cnt <= 5'd0;
            pc_beat_buf <= 256'd0;
            pc_samp_ph  <= 4'd0;
        end else if ((state == ST_IDLE) && win_tick) begin
            pc_state    <= PC_IDLE;
            pc_cmd_cnt  <= 10'd0;
            pc_beat_cnt <= 5'd0;
            pc_samp_ph  <= 4'd0;
        end else begin
            case (pc_state)
                PC_IDLE: begin
                    if (pc_issue) begin
                        pc_state <= PC_CMD;
                    end
                end
                PC_CMD: begin
                    if (m2_done) begin
                        pc_state    <= PC_BEAT;
                        pc_beat_cnt <= 5'd0;
                    end
                end
                PC_BEAT: begin
                    if (m2_rd_valid) begin
                        pc_beat_buf <= m2_rd_data;
                        pc_state    <= PC_FEED;
                        pc_samp_ph  <= 4'd0;
                    end
                end
                PC_FEED: begin
                    if (pcm_feed_ready) begin
                        if (pc_samp_ph == 4'd15) begin
                            if (pc_beat_cnt == 5'd15) begin
                                pc_cmd_cnt  <= pc_cmd_cnt + 10'd1;
                                pc_state    <= PC_IDLE;
                            end else begin
                                pc_beat_cnt <= pc_beat_cnt + 5'd1;
                                pc_state    <= PC_BEAT;
                            end
                        end else begin
                            pc_samp_ph <= pc_samp_ph + 4'd1;
                        end
                    end
                end
                default: begin
                    pc_state <= PC_IDLE;
                end
            endcase
        end
    end

    always @* begin
        pcm_feed_valid = (pc_state == PC_FEED);
        pcm_feed_data  = {16'd0, pc_lane};
    end

    assign m2_rd_ready = (pc_state == PC_BEAT);

    localparam [1:0] EX_READ = 2'd0;
    localparam [1:0] EX_CMD  = 2'd1;
    localparam [1:0] EX_FIN  = 2'd2;

    reg [1:0]   ex_state;
    reg [14:0]  ex_elem;
    reg [4:0]   ex_ph;
    reg [255:0] ex_shift;

    wire ex_last_group = (ex_elem == 15'd16496);
    wire ex_fin = (ex_state == EX_FIN);

    wire [14:0] ex_rd_addr = {1'b0, ex_elem} + 15'd64
                             + (15 - ex_ph[3:0]);

    wire [27:0] ex_cmd_addr = SPEC_EX_BASE + {13'd0, ex_elem, 1'b0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_state <= EX_READ;
            ex_elem  <= 15'd0;
            ex_ph    <= 5'd0;
            ex_shift <= 256'd0;
        end else if (std_start_pulse) begin

            ex_state <= EX_READ;
            ex_elem  <= 15'd0;
        end else if (ex_active) begin
            case (ex_state)
                EX_READ: begin

                    if (ex_ph < 5'd16) begin
                        if (ex_ph > 5'd0)
                            ex_shift <= {ex_shift[239:0], bank_q};
                        ex_ph <= ex_ph + 5'd1;
                    end else begin
                        ex_shift <= {ex_shift[239:0], bank_q};
                        ex_ph    <= 5'd0;
                        ex_state <= EX_CMD;
                    end
                end
                EX_CMD: begin
                    if (m2_done) begin
                        if (ex_last_group) begin
                            ex_state <= EX_FIN;
                        end else begin
                            ex_elem  <= ex_elem + 15'd16;
                            ex_state <= EX_READ;
                        end
                    end
                end
                default: begin
                    ex_state <= EX_FIN;
                end
            endcase
        end
    end

    wire ex_cmd_valid = ex_active && (ex_state == EX_CMD);

    always @* begin
        m2_cmd_valid = 1'b0;
        m2_cmd       = 37'd0;
        m2_wdata     = 256'd0;
        if (run_active && (pc_state == PC_CMD)) begin
            m2_cmd_valid = 1'b1;
            m2_cmd       = {1'b0, pc_cmd_addr, 8'd15};
        end else if (ex_cmd_valid) begin
            m2_cmd_valid = 1'b1;
            m2_cmd       = {1'b1, ex_cmd_addr, 8'd0};
            m2_wdata     = ex_shift;
        end
    end

    reg [24:0] wd_cnt;
    reg [31:0] mel_cycle_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            win_base    <= 28'd0;
            frm_out     <= 9'd0;
            stats_seen  <= 1'b0;
            win_miss    <= 1'b0;
            mel_timeout <= 1'b0;
            mel_done    <= 1'b0;
            npu_start   <= 1'b0;
            feat_page   <= 1'b0;
            mel_cycles  <= 32'd0;
            mel_cycle_cnt <= 32'd0;
            wd_cnt      <= 25'd0;
        end else begin
            mel_done  <= 1'b0;
            npu_start <= 1'b0;
            if (win_tick && (state != ST_IDLE)) begin
                win_miss <= 1'b1;
            end

            if (state != ST_IDLE) begin
                if (wd_cnt < WATCHDOG_LIMIT[24:0]) begin
                    wd_cnt <= wd_cnt + 25'd1;
                end else begin
                    mel_timeout <= 1'b1;
                end
            end else begin
                wd_cnt <= 25'd0;
            end

            if (state != ST_IDLE) begin
                mel_cycle_cnt <= mel_cycle_cnt + 32'd1;
            end
            case (state)
                ST_IDLE: begin
                    if (win_tick) begin
                        state    <= ST_RUN;
                        win_base <= win_id[0] ? PCM_WIN_STRIDE : 28'd0;
                        frm_out  <= 9'd0;
                        stats_seen <= 1'b0;
                        mel_cycle_cnt <= 32'd0;
                    end
                end
                ST_RUN: begin
                    if (frame_mel_done) begin
                        frm_out <= frm_out + 9'd1;
                    end
                    if (db_start_pulse) begin
                        state <= ST_DB;
                    end
                end
                ST_DB: begin
                    if (db_stats_valid) begin
                        stats_seen <= 1'b1;
                        state      <= ST_SPECEX;
                    end
                end
                ST_SPECEX: begin
                    if (ex_fin) begin
                        state <= ST_STD;
                    end
                end
                ST_STD: begin
                    if (std_feat_done) begin
                        state <= ST_DONE;
                    end
                end
                ST_DONE: begin
                    mel_done      <= 1'b1;
                    npu_start     <= 1'b1;
                    feat_page     <= ~feat_page;
                    mel_cycles    <= mel_cycle_cnt;
                    state         <= ST_IDLE;
                end
                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
