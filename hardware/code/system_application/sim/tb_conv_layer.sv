// ---------------------------------------------------------------------------
// tb_conv_layer.sv -- Verilator testbench for conv2 / conv3 / conv4
//
// Replays ONE conv layer through the real ``conv_engine`` +
// ``requant_unit`` pair, with the same contract/tap loader phase
// discipline that took conv1 to 0 mismatch, and scores the full egress
// stream against reports/golden_ref/sine_440_full/convN.npy.
//
// It deliberately does NOT reuse src/diag/top_npu_conv1_test.v: that file
// is a conv1-shaped bitstream (fixed geometry, own UART frame engine).
// Here the geometry is parameterised and the tables come from
// build/gen_layer_hex.py:
//
//     build/ml_conv/L<n>/tap.hex   4 * TAPS words per group (group major)
//     build/ml_conv/L<n>/ctr.hex   bias(COUT) + M(COUT) + shift(COUT)
//     build/ml_conv/L<n>/x.hex     input map in (row, col, ch) order
//
// Output: build/sim_L<n>_y.bin, every egress sample in
// (row, group, col, lane) order -- exactly what compare_sim_layer.py reads.
//
// Loader contract (identical to the fixed conv1 loader):
//   * the ROM adds one read-latency register on top of the address
//     register and conv_engine samples one beat later, so the word used
//     on beat k was addressed two beats earlier -> address logical word
//     k+1 on beat k and prefetch word 0 on the launch edge.
//   * one contract beat per group: 16 bias, 16 M, 16 shift, with a
//     dedicated grp_start beat first (49 beats total).
//   * one tap bank PER output group (a 2-bank ping-pong cannot work with
//     three or more groups).
//
// Usage (from instrec_fpga):
//   H:\GG\bin\verilator.bat --binary --timing -j 2 -Wno-fatal \
//     --top-module tb_conv_layer -GLAYER=1 -GCIN=48 -GCOUT=96 -GH=32 -GW=129 \
//     -Mdir build/sim_L1_obj --build-jobs 2 \
//     src/npu/conv_engine.v src/npu/requant_unit.v sim/tb_conv_layer.sv
//   ./build/sim_L1_obj/Vtb_conv_layer.exe
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_conv_layer #(
    parameter integer LAYER = 1,      // 1 = conv2, 2 = conv3, 3 = conv4
    parameter integer CIN   = 48,
    parameter integer COUT  = 96,
    parameter integer H     = 32,
    parameter integer W     = 129
);

    localparam integer GROUPS = COUT / 16;
    localparam integer TAPS   = 9 * CIN;          // taps per pixel per group
    localparam integer WORDS  = 4 * TAPS;         // 32-bit tap ROM words/group
    localparam integer STREAM = GROUPS * H * W * 16;

    // -----------------------------------------------------------------------
    // stimulus tables
    // -----------------------------------------------------------------------
    reg [31:0] tap_rom [0:GROUPS * WORDS - 1];
    reg [31:0] ctr_rom [0:3 * COUT - 1];
    reg  [7:0] x_rom   [0:CIN * H * W - 1];

    string tap_path;
    string ctr_path;
    string x_path;
    string y_path;
    integer fd_y;

    integer i;
    integer cyc;
    integer n_samp;
    integer probe_cnt;

    initial begin
        tap_path = $sformatf("build/ml_conv/L%0d/tap.hex", LAYER);
        ctr_path = $sformatf("build/ml_conv/L%0d/ctr.hex", LAYER);
        x_path   = $sformatf("build/ml_conv/L%0d/x.hex", LAYER);
        y_path   = $sformatf("build/sim_L%0d_y.bin", LAYER);
        $readmemh(tap_path, tap_rom);
        $readmemh(ctr_path, ctr_rom);
        $readmemh(x_path, x_rom);
        fd_y = $fopen(y_path, "wb");
        if (fd_y == 0) begin
            $display("FATAL: cannot open %0s", y_path);
            $finish;
        end
        $display("TB layer=%0d CIN=%0d COUT=%0d H=%0d W=%0d TAPS=%0d STREAM=%0d",
                 LAYER, CIN, COUT, H, W, TAPS, STREAM);
    end

    // -----------------------------------------------------------------------
    // clock / reset
    // -----------------------------------------------------------------------
    reg clk;
    reg rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst_n) cyc <= cyc + 1;
    end

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    reg         cfg_valid;
    reg  [7:0]  cfg_zp_in;
    reg  [7:0]  cfg_zp_out;
    reg  [1:0]  conv_sel;

    reg         start_pulse;
    wire        st0, st1, st2, st3;
    wire        done0, done1, done2, done3;

    reg         x0_valid;
    reg  [7:0]  x0_u8;

    reg         grp_start;
    reg         bias_valid;
    reg  signed [31:0] bias_s32;
    reg         mult_valid;
    reg  signed [31:0] m_s32;
    reg         shft_valid;
    reg  [6:0]  shift_w;

    reg         w_valid;
    reg  [127:0] w_data;
    wire        w_ready;

    wire        y_valid;
    wire [7:0]  y_u8;

    wire        adv0, adv1, adv2, adv3;

    assign st0 = (LAYER == 0) ? start_pulse : 1'b0;
    assign st1 = (LAYER == 1) ? start_pulse : 1'b0;
    assign st2 = (LAYER == 2) ? start_pulse : 1'b0;
    assign st3 = (LAYER == 3) ? start_pulse : 1'b0;

    wire done_sel = (LAYER == 1) ? done1 : (LAYER == 2) ? done2 : done3;
    wire adv_sel  = (LAYER == 1) ? adv1  : (LAYER == 2) ? adv2  : adv3;

    wire [15:0] ingress_unused;
    conv_engine u_conv (
        .clk         (clk),
        .rst_n       (rst_n),
        .cfg_valid   (cfg_valid),
        .cfg_zp_in   (cfg_zp_in),
        .cfg_zp_out  (cfg_zp_out),
        .conv_sel    (conv_sel),
        .start0      (st0),
        .start1      (st1),
        .start2      (st2),
        .start3      (st3),
        .done0       (done0),
        .done1       (done1),
        .done2       (done2),
        .done3       (done3),
        .x0_ingress_max_row(ingress_unused),
        .x0_valid    ((LAYER == 0) ? x0_valid : 1'b0),
        .x0_u8       ((LAYER == 0) ? x0_u8 : 8'd0),
        .x1_valid    ((LAYER == 1) ? x0_valid : 1'b0),
        .x1_u8       ((LAYER == 1) ? x0_u8 : 8'd0),
        .x2_valid    ((LAYER == 2) ? x0_valid : 1'b0),
        .x2_u8       ((LAYER == 2) ? x0_u8 : 8'd0),
        .x3_valid    ((LAYER == 3) ? x0_valid : 1'b0),
        .x3_u8       ((LAYER == 3) ? x0_u8 : 8'd0),
        .grp_start   (grp_start),
        .bias_valid  (bias_valid),
        .bias_s32    (bias_s32),
        .mult_valid  (mult_valid),
        .m_s32       (m_s32),
        .shft_valid  (shft_valid),
        .shift       (shift_w),
        .w_valid     (w_valid),
        .w_data      (w_data),
        .w_ready     (w_ready),
        .y_ready      (1'b1),
        .y_valid     (y_valid),
        .y_u8        (y_u8),
        .adv0        (adv0),
        .adv1        (adv1),
        .adv2        (adv2),
        .adv3        (adv3)
    );

    // -----------------------------------------------------------------------
    // contract / tap ROM read ports (synchronous, one beat of latency)
    // -----------------------------------------------------------------------
    integer     ctr_addr;
    integer     w_addr;
    reg  [31:0] ctr_dout;
    reg  [31:0] w_dout;

    always @(posedge clk) ctr_dout <= ctr_rom[ctr_addr];
    always @(posedge clk) w_dout   <= tap_rom[w_addr];

    // -----------------------------------------------------------------------
    // group / tap bookkeeping
    // -----------------------------------------------------------------------
    localparam [1:0] GT_IDLE = 2'd0;
    localparam [1:0] GT_CTR  = 2'd1;
    localparam [1:0] GT_TAP  = 2'd2;

    integer      use_grp;
    integer      job_grp;
    integer      tap_idx;
    reg   [1:0]  gt_step;
    reg          gt_launch;
    reg          gt_done;
    integer      c_step;          // 0..48, beat 0 = grp_start only
    integer      t_step;          // 0..WORDS, beat 0 = address prefetch
    integer      c_logi;
    reg   [30:0] ctr_off;

    localparam integer BANKS = 16;   // GROUPS <= 16 for every layer
    reg [127:0] tap_bank  [0:BANKS-1][0:TAPS-1];
    reg [127:0] tap_ld_acc[0:TAPS-1];
    reg [127:0] w_tap_word;

    integer t_pair;
    integer ld_tap;
    integer ld_sub;

    // Logical contract word to prefetch on this beat (see header note).
    // One group is always 48 words = 16 bias + 16 M + 16 shift, so the
    // BLOCK is selected by the beat counter (16 / 32), while the block
    // BASE in the ROM is COUT (bias), COUT (M) and 2*COUT (shift) because
    // every block holds all COUT channels.
    always @* begin
        c_logi = c_step + 1;
        if (c_logi >= 32)
            ctr_off = 2 * COUT + job_grp * 16 + (c_logi % 16);
        else if (c_logi >= 16)
            ctr_off = COUT + job_grp * 16 + (c_logi % 16);
        else
            ctr_off = job_grp * 16 + (c_logi % 16);
    end

    // 9:1 (well, GROUPS:1) tap bank mux
    always @* w_tap_word = tap_bank[use_grp][tap_idx];

    wire c_bias = (c_step >= 1) && (c_step <= 16);
    wire c_mult = (c_step >= 17) && (c_step <= 32);
    wire c_shft = (c_step >= 33) && (c_step <= 48);

    always @* begin
        t_pair = t_step - 1;
        ld_tap = t_pair / 4;
        ld_sub = t_pair % 4;
    end

    wire [127:0] acc_next = {w_dout, tap_ld_acc[ld_tap][127:32]};

    // -----------------------------------------------------------------------
    // main sequencer
    // -----------------------------------------------------------------------
    localparam [2:0] S_CFG  = 3'd0;
    localparam [2:0] S_START = 3'd1;
    localparam [2:0] S_BOOT = 3'd2;
    localparam [2:0] S_RUN  = 3'd3;
    localparam [2:0] S_STOP = 3'd4;
    localparam [2:0] S_END  = 3'd5;

    reg  [2:0] seq;
    integer    boot_job;
    integer    settle_cnt;
    reg        done_latched;
    integer    use_next;
    integer    job_next;

    always @* begin
        use_next = (use_grp == GROUPS - 1) ? 0 : use_grp + 1;
        job_next = (use_grp + 2) % GROUPS;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq          <= S_CFG;
            boot_job     <= 0;
            settle_cnt   <= 0;
            done_latched <= 1'b0;
            cfg_valid    <= 1'b0;
            cfg_zp_in    <= 8'd0;
            cfg_zp_out   <= 8'd0;
            conv_sel     <= 2'd0;
            start_pulse  <= 1'b0;
            gt_step      <= GT_IDLE;
            gt_launch    <= 1'b0;
            gt_done      <= 1'b0;
            c_step       <= 0;
            t_step       <= 0;
            job_grp      <= 0;
            use_grp      <= 0;
            tap_idx      <= 0;
            ctr_addr     <= 0;
            w_addr       <= 0;
        end else begin
            gt_done      <= 1'b0;
            cfg_valid    <= 1'b0;
            start_pulse  <= 1'b0;

            case (seq)
                S_CFG: begin
                    cfg_valid  <= 1'b1;
                    cfg_zp_in  <= 8'd0;
                    cfg_zp_out <= 8'd0;
                    conv_sel   <= LAYER[1:0];
                    seq        <= S_START;
                end

                S_START: begin
                    start_pulse <= 1'b1;
                    use_grp     <= 0;
                    tap_idx     <= 0;
                    boot_job    <= 0;
                    job_grp     <= 0;
                    gt_launch   <= 1'b1;
                    seq         <= S_BOOT;
                end

                S_BOOT: begin
                    if (gt_done) begin
                        if (boot_job == 1) begin
                            seq <= S_RUN;
                        end else begin
                            boot_job  <= 1;
                            job_grp   <= 1;
                            gt_launch <= 1'b1;
                        end
                    end
                end

                S_RUN: begin
                    if (done_sel) begin
                        done_latched <= 1'b1;
                        settle_cnt   <= 0;
                        seq          <= S_STOP;
                    end else if ((gt_step == GT_IDLE) && !gt_launch) begin
                        if (adv_sel) begin
                            use_grp   <= use_next;
                            job_grp   <= job_next;
                            gt_launch <= 1'b1;
                            tap_idx   <= 0;
                        end else if (w_valid && w_ready) begin
                            tap_idx <= (tap_idx == TAPS - 1) ? 0 : tap_idx + 1;
                        end
                    end
                end

                S_STOP: begin
                    settle_cnt <= settle_cnt + 1;
                    if (settle_cnt == 63) seq <= S_END;
                end

                default: begin
                    seq <= S_END;
                end
            endcase

            // ---- contract / tap job engine (same phase discipline as conv1)
            if (gt_step == GT_IDLE) begin
                if (gt_launch) begin
                    gt_launch <= 1'b0;
                    gt_step   <= GT_CTR;
                    c_step    <= 0;
                    ctr_addr  <= job_grp * 16;       // prefetch logical word 0
                end
            end else if (gt_step == GT_CTR) begin
                if (c_step < 47)
                    ctr_addr <= ctr_off;
                if (c_step == 48) begin
                    c_step  <= 0;
                    t_step  <= 0;
                    gt_step <= GT_TAP;
                    w_addr  <= job_grp * WORDS;      // prefetch tap sub-word 0
                end else begin
                    c_step <= c_step + 1;
                end
            end else begin
                if (t_step < WORDS - 1)
                    w_addr <= job_grp * WORDS + t_step + 1;
                if (t_step == WORDS) begin
                    t_step  <= 0;
                    gt_step <= GT_IDLE;
                    gt_done <= 1'b1;
                end else begin
                    t_step <= t_step + 1;
                end
            end

            // ---- tap word assembly (4 sub-words -> one 128-bit tap) ----
            if ((gt_step == GT_TAP) && (t_step != 0)) begin
                tap_ld_acc[ld_tap] <= acc_next;
                if (ld_sub == 3)
                    tap_bank[job_grp][ld_tap] <= acc_next;
            end
        end
    end

    // -----------------------------------------------------------------------
    // drive toward conv_engine
    // -----------------------------------------------------------------------
    always @* begin
        grp_start  = (gt_step == GT_CTR) && (c_step == 0);
        bias_valid = (gt_step == GT_CTR) && c_bias;
        mult_valid = (gt_step == GT_CTR) && c_mult;
        shft_valid = (gt_step == GT_CTR) && c_shft;
        bias_s32   = ctr_dout;
        m_s32      = ctr_dout;
        shift_w    = ctr_dout[6:0];
        w_data     = w_tap_word;
        w_valid    = (seq == S_RUN) && (gt_step == GT_IDLE) && !gt_launch;
    end

    // -----------------------------------------------------------------------
    // ingress replay (stage 1: ROM address, stage 2: data, stage 3: valid)
    // -----------------------------------------------------------------------
    integer ing_row;
    integer ing_col;
    integer ing_ch;
    integer feat_addr;
    reg [7:0] feat_dout;
    reg     feat_vld1;
    reg     x0_valid_r;
    reg [7:0] x0_u8_r;
    integer row_done_cnt;
    integer adv_mod;

    wire ing_go = (seq == S_RUN) && !done_latched &&
                  (ing_row < H) && (ing_row <= row_done_cnt + 1);

    // synchronous feature ROM: address -> dout -> valid -> x0 (3 stages,
    // same alignment as the conv1 top level)
    always @(posedge clk) feat_dout <= x_rom[feat_addr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ing_row      <= 0;
            ing_col      <= 0;
            ing_ch       <= 0;
            feat_addr    <= 0;
            feat_vld1    <= 1'b0;
            x0_valid_r   <= 1'b0;
            x0_u8_r      <= 8'd0;
            row_done_cnt <= 0;
            adv_mod      <= 0;
        end else begin
            feat_vld1  <= ing_go;
            x0_valid_r <= feat_vld1;
            x0_u8_r    <= feat_dout;

            if (seq == S_START) begin
                ing_row      <= 0;
                ing_col      <= 0;
                ing_ch       <= 0;
                feat_addr    <= 0;
                row_done_cnt <= 0;
                adv_mod      <= 0;
            end else if (ing_go) begin
                feat_addr <= feat_addr + 1;
                if (ing_ch == CIN - 1) begin
                    ing_ch <= 0;
                    if (ing_col == W - 1) begin
                        ing_col <= 0;
                        ing_row <= ing_row + 1;
                    end else begin
                        ing_col <= ing_col + 1;
                    end
                end else begin
                    ing_ch <= ing_ch + 1;
                end
            end

            if (adv_sel) begin
                adv_mod <= (adv_mod == GROUPS - 1) ? 0 : adv_mod + 1;
                if (adv_mod == GROUPS - 1)
                    row_done_cnt <= row_done_cnt + 1;
            end
        end
    end

    assign x0_valid = x0_valid_r;
    assign x0_u8    = x0_u8_r;

    // -----------------------------------------------------------------------
    // egress capture
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && y_valid && (n_samp < STREAM)) begin
            $fwrite(fd_y, "%c", y_u8);
            n_samp <= n_samp + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && (seq == S_END)) begin
            $display("TB DONE layer=%0d samples=%0d/%0d cyc=%0d", LAYER, n_samp, STREAM, cyc);
            $fclose(fd_y);
            if(n_samp != STREAM) $fatal(1,"incomplete conv output stream");
            $display("RESULT: PASS conv layer output count; numerical scoring is external");
            $finish;
        end
    end

    // acc probe at the first pixels (same shape as the conv1 debug dump)
    always @(posedge clk) begin
        if (rst_n && u_conv.snapshot_go && (u_conv.out_row_cnt < 2) &&
            (u_conv.out_col_cnt < 3) && (probe_cnt < 12)) begin
            $write("SNAP row=%0d grp=%0d col=%0d acc=", u_conv.out_row_cnt,
                   u_conv.grp_cnt, u_conv.out_col_cnt);
            for (i = 0; i < 16; i = i + 1)
                $write("%0d ", u_conv.acc_snap[i]);
            $write(" |");
            probe_cnt <= probe_cnt + 1;
        end
    end

    // progress probe + watchdog (a stuck layer must never hang the shell)
    always @(posedge clk) begin
        if (rst_n && (cyc != 0) && (cyc % 2000000 == 0))
            $display("PROG cyc=%0d seq=%0d n=%0d ing_row=%0d rdc=%0d use=%0d job=%0d gt=%0d cstep=%0d tstep=%0d wv=%0d wr=%0d",
                     cyc, seq, n_samp, ing_row, row_done_cnt, use_grp, job_grp,
                     gt_step, c_step, t_step, w_valid, w_ready);
    end

    always @(posedge clk) begin
        if (rst_n && (cyc > 60000000)) begin
            $display("TIMEOUT cyc=%0d seq=%0d n=%0d/%0d ing_row=%0d rdc=%0d use=%0d gt=%0d cstep=%0d tstep=%0d",
                     cyc, seq, n_samp, STREAM, ing_row, row_done_cnt, use_grp,
                     gt_step, c_step, t_step);
            $fclose(fd_y);
            $fatal(1,"conv layer watchdog expired");
        end
    end

    initial begin
        n_samp = 0;
        probe_cnt = 0;
        cyc    = 0;
        rst_n  = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
    end

endmodule