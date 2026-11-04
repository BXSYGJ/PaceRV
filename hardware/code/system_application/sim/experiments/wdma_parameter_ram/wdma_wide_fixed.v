// ---------------------------------------------------------------------------
// wdma.v -- weight DMA for the INT8 NPU (T-M2-02)
//
// Two streams per layer, both from DDR3 master 1:
//
//  1. Contract: bias/M/shift live after the weights in the same region.
//     They are read once at layer start into small on-chip RAMs, then
//     emitted per group as the 48-beat sequence conv_engine expects:
//       16 x bias (s32) -> 16 x M (s32) -> 16 x shift (u8/7-bit).
//     fc2 has only 8 channels; the group is zero-padded to 16 lanes.
//
//  2. Weights: a contiguous 32-byte beat stream cut into taps
//     (16 B conv/fc1, 8 B fc2). conv1 is the odd case: 27 taps = 432 B =
//     13.5 beats, so the last beat contributes one tap.
//
// Flow: contract read -> per (row, group) {48 contract beats, weight
// burst(s), tap emit} -> next (row, group). A 16-beat FIFO absorbs the 2:1
// rate difference between a 32-byte beat and a 16-byte tap, because the
// DDR3 IP cannot be back-pressured. w_data/w_valid are held until w_ready
// (conv/fc only accept during their MAC window).
//
// Group walk: conv_engine re-arms the weight window once per (row, group)
// -- the row pipeline walks H_IN rows and every row scans the same GRP_NUM
// channel groups, so the walk is grp_total = h_times * grp_num long
// (conv1 64*3=192, conv2 32*6=192, conv3 16*12=192, conv4 8*16=128).
// Every (row, group) re-reads the SAME weight group from DDR3 (h_times
// read amplification). The extra volume is bounded: ~7.6 MB per inference
// (conv4 alone 8*16*27648 B = 3.5 MB) against a 4 GB/s beat rate at
// 125 MHz -- under 2 ms of bus time versus ~234 ms of MAC time, so the
// re-read is acceptable and no weight cache is needed.
// ---------------------------------------------------------------------------

module wdma (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    input  wire [3:0]   layer_id,

    output reg          rd_cmd_valid,
    output reg  [36:0]  rd_cmd,
    input  wire         rd_ready,
    input  wire [255:0] rd_data,
    input  wire         rd_valid,
    input  wire         rd_done,

    output reg          w_valid,
    output reg  [127:0] w_data,
    input  wire         w_ready,
    input  wire         grp_advance,   // conv finished the current group

    output reg          grp_start,

    // 48-beat group contract toward conv_engine
    output reg          b_valid,
    output reg  signed [31:0] bias_s32,
    output reg          m_valid,
    output reg  signed [31:0] m_s32,
    output reg          s_valid,
    output reg  [6:0]   shift,

    output reg          busy,
    output reg          done
);

    // ---- layer geometry ----
    // h_times    : row repeats of the group table (== H_IN, pad-1 stride-1
    //              keeps out rows == in rows).
    // grp_num    : channel groups per row (16 output channels per group).
    // grp_total  : h_times * grp_num, counted out as (row, group)
    //              boundaries (explicit literals, no runtime multiply).
    // group_bytes: taps_per_grp * tap_bytes, the byte span of one group;
    // grp_beats  : ceil(group_bytes / 32), the beats read per group.
    reg [27:0] wb, bb, mb, sb;
    reg [8:0]  cout;
    reg [15:0] grp_num, grp_total;
    reg [7:0]  h_times;
    reg [15:0] taps_per_grp;
    reg [7:0]  tap_bytes;
    reg [15:0] group_bytes, grp_beats;

    always @* begin
        case (layer_id)
            4'd0: begin wb=28'd512;    bb=28'd944;    mb=28'd1136;   sb=28'd1328;
                         cout=9'd48;  h_times=8'd64; grp_num=16'd3;
                         grp_total=16'd192;   // 64 * 3
                         taps_per_grp=16'd9;    tap_bytes=8'd16;
                         group_bytes=16'd144;  grp_beats=16'd5;    end
            4'd1: begin wb=28'd1376;   bb=28'd42848;  mb=28'd43232;  sb=28'd43616;
                         cout=9'd96;  h_times=8'd32; grp_num=16'd6;
                         grp_total=16'd192;   // 32 * 6
                         taps_per_grp=16'd432;  tap_bytes=8'd16;
                         group_bytes=16'd6912; grp_beats=16'd216;  end
            4'd2: begin wb=28'd43712;  bb=28'd209600; mb=28'd210368; sb=28'd211136;
                         cout=9'd192; h_times=8'd16; grp_num=16'd12;
                         grp_total=16'd192;   // 16 * 12
                         taps_per_grp=16'd864;  tap_bytes=8'd16;
                         group_bytes=16'd13824; grp_beats=16'd432; end
            4'd3: begin wb=28'd211328; bb=28'd653696; mb=28'd654720; sb=28'd655744;
                         cout=9'd256; h_times=8'd8;  grp_num=16'd16;
                         grp_total=16'd128;   // 8 * 16
                         taps_per_grp=16'd1728; tap_bytes=8'd16;
                         group_bytes=16'd27648; grp_beats=16'd864; end
            4'd4: begin wb=28'd656000; bb=28'd688768; mb=28'd689280; sb=28'd689792;
                         cout=9'd128; h_times=8'd1;  grp_num=16'd8;
                         grp_total=16'd8;     // 1 * 8 (fc: one row only)
                         taps_per_grp=16'd256;  tap_bytes=8'd16;
                         group_bytes=16'd4096; grp_beats=16'd128;  end
            default: begin wb=28'd689920; bb=28'd690944; mb=28'd690976; sb=28'd691008;
                         cout=9'd8;   h_times=8'd1;  grp_num=16'd1;
                         grp_total=16'd1;     // 1 * 1 (fc: one row only)
                         taps_per_grp=16'd128;  tap_bytes=8'd8;
                         group_bytes=16'd1024; grp_beats=16'd32;   end
        endcase
    end

    localparam [3:0] S_IDLE   = 4'd0;
    localparam [3:0] S_CB_CMD = 4'd1;
    localparam [3:0] S_CB_FIL = 4'd2;
    localparam [3:0] S_CM_CMD = 4'd3;
    localparam [3:0] S_CM_FIL = 4'd4;
    localparam [3:0] S_CS_CMD = 4'd5;
    localparam [3:0] S_CS_FIL = 4'd6;
    localparam [3:0] S_GRP    = 4'd7;
    localparam [3:0] S_TCMD   = 4'd8;
    localparam [3:0] S_TFIL   = 4'd9;
    localparam [3:0] S_TEMIT  = 4'd10;
    localparam [3:0] S_NEXT   = 4'd11;
    localparam [3:0] S_DONE   = 4'd12;
    localparam [3:0] S_PRIME = 4'd13;
    reg [3:0] state;

    // One 768x32 block RAM holds the three per-channel parameter tables:
    //   [  0..255] bias (s32)
    //   [256..511] M    (Q0.31, s32)
    //   [512..767] shift (6-bit value in the low byte)
    // The old code used three separately-addressed arrays read asynchronously,
    // so PDS had to build them from LUTRAM/FF: u_wdma measured 8004 LUT /
    // 18608 FF, which is also where the worst core_clk path lives
    // (c_cnt -> m_s32: 0.8 ns logic, 8.8 ns route = 92%).
    // A single synchronous-read port keeps the whole table in one DRAM.
    // (syn_ramstyle alone was tried first and was ignored for async reads.)
    // Wide single-write-port parameter stores; preserve original addressing.
    (* syn_ramstyle = "block_ram" *) reg [255:0] param_bm [0:63];
    (* syn_ramstyle = "block_ram" *) reg [255:0] param_shift [0:15];
    reg [255:0] param_bm_q;
    reg [255:0] param_shift_q;
    reg [4:0] param_lane_q;
    reg param_shift_sel_q;
    reg param_q_valid;

    reg  [9:0]  pa;          // read address presented this cycle
    wire [31:0] pq;          // data returned for the address given last cycle
    wire [31:0] param_bm_word = param_bm_q[param_lane_q[2:0]*32 +: 32];
    wire [7:0] param_shift_byte = param_shift_q[param_lane_q*8 +: 8];
    assign pq = !param_q_valid ? 32'd0 :
                param_shift_sel_q ? {24'd0, param_shift_byte} : param_bm_word;

    // contract read bookkeeping
    reg [15:0] cfg_beats_left;
    reg [4:0]  cfg_cmd_beats;
    reg [27:0] cfg_addr;
    reg [8:0]  cfg_idx;      // element index inside the current contract

    // contract emit
    reg [8:0]  c_cnt;
    reg [15:0] grp_cnt;      // 0..grp_total-1: (row, group) walk position
    reg [4:0]  grp_mod;      // 0..grp_num-1: channel group inside the row
    reg [27:0] grp_base;     // wb + grp_mod * group_bytes (tracked by add)

    // weight stream
    reg [255:0] fifo [0:15];
    reg [4:0]   wr_ptr, rd_ptr, fifo_cnt;
    reg [15:0]  taps_left, beats_left;
    reg [4:0]   cmd_beats, emit_beats;
    reg [7:0]   sub;
    reg [15:0]  tap_in_grp;
    reg [27:0]  cur_addr;

    // conv1's group stride is 144 B, so odd groups start 16 B into a 32 B
    // beat. The read address is aligned down and the first beat's low half
    // is skipped: grp_off marks that half-beat pad, first_chunk makes it
    // apply to the first weight command of a group only. Every other layer
    // has a 32 B group stride, so grp_off stays 0 and the beat/tap stream is
    // bit-identical to the unaligned-free path.
    reg         grp_off;
    reg         first_chunk;

    wire [255:0] beat_c = fifo[rd_ptr[3:0]];
    wire [31:0]  total_taps  = taps_per_grp * grp_total;
    wire [31:0]  total_bytes = total_taps * tap_bytes;
    wire [15:0]  total_beats = (total_bytes + 32'd31) >> 5;
    wire [4:0]   chunk = (cfg_beats_left > 16'd16) ? 5'd16 : cfg_beats_left[4:0];
    wire         is_fc = (layer_id >= 4'd4);
    wire [9:0]   cfg_end = is_fc ? ({1'b0, cout} * 10'd3) : 10'd48;

    // Aligned group read: next_base is the unaligned start of the group that
    // S_NEXT is stepping to. When bit 4 is set the group begins 16 B into a
    // beat, so one extra beat is needed to cover the last tap.
    wire [27:0]  next_base     = grp_base + {12'd0, group_bytes};
    wire [15:0]  grp_beats_alg = next_base[4] ? ((group_bytes + 16'd47) >> 5)
                                              : grp_beats;

    // Contract RAM index: grp_mod * 16 + lane (no modulo, no divider).
    wire [8:0]  ctr_idx  = {grp_mod[3:0], 4'd0} + {5'd0, c_cnt[3:0]};
    wire        ctr_hit  = (ctr_idx < {1'b0, cout});
    wire [7:0]  ctr_addr = ctr_idx[7:0];

    // Address pipeline for the shared parameter table (see pram).  The data
    // for index i arrives one cycle after pa=i is presented, so S_GRP consumes
    // pq and issues the address for the NEXT element in the same cycle.
    // pa presents the address for element t+1 while S_GRP is at element t,
    // because pq is registered one cycle later.  So the NEXT address to
    // present is element (t+2), not (t+1).  The table is padded to 1024 words
    // so the last iteration's look-ahead reads a zeroed slot instead of
    // running past the end.
    wire [9:0]  c_cnt_n   = {1'b0, c_cnt} + 10'd2;
    wire [8:0]  ctr_idx_n = {grp_mod[3:0], 4'd0} + c_cnt_n[3:0];
    wire [9:0]  pa_fc     = (c_cnt_n < {1'b0, cout}) ? c_cnt_n :
                            (c_cnt_n < ({2'b0, cout} + {2'b0, cout})) ?
                                 (10'd256 + c_cnt_n - cout) :
                                 (10'd512 + c_cnt_n - cout - cout);
    wire [9:0]  pa_cv     = (c_cnt_n < 10'd16) ? ctr_idx_n :
                            (c_cnt_n < 10'd32) ? (10'd256 + ctr_idx_n) :
                                                 (10'd512 + ctr_idx_n);
    wire [9:0]  pa_next   = is_fc ? pa_fc : pa_cv;
    wire signed [31:0] pq_s = pq;

    // Present the current FIFO tap; advance only on its actual handshake.
    // The pointer holds under backpressure, so both valid and data hold too.
    always @* begin
        w_valid = (state == S_TEMIT && emit_beats != 5'd0 && taps_left != 16'd0);
        w_data = 128'd0;
        if (tap_bytes == 8'd16)
            w_data = sub[0] ? beat_c[255:128] : beat_c[127:0];
        else case (sub[1:0])
            2'd0: w_data = {64'd0, beat_c[63:0]};
            2'd1: w_data = {64'd0, beat_c[127:64]};
            2'd2: w_data = {64'd0, beat_c[191:128]};
            default: w_data = {64'd0, beat_c[255:192]};
        endcase
    end

    // FIFO write (never back-pressured by the IP).
    always @(posedge clk) begin
        if (rd_valid) fifo[wr_ptr[3:0]] <= rd_data;
    end

    // Corrected element indices map one DDR beat to one wide RAM word.
    always @(posedge clk) begin
        if (rd_valid && (state == S_CB_FIL))
            param_bm[{1'b0, cfg_idx[7:3]}] <= rd_data;
        else if (rd_valid && (state == S_CM_FIL))
            param_bm[{1'b1, cfg_idx[7:3]}] <= rd_data;
        if (rd_valid && (state == S_CS_FIL))
            param_shift[cfg_idx[7:5]] <= rd_data;
    end

    // Both reads retain read-first behavior on a coincident write.
    // Keep reset off the inferred block RAM output registers.
    always @(posedge clk) begin
        param_bm_q <= param_bm[pa[8:3]];
        param_shift_q <= param_shift[pa[7:5]];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            param_lane_q <= 5'd0;
            param_shift_sel_q <= 1'b0;
            param_q_valid <= 1'b0;
        end else begin
            param_lane_q <= pa[4:0];
            param_shift_sel_q <= pa[9];
            param_q_valid <= 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            rd_cmd_valid <= 1'b0;
            rd_cmd       <= 37'd0;
            grp_start    <= 1'b0;
            b_valid      <= 1'b0;
            m_valid      <= 1'b0;
            s_valid      <= 1'b0;
            busy         <= 1'b0;
            done         <= 1'b0;
            cfg_beats_left <= 16'd0;
            cfg_cmd_beats  <= 5'd0;
            cfg_addr       <= 28'd0;
            cfg_idx        <= 9'd0;
            c_cnt          <= 6'd0;
            grp_cnt        <= 16'd0;
            grp_mod        <= 5'd0;
            grp_base       <= 28'd0;
            wr_ptr         <= 5'd0;
            rd_ptr         <= 5'd0;
            fifo_cnt       <= 5'd0;
            taps_left      <= 16'd0;
            beats_left     <= 16'd0;
            cmd_beats      <= 5'd0;
            emit_beats     <= 5'd0;
            sub            <= 8'd0;
            tap_in_grp     <= 16'd0;
            cur_addr       <= 28'd0;
            grp_off        <= 1'b0;
            first_chunk    <= 1'b0;
        end else begin
            grp_start <= 1'b0;
            b_valid   <= 1'b0;
            m_valid   <= 1'b0;
            s_valid   <= 1'b0;
            done      <= 1'b0;

            if (rd_valid) begin
                wr_ptr   <= wr_ptr + 5'd1;
                fifo_cnt <= fifo_cnt + 5'd1;
            end
            if (rd_valid && (state == S_CB_FIL || state == S_CM_FIL))
                cfg_idx <= cfg_idx + 9'd8;
            if (rd_valid && (state == S_CS_FIL))
                cfg_idx <= cfg_idx + 9'd32;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy           <= 1'b1;
                        grp_cnt        <= 16'd0;
                        cfg_addr       <= bb;
                        cfg_idx        <= 9'd0;
                        cfg_beats_left <= (cout + 9'd7) >> 3;
                        state          <= S_CB_CMD;
                    end
                end

                // ---- bias ----
                S_CB_CMD: begin
                    cfg_cmd_beats <= chunk;
                    rd_cmd <= {1'b0, cfg_addr,
                               ((cfg_beats_left > 16'd16) ? 8'd15 : (cfg_beats_left[7:0] - 8'd1))};
                    rd_cmd_valid <= 1'b1;
                    state <= S_CB_FIL;
                end
                S_CB_FIL: begin
                    if (rd_done) begin
                        rd_cmd_valid   <= 1'b0;
                        cfg_addr       <= cfg_addr + {19'd0, cfg_cmd_beats, 5'd0};
                        cfg_beats_left <= cfg_beats_left - {11'd0, cfg_cmd_beats};
                        if (cfg_beats_left <= 16'd16) begin
                            cfg_addr <= mb;
                            cfg_idx  <= 9'd0;
                            cfg_beats_left <= (cout + 9'd7) >> 3;
                            state <= S_CM_CMD;
                        end else begin
                            state <= S_CB_CMD;
                        end
                    end
                end

                // ---- M ----
                S_CM_CMD: begin
                    cfg_cmd_beats <= chunk;
                    rd_cmd <= {1'b0, cfg_addr,
                               ((cfg_beats_left > 16'd16) ? 8'd15 : (cfg_beats_left[7:0] - 8'd1))};
                    rd_cmd_valid <= 1'b1;
                    state <= S_CM_FIL;
                end
                S_CM_FIL: begin
                    if (rd_done) begin
                        rd_cmd_valid   <= 1'b0;
                        cfg_addr       <= cfg_addr + {19'd0, cfg_cmd_beats, 5'd0};
                        cfg_beats_left <= cfg_beats_left - {11'd0, cfg_cmd_beats};
                        if (cfg_beats_left <= 16'd16) begin
                            cfg_addr <= sb;
                            cfg_idx  <= 9'd0;
                            cfg_beats_left <= (cout + 9'd31) >> 5;
                            state <= S_CS_CMD;
                        end else begin
                            state <= S_CM_CMD;
                        end
                    end
                end

                // ---- shift ----
                S_CS_CMD: begin
                    cfg_cmd_beats <= chunk;
                    rd_cmd <= {1'b0, cfg_addr,
                               ((cfg_beats_left > 16'd16) ? 8'd15 : (cfg_beats_left[7:0] - 8'd1))};
                    rd_cmd_valid <= 1'b1;
                    // Preset the parameter-table read address here, not in
                    // S_CS_FIL: pq is registered from the address of the
                    // PREVIOUS cycle, so the address needs one extra cycle of
                    // settling before S_GRP consumes pq.  Both contract types
                    // start at index 0 (fc bias[0]; conv grp_mod is still 0).
                    pa    <= 10'd0;
                    state <= S_CS_FIL;
                end
                S_CS_FIL: begin
                    if (rd_done) begin
                        rd_cmd_valid   <= 1'b0;
                        cfg_addr       <= cfg_addr + {19'd0, cfg_cmd_beats, 5'd0};
                        cfg_beats_left <= cfg_beats_left - {11'd0, cfg_cmd_beats};
                        if (cfg_beats_left <= 16'd16) begin
                            c_cnt     <= 9'd0;
                            grp_cnt   <= 16'd0;
                            grp_mod   <= 5'd0;
                            grp_base  <= wb;
                            tap_in_grp<= 16'd0;
                            cur_addr  <= {wb[27:5], 5'd0};
                            grp_off   <= wb[4];
                            first_chunk <= 1'b1;
                            taps_left <= taps_per_grp;
                            beats_left<= wb[4] ? ((group_bytes + 16'd47) >> 5)
                                               : grp_beats;
                            wr_ptr    <= 5'd0;
                            rd_ptr    <= 5'd0;
                            fifo_cnt  <= 5'd0;
                            // pq is registered from the PREVIOUS cycle's pa,
                            // so S_GRP cycle 0 already consumes pram[0] (loaded
                            // during S_CS_FIL) and pa must already point at the
                            // SECOND element when S_GRP starts.  Both contract
                            // shapes index element 1 by 1 (new group: grp_mod=0).
                            pa        <= 10'd1;
                            state     <= S_GRP; grp_start <= 1'b1;
                        end else begin
                            state <= S_CS_CMD;
                        end
                    end
                end

                // ---- 48-beat group contract ----
                S_GRP: begin
                    

                    if (is_fc) begin
                        // fc contract: COUT beats each of bias, M, shift.
                        if (c_cnt < cout) begin
                            b_valid  <= 1'b1;
                            bias_s32 <= pq_s;
                        end else if (c_cnt < {1'b0, cout} + {1'b0, cout}) begin
                            m_valid  <= 1'b1;
                            m_s32    <= pq_s;
                        end else begin
                            s_valid  <= 1'b1;
                            shift    <= pq_s[6:0];
                        end
                    end else begin
                        // conv contract: 16 bias + 16 M + 16 shift per group,
                        // indexed by the channel group inside the current row
                        // (grp_mod), NOT by the (row, group) walk counter.
                        if (c_cnt < 9'd16) begin
                            b_valid  <= 1'b1;
                            bias_s32 <= ctr_hit ? pq_s : 32'sd0;
                        end else if (c_cnt < 9'd32) begin
                            m_valid <= 1'b1;
                            m_s32   <= ctr_hit ? pq_s : 32'sd0;
                        end else begin
                            s_valid <= 1'b1;
                            shift   <= ctr_hit ? pq_s[6:0] : 7'd0;
                        end
                    end
                    pa <= pa_next;

                    c_cnt <= c_cnt + 9'd1;
                    if (({1'b0, c_cnt} + 10'd1) == cfg_end) state <= S_TCMD;
                end

                // ---- weight burst for this group ----
                S_TCMD: begin
                    if (beats_left == 16'd0) begin
                        state <= S_NEXT;
                    end else begin
                        cmd_beats <= (beats_left > 16'd16) ? 5'd16 : beats_left[4:0];
                        rd_cmd <= {1'b0, cur_addr,
                                   ((beats_left > 16'd16) ? 8'd15 : (beats_left[7:0] - 8'd1))};
                        rd_cmd_valid <= 1'b1;
                        state <= S_TFIL;
                    end
                end
                S_TFIL: begin
                    if (rd_done) begin
                        rd_cmd_valid <= 1'b0;
                        cur_addr     <= cur_addr + {19'd0, cmd_beats, 5'd0};
                        beats_left   <= beats_left - {11'd0, cmd_beats};
                        emit_beats   <= cmd_beats;
                        // Offset groups start at the high half of the first
                        // beat; sub == 1 selects [255:128] and consumes that
                        // beat after the first tap.
                        sub          <= (first_chunk && grp_off) ? 8'd1 : 8'd0;
                        first_chunk  <= 1'b0;
                        state        <= S_TEMIT;
                    end
                end
                S_TEMIT: begin
                    if (emit_beats != 5'd0 && taps_left != 16'd0) begin
                        if (w_ready) begin
                            tap_in_grp <= (tap_in_grp + 16'd1 == taps_per_grp) ? 16'd0 : tap_in_grp + 16'd1;
                            taps_left  <= taps_left - 16'd1; if (taps_left == 16'd1) state <= S_NEXT;
                            if ((tap_bytes == 8'd16 && sub == 8'd1) ||
                                (tap_bytes == 8'd8  && sub == 8'd3)) begin
                                sub        <= 8'd0;
                                rd_ptr     <= rd_ptr + 5'd1;
                                fifo_cnt   <= fifo_cnt - 5'd1;
                                emit_beats <= emit_beats - 5'd1;
                                if (taps_left == 16'd1) begin
                                    state <= S_NEXT;
                                end else if (emit_beats == 5'd1) begin
                                    state <= S_TCMD;
                                end
                            end else begin
                                sub <= sub + 8'd1;
                            end
                        end
                    end
                end

                S_NEXT: begin
                    // NOTE: grp_advance is sampled by the caller for
                    // observability, but the DMA keeps its own group rhythm.
                    // Waiting here can deadlock when the conv pulse arrives
                    // before S_NEXT; revisit with simulation.
                    if (grp_cnt + 16'd1 == grp_total) begin
                        state <= S_DONE;
                    end else begin
                        grp_cnt <= grp_cnt + 16'd1;
                        // Next (row, group): grp_mod cycles 0..grp_num-1, and
                        // the weight base steps by group_bytes inside a row
                        // (== wb + grp_mod * group_bytes) and snaps back to
                        // wb on row rollover. Tracked by addition so no
                        // multiplier/divider is inferred.
                        if (grp_mod + 5'd1 == grp_num[4:0]) begin
                            grp_mod  <= 5'd0;
                            grp_base <= wb;
                            cur_addr <= {wb[27:5], 5'd0};
                            grp_off  <= wb[4];
                            beats_left <= wb[4] ? ((group_bytes + 16'd47) >> 5)
                                                : grp_beats;
                        end else begin
                            grp_mod  <= grp_mod + 5'd1;
                            grp_base <= next_base;
                            cur_addr <= {next_base[27:5], 5'd0};
                            grp_off  <= next_base[4];
                            beats_left <= grp_beats_alg;
                        end
                        first_chunk <= 1'b1;
                        tap_in_grp <= 16'd0;
                        taps_left  <= taps_per_grp;
                        // Drop the leftover of a partial last beat (conv1:
                        // 9 taps = 4.5 beats) so the next group's burst starts
                        // with clean FIFO pointers.
                        wr_ptr     <= 5'd0;
                        rd_ptr     <= 5'd0;
                        fifo_cnt   <= 5'd0;
                        c_cnt      <= 9'd0;
                        pa <= (is_fc || grp_mod + 5'd1 == grp_num[4:0]) ? 10'd0 : {2'd0,grp_mod[3:0],4'd0} + 10'd16;
                        state <= S_PRIME; grp_start <= 1'b1;
                    end
                end

                S_PRIME: begin
                    pa <= (is_fc ? 10'd0 : {2'd0,grp_mod[3:0],4'd0}) + 10'd1;
                    state <= S_GRP;
                end
                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule