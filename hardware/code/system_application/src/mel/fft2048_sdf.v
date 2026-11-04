`timescale 1ns / 1ps

module fft2048_sdf (

    input  wire        clk,
    input  wire        rst_n,

    input  wire        frame_start,
    output wire        in_ready,
    input  wire        in_valid,
    input  wire [16:0] in_s17,

    output reg         bin_valid,
    output reg  [10:0] bin_idx,
    output reg  [26:0] bin_re_s27,
    output reg  [26:0] bin_im_s27,
    output reg         frame_fft_done
);

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_LOAD  = 2'd1;
    localparam [1:0] ST_RUN   = 2'd2;
    localparam [1:0] ST_DRAIN = 2'd3;

    reg [1:0]  state;
    reg [11:0] ld_cnt;
    reg [11:0] run_cnt;
    reg [1:0]  ph2;

    wire load_active  = (state == ST_LOAD);
    wire run_active   = (state == ST_RUN);
    wire drain_active = (state == ST_DRAIN);
    wire beat_active  = run_active | drain_active;

    wire clr_n = load_active && in_valid && (ld_cnt == 12'd2047);

    assign in_ready = load_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            ld_cnt    <= 12'd0;
            run_cnt   <= 12'd0;
            ph2       <= 2'd0;
            frame_fft_done <= 1'b0;
        end else begin
            frame_fft_done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (frame_start) begin
                        state  <= ST_LOAD;
                        ld_cnt <= 12'd0;
                    end
                end
                ST_LOAD: begin
                    if (in_valid) begin
                        if (ld_cnt == 12'd2047) begin
                            state   <= ST_RUN;
                            run_cnt <= 12'd0;
                            ph2     <= 2'd0;
                        end else begin
                            ld_cnt <= ld_cnt + 12'd1;
                        end
                    end
                end
                ST_RUN: begin

                    if (ph2 == 2'd3) begin
                        ph2 <= 2'd0;
                        if (run_cnt == 12'd2047) begin
                            run_cnt <= 12'd2048;
                            state   <= ST_DRAIN;
                        end else begin
                            run_cnt <= run_cnt + 12'd1;
                        end
                    end else begin
                        ph2 <= ph2 + 2'd1;
                    end
                end
                ST_DRAIN: begin
                    if (ph2 == 2'd3) begin
                        ph2 <= 2'd0;
                        if (run_cnt == 12'd4095) begin
                            state <= ST_IDLE;
                            frame_fft_done <= 1'b1;
                            run_cnt <= 12'd0;
                        end else begin
                            run_cnt <= run_cnt + 12'd1;
                        end
                    end else begin
                        ph2 <= ph2 + 2'd1;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

    reg [17:0] in_buf [0:2047];

    function [10:0] bitrev11;
        input [10:0] v;
        begin
            bitrev11 = {v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7],
                        v[8], v[9], v[10]};
        end
    endfunction

    wire [10:0] in_rd_addr = bitrev11(run_cnt[10:0]);
    reg  [17:0] in_q_r;

    always @(posedge clk) begin
        if (load_active && in_valid)
            in_buf[ld_cnt[10:0]] <= {in_s17[16], in_s17};
    end

    always @(posedge clk) begin
        if (beat_active)
            in_q_r <= in_buf[in_rd_addr];
    end

    wire [31:0] tw_q    [1:10];
    wire [9:0]  tw_addr [1:10];

    tw_rom_s #(.AW(1),  .TW_FILE("src/mel/twiddle_s2.hex"))  u_tw_s2  (.clk(clk), .addr(tw_addr[1][0:0]),  .q(tw_q[1]));
    tw_rom_s #(.AW(2),  .TW_FILE("src/mel/twiddle_s3.hex"))  u_tw_s3  (.clk(clk), .addr(tw_addr[2][1:0]),  .q(tw_q[2]));
    tw_rom_s #(.AW(3),  .TW_FILE("src/mel/twiddle_s4.hex"))  u_tw_s4  (.clk(clk), .addr(tw_addr[3][2:0]),  .q(tw_q[3]));
    tw_rom_s #(.AW(4),  .TW_FILE("src/mel/twiddle_s5.hex"))  u_tw_s5  (.clk(clk), .addr(tw_addr[4][3:0]),  .q(tw_q[4]));
    tw_rom_s #(.AW(5),  .TW_FILE("src/mel/twiddle_s6.hex"))  u_tw_s6  (.clk(clk), .addr(tw_addr[5][4:0]),  .q(tw_q[5]));
    tw_rom_s #(.AW(6),  .TW_FILE("src/mel/twiddle_s7.hex"))  u_tw_s7  (.clk(clk), .addr(tw_addr[6][5:0]),  .q(tw_q[6]));
    tw_rom_s #(.AW(7),  .TW_FILE("src/mel/twiddle_s8.hex"))  u_tw_s7x (.clk(clk), .addr(tw_addr[7][6:0]),  .q(tw_q[7]));
    tw_rom_s #(.AW(8),  .TW_FILE("src/mel/twiddle_s9.hex"))  u_tw_s9  (.clk(clk), .addr(tw_addr[8][7:0]),  .q(tw_q[8]));
    tw_rom_s #(.AW(9),  .TW_FILE("src/mel/twiddle_s10.hex")) u_tw_s10 (.clk(clk), .addr(tw_addr[9][8:0]),  .q(tw_q[9]));
    tw_rom_s #(.AW(10), .TW_FILE("src/mel/twiddle_s11.hex")) u_tw_s11 (.clk(clk), .addr(tw_addr[10][9:0]), .q(tw_q[10]));

    wire [26:0] s_out_re [0:10];
    wire [26:0] s_out_im [0:10];
    wire        s_out_vld [0:10];

    wire samp_vld = beat_active;

    reg  [16:0] st0_dly;
    reg  [16:0] st0_d_r;
    reg  [16:0] s0_re_r;
    reg         s0_vld_r;

    wire signed [18:0] st0_rnd = 19'sd16384 - {{2{st0_d_r[16]}}, st0_d_r};
    wire signed [16:0] st0_pr  = st0_d_r + {{13{st0_rnd[18]}}, st0_rnd[18:15]};

    wire [17:0] st0_sum = {st0_dly[16], st0_dly} + {st0_pr[16], st0_pr};
    wire [17:0] st0_dif = {st0_dly[16], st0_dly} - {st0_pr[16], st0_pr};

    always @(posedge clk) begin
        if (ph2 == 2'd1)
            st0_d_r <= in_q_r[16:0];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st0_dly  <= 17'd0;
            s0_re_r  <= 17'd0;
            s0_vld_r <= 1'b0;
        end else if (ph2 == 2'd3) begin
            if (run_cnt[0]) begin

                s0_re_r <= st0_sum[16:0];
                st0_dly <= st0_dif[16:0];
            end else begin

                s0_re_r <= st0_dly;
                st0_dly <= st0_d_r;
            end
            s0_vld_r <= samp_vld;
        end
    end

    assign s_out_re[0]   = {{10{s0_re_r[16]}}, s0_re_r};
    assign s_out_im[0]   = 27'd0;
    assign s_out_vld[0]  = s0_vld_r;

    genvar k;
    generate
    for (k = 1; k <= 10; k = k + 1) begin : g_stage

        localparam integer IW = 16 + k;
        localparam integer OW = 17 + k;

        reg [10:0] n_cnt;

        localparam integer OFF_M   = (1 << k) + k - 1;
        localparam [10:0]  CNT_INIT = 11'd0 - OFF_M[10:0];

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                n_cnt <= CNT_INIT;
            else if (clr_n)
                n_cnt <= CNT_INIT;
            else if (ph2 == 2'd3)
                n_cnt <= n_cnt + 11'd1;
        end

        wire fly = n_cnt[k];

        reg [IW-1:0] d_re_r;
        reg [IW-1:0] d_im_r;

        wire [IW-1:0] prev_re = s_out_re[k-1][IW-1:0];
        wire [IW-1:0] prev_im = s_out_im[k-1][IW-1:0];

        always @(posedge clk) begin
            if (ph2 == 2'd0) begin
                d_re_r <= prev_re;
                d_im_r <= prev_im;
            end
        end

        reg [OW-1:0] dly_re [0:(1 << k) - 1];
        reg [OW-1:0] dly_im [0:(1 << k) - 1];

        wire [k-1:0] ram_addr = n_cnt[k-1:0];
        reg  [OW-1:0] ram_q_re;
        reg  [OW-1:0] ram_q_im;

        always @(posedge clk) begin
            ram_q_re <= dly_re[ram_addr];
            ram_q_im <= dly_im[ram_addr];
        end

        assign tw_addr[k] = {{(10-k){1'b0}}, n_cnt[k-1:0]};

        wire signed [15:0] tw_re = tw_q[k][15:0];
        wire signed [15:0] tw_im = tw_q[k][31:16];

        localparam integer SH = (k >= 2) ? (k - 2) : 0;

        localparam [8:0] LO_MASK =
            ((9'd1 << ((k >= 2) ? (k - 2) : 0)) - ((k >= 2) ? 9'd1 : 9'd0));

        wire signed [17:0] d_hi_re;
        wire signed [17:0] d_hi_im;
        wire [8:0] d_lo_re;
        wire [8:0] d_lo_im;

        if (k == 1) begin : g_split_hi
            assign d_hi_re = {d_re_r[16], d_re_r};
            assign d_hi_im = {d_im_r[16], d_im_r};
            assign d_lo_re = 9'd0;
            assign d_lo_im = 9'd0;
        end else begin : g_split_lo
            assign d_hi_re = d_re_r[IW-1:k-2];
            assign d_hi_im = d_im_r[IW-1:k-2];
            assign d_lo_re = d_re_r[8:0] & LO_MASK;
            assign d_lo_im = d_im_r[8:0] & LO_MASK;
        end

        wire signed [17:0] apm_d = (ph2 == 2'd1) ? d_hi_re : d_hi_im;

        wire signed [33:0] m_a = tw_re * apm_d;
        wire signed [33:0] m_b = tw_im * apm_d;

        reg signed [33:0] m_rr;
        reg signed [33:0] m_ir;
        reg signed [33:0] m_ri;
        reg signed [33:0] m_ii;

        always @(posedge clk) begin
            if (ph2 == 2'd1) begin
                m_rr <= m_a;
                m_ir <= m_b;
            end else if (ph2 == 2'd2) begin
                m_ri <= m_a;
                m_ii <= m_b;
            end
        end

        function signed [24:0] mul_lo;
            input signed [15:0] a;
            input [8:0] b;
            integer i;
            reg signed [24:0] acc;
            begin
                acc = 25'sd0;
                for (i = 0; i < 9; i = i + 1)
                    if (b[i])
                        acc = acc + ({{9{a[15]}}, a} <<< i);
                mul_lo = acc;
            end
        endfunction

        reg signed [24:0] lo_rr;
        reg signed [24:0] lo_ir;
        reg signed [24:0] lo_ri;
        reg signed [24:0] lo_ii;

        always @(posedge clk) begin
            if (ph2 == 2'd1) begin
                lo_rr <= mul_lo(tw_re, d_lo_re);
                lo_ir <= mul_lo(tw_im, d_lo_re);
                lo_ri <= mul_lo(tw_re, d_lo_im);
                lo_ii <= mul_lo(tw_im, d_lo_im);
            end
        end

        wire signed [45:0] pr_full =
              ({{12{m_rr[33]}}, m_rr} <<< SH) + {{21{lo_rr[24]}}, lo_rr}
            - ({{12{m_ii[33]}}, m_ii} <<< SH) - {{21{lo_ii[24]}}, lo_ii};
        wire signed [45:0] pi_full =
              ({{12{m_ri[33]}}, m_ri} <<< SH) + {{21{lo_ri[24]}}, lo_ri}
            + ({{12{m_ir[33]}}, m_ir} <<< SH) + {{21{lo_ir[24]}}, lo_ir};

        wire signed [45:0] pr_hu = pr_full + 46'sd16384;
        wire signed [45:0] pi_hu = pi_full + 46'sd16384;

        wire signed [IW-1:0] p_re = pr_hu[15+IW-1:15];
        wire signed [IW-1:0] p_im = pi_hu[15+IW-1:15];

        wire signed [OW-1:0] a_r = ram_q_re;
        wire signed [OW-1:0] ai_r = ram_q_im;
        wire signed [OW-1:0] sum_re = a_r + p_re;
        wire signed [OW-1:0] dif_re = a_r - p_re;
        wire signed [OW-1:0] sum_im = ai_r + p_im;
        wire signed [OW-1:0] dif_im = ai_r - p_im;

        reg [OW-1:0] s_re_r;
        reg [OW-1:0] s_im_r;
        reg          s_vld_r;

        wire prev_vld = s_out_vld[k-1];

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                s_re_r  <= {OW{1'b0}};
                s_im_r  <= {OW{1'b0}};
                s_vld_r <= 1'b0;
            end else if (ph2 == 2'd3) begin
                if (fly) begin
                    s_re_r  <= sum_re;
                    s_im_r  <= sum_im;
                    dly_re[ram_addr] <= dif_re;
                    dly_im[ram_addr] <= dif_im;
                end else begin
                    s_re_r  <= a_r;
                    s_im_r  <= ai_r;
                    dly_re[ram_addr] <= {{(OW-IW){d_re_r[IW-1]}}, d_re_r};
                    dly_im[ram_addr] <= {{(OW-IW){d_im_r[IW-1]}}, d_im_r};
                end
                s_vld_r <= prev_vld;
            end
        end

        assign s_out_re[k]  = {{(27-OW){s_re_r[OW-1]}}, s_re_r};
        assign s_out_im[k]  = {{(27-OW){s_im_r[OW-1]}}, s_im_r};
        assign s_out_vld[k] = s_vld_r;

    end
    endgenerate

    localparam [11:0] BIN_FIRST_RUN = 12'd2058;
    localparam [11:0] BIN_LAST_RUN  = 12'd3082;

    wire [26:0] last_re  = s_out_re[10];
    wire [26:0] last_im  = s_out_im[10];
    wire        last_vld = s_out_vld[10];
    wire        bin_beat = last_vld && (ph2 == 2'd3)
                         && (run_cnt >= BIN_FIRST_RUN)
                         && (run_cnt <= BIN_LAST_RUN);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin_valid  <= 1'b0;
            bin_idx    <= 11'd0;
            bin_re_s27 <= 27'd0;
            bin_im_s27 <= 27'd0;
        end else begin
            bin_valid <= 1'b0;
            if (bin_beat) begin
                bin_valid  <= 1'b1;
                bin_idx    <= run_cnt - BIN_FIRST_RUN;
                bin_re_s27 <= last_re;
                bin_im_s27 <= last_im;
            end
        end
    end

endmodule
