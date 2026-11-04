// ---------------------------------------------------------------------------
// tb_conv_engine.sv -- direct-drive testbench for src/npu/conv_engine.v
//
// This TB talks to conv_engine through its REAL port contract (no
// top_npu_conv1_test scaffolding, which is where the 2026-10-31 board FAIL
// came from):
//
//   * start0 pulses, then the group contract is streamed the way wdma does:
//     grp_start gets its own beat, then 16 x bias -> 16 x M -> 16 x shift
//   * group 0 goes to the ACTIVE bank and group 1 to the SHADOW bank during
//     boot; from then on every adv0 promotes the shadow and the TB loads the
//     group after it (the conv_engine loader contract)
//   * weights are fed on w_ready: one 128-bit tap word per MAC beat, tap
//     order cin-major / (dy*3+dx) minor, lane i = w[grp*16+i]
//   * ingress replays hex_conv1/conv1_feat.hex in (row, col) order, throttled
//     by the documented 3-bank safety rule: row k may only be written after
//     row_done_cnt >= k-1, i.e. after the scan has passed row k-2
//
// Egress is captured IN FULL (792,576 u8 values -- free in simulation) and
// compared against the golden conv1 tensor flattened to the engine's own
// stream order (row, grp, col, lane 0..15), giving
//   stream_samples, mismatch total, FIRST_MISMATCH (row/grp/col/ch + exp/obs)
//   and the per-channel mismatch histogram (48 channels).
//
// SELF-VALIDATION (see sim/README.md): compile with +define+WRONG_CTR_MAP.
// That switches the contract address mapping to the broken board version
// (ctr_base + c_step, i.e. 48 consecutive words per group).  The TB must then
// FAIL with grp1 pinned at 255 and grp2 collapsing towards 0, matching the
// board observation.  If it still passes, the TB is not actually exercising
// the contract path.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_conv_engine;

    localparam integer CLK_HALF  = 5;      // 100 MHz
    localparam integer H_ROWS    = 64;
    localparam integer W_COLS    = 258;
    localparam integer GRP_NUM   = 3;
    localparam integer LANES     = 16;
    localparam integer PIX_PER_ROW = GRP_NUM * W_COLS;          // 774
    localparam integer STREAM_N  = H_ROWS * PIX_PER_ROW * LANES; // 792576
    localparam integer MAX_CYC   = 6_000_000;
    localparam [7:0]   ZP_IN     = 8'd49;
    localparam [7:0]   ZP_OUT    = 8'd0;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    // -----------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------
    reg                cfg_valid   = 1'b0;
    reg  [7:0]         cfg_zp_in   = 8'd0;
    reg  [7:0]         cfg_zp_out  = 8'd0;
    reg  [1:0]         conv_sel    = 2'd0;
    reg                start0      = 1'b0;
    reg                start1      = 1'b0;
    reg                start2      = 1'b0;
    reg                start3      = 1'b0;
    wire               done0, done1, done2, done3;

    reg                x0_valid    = 1'b0;
    reg  [7:0]         x0_u8      = 8'd0;

    reg                grp_start   = 1'b0;
    reg                bias_valid  = 1'b0;
    reg  signed [31:0] bias_s32    = 32'sd0;
    reg                mult_valid  = 1'b0;
    reg  signed [31:0] m_s32       = 32'sd0;
    reg                shft_valid  = 1'b0;
    reg        [6:0]   shift       = 7'd0;

    wire               w_ready;
    wire               y_valid;
    wire        [7:0]  y_u8;
    wire               adv0, adv1, adv2, adv3;

    // wdma-style tap stream: valid is tied to the engine's consumption window
    wire          w_valid = w_ready;
    wire [127:0]  w_data;

    wire [15:0] ingress_unused;
    conv_engine dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .cfg_valid    (cfg_valid),
        .cfg_zp_in    (cfg_zp_in),
        .cfg_zp_out   (cfg_zp_out),
        .conv_sel     (conv_sel),
        .start0       (start0),
        .start1       (start1),
        .start2       (start2),
        .start3       (start3),
        .done0        (done0),
        .done1        (done1),
        .done2        (done2),
        .done3        (done3),
        .x0_ingress_max_row(ingress_unused),
        .x0_valid     (x0_valid),
        .x0_u8        (x0_u8),
        .x1_valid     (1'b0),
        .x1_u8        (8'd0),
        .x2_valid     (1'b0),
        .x2_u8        (8'd0),
        .x3_valid     (1'b0),
        .x3_u8        (8'd0),
        .grp_start    (grp_start),
        .bias_valid   (bias_valid),
        .bias_s32     (bias_s32),
        .mult_valid   (mult_valid),
        .m_s32        (m_s32),
        .shft_valid   (shft_valid),
        .shift        (shift),
        .w_valid      (w_valid),
        .w_data       (w_data),
        .w_ready      (w_ready),
        .y_ready      (1'b1),
        .y_valid      (y_valid),
        .y_u8         (y_u8),
        .adv0         (adv0),
        .adv1         (adv1),
        .adv2         (adv2),
        .adv3         (adv3)
    );

    // -----------------------------------------------------------------
    // ROMs: the exact tables the board bitstream uses, plus the golden
    // tensor flattened into the engine egress order.
    // -----------------------------------------------------------------
    reg [31:0] w_rom    [0:107];    // 27 taps x 4 sub-words (group-major)
    reg [31:0] ctr_rom  [0:143];    // 48 bias, 48 M, 48 shift (layer-major)
    reg [7:0]  feat_rom [0:16511];  // (64, 258) u8 feature map
    reg [7:0]  gold_rom [0:STREAM_N-1];

    initial begin
        $readmemh("hex_conv1/conv1_w32.hex",  w_rom);
        $readmemh("hex_conv1/conv1_ctr.hex",  ctr_rom);
        $readmemh("hex_conv1/conv1_feat.hex", feat_rom);
        $readmemh("build/sim/conv1/golden_conv1.hex", gold_rom);
    end

    // -----------------------------------------------------------------
    // Tap stream: one 16-lane tap per accepted beat, group-major words
    // -----------------------------------------------------------------
    integer   tap_idx = 0;
    reg [1:0] cur_grp = 2'd0;

    wire [15:0] w_base_c = cur_grp * 16'd36 + tap_idx[15:0] * 16'd4;
    assign w_data = {w_rom[w_base_c + 3], w_rom[w_base_c + 2],
                     w_rom[w_base_c + 1], w_rom[w_base_c]};

    always @(posedge clk) begin
        if (rst_n && w_ready)
            tap_idx <= (tap_idx == 8) ? 0 : tap_idx + 1;
    end

    always @(posedge clk) begin
        if (!rst_n)
            cur_grp <= 2'd0;
        else if (adv0)
            cur_grp <= (cur_grp == 2'd2) ? 2'd0 : cur_grp + 2'd1;
    end

    // -----------------------------------------------------------------
    // Group contract loader (48 beats per group, one valid per beat)
    // -----------------------------------------------------------------
    function [31:0] ctr_word;
        input integer idx;
        begin
            ctr_word = ctr_rom[idx];
        end
    endfunction

    task automatic load_contract;
        input [1:0] grp;
        integer c;
        begin
            @(posedge clk);
            grp_start <= 1'b1;               // clean beat, no valid strobe
            @(posedge clk);
            grp_start <= 1'b0;

            for (c = 0; c < 16; c = c + 1) begin
`ifdef WRONG_CTR_MAP
                // broken board mapping: 48 consecutive words per group
                bias_s32   <= $signed(ctr_word(grp * 48 + c));
`else
                bias_s32   <= $signed(ctr_word(grp * 16 + c));
`endif
                bias_valid <= 1'b1;
                @(posedge clk);
            end
            bias_valid <= 1'b0;

            for (c = 0; c < 16; c = c + 1) begin
`ifdef WRONG_CTR_MAP
                m_s32    <= $signed(ctr_word(grp * 48 + 16 + c));
`else
                m_s32    <= $signed(ctr_word(48 + grp * 16 + c));
`endif
                mult_valid <= 1'b1;
                @(posedge clk);
            end
            mult_valid <= 1'b0;

            for (c = 0; c < 16; c = c + 1) begin
`ifdef WRONG_CTR_MAP
                shift    <= ctr_word(grp * 48 + 32 + c);
`else
                shift    <= ctr_word(96 + grp * 16 + c);
`endif
                shft_valid <= 1'b1;
                @(posedge clk);
            end
            shft_valid <= 1'b0;
        end
    endtask

    // -----------------------------------------------------------------
    // Ingress: replay the feature map row by row, behind the row scan
    // -----------------------------------------------------------------
    integer pix_done = 0;
    always @(posedge clk) begin
        if (rst_n && y_valid)
            pix_done <= pix_done + 1;
    end

    task automatic feed_row;
        input integer row;
        integer col;
        begin

            for (col = 0; col < W_COLS; col = col + 1) begin
                // 3-bank safety: row k may only be written once the scan has
                // passed row k-2 (row_done_cnt >= k-1 in T22 terms).
                if (row >= 1) begin
                    // pix_done counts y_valid bytes, including all 16
                    // output lanes, rather than spatial/group pixels.
                    while (pix_done < (row - 1) * PIX_PER_ROW * LANES)
                        @(posedge clk);
                end
                // Blocking drive: the ingress beat is sampled by the engine
                // on the next posedge, no NBA scheduling race in the task.
                x0_valid = 1'b1;
                x0_u8    = feat_rom[row * W_COLS + col];
                @(posedge clk);
                x0_valid = 1'b0;
                @(posedge clk);
            end

        end
    endtask

    // -----------------------------------------------------------------
    // Egress capture + golden comparison
    // -----------------------------------------------------------------
    integer    samples     = 0;
    integer    mism        = 0;
    integer    ch_mism [0:47];
    integer    col_mism [0:W_COLS-1];
    integer    ci;
    integer    first_idx   = -1;
    integer    nlisted      = 0;
    integer    list_idx [0:7];
    reg [7:0]  list_exp [0:7];
    reg [7:0]  list_obs [0:7];
    reg [7:0]  first_exp   = 8'd0;
    reg [7:0]  first_obs   = 8'd0;

    integer    s_row, s_grp, s_col, s_lane, s_ch;

    initial begin
        for (ci = 0; ci < 48; ci = ci + 1)
            ch_mism[ci] = 0;
        for (ci = 0; ci < W_COLS; ci = ci + 1)
            col_mism[ci] = 0;
    end

    always @(posedge clk) begin
        if (rst_n && y_valid) begin
            if (samples < STREAM_N) begin
                if (y_u8 !== gold_rom[samples]) begin
                    mism <= mism + 1;
                    ch_mism[((samples / LANES) % GRP_NUM) * 16 + (samples % LANES)]
                        <= ch_mism[((samples / LANES) % GRP_NUM) * 16 + (samples % LANES)] + 1;
                    col_mism[(samples / LANES) % W_COLS]
                        <= col_mism[(samples / LANES) % W_COLS] + 1;
                    if (first_idx < 0) begin
                        first_idx <= samples;
                        first_exp <= gold_rom[samples];
                        first_obs <= y_u8;
                    end
                    // keep the first eight mismatches for pattern analysis
                    if (nlisted < 8) begin
                        list_idx[nlisted]  <= samples;
                        list_exp[nlisted]  <= gold_rom[samples];
                        list_obs[nlisted]  <= y_u8;
                        nlisted <= nlisted + 1;
                    end
                end
            end
            samples <= samples + 1;
        end
    end

    // -----------------------------------------------------------------
    // Run control
    // -----------------------------------------------------------------
    reg     started     = 1'b0;
    reg     done_seen   = 1'b0;
    integer cycles      = 0;
    integer errors      = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            cycles <= cycles + 1;
            if (done0)
                done_seen <= 1'b1;
        end
    end

    // Progress monitor (one line every 200k cycles) so a wedged FSM is
    // immediately localised instead of only reported as a timeout.
    always @(posedge clk) begin
        if (rst_n && (cycles % 200000) == 0 && cycles != 0)
            $display("MON cycles=%0d run=%0b phase=%0d grp=%0d row=%0d col=%0d tap=%0d grp_arm=%0b shadow=%0b g0_row=%0d pix=%0d samples=%0d",
                     cycles, dut.run_reg, dut.phase_reg, dut.grp_cnt,
                     dut.out_row_cnt, dut.out_col_cnt, dut.tap_cnt,
                     dut.grp_arm, dut.shadow_rdy, dut.g0_row,
                     pix_done, samples);
    end

    // NOTE: Verilator 5.050 + gcc 16.2 miscompiles $sformatf, so observations are
    // printed with plain $display and the check takes a boolean only.
    task automatic check;
        input [255:0] name;
        input         ok;
        begin
            if (ok) begin
                $display("CHECK PASS: %0s", name);
            end else begin
                errors = errors + 1;
                $display("CHECK FAIL: %0s", name);
            end
        end
    endtask

    initial begin : boot_and_contracts
        integer next_load;
        $display("=== tb_conv_engine start ===");
        wait (started === 1'b1);
        // let the start0 pulse clear the engine counters first: any ingress
        // beat or contract strobe landing on the start edge is discarded.
        repeat (4) @(posedge clk);
        // boot: group 0 -> ACTIVE, group 1 -> SHADOW
        load_contract(2'd0);
        load_contract(2'd1);
        next_load = 2;
        forever begin
            @(posedge adv0);
            load_contract(next_load[1:0]);
            next_load = (next_load == 2) ? 0 : next_load + 1;
        end
    end

    initial begin : ingress
        integer r;
        wait (started === 1'b1);
        repeat (4) @(posedge clk);
        for (r = 0; r < H_ROWS; r = r + 1)
            feed_row(r);
    end

    initial begin : main
        // reset
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // layer configuration then start (cfg may precede the start pulse)
        cfg_zp_in  <= ZP_IN;
        cfg_zp_out <= ZP_OUT;
        cfg_valid  <= 1'b1;
        @(posedge clk);
        cfg_valid  <= 1'b0;
        conv_sel   <= 2'd0;

        @(posedge clk);
        start0    <= 1'b1;
        @(posedge clk);
        start0    <= 1'b0;
        started   <= 1'b1;

        // wait for the layer-done pulse (or give up on timeout)
        while (!done_seen && cycles < MAX_CYC)
            @(posedge clk);

        // let the final drain beats (requant latency) land
        repeat (40) @(posedge clk);

        if (!done_seen) begin
            $display("ERROR: conv_engine did not raise done0 within %0d cycles",
                     MAX_CYC);
            $display("       progress: stream_samples=%0d pixels=%0d",
                     samples, pix_done);
            errors = errors + 1;
        end

        $display("STREAM_SAMPLES %0d (expected %0d)", samples, STREAM_N);
        $display("MISMATCH_TOTAL %0d", mism);
        $display("CYCLES %0d", cycles);

        if (first_idx >= 0) begin
            s_row  = first_idx / (PIX_PER_ROW * LANES);
            s_grp  = (first_idx / (W_COLS * LANES)) % GRP_NUM;
            s_col  = (first_idx / LANES) % W_COLS;
            s_lane = first_idx % LANES;
            s_ch   = s_grp * 16 + s_lane;
            $display("FIRST_MISMATCH row=%0d grp=%0d col=%0d ch=%0d lane=%0d expected=%0d observed=%0d",
                     s_row, s_grp, s_col, s_ch, s_lane, first_exp, first_obs);
        end else begin
            $display("FIRST_MISMATCH none");
        end

        // per-channel histogram (16 per line so all 48 fit in three lines)
        for (ci = 0; ci < nlisted && ci < 8; ci = ci + 1) begin
            $display("MISMATCH_DETAIL idx=%0d row=%0d grp=%0d col=%0d ch=%0d expected=%0d observed=%0d",
                     list_idx[ci],
                     list_idx[ci] / (PIX_PER_ROW * LANES),
                     (list_idx[ci] / (W_COLS * LANES)) % GRP_NUM,
                     (list_idx[ci] / LANES) % W_COLS,
                     ((list_idx[ci] / LANES) % GRP_NUM) * 16 + (list_idx[ci] % LANES),
                     list_exp[ci], list_obs[ci]);
        end

        $display("PER_COL mismatch (non-zero columns only, up to 24)");
        begin : col_dump
            integer shown;
            shown = 0;
            for (ci = 0; ci < W_COLS && shown < 24; ci = ci + 1)
                if (col_mism[ci] != 0) begin
                    $display("COL%03d mismatch %0d", ci, col_mism[ci]);
                    shown = shown + 1;
                end
        end

        $display("PER_CHANNEL mismatch (channel: count)");
        for (ci = 0; ci < 48; ci = ci + 16)
            $display("CH%02d..%02d : %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                     ci, ci + 15,
                     ch_mism[ci + 0],  ch_mism[ci + 1],  ch_mism[ci + 2],  ch_mism[ci + 3],
                     ch_mism[ci + 4],  ch_mism[ci + 5],  ch_mism[ci + 6],  ch_mism[ci + 7],
                     ch_mism[ci + 8],  ch_mism[ci + 9],  ch_mism[ci + 10], ch_mism[ci + 11],
                     ch_mism[ci + 12], ch_mism[ci + 13], ch_mism[ci + 14], ch_mism[ci + 15]);

        // group-level summary: the board symptom was grp1 saturated and
        // grp2 collapsing, which shows up immediately in this split.
        for (ci = 0; ci < GRP_NUM; ci = ci + 1) begin
            integer gsum;
            integer gch;
            gsum = 0;
            for (gch = 0; gch < 16; gch = gch + 1)
                gsum = gsum + ch_mism[ci * 16 + gch];
            $display("GROUP%0d mismatch %0d", ci, gsum);
        end

        $display("OBS conv1: samples=%0d expected=%0d mismatch=%0d first_idx=%0d",
                 samples, STREAM_N, mism, first_idx);
        check("conv1 stream length", samples == STREAM_N);
        check("conv1 bit-exact vs golden", mism == 0);

        if (errors == 0) begin
            $display("RESULT: PASS tb_conv_engine");
            $finish;
        end else begin
            $display("RESULT: FAIL tb_conv_engine (%0d errors)", errors);
            $fatal(1, "tb_conv_engine failed");
        end
    end

    // Absolute watchdog so a wedged FSM cannot hang the parallel runner.
    initial begin : watchdog
        #(MAX_CYC * 10ns);
        $display("ERROR: tb_conv_engine wall-clock watchdog fired");
        $display("ERROR: stream_samples=%0d pixels=%0d mism=%0d",
                 samples, pix_done, mism);
        $fatal(1, "tb_conv_engine timeout");
    end

endmodule
