// ---------------------------------------------------------------------------
// tb_mel_engine.sv -- direct-drive testbench for src/mel/mel_engine.v
//
// The board bring-up of the mel layer (T23/T26) failed twice because the
// scaffolding in top_mel_test.v faked DDR3 with a responder that answered only
// a handful of the 516 PCM read commands.  This TB replaces that scaffolding
// with a *simple behavioural* PCM source that honours the real master-2
// contract:
//
//   command bundle {wr, addr[27:0], len[7:0]}  (bit 36 = wr, 35:8 = addr,
//   7:0 = len -- confirmed by T26 against ddr3_ctrl_axi)
//   read command  -> `done` one pulse after the command is accepted, then
//                    len+1 = 16 beats of 256 bits (16 x s16 lane samples)
//   write command -> one wready_beat pulse per beat, `done` on the last one
//
// Window sample addressing: byte address / 2 = sample index, so one beat of
// 256 bits carries pcm[base + 0 .. 15].
//
// Two runs are provided by the runner sharing this one TB:
//
//   sim/run_sim.py mel         FILL_CREDIT = 1025 (unmodified source)
//                                -> must reproduce the credit deadlock:
//                                   cmds=4, accepted=1024, frames=0
//   sim/run_sim.py mel_credit  FILL_CREDIT = 1280 (source copy under
//                                build/sim/mel_credit/rtl, repo untouched)
//                                -> cmds=516, accepted=132096, frames>0 and
//                                   the 16512 feature bytes must match
//                                   reports/golden_ref/sine_440_full/feat.npy
//
// The feature read-back uses the SAME flattening as the golden table:
// sim/prep writes feat.T.reshape(-1) (golden is (mel=64, frame=258)), i.e.
// line index == frame*64 + mel, which is exactly the engine export index.
// T35 note: the table used to be indexed as mel*258+frame, which re-read a
// transposed golden and inflated the mismatch count by ~17x (4369 vs the
// real 261) without changing the underlying RTL result.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_mel_engine;

    localparam integer CLK_HALF   = 5;          // 100 MHz
    localparam integer PCM_N      = 132096;
    localparam integer FEAT_N     = 16512;
    localparam integer MAX_CYC    = 6_500_000;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    // -----------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------
    reg         win_tick   = 1'b0;
    reg  [15:0] win_id     = 16'd0;

    wire        m2_cmd_valid;
    wire [36:0] m2_cmd;
    wire [255:0] m2_wdata;
    reg         m2_wready    = 1'b0;
    reg         m2_rd_valid = 1'b0;
    wire        m2_rd_ready;
    reg  [255:0] m2_rd_data  = 256'd0;
    reg         m2_done      = 1'b0;

    wire        npu_start;
    wire        feat_page;
    reg  [14:0] feat_rd_addr = 15'd0;
    wire [7:0]  feat_rd_data;

    wire        mel_done;
    wire [31:0] mel_cycles;
    wire        mel_timeout;
    wire        win_miss;
    wire        busy;

    mel_engine #(
        .HAN_HEX_FILE ("src/mel/hann_q15.hex"),
        .COO_HEX_FILE ("src/mel/mel_coo.hex"),
        .LUT_HEX_FILE ("src/mel/log2_lut.hex"),
        .WATCHDOG_LIMIT (8_000_000)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .win_tick     (win_tick),
        .win_id       (win_id),
        .m2_cmd_valid (m2_cmd_valid),
        .m2_cmd       (m2_cmd),
        .m2_wdata     (m2_wdata),
        .m2_wready    (m2_wready),
        .m2_rd_valid  (m2_rd_valid),
        .m2_rd_ready  (m2_rd_ready),
        .m2_rd_data   (m2_rd_data),
        .m2_done      (m2_done),
        .npu_start    (npu_start),
        .feat_page    (feat_page),
        .feat_rd_addr (feat_rd_addr),
        .feat_rd_data (feat_rd_data),
        .mel_done     (mel_done),
        .mel_cycles   (mel_cycles),
        .mel_timeout  (mel_timeout),
        .win_miss     (win_miss),
        .busy         (busy)
    );

    // -----------------------------------------------------------------
    // PCM window + golden feature tables
    // -----------------------------------------------------------------
    reg [15:0] pcm       [0:PCM_N-1];
    reg [7:0]  gold_feat [0:FEAT_N-1];

    initial begin
        $readmemh("build/sim/mel/pcm.hex", pcm);
        $readmemh("build/sim/mel/golden_feat.hex", gold_feat);
        $display("=== tb_mel_engine start ===");
    end

    // -----------------------------------------------------------------
    // Behavioural PCM / spectrum-export responder (master 2)
    // -----------------------------------------------------------------
    localparam integer R_IDLE = 0;
    localparam integer R_DLY  = 1;
    localparam integer R_RD   = 2;
    localparam integer R_WR   = 3;

    reg [2:0]  rsp_state = R_IDLE;
    reg [36:0] c_cmd     = 37'd0;
    reg [27:0] c_addr    = 28'd0;
    reg [4:0]  beat      = 5'd0;
    integer    dly       = 0;

    // observations
    integer cmd_cnt      = 0;
    integer rd_beats     = 0;
    integer wr_cmds      = 0;
    integer addr_err     = 0;

    reg [255:0] pcm_beat_v;

    function [255:0] pcm_beat;
        input [27:0] addr;
        input [4:0]  idx;
        integer base;
        integer lane;
        begin
            base = addr[27:1] + idx * 16;      // sample index of the beat
            pcm_beat = 256'd0;
            for (lane = 0; lane < 16; lane = lane + 1)
                pcm_beat[lane*16 +: 16] = pcm[(base + lane) % PCM_N];
        end
    endfunction

    always @(posedge clk) begin
        m2_done     <= 1'b0;
        m2_wready   <= 1'b0;
        m2_rd_valid <= 1'b0;      // T34: one beat per handshake, default low

        if (!rst_n) begin
            rsp_state <= R_IDLE;
            beat      <= 5'd0;
            dly       <= 0;
        end else begin
            case (rsp_state)
                R_IDLE: begin
                    if (m2_cmd_valid) begin
                        c_cmd     <= m2_cmd;
                        c_addr    <= m2_cmd[35:8];
                        cmd_cnt   <= cmd_cnt + 1;
                        beat      <= 5'd0;
                        dly       <= 2;
                        rsp_state <= R_DLY;
                        if (!m2_cmd[36]) begin
                            // PCM read: window base is 0x0 or 0x84000
                            if (m2_cmd[35:8] > 28'h0008_4000)
                                addr_err <= addr_err + 1;
                        end else begin
                            wr_cmds <= wr_cmds + 1;
                        end
                    end
                end
                R_DLY: begin
                    if (dly > 0) begin
                        dly <= dly - 1;
                    end else if (c_cmd[36]) begin
                        m2_wready <= 1'b1;         // one beat write command
                        m2_done   <= 1'b1;
                        rsp_state <= R_IDLE;
                    end else begin
                        // T34: drive beat 0 here and hold it (valid + data)
                        // until mel_engine samples it in PC_BEAT. The old
                        // form parked beat 0 without m2_rd_valid and then
                        // streamed beats 1..15 back-to-back, so the engine
                        // (one beat per PC_BEAT visit, 16 clk of PC_FEED in
                        // between) lost most beats and the PCM stream no
                        // longer matched golden at all.
                        m2_done     <= 1'b1;
                        m2_rd_data  <= pcm_beat(c_addr, 5'd0);
                        m2_rd_valid <= 1'b1;
                        beat        <= 5'd0;
                        rsp_state   <= R_RD;
                    end
                end
                R_RD: begin
                    // One beat per accepted handshake: mel_engine only
                    // asserts m2_rd_ready while in PC_BEAT (one beat per
                    // 16 cycles of PC_FEED), so the beat must be held.
                    m2_rd_valid <= 1'b1;
                    if (m2_rd_ready) begin
                        rd_beats <= rd_beats + 1;
                        if (beat == 5'd15) begin
                            beat      <= 5'd0;
                            rsp_state <= R_IDLE;
                        end else begin
                            beat       <= beat + 5'd1;
                            m2_rd_data <= pcm_beat(c_addr, beat + 5'd1);
                        end
                    end
                end
                default: rsp_state <= R_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------
    // Feature read-back + golden compare (golden is mel*258+frame)
    // -----------------------------------------------------------------
    integer feat_mism = 0;
    integer feat_first = -1;
    reg [7:0] feat_exp = 8'd0;
    reg [7:0] feat_obs = 8'd0;
    integer idx;
    integer frame_i, mel_i;

    task automatic read_features;
        begin
            for (idx = 0; idx < FEAT_N; idx = idx + 1) begin
                feat_rd_addr = idx[14:0];
                @(posedge clk);
                @(posedge clk);
                frame_i = idx / 64;
                mel_i   = idx % 64;
                if (feat_rd_data !== gold_feat[idx]) begin
                    feat_mism = feat_mism + 1;
                    if (feat_first < 0) begin
                        feat_first = idx;
                        feat_exp   = gold_feat[idx];
                        feat_obs   = feat_rd_data;
                    end
                end
            end
        end
    endtask

    // -----------------------------------------------------------------
    // Control / reporting
    // -----------------------------------------------------------------
    integer cycles = 0;
    always @(posedge clk)
        if (rst_n) cycles <= cycles + 1;

    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // one window beat
        win_id   <= 16'd0;
        win_tick <= 1'b1;
        @(posedge clk);
        win_tick <= 1'b0;

        while (!mel_done && !mel_timeout && cycles < MAX_CYC)
            @(posedge clk);

        $display("MEL_CREDIT cmds=%0d accepted=%0d frames=%0d wr_cmds=%0d timeout=%0b done=%0b cycles=%0d",
                 cmd_cnt, rd_beats * 16, dut.frm_out, wr_cmds,
                 mel_timeout, mel_done, cycles);
        if (addr_err != 0)
            $display("MEL_ADDR_ERR %0d out-of-window PCM commands", addr_err);

        if (mel_timeout || !mel_done) begin
            // Deadlock reproduction: print the exact credit state so the
            // FILL_CREDIT arithmetic can be checked against the header.
            $display("DEADLOCK_REPRODUCED pc_credit=%0d pc_cmd_cnt=%0d pc_state=%0d frm_out=%0d",
                     dut.pc_credit, dut.pc_cmd_cnt, dut.pc_state, dut.frm_out);
            $display("RESULT: FAIL tb_mel_engine (deadlock reproduced: mel_timeout=%0b)",
                     mel_timeout);
            $finish;
        end

        $display("MEL_DONE mel_cycles=%0d feat_page=%0b", mel_cycles, feat_page);
        read_features();
        $display("FEAT_SAMPLES %0d mismatch %0d", FEAT_N, feat_mism);
        if (feat_first >= 0)
            $display("FIRST_MISMATCH feat_idx=%0d frame=%0d mel=%0d expected=%0d observed=%0d",
                     feat_first, feat_first / 64, feat_first % 64, feat_exp, feat_obs);
        else
            $display("FIRST_MISMATCH none");

        if (feat_mism == 0) begin
            $display("RESULT: PASS tb_mel_engine");
            $finish;
        end else begin
            $display("RESULT: FAIL tb_mel_engine (%0d feature bytes differ)", feat_mism);
            $fatal(1, "tb_mel_engine feature mismatch");
        end
    end

    initial begin : watchdog
        #(MAX_CYC * 10ns);
        $display("ERROR: tb_mel_engine wall-clock watchdog fired (cmds=%0d beats=%0d frames=%0d)",
                 cmd_cnt, rd_beats, dut.frm_out);
        $fatal(1, "tb_mel_engine timeout");
    end

endmodule