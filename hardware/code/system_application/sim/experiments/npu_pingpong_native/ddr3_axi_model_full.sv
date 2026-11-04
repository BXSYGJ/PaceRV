// -----------------------------------------------------------------------------
// File    : ddr3_axi_model.sv
// Module  : ddr3_axi_model
// Project : InstRec-FPGA / T28 DDR3 subsystem simulation
// Purpose : Behavioral model of the Pango DDR3 hard-IP user-side AXI ports,
//           reproducing the NON-STANDARD contract that the real IP presents
//           (this is a hard fact of the project, do NOT "fix" it towards
//           standard AXI):
//
//   1. There is NO axi_rready input on the IP. Once a read burst starts the
//      IP pushes one beat per cycle unconditionally; the consumer must be
//      able to accept every cycle. This model therefore drives rvalid/rdata
//      with a plain counter and never waits for any ready.
//
//   2. There is NO axi_wvalid input on the IP. A write beat is accepted on
//      every cycle where axi_wready is high. The controller sees
//      "wready high == this beat was taken". The model keeps the same view.
//
//   3. There is no write-response (b) channel. A write burst is complete when
//      the programmed number of beats (awlen+1) has been accepted.
//
//   4. axi_wusero_last is the IP's "last beat of the burst was taken" marker.
//      It is raised for LAST_HOLD cycles starting the cycle AFTER the last
//      beat is accepted, which covers the 4-cycle epilogue window the
//      controller uses for its side-evidence check.
//
// Fault injection is parameterised so the testbench can reproduce the board
// failure modes and the known watchdog blind spot:
//   AW_READY_AW_COUNT    : only the first N AW bursts ever see awready
//                          (0 = "awready never comes", -1 = unlimited).
//   W_READY_BURST_COUNT  : only the first N write bursts ever see wready
//                          (0 = "wready never comes", -1 = unlimited).
//   AR_NEVER             : arready is never asserted.
//   R_MODE               : 0 = normal streaming read data
//                          1 = rvalid stuck high, rlast never asserted
//                              (the controller watchdog blind spot: it only
//                              counts S_R && !rvalid, so it never times out)
//                          2 = rvalid stuck low (read data never returns)
//
// Experimental full-address variant: flat 256-bit beats indexed by addr[27:5].
// Use MEM_BEATS=262144 for 8 MiB; runtime checks reject out-of-range commands.
// The original sim/ddr3_axi_model.sv intentionally uses only addr[20:5].
// This file does not inherit that low-2-MiB aliasing.
//
// This file is simulation-only. It is not part of src/** and is not built by
// PDS.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module ddr3_axi_model_full #(
    // ffff 0 = awready present immediately; N = the first N AW bursts get ready
    parameter integer AW_READY_AW_COUNT   = -1,
    // 0 = wready present immediately; N = the first N write bursts get wready
    parameter integer W_READY_BURST_COUNT = -1,
    // fixed latency knobs (cycles)
    parameter integer AW_DELAY            = 0,
    parameter integer W_DELAY             = 0,
    parameter integer AR_DELAY            = 0,
    // fault injection switches
    parameter integer AR_NEVER            = 0,
    parameter integer R_MODE              = 0,
    // beat memory size (256-bit beats), covers the low 2 MB of the address map
    parameter integer MEM_BEATS           = 65536,
    // 1 = the IP ignores the byte strobes and always writes all 32 bytes.
    //     This models a hard IP whose data mask (DM) path does not honour
    //     wstrb == 0, which turns the mandatory dummy-write-before-read into a
    //     real write of zeros at the read address (T37 experiment A5).
    parameter integer WSTRB_IGNORE        = 0
) (
    input  wire         clk,
    input  wire         rst_n,
    // ---- write address channel (IP is the slave) ----
    input  wire [27:0]  s_awaddr,
    input  wire         s_awvalid,
    input  wire [3:0]   s_awlen,      // beats-1
    input  wire [3:0]   s_awuser_id,  // master id from the controller
    output wire         s_awready,
    // ---- write data channel: NO wvalid ----
    input  wire [255:0] s_wdata,
    input  wire [31:0]  s_wstrb,
    output wire         s_wready,
    output wire         s_wusero_last,
    // ---- read address channel ----
    input  wire [27:0]  s_araddr,
    input  wire         s_arvalid,
    input  wire [3:0]   s_arlen,
    input  wire [3:0]   s_aruser_id,
    output wire         s_arready,
    // ---- read data channel: NO rready ----
    output wire [255:0] s_rdata,
    output wire [3:0]   s_rid,
    output wire         s_rlast,
    output wire         s_rvalid,
    // ---- observation (testbench only, not part of the IP contract) ----
    output reg  [31:0]  obs_aw_hs,        // AW handshakes seen
    output reg  [31:0]  obs_ar_hs,        // AR handshakes seen
    output reg  [31:0]  obs_wr_beats,     // write beats accepted
    output reg  [31:0]  obs_rd_beats,     // read beats pushed
    output reg  [31:0]  obs_len0_wr,      // single-beat write bursts (len=0)
    output reg  [31:0]  obs_len0_wstrb0,  // of those, wstrb == all zero
    output reg  [31:0]  obs_len0_wstrb1,  // of those, wstrb == all ones
    output reg  [31:0]  obs_last_marker   // wusero_last pulses seen
);

    // ------------------------------------------------------------------
    // Constants derived from the parameters (integer -> sized locals,
    // avoids signed/unsigned comparison surprises inside the model)
    // ------------------------------------------------------------------
    localparam [31:0] AW_LIMIT  = AW_READY_AW_COUNT[31:0];
    localparam [31:0] W_LIMIT   = W_READY_BURST_COUNT[31:0];
    localparam        AW_LIM_ON = (AW_READY_AW_COUNT >= 0);
    localparam        W_LIM_ON  = (W_READY_BURST_COUNT >= 0);
    localparam [3:0]  AW_DLY_C  = AW_DELAY[3:0];
    localparam [3:0]  W_DLY_C   = W_DELAY[3:0];
    localparam [3:0]  AR_DLY_C  = AR_DELAY[3:0];

    localparam [2:0]  LAST_HOLD = 3'd4;   // wusero_last high for 4 cycles

    // ------------------------------------------------------------------
    // Beat memory (256-bit x MEM_BEATS). Zeroed once at time 0 so the
    // simulation is deterministic even when Verilator runs in 2-state mode.
    // ------------------------------------------------------------------
    reg [255:0] mem [0:MEM_BEATS-1];
    integer mi;

    initial begin
        for (mi = 0; mi < MEM_BEATS; mi = mi + 1) begin
            mem[mi] = 256'd0;
        end
    end

    // ------------------------------------------------------------------
    // Write path state
    // ------------------------------------------------------------------
    reg        aw_pending;    // an AW was accepted, burst not complete
    reg [27:0] aw_addr_r;
    reg [3:0]  aw_len_r;
    reg [4:0]  wr_beats_left;
    reg [4:0]  wr_beat_idx;
    reg [31:0] aw_cnt;        // AW handshakes so far
    reg [31:0] wr_burst_seq;  // burst sequence number currently executing
    reg [3:0]  aw_dly;
    reg [3:0]  w_dly;
    reg [2:0]  last_cnt;

    // Read path state
    reg        ar_pending;
    reg        r_push;
    reg [27:0] ar_addr_r;
    reg [4:0]  rd_beats_left;
    reg [4:0]  rd_beat_idx;
    reg [3:0]  r_id_r;
    reg [3:0]  ar_dly;

    // ------------------------------------------------------------------
    // Memory index helpers: 32-byte beats, low 128 KB window
    // ------------------------------------------------------------------
    // 16-bit index covers the low 2 MB of the address space; the self-test
    // region (0x0030_0000) and the PCM windows (0x0000_0020 / 0x0008_4020)
    // then never alias each other (a 12-bit index did alias them, which
    // produced a false self-test data mismatch in an earlier revision).
    wire [23:0] wr_mem_idx = {1'b0,aw_addr_r[27:5]} + wr_beat_idx;
    wire [23:0] rd_mem_idx = {1'b0,ar_addr_r[27:5]} + rd_beat_idx;

    // ------------------------------------------------------------------
    // Ready generation (fault-injected)
    // ------------------------------------------------------------------
    wire aw_allowed = !AW_LIM_ON || (aw_cnt < AW_LIMIT);
    wire w_allowed  = !W_LIM_ON  || (wr_burst_seq < W_LIMIT);

    assign s_awready = s_awvalid && !aw_pending && aw_allowed &&
                       (aw_dly >= AW_DLY_C);

    // No wvalid: a beat is taken whenever wready is high.
    assign s_wready  = aw_pending && (wr_beats_left != 5'd0) && w_allowed &&
                       (w_dly >= W_DLY_C);

    assign s_wusero_last = (last_cnt != 3'd0);

    // ------------------------------------------------------------------
    // Read side
    // ------------------------------------------------------------------
    assign s_arready = s_arvalid && !ar_pending && (AR_NEVER == 0) &&
                       (ar_dly >= AR_DLY_C);

    // R_MODE 0: stream while a burst is active; 1: rvalid stuck high and
    // rlast never asserted; 2: rvalid stuck low.
    assign s_rvalid = (R_MODE == 2) ? 1'b0 :
                      (R_MODE == 1) ? 1'b1 : r_push;
    // rlast is asserted together with the last data beat.
    assign s_rlast  = (R_MODE == 1) ? 1'b0 : (r_push && (rd_beats_left == 5'd1));
    assign s_rdata  = (R_MODE == 1) ? {8{32'hB1B2_B3B4}} : mem[rd_mem_idx];
    assign s_rid    = r_id_r;

    // ------------------------------------------------------------------
    // Write data apply (byte strobes honoured: wstrb=0 leaves the byte
    // untouched). This is what makes the DUMMY_WSTRB_ALL1=1 configuration
    // destroy the first beat of the region being read.
    // ------------------------------------------------------------------
    reg [255:0] w_tmp;
    integer     bi;

    always @(posedge clk) begin
        if (s_wready) begin
            if (WSTRB_IGNORE != 0) begin
                // strobe-blind write: every byte is replaced
                mem[wr_mem_idx] <= s_wdata;
            end else if (s_wstrb != 32'h0000_0000) begin
                w_tmp = mem[wr_mem_idx];
                for (bi = 0; bi < 32; bi = bi + 1) begin
                    if (s_wstrb[bi]) begin
                        w_tmp[bi*8 +: 8] = s_wdata[bi*8 +: 8];
                    end
                end
                mem[wr_mem_idx] <= w_tmp;
            end
        end
    end

    // ------------------------------------------------------------------
    // Write channel control
    // ------------------------------------------------------------------
    wire aw_hs = s_awvalid && s_awready;
    wire w_hs  = s_wready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_pending    <= 1'b0;
            aw_addr_r     <= 28'd0;
            aw_len_r      <= 4'd0;
            wr_beats_left <= 5'd0;
            wr_beat_idx   <= 5'd0;
            aw_cnt        <= 32'd0;
            wr_burst_seq  <= 32'd0;
            aw_dly        <= 4'd0;
            w_dly         <= 4'd0;
            last_cnt      <= 3'd0;
            obs_aw_hs       <= 32'd0;
            obs_wr_beats    <= 32'd0;
            obs_len0_wr     <= 32'd0;
            obs_len0_wstrb0 <= 32'd0;
            obs_len0_wstrb1 <= 32'd0;
            obs_last_marker <= 32'd0;
        end else begin
            // AW arrival latency counter
            if (s_awvalid && !aw_pending && !s_awready) begin
                aw_dly <= aw_dly + 4'd1;
            end else if (!s_awvalid) begin
                aw_dly <= 4'd0;
            end

            // Accept a write address
            if (aw_hs) begin
                aw_pending    <= 1'b1;
                aw_addr_r     <= s_awaddr;
                aw_len_r      <= s_awlen;
                wr_beats_left <= {1'b0, s_awlen} + 5'd1;
                wr_beat_idx   <= 5'd0;
                wr_burst_seq  <= aw_cnt;
                aw_cnt        <= aw_cnt + 32'd1;
                aw_dly        <= 4'd0;
                obs_aw_hs     <= obs_aw_hs + 32'd1;
            end

            // Write data latency counter (no wvalid, so wready drives it)
            if (aw_pending && !s_wready && (wr_beats_left != 5'd0)) begin
                w_dly <= w_dly + 4'd1;
            end else if (!aw_pending) begin
                w_dly <= 4'd0;
            end

            // wusero_last hold window
            if (last_cnt != 3'd0) begin
                last_cnt <= last_cnt - 3'd1;
            end
            if (s_wusero_last) begin
                obs_last_marker <= obs_last_marker + 32'd1;
            end

            // Accept one write beat
            if (w_hs) begin
                obs_wr_beats  <= obs_wr_beats + 32'd1;
                wr_beats_left <= wr_beats_left - 5'd1;
                wr_beat_idx   <= wr_beat_idx + 5'd1;
                w_dly         <= 4'd0;

                if (aw_len_r == 4'd0) begin
                    obs_len0_wr <= obs_len0_wr + 32'd1;
                    if (s_wstrb == 32'h0000_0000) begin
                        obs_len0_wstrb0 <= obs_len0_wstrb0 + 32'd1;
                    end
                    if (s_wstrb == 32'hFFFF_FFFF) begin
                        obs_len0_wstrb1 <= obs_len0_wstrb1 + 32'd1;
                    end
                end

                if (wr_beats_left == 5'd1) begin
                    aw_pending <= 1'b0;
                    last_cnt   <= LAST_HOLD;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Read channel control
    // ------------------------------------------------------------------
    wire ar_hs = s_arvalid && s_arready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_pending    <= 1'b0;
            r_push        <= 1'b0;
            ar_addr_r     <= 28'd0;
            rd_beats_left <= 5'd0;
            rd_beat_idx   <= 5'd0;
            r_id_r        <= 4'd0;
            ar_dly        <= 4'd0;
            obs_ar_hs     <= 32'd0;
            obs_rd_beats  <= 32'd0;
        end else begin
            // AR arrival latency counter
            if (s_arvalid && !ar_pending && !s_arready) begin
                ar_dly <= ar_dly + 4'd1;
            end else if (!s_arvalid) begin
                ar_dly <= 4'd0;
            end

            // Accept a read address
            if (ar_hs) begin
                ar_pending    <= 1'b1;
                r_push        <= 1'b1;
                ar_addr_r     <= s_araddr;
                rd_beats_left <= {1'b0, s_arlen} + 5'd1;
                rd_beat_idx   <= 5'd0;
                r_id_r        <= s_aruser_id;
                ar_dly        <= 4'd0;
                obs_ar_hs     <= obs_ar_hs + 32'd1;
            end

            // Stream one beat per cycle (no rready exists)
            if (r_push && (R_MODE == 0)) begin
                obs_rd_beats  <= obs_rd_beats + 32'd1;
                rd_beats_left <= rd_beats_left - 5'd1;
                rd_beat_idx   <= rd_beat_idx + 5'd1;
                if (rd_beats_left == 5'd1) begin
                    r_push     <= 1'b0;
                    ar_pending <= 1'b0;
                end
            end
        end
    end

always @(posedge clk) if(rst_n) begin
 if(s_awvalid && s_awready && (s_awaddr>>5)+s_awlen>=MEM_BEATS) $fatal(1,"write memory address out of range");
 if(s_arvalid && s_arready && (s_araddr>>5)+s_arlen>=MEM_BEATS) $fatal(1,"read memory address out of range");
end
endmodule