// ---------------------------------------------------------------------------
// tb_npu_chain.sv -- gap_unit -> fc1 -> fc2 -> softmax_top chain testbench
//
// The board-side "per-layer compare" was DEFERRED because no layer-export
// path exists, so the last three NPU stages (global average pooling, the two
// fully-connected layers and the fixed-point softmax) were never proven
// numerically.  This TB closes that hole without DDR3 and without any
// scaffolding top level:
//
//   pool4 (golden) --> gap_unit --> fc1 --> fc2 --> softmax_top
//
// Stream contracts used here are the engines' own ports:
//   gap      : (row, grp, col, lane) beats, one per cycle
//              gap_we/gap_waddr/gap_wdata carry the 256 pooled channels
//   fc1      : x_s16 stream = the gap result (u8 container), 128 x 3 contract
//              beats (bias/M/shift in parallel), then 8 groups x 256 weight
//              beats on w_ready
//   fc2      : x stream = fc1 egress, 8 contract beats, 1 group x 128 weights
//   softmax  : 8 signed logits = fc2_u8 - zp_out(57), start pulse
//
// Compared against the golden reference (all four stages):
//   gap.npy (256 s32), fc1.npy (128 u8), fc2_logits.npy (8 s32, +57 = u8),
//   probs.npy (8 u16 Q0.16)
//
// Self-validation: flip ZP_OUT on the fc2 instance to 56 (or skip the -57 in
// the softmax logits) and the chain must FAIL at fc2/softmax; a checker that
// still passes is not exercising the data path.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_npu_chain;

    localparam integer CLK_HALF = 5;            // 100 MHz
    localparam integer POOL_N   = 256 * 4 * 16; // 16384 gap input beats
    localparam integer GAP_N    = 256;
    localparam integer FC1_N    = 128;
    localparam integer FC2_N    = 8;
    localparam integer FC1_GRP  = 8;
    localparam integer FC1_K    = 256;
    localparam integer FC2_K    = 128;
    localparam [7:0]   FC2_ZP   = 8'd57;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    // -----------------------------------------------------------------
    // Golden tables
    // -----------------------------------------------------------------
    reg [7:0]  pool4    [0:POOL_N-1];
    reg [31:0] gap_exp  [0:GAP_N-1];
    reg [7:0]  fc1_exp  [0:FC1_N-1];
    reg [7:0]  fc2_exp  [0:FC2_N-1];
    reg [15:0] probs_exp[0:FC2_N-1];

    reg [31:0] fc1_w    [0:FC1_GRP*FC1_K*4-1];   // 4 x 32-bit words per tap
    reg [31:0] fc1_ctr  [0:3*FC1_N-1];
    reg [31:0] fc2_w    [0:FC2_K*4-1];
    reg [31:0] fc2_ctr  [0:3*16-1];

    initial begin
        $readmemh("build/sim/npu_chain/pool4.hex",     pool4);
        $readmemh("build/sim/npu_chain/gap_exp.hex",   gap_exp);
        $readmemh("build/sim/npu_chain/fc1_exp.hex",   fc1_exp);
        $readmemh("build/sim/npu_chain/fc2_exp.hex",   fc2_exp);
        $readmemh("build/sim/npu_chain/probs_exp.hex", probs_exp);
        $readmemh("build/sim/npu_chain/fc1_w.hex",     fc1_w);
        $readmemh("build/sim/npu_chain/fc1_ctr.hex",   fc1_ctr);
        $readmemh("build/sim/npu_chain/fc2_w.hex",     fc2_w);
        $readmemh("build/sim/npu_chain/fc2_ctr.hex",   fc2_ctr);
        $display("=== tb_npu_chain start ===");
    end

    // -----------------------------------------------------------------
    // Stage 1: gap_unit
    // -----------------------------------------------------------------
    reg         gap_start = 1'b0;
    reg         gap_iv    = 1'b0;
    reg  [7:0]  gap_iu    = 8'd0;
    // Stream gate: held low until layer_start has been sampled by gap_unit.
    // gap_unit zeroes row/grp/col/lane on layer_start while in S_ACC
    // (src/npu/gap_unit.v:149-154), so any beat accepted before that edge is
    // consumed but not counted; the map then stays N beats out of phase and
    // last_beat (gap_unit.v:60-62) can never be reached.
    reg         stream_en = 1'b0;

    wire [7:0]  gap_raddr = 8'd0;
    wire [15:0] gap_rdata;
    wire        gap_done;
    wire [7:0]  gap_waddr;
    wire        gap_we;
    wire [15:0] gap_wdata;

    gap_unit u_gap (
        .clk       (clk),
        .rst_n     (rst_n),
        .layer_start(gap_start),
        .y_valid   (gap_iv),
        .y_u8      (gap_iu),
        .g_raddr   (gap_raddr),
        .g_rdata   (gap_rdata),
        .gap_done  (gap_done),
        .gap_waddr (gap_waddr),
        .gap_we    (gap_we),
        .gap_wdata (gap_wdata)
    );

    // -----------------------------------------------------------------
    // Stage 2: fc1 (CIN=256, COUT=128, zp 0/0)
    // -----------------------------------------------------------------
    wire        fc1_xv;
    wire signed [15:0] fc1_xs;
    wire        fc1_wv;
    wire [127:0] fc1_wd;
    wire        fc1_wr;
    reg         fc1_bv = 1'b0, fc1_mv = 1'b0, fc1_sv = 1'b0;
    reg  signed [31:0] fc1_b = 32'sd0, fc1_m = 32'sd0;
    reg  [6:0]  fc1_s = 7'd0;
    wire        fc1_yv;
    wire [7:0]  fc1_yu;
    wire        fc1_done;
    wire        fc1_grp_advance_unused;

    // gap result feeds fc1 directly (both are 1 beat/cycle streams)
    assign fc1_xv = gap_we;
    assign fc1_xs = $signed({8'd0, gap_wdata[7:0]});

    fc_engine #(
        .CIN  (256),
        .COUT (128),
        .ZP_IN (8'd0),
        .ZP_OUT(8'd0)
    ) u_fc1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .layer_start(gap_start),
        .x_valid    (fc1_xv),
        .x_s16      (fc1_xs),
        .w_valid    (fc1_wv),
        .w_data     (fc1_wd),
        .w_ready    (fc1_wr),
        .b_valid    (fc1_bv),
        .bias_s32   (fc1_b),
        .m_valid    (fc1_mv),
        .m_s32      (fc1_m),
        .s_valid    (fc1_sv),
        .shift      (fc1_s),
        .y_valid    (fc1_yv),
        .y_u8       (fc1_yu),
        .done       (fc1_done),
        .grp_advance(fc1_grp_advance_unused)
    );

    // -----------------------------------------------------------------
    // Stage 3: fc2 (CIN=128, COUT=8, zp 0/57)
    // -----------------------------------------------------------------
    wire        fc2_xv;
    wire signed [15:0] fc2_xs;
    wire        fc2_wv;
    wire [127:0] fc2_wd;
    wire        fc2_wr;
    reg         fc2_bv = 1'b0, fc2_mv = 1'b0, fc2_sv = 1'b0;
    reg  signed [31:0] fc2_b = 32'sd0, fc2_m = 32'sd0;
    reg  [6:0]  fc2_s = 7'd0;
    wire        fc2_yv;
    wire [7:0]  fc2_yu;
    wire        fc2_done;
    wire        fc2_grp_advance_unused;

    assign fc2_xv = fc1_yv;
    assign fc2_xs = $signed({8'd0, fc1_yu});

    fc_engine #(
        .CIN  (128),
        .COUT (8),
        .ZP_IN (8'd0),
        .ZP_OUT(FC2_ZP)
    ) u_fc2 (
        .clk        (clk),
        .rst_n      (rst_n),
        .layer_start(gap_start),
        .x_valid    (fc2_xv),
        .x_s16      (fc2_xs),
        .w_valid    (fc2_wv),
        .w_data     (fc2_wd),
        .w_ready    (fc2_wr),
        .b_valid    (fc2_bv),
        .bias_s32   (fc2_b),
        .m_valid    (fc2_mv),
        .m_s32      (fc2_m),
        .s_valid    (fc2_sv),
        .shift      (fc2_s),
        .y_valid    (fc2_yv),
        .y_u8       (fc2_yu),
        .done       (fc2_done),
        .grp_advance(fc2_grp_advance_unused)
    );

    // -----------------------------------------------------------------
    // Stage 4: softmax_top
    // -----------------------------------------------------------------
    reg         smx_start = 1'b0;
    reg  [255:0] smx_logits = 256'd0;
    wire        smx_ov;
    wire [15:0] smx_q16;
    wire [7:0]  smx_pct;
    wire [3:0]  smx_idx;
    wire [3:0]  smx_top1;
    wire        smx_done;

    softmax_top u_softmax (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (smx_start),
        .logits    (smx_logits),
        .out_valid (smx_ov),
        .out_q16   (smx_q16),
        .out_pct   (smx_pct),
        .out_idx   (smx_idx),
        .top1_idx  (smx_top1),
        .done      (smx_done)
    );

    // -----------------------------------------------------------------
    // Stream drivers / capture
    // -----------------------------------------------------------------
    integer gap_in_cnt  = 0;
    integer gap_out_cnt = 0;
    reg [15:0] gap_cap [0:GAP_N-1];

    always @(posedge clk) begin
        if (!rst_n) begin
            gap_in_cnt  <= 0;
            gap_out_cnt <= 0;
            gap_iv      <= 1'b0;
            gap_iu      <= 8'd0;
        end else if (!stream_en) begin
            // Hold the 16384-beat pool4 stream until layer_start landed.
            gap_iv <= 1'b0;
        end else if (gap_in_cnt < POOL_N) begin
            gap_iv     <= 1'b1;
            gap_iu     <= pool4[gap_in_cnt];
            gap_in_cnt <= gap_in_cnt + 1;
        end else begin
            gap_iv <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst_n && gap_we) begin
            gap_cap[gap_waddr] <= gap_wdata;
            gap_out_cnt        <= gap_out_cnt + 1;
        end
    end

    // fc1 weight stream: tied to the engine's consumption window
    integer fc1_w_cnt = 0;
    assign fc1_wv = fc1_wr;
    wire [15:0] fc1_wi = fc1_w_cnt;             // 0 .. 8*256-1
    assign fc1_wd = {fc1_w[fc1_wi * 4 + 3], fc1_w[fc1_wi * 4 + 2],
                     fc1_w[fc1_wi * 4 + 1], fc1_w[fc1_wi * 4 + 0]};

    always @(posedge clk) begin
        if (!rst_n) fc1_w_cnt <= 0;
        else if (fc1_wv && fc1_w_cnt < FC1_GRP * FC1_K) fc1_w_cnt <= fc1_w_cnt + 1;
    end

    integer fc1_x_cnt = 0;
    integer fc1_y_cnt = 0;
    reg [7:0] fc1_cap [0:FC1_N-1];
    always @(posedge clk) begin
        if (!rst_n) begin
            fc1_x_cnt <= 0;
            fc1_y_cnt <= 0;
        end else begin
            if (fc1_xv) fc1_x_cnt <= fc1_x_cnt + 1;
            if (fc1_yv && fc1_y_cnt < FC1_N) begin
                fc1_cap[fc1_y_cnt] <= fc1_yu;
                fc1_y_cnt <= fc1_y_cnt + 1;
            end
        end
    end

    // fc2 weight stream
    integer fc2_w_cnt = 0;
    assign fc2_wv = fc2_wr;
    assign fc2_wd = {fc2_w[fc2_w_cnt * 4 + 3], fc2_w[fc2_w_cnt * 4 + 2],
                     fc2_w[fc2_w_cnt * 4 + 1], fc2_w[fc2_w_cnt * 4 + 0]};

    always @(posedge clk) begin
        if (!rst_n) fc2_w_cnt <= 0;
        else if (fc2_wv && fc2_w_cnt < FC2_K) fc2_w_cnt <= fc2_w_cnt + 1;
    end

    integer fc2_x_cnt = 0;
    integer fc2_y_cnt = 0;
    reg [7:0] fc2_cap [0:15];
    always @(posedge clk) begin
        if (!rst_n) begin
            fc2_x_cnt <= 0;
            fc2_y_cnt <= 0;
        end else begin
            if (fc2_xv) fc2_x_cnt <= fc2_x_cnt + 1;
            if (fc2_yv && fc2_y_cnt < 16) begin
                fc2_cap[fc2_y_cnt] <= fc2_yu;
                fc2_y_cnt <= fc2_y_cnt + 1;
            end
        end
    end

    // softmax capture
    reg [15:0] probs_cap [0:FC2_N-1];
    integer    smx_out_cnt = 0;
    always @(posedge clk) begin
        if (rst_n && smx_ov) begin
            probs_cap[smx_idx] <= smx_q16;
            smx_out_cnt        <= smx_out_cnt + 1;
        end
    end

    // -----------------------------------------------------------------
    // Sequencer
    // -----------------------------------------------------------------
    integer i;
    integer errors = 0;
    integer checks = 0;
    integer gap_mism = 0, fc1_mism = 0, fc2_mism = 0, prob_mism = 0;

    task automatic check;
        input [511:0] name;
        input         ok;
        begin
            checks = checks + 1;
            if (ok) $display("CHECK PASS: %0s", name);
            else begin
                errors = errors + 1;
                $display("CHECK FAIL: %0s", name);
            end
        end
    endtask

    task automatic send_fc1_contract;
        begin
            for (i = 0; i < FC1_N; i = i + 1) begin
                fc1_bv <= 1'b1;
                fc1_mv <= 1'b1;
                fc1_sv <= 1'b1;
                fc1_b  <= $signed(fc1_ctr[i]);
                fc1_m  <= $signed(fc1_ctr[FC1_N + i]);
                fc1_s  <= fc1_ctr[2*FC1_N + i][6:0];
                @(posedge clk);
            end
            fc1_bv <= 1'b0;
            fc1_mv <= 1'b0;
            fc1_sv <= 1'b0;
        end
    endtask

    task automatic send_fc2_contract;
        begin
            for (i = 0; i < FC2_N; i = i + 1) begin
                fc2_bv <= 1'b1;
                fc2_mv <= 1'b1;
                fc2_sv <= 1'b1;
                fc2_b  <= $signed(fc2_ctr[i]);
                fc2_m  <= $signed(fc2_ctr[16 + i]);
                fc2_s  <= fc2_ctr[32 + i][6:0];
                @(posedge clk);
            end
            fc2_bv <= 1'b0;
            fc2_mv <= 1'b0;
            fc2_sv <= 1'b0;
        end
    endtask

    initial begin : sequencer
        // reset
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // gap layer start (also resets the fc input buffers).  The data
        // stream is released only AFTER this pulse has been sampled:
        // gap_unit clears its position counters on layer_start in S_ACC, so
        // releasing early would consume beats that the counter does not
        // account for and last_beat would never fire.
        @(posedge clk);
        gap_start <= 1'b1;
        @(posedge clk);
        gap_start <= 1'b0;
        stream_en  = 1'b1;

        // wait for the gap result stream to be fully loaded into fc1
        wait (fc1_x_cnt >= 256);
        send_fc1_contract();
        wait (fc1_y_cnt >= FC1_N);

        wait (fc2_x_cnt >= 128);
        send_fc2_contract();
        wait (fc2_y_cnt >= 8);
        repeat (20) @(posedge clk);

        // softmax logits = fc2 u8 - zp_out(57), lane i = logits[i]
        for (i = 0; i < FC2_N; i = i + 1)
            smx_logits[i*32 +: 32] = $signed({24'd0, fc2_cap[i]}) - 32'sd57;

        @(posedge clk);
        smx_start <= 1'b1;
        @(posedge clk);
        smx_start <= 1'b0;

        i = 0;
        while (!smx_done && i < 20000) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (4) @(posedge clk);

        // -------------------------------------------------------------
        // Compare every stage
        // -------------------------------------------------------------
        for (i = 0; i < GAP_N; i = i + 1)
            if (gap_cap[i] !== gap_exp[i][15:0]) begin
                gap_mism = gap_mism + 1;
                if (gap_mism <= 3)
                    $display("MISMATCH_DETAIL gap ch=%0d expected=%0d observed=%0d",
                             i, gap_exp[i], gap_cap[i]);
            end

        for (i = 0; i < FC1_N; i = i + 1)
            if (fc1_cap[i] !== fc1_exp[i]) begin
                fc1_mism = fc1_mism + 1;
                if (fc1_mism <= 3)
                    $display("MISMATCH_DETAIL fc1 ch=%0d expected=%0d observed=%0d",
                             i, fc1_exp[i], fc1_cap[i]);
            end

        for (i = 0; i < FC2_N; i = i + 1)
            if (fc2_cap[i] !== fc2_exp[i]) begin
                fc2_mism = fc2_mism + 1;
                if (fc2_mism <= 3)
                    $display("MISMATCH_DETAIL fc2 ch=%0d expected=%0d observed=%0d",
                             i, fc2_exp[i], fc2_cap[i]);
            end

        for (i = 0; i < FC2_N; i = i + 1)
            if (probs_cap[i] !== probs_exp[i]) begin
                prob_mism = prob_mism + 1;
                if (prob_mism <= 3)
                    $display("MISMATCH_DETAIL probs ch=%0d expected=%0d observed=%0d",
                             i, probs_exp[i], probs_cap[i]);
            end

        $display("STAGE gap:  samples=%0d mismatch=%0d (expect %0d)", gap_out_cnt, gap_mism, GAP_N);
        $display("STAGE fc1:  samples=%0d mismatch=%0d (expect %0d)", fc1_y_cnt, fc1_mism, FC1_N);
        $display("STAGE fc2:  samples=%0d mismatch=%0d (expect %0d)", fc2_y_cnt, fc2_mism, FC2_N);
        $display("STAGE prob: samples=%0d mismatch=%0d top1=%0d (expect %0d)",
                 smx_out_cnt, prob_mism, smx_top1, FC2_N);

        check("gap 256 channels bit-exact", gap_mism == 0 && gap_out_cnt == GAP_N);
        check("fc1 128 outputs bit-exact", fc1_mism == 0);
        check("fc2 8 outputs bit-exact", fc2_mism == 0);
        check("softmax 8 probabilities bit-exact", prob_mism == 0);

        if (errors == 0) begin
            $display("RESULT: PASS tb_npu_chain");
            $finish;
        end else begin
            $display("RESULT: FAIL tb_npu_chain (%0d errors)", errors);
            $fatal(1, "tb_npu_chain failed");
        end
    end

    initial begin : watchdog
        #(40ms);
        $display("ERROR: tb_npu_chain watchdog (gap_in=%0d gap_out=%0d fc1_x=%0d fc1_y=%0d fc2_x=%0d fc2_y=%0d)",
                 gap_in_cnt, gap_out_cnt, fc1_x_cnt, fc1_y_cnt, fc2_x_cnt, fc2_y_cnt);
        $fatal(1, "tb_npu_chain timeout");
    end

endmodule