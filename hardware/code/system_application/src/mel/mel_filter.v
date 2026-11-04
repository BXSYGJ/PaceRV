`timescale 1ns / 1ps

module mel_filter #(

    parameter COO_HEX_FILE = "mel_coo.hex",
    parameter LUT_HEX_FILE = "log2_lut.hex"
) (

    input  wire        clk,
    input  wire        rst_n,

    input  wire        bin_valid,
    input  wire [10:0] bin_idx,
    input  wire [26:0] bin_re_s27,
    input  wire [26:0] bin_im_s27,
    input  wire        frame_fft_done,

    output reg         mel_valid,
    output reg  [5:0]  mel_ch,
    output reg signed [15:0] mel_q88,
    output reg         frame_mel_done
);

    localparam [10:0] COO_E_OFF = 11'd65;

    reg [26:0] coo_rom [0:2024];
    reg  [7:0] log2_lut [0:255];

    initial begin
        $readmemh(COO_HEX_FILE, coo_rom);
        $readmemh(LUT_HEX_FILE, log2_lut);
    end

    reg [47:0] pwr_ram [0:1023];

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_PWR   = 3'd1;
    localparam [2:0] ST_ROFF  = 3'd2;
    localparam [2:0] ST_MAC   = 3'd3;
    localparam [2:0] ST_FLUSH = 3'd4;
    localparam [2:0] ST_L2D   = 3'd5;

    reg [2:0]  state;
    reg [10:0] bin_cnt;
    reg [5:0]  ch;
    reg [11:0] e_idx;
    reg [11:0] off_lo;
    reg [11:0] off_hi;
    reg [1:0]  roff_ph;
    reg [2:0]  fl_cnt;
    reg        done_seen;

    wire pwr_active  = (state == ST_PWR);
    wire mac_active  = (state == ST_MAC);
    wire flush_active = (state == ST_FLUSH);

    reg [26:0] re_r, im_r;
    reg [10:0] bin_r;
    reg [1:0]  pw_ph;
    reg        pw_run;

    reg signed [17:0] apm_a, apm_b, apm_c, apm_d;

    reg signed [35:0] sq_hi_re_r, sq_hi_im_r;
    reg signed [35:0] cross_re_r, cross_im_r;
    reg signed [35:0] sq_lo_re_r, sq_lo_im_r;

    wire signed [35:0] sq_hi_sum = sq_hi_re_r + sq_hi_im_r;
    wire signed [27:0] cross_sum = cross_re_r + cross_im_r;
    wire signed [19:0] sq_lo_sum = sq_lo_re_r + sq_lo_im_r;

    wire signed [53:0] pwr_sum_s =
        (sq_hi_sum <<< 18) + (cross_sum <<< 10) + sq_lo_sum;
    wire signed [53:0] pwr_rnd = pwr_sum_s + 54'sd512;
    wire [47:0] p_s48 = {4'b0, pwr_rnd[53:10]};

    reg signed [35:0] apm_ya_r, apm_yc_r;
    always @(posedge clk) begin
        apm_ya_r <= apm_a * apm_b;
        apm_yc_r <= apm_c * apm_d;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            re_r    <= 27'd0;
            im_r    <= 27'd0;
            bin_r   <= 11'd0;
            pw_ph   <= 2'd0;
            pw_run  <= 1'b0;
        end else begin
            if (pwr_active && bin_valid) begin

                re_r   <= bin_re_s27;
                im_r   <= bin_im_s27;
                bin_r  <= bin_idx;
                pw_ph  <= 2'd0;
                pw_run <= 1'b1;
            end else if (pw_run) begin
                if (pw_ph == 2'd3) begin

                    pw_run <= bin_valid ? 1'b1 : 1'b0;
                    pw_ph  <= 2'd0;
                end else begin
                    pw_ph <= pw_ph + 2'd1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (pwr_active || pw_run) begin
            if (pwr_active && bin_valid) begin

            end else if (pw_run && pw_ph == 2'd0) begin
                sq_hi_re_r <= apm_ya_r;
                sq_hi_im_r <= apm_yc_r;
            end else if (pw_run && pw_ph == 2'd1) begin
                cross_re_r <= apm_ya_r;
                cross_im_r <= apm_yc_r;
            end else if (pw_run && pw_ph == 2'd2) begin
                sq_lo_re_r <= apm_ya_r;
                sq_lo_im_r <= apm_yc_r;
            end
        end
        if (pw_run && pw_ph == 2'd3) begin

            pwr_ram[bin_r[9:0]] <= p_s48;
        end
    end

    reg [26:0] q_ent;
    reg signed [15:0] q_w;
    reg signed [15:0] q_w_d;
    reg [47:0] q_p;
    reg        f1_v, f2_v, f3_v, f4_v, f5_v;
    reg [65:0] acc;
    reg [59:0] prod_r;

    wire [6:0]  rom_ch = {1'b0, ch} + ((roff_ph == 2'd0) ? 7'd0 : 7'd1);
    wire [10:0] rom_ra = (state == ST_ROFF)
                       ? {4'b0, rom_ch}
                       : (COO_E_OFF + e_idx[10:0]);
    wire [26:0] rom_q = coo_rom[rom_ra];

    wire [9:0] ram_ra = q_ent[25:16];
    reg [47:0] pwr_q;
    always @(posedge clk) begin
        pwr_q <= pwr_ram[ram_ra];
    end

    wire signed [17:0] w_sext18 = {{2{q_w_d[15]}}, q_w_d};

    wire mac_pipe_f3 = (mac_active || flush_active) && f3_v;

    always @* begin
        apm_a = 18'sd0;
        apm_b = 18'sd0;
        apm_c = 18'sd0;
        apm_d = 18'sd0;
        if (pwr_active && bin_valid) begin

            apm_a = bin_re_s27[26:9];
            apm_b = bin_re_s27[26:9];
            apm_c = bin_im_s27[26:9];
            apm_d = bin_im_s27[26:9];
        end else if (pwr_active && pw_run && pw_ph == 2'd0) begin

            apm_a = re_r[26:9];
            apm_b = {9'b0, re_r[8:0]};
            apm_c = im_r[26:9];
            apm_d = {9'b0, im_r[8:0]};
        end else if (pwr_active && pw_run && pw_ph == 2'd1) begin

            apm_a = {9'b0, re_r[8:0]};
            apm_b = {9'b0, re_r[8:0]};
            apm_c = {9'b0, im_r[8:0]};
            apm_d = {9'b0, im_r[8:0]};
        end else if (mac_pipe_f3) begin

            apm_a = {1'b0, q_p[42:26]};
            apm_b = w_sext18;
            apm_c = {1'b0, q_p[25:9]};
            apm_d = w_sext18;
        end
    end

    function signed [24:0] mul_lo9x16;
        input signed [15:0] a;
        input [8:0] b;
        integer i;
        reg signed [24:0] a_acc;
        begin
            a_acc = 25'sd0;
            for (i = 0; i < 9; i = i + 1)
                if (b[i])
                    a_acc = a_acc + ({{9{a[15]}}, a} <<< i);
            mul_lo9x16 = a_acc;
        end
    endfunction

    wire signed [24:0] lo_prod = mul_lo9x16(q_w_d, q_p[8:0]);
    reg  signed [24:0] lo_r;

    wire [31:0] ya_u = apm_ya_r[31:0];
    wire [31:0] yc_u = apm_yc_r[31:0];
    wire [59:0] prod_comb = {ya_u, 26'b0}
                          + {27'b0, yc_u, 9'b0}
                          + {35'b0, lo_r};

    wire f0_issue = mac_active && (e_idx < off_hi);
    wire flush_clear = flush_active && (fl_cnt == 3'd4);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_ent <= 27'd0;
            q_p   <= 48'd0;
            q_w   <= 16'sd0;
            q_w_d <= 16'sd0;
            lo_r  <= 25'sd0;
            prod_r<= 60'd0;
            f1_v  <= 1'b0;
            f2_v  <= 1'b0;
            f3_v  <= 1'b0;
            f4_v  <= 1'b0;
            f5_v  <= 1'b0;
            acc   <= 66'd0;
        end else begin

            if (f0_issue) begin
                q_ent <= rom_q;
            end
            f1_v <= f0_issue;

            if (f1_v) begin
                q_w <= q_ent[15:0];
            end
            f2_v <= f1_v;

            if (f2_v) begin
                q_p   <= pwr_q;
                q_w_d <= q_w;
            end
            f3_v <= f2_v;

            if (f3_v) begin
                lo_r <= lo_prod;
            end
            f4_v <= f3_v;

            if (f4_v) begin
                prod_r <= prod_comb;
            end
            f5_v <= f4_v;

            if (f5_v) begin
                acc <= acc + prod_r;
            end else if (flush_clear) begin
                acc <= 66'd0;
            end
        end
    end

    reg [65:0] l2_acc;
    reg [5:0]  l2_ch;
    reg [6:0]  l2_e;
    reg [8:0]  l2_mant;
    reg [7:0]  l2_lut;
    reg [2:0]  l2_ph;
    reg        l2_run;

    wire l2_start = flush_clear;

    reg [6:0] lzc_e;
    integer bi;
    always @* begin
        lzc_e = 7'd0;
        for (bi = 0; bi < 66; bi = bi + 1)
            if (l2_acc[bi])
                lzc_e = 7'd0 + bi;
    end

    wire [65:0] l2_sh_hi = l2_acc >> (l2_e - 7'd8);
    wire [65:0] l2_sh_lo = l2_acc << (7'd8 - l2_e);
    wire [8:0]  l2_mant_mux = (l2_e >= 7'd8) ? l2_sh_hi[8:0]
                                             : l2_sh_lo[8:0];

    wire signed [15:0] l2_exp_term = ($signed({1'b0, l2_e}) - 8'sd56) <<< 8;
    wire signed [15:0] l2_q88_comb = l2_exp_term + $signed({8'b0, l2_lut});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_acc  <= 66'd0;
            l2_ch   <= 6'd0;
            l2_e    <= 7'd0;
            l2_mant <= 9'd0;
            l2_lut  <= 8'd0;
            l2_ph   <= 3'd0;
            l2_run  <= 1'b0;
            mel_valid <= 1'b0;
            mel_ch    <= 6'd0;
            mel_q88   <= 16'sd0;
        end else begin
            mel_valid <= 1'b0;
            if (l2_start) begin
                l2_acc <= acc;
                l2_ch  <= ch;
                l2_ph  <= 3'd0;
                l2_run <= 1'b1;
            end else if (l2_run) begin
                case (l2_ph)
                    3'd0: begin
                        l2_e   <= lzc_e;
                        l2_ph  <= 3'd1;
                    end
                    3'd1: begin
                        l2_mant <= l2_mant_mux;
                        l2_ph   <= 3'd2;
                    end
                    3'd2: begin
                        l2_lut <= log2_lut[l2_mant[7:0]];
                        l2_ph  <= 3'd3;
                    end
                    3'd3: begin
                        mel_q88   <= l2_q88_comb;
                        mel_ch    <= l2_ch;
                        mel_valid <= 1'b1;
                        l2_ph     <= 3'd4;
                    end
                    3'd4: begin
                        l2_run <= 1'b0;
                    end
                endcase
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            bin_cnt  <= 11'd0;
            ch       <= 6'd0;
            e_idx    <= 12'd0;
            off_lo   <= 12'd0;
            off_hi   <= 12'd0;
            roff_ph  <= 2'd0;
            fl_cnt   <= 3'd0;
            done_seen<= 1'b0;
            frame_mel_done <= 1'b0;
        end else begin
            frame_mel_done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (bin_valid) begin
                        state <= ST_PWR;
                        bin_cnt <= 11'd1;
                        done_seen <= 1'b0;
                    end
                end
                ST_PWR: begin
                    if (bin_valid) begin
                        bin_cnt <= bin_cnt + 11'd1;
                    end
                    if (frame_fft_done) begin
                        done_seen <= 1'b1;
                    end
                    if (done_seen && !pw_run && !bin_valid) begin
                        state   <= ST_ROFF;
                        ch      <= 6'd0;
                        roff_ph <= 2'd0;
                    end
                end
                ST_ROFF: begin
                    if (roff_ph == 2'd0) begin
                        off_lo  <= rom_q;
                        roff_ph <= 2'd1;
                    end else begin
                        off_hi  <= rom_q;
                        e_idx   <= off_lo;
                        roff_ph <= 2'd0;
                        state   <= ST_MAC;
                    end
                end
                ST_MAC: begin

                    if (f0_issue) begin
                        e_idx <= e_idx + 12'd1;
                    end
                    if (e_idx >= off_hi) begin
                        state  <= ST_FLUSH;
                        fl_cnt <= 3'd0;
                    end
                end
                ST_FLUSH: begin
                    if (fl_cnt == 3'd4) begin
                        if (ch == 6'd63) begin
                            state <= ST_L2D;
                        end else begin
                            ch      <= ch + 6'd1;
                            state   <= ST_ROFF;
                            roff_ph <= 2'd0;
                        end
                    end else begin
                        fl_cnt <= fl_cnt + 3'd1;
                    end
                end
                ST_L2D: begin
                    if (!l2_run) begin
                        frame_mel_done <= 1'b1;
                        state <= ST_IDLE;
                    end
                end
                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
