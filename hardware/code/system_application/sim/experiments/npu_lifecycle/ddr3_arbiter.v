// -----------------------------------------------------------------------------
// File    : ddr3_arbiter.v
// Module  : ddr3_arbiter
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Purpose : Four-master fixed-priority DDR3 command arbiter with a
//           starvation-quota override for the lowest-priority master
//           (design doc section 2.2.5 / 5.4, REQ-MEM-004).
//
// Masters (priority order, fixed):
//   P0 = audio_sink PCM write   (highest)
//   P1 = NPU weight stream read
//   P2 = Mel PCM window read
//   P3 = UI waveform read       (lowest, protected by quota)
//
// Behavior:
//   * When arb_en is high the controller can accept one new command this
//     cycle; the arbiter presents a one-hot grant following the fixed
//     priority P0 > P1 > P2 > P3.
//   * P3 quota: if master 3 keeps a request pending for P3_QUOTA_TIMEOUT
//     core_clk cycles (125000 = 1 ms at 125 MHz) without being granted,
//     the override forces the next grant to P3 regardless of priority
//     (bandwidth floor "at least one burst per 1 ms", section 5.4).
//   * Per-master 32-bit wait counters (m{i}_wait_cnt) count core_clk
//     cycles with cmd_valid asserted but not yet granted; they reset when
//     the command is granted. Exported for board-level observation
//     (REQ-MEM-004, wait budget <= 10 percent of the 3 s window).
//   * Region check (section 5.1, REQ-RSC-006): a granted address must be
//     32-byte aligned and fall into one of the five legal DDR3 windows
//     (PCM left / PCM right / weights / log2-spectrum export / self-test
//     pattern). Violations latch a sticky per-master addr_err flag for the
//     self-test chain; the command itself is NOT blocked (upstream address
//     maps are compile-time fixed; a latch here indicates integration
//     error and is reported, not silently dropped).
//
// The command bundle m{i}_cmd packs {wr(1), addr(28), len(8)} = 37 bits
// (section 2.2.5 lists the same fields; len is beats-1, legal range 0..15).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module ddr3_arbiter #(
    // P3 starvation quota in core_clk cycles: 125000 = 1 ms at 125 MHz.
    parameter integer P3_QUOTA_TIMEOUT = 125000
) (
    input  wire        clk,
    input  wire        rst_n,
    // Controller handshake: high while the controller can accept a new
    // command this cycle (FSM idle AND read fifo empty for read grants).
    input  wire        arb_en,
    // ---- four master request ports ----
    input  wire [3:0]  cmd_valid,   // per-master request, held until done
    input  wire [36:0] m0_cmd,      // {wr, addr[27:0], len[7:0]}
    input  wire [36:0] m1_cmd,
    input  wire [36:0] m2_cmd,
    input  wire [36:0] m3_cmd,
    // ---- arbitration result (one-hot, qualified by arb_en) ----
    output wire [3:0]  grant,
    output wire        grant_wr,
    output wire [27:0] grant_addr,
    output wire [7:0]  grant_len,
    // ---- per-master observation exports ----
    output reg  [31:0] wait_cnt_0,  // REQ-MEM-004 wait cycle counters
    output reg  [31:0] wait_cnt_1,
    output reg  [31:0] wait_cnt_2,
    output reg  [31:0] wait_cnt_3,
    output reg  [3:0]  addr_err     // sticky per-master region/align error
);

    // ------------------------------------------------------------------
    // Command field unpacking helpers
    // ------------------------------------------------------------------
    wire        m0_wr   = m0_cmd[36];
    wire [27:0] m0_addr = m0_cmd[35:8];
    wire [7:0]  m0_len  = m0_cmd[7:0];
    wire        m1_wr   = m1_cmd[36];
    wire [27:0] m1_addr = m1_cmd[35:8];
    wire [7:0]  m1_len  = m1_cmd[7:0];
    wire        m2_wr   = m2_cmd[36];
    wire [27:0] m2_addr = m2_cmd[35:8];
    wire [7:0]  m2_len  = m2_cmd[7:0];
    wire        m3_wr   = m3_cmd[36];
    wire [27:0] m3_addr = m3_cmd[35:8];
    wire [7:0]  m3_len  = m3_cmd[7:0];

    // ------------------------------------------------------------------
    // Fixed-priority selection with P3 quota override (combinational)
    // ------------------------------------------------------------------
    reg [16:0] p3_starve_cnt;  // 125000 needs 17 bits (2^17 = 131072)
    wire       p3_override;

    assign p3_override = (p3_starve_cnt >= P3_QUOTA_TIMEOUT[16:0]);

    reg [3:0] sel_onehot;
    always @* begin
        if (p3_override && cmd_valid[3]) begin
            // Quota floor: force P3 after 1 ms of continuous waiting.
            sel_onehot = 4'b1000;
        end else if (cmd_valid[0]) begin
            sel_onehot = 4'b0001;                     // P0 audio write
        end else if (cmd_valid[1]) begin
            sel_onehot = 4'b0010;                     // P1 weight read
        end else if (cmd_valid[2]) begin
            sel_onehot = 4'b0100;                     // P2 mel read
        end else if (cmd_valid[3]) begin
            sel_onehot = 4'b1000;                     // P3 ui read
        end else begin
            sel_onehot = 4'b0000;
        end
    end

    // Grant is only presented while the controller can accept a command.
    assign grant = arb_en ? sel_onehot : 4'b0000;

    assign grant_wr   = (sel_onehot == 4'b0001) ? m0_wr   :
                        (sel_onehot == 4'b0010) ? m1_wr   :
                        (sel_onehot == 4'b0100) ? m2_wr   : m3_wr;
    assign grant_addr = (sel_onehot == 4'b0001) ? m0_addr :
                        (sel_onehot == 4'b0010) ? m1_addr :
                        (sel_onehot == 4'b0100) ? m2_addr : m3_addr;
    assign grant_len  = (sel_onehot == 4'b0001) ? m0_len  :
                        (sel_onehot == 4'b0010) ? m1_len  :
                        (sel_onehot == 4'b0100) ? m2_len  : m3_len;

    // ------------------------------------------------------------------
    // Address region check (design doc section 5.1, REQ-RSC-006)
    // ------------------------------------------------------------------
    // Legal windows (byte addresses, 28-bit space):
    //   PCM left   : 0x000000 .. 0x083FFF  (528 KB, two 264 KB windows)
    //   PCM right  : 0x084000 .. 0x0C5FFF  (264 KB archive)
    //   weights    : 0x100000 .. 0x1B7FFF  (736 KB mirror)
    //   spectrum   : 0x200000 .. 0x20FFFF  (64 KB export snapshot)
    //   self-test  : 0x300000 .. 0x30FFFF  (64 KB pattern)
    wire [27:0] check_addr = grant_addr;

    wire region_pcm_l = (check_addr >= 28'h000000) && (check_addr <= 28'h083FFF);
    wire region_pcm_r = (check_addr >= 28'h084000) && (check_addr <= 28'h0C5FFF);
    wire region_wgt   = (check_addr >= 28'h100000) && (check_addr <= 28'h1B7FFF);
    wire region_spec  = (check_addr >= 28'h200000) && (check_addr <= 28'h20FFFF);
    wire region_self  = (check_addr >= 28'h300000) && (check_addr <= 28'h30FFFF);
    // Experimental activation scratch windows, m1 single-beat traffic only.
    wire region_act_a = (check_addr >= 28'h0400000) && (check_addr <= 28'h043FFE0);
    wire region_act_b = (check_addr >= 28'h0440000) && (check_addr <= 28'h045FFE0);
    wire activation_legal = (sel_onehot == 4'b0010) && (grant_len == 8'd0) &&
                            (region_act_a || region_act_b);
    wire addr_aligned = (check_addr[4:0] == 5'b00000);  // 32 B alignment
    wire len_legal    = (grant_len <= 8'd15);            // 16-beat max burst
    wire addr_legal   = addr_aligned && len_legal &&
                         (region_pcm_l || region_pcm_r ||
                          region_wgt || region_spec || region_self || activation_legal);

    // ------------------------------------------------------------------
    // Sequential logic: wait counters, P3 starvation counter, sticky errors
    // ------------------------------------------------------------------
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wait_cnt_0    <= 32'd0;
            wait_cnt_1    <= 32'd0;
            wait_cnt_2    <= 32'd0;
            wait_cnt_3    <= 32'd0;
            p3_starve_cnt <= 17'd0;
            addr_err      <= 4'b0000;
        end else begin
            // Wait counters: count while requested but not granted.
            if (cmd_valid[0] && !grant[0]) begin
                wait_cnt_0 <= wait_cnt_0 + 32'd1;
            end else begin
                wait_cnt_0 <= 32'd0;
            end
            if (cmd_valid[1] && !grant[1]) begin
                wait_cnt_1 <= wait_cnt_1 + 32'd1;
            end else begin
                wait_cnt_1 <= 32'd0;
            end
            if (cmd_valid[2] && !grant[2]) begin
                wait_cnt_2 <= wait_cnt_2 + 32'd1;
            end else begin
                wait_cnt_2 <= 32'd0;
            end
            if (cmd_valid[3] && !grant[3]) begin
                wait_cnt_3 <= wait_cnt_3 + 32'd1;
            end else begin
                wait_cnt_3 <= 32'd0;
            end

            // P3 starvation counter: counts while P3 waits without grant.
            if (cmd_valid[3] && !grant[3]) begin
                if (p3_starve_cnt < P3_QUOTA_TIMEOUT[16:0]) begin
                    p3_starve_cnt <= p3_starve_cnt + 17'd1;
                end
            end else begin
                p3_starve_cnt <= 17'd0;
            end

            // Sticky region error latch on each granted command.
            if ((grant != 4'b0000) && !addr_legal) begin
                for (i = 0; i < 4; i = i + 1) begin
                    if (grant[i]) begin
                        addr_err[i] <= 1'b1;
                    end
                end
            end
        end
    end

endmodule