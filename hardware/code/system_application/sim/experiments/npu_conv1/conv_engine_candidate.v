// ---------------------------------------------------------------------------
// conv_engine.v -- shared-core 3x3 stride-1 pad-1 INT8 convolution engine
//
// Task      : T-M2-03 conv_engine (INT8 CNN NPU numeric core)
// Bit truth : scripts/golden_pipeline.py  conv2d_int8() + requant_u8()
// Contract  : scripts/outputs/layer_contract.json (per-layer shapes,
//             bias_int32, M Q0.31, shift, zp_in/zp_out, padding_value)
//
// Golden dataflow mirrored here (conv2d_int8, bit-level):
//     acc_s32[c] = sum_(cin,dy,dx) (x_u8[cin] - zp_in) * w_s8[c][cin][dy][dx]
//                  + bias_int32[c]
//     y_u8[c]    = requant_unit(acc_s32[c], M[c], shift[c], zp_out)
// Storage-domain note (bit-level critical): the line buffers keep the
// RAW u8 container values; the zp_in subtraction happens live at the
// MAC beat (x_eff = pad ? 0 : x_u8 - zp_in, a signed 9-bit value).
// Pre-shifting to s8 at ingress would OVERFLOW on loud samples:
// conv1 zp_in = 49 with x_u8 up to 255 gives x - zp = 206 > s8 max
// 127 (the REQ-INF-007 full-scale saturation path), so the u8 store +
// live subtract is the only bit-exact mapping of the golden padded
// array (which is u8 zero-padded with padding_value == zp_in == 49
// and then reduced by zp_in). Pad-1 cells read as 0 in the signed
// domain, i.e. exactly the neutral value; the pad inject is done
// read-side (row/col window guard returns 0), which is bit-identical
// to pre-filling zero rows and zero column phases (tasks.md T-M2-03
// wording) without spending buffer slots on them.
// Accumulator headroom check: |x_eff| <= 255, |w| <= 128, taps <=
// 9*192 = 1728, |bias| < 2^17 -> |acc| < 1728*32640 + 2^17 ~= 5.6e7,
// far inside the s32 accumulator (golden tensordot is int64 but the
// measured contract never leaves s32; requant_unit consumes s32).
//
// Architecture (design.md 4.2, 16-MAC option; 2026-10-29 single-core rev):
//   - ONE 16-lane INT8 MAC array serves ALL FOUR logical conv layers.
//     The layer sequencer is serial, so no two layers ever scan at the
//     same time. Their activation INGRESS streams, however, DO overlap:
//     the pool stage of layer i feeds conv i+1 while conv i is still
//     producing its egress stream. Every layer therefore owns its own
//     three-bank line buffer and its own ingress counters, while the
//     MAC array, the requant unit, the accumulator banks, the group
//     contract bank and the scan FSM are shared by all four layers.
//     Merging the four logical layers into one physical core removes
//     the second copy of the compute datapath (the place-and-route
//     congestion driver) without changing the scan order, the
//     streaming order or the layer overlap. The row buffers are NOT
//     merged: sharing them would collide (conv N scans its window
//     while the pool egress pre-fills conv N+1's buffer).
//   - 16 parallel INT8 MAC lanes = the 16 output channels of one
//     weight group (group_channels = 16 in the layer contract). Every
//     cycle ONE tap (cin, dy, dx) of the shared input window is
//     broadcast to all 16 lanes, each lane multiplying its own
//     per-channel weight: pe[c] += x * w[c][cin][dy][dx].
//   - The tap index is scanned serially over 9*Cin cycles per output
//     pixel per group (golden flatten order: cin outer, dy*3+dx inner,
//     matching the (dy*3+dx) weight layout).
//   - 16 x s32 accumulators, double-banked (A/B ping-pong): one bank
//     accumulates the current pixel while the snapshot bank drains
//     through the time-multiplexed requant_unit (16-beat TDM).
//   - Row-pipeline: ingress rows stream into a 3-bank sliding-window
//     line buffer (bank = row mod 3); output row r only needs input
//     rows r-1..r+1 (pad rows read as zero). Activations never touch
//     DDR3 (architecture principle 1).
//   - Scan order: out_row -> group -> column -> tap. Weight groups are
//     re-armed per (row, group); the group contract (16 x bias_s32,
//     16 x M_s32, 16 x shift) is double-buffered so the wdma prefetch
//     of the next group overlaps the current group computation.
//   - Layer select: conv_sel (2 bits, layer id 0..3) is latched at the
//     layer start pulse and drives the compile-time shape muxes and
//     the line-buffer bank-group muxes. All four shape sets are
//     parameters, so the address arithmetic stays constant-folded.
//
// MAC implementation note (design.md 4.2 selection): int8 x int8
// products are written as plain signed multiplies so synthesis maps
// them onto 8 APM 18x18 tiles (9x9 split, 2 int8 lanes per APM) per
// the design selection; LUT fallback is acceptable within the LUT
// budget. The requant_unit 32x32 multiply adds ~4 more APM blocks,
// for a shared core total of ~12 APM.
//
// Timing budget table (real MAC counts; task note "conv2 432
// taps/pixel = 27 cycles/pixel/16-channel-group" means 432 = 27 x 16:
// 27 MAC cycles per output channel, 16 channels sharing the array,
// i.e. 435 pipe cycles per pixel per group including load/snapshot
// beats):
//   layer | Cin | Cout | out HxW | cycles/px/group | total beats | @125MHz
//   conv1 |   1 |   48 |  64x258 | max(12, 16) = 16|  16512x3x16  =  793k |  6.3 ms
//   conv2 |  48 |   96 |  32x129 | 9*48+3 = 435    |  4128x6x435  = 10.7M | 86.1 ms
//   conv3 |  96 |  192 |  16x64  | 9*96+3 = 867    |  1024x12x867 = 10.6M | 85.2 ms
//   conv4 | 192 |  256 |   8x32  | 9*192+3 = 1731  |  256x16x1731 =  7.1M | 56.7 ms
//   conv total ~= 234 ms -- see RISK note below.
// RISK (reported to team lead): design.md 4.6 counts conv-layer MACs
// on the post-pool shapes (114.6M total, 57.5 ms); the true pre-pool
// count is ~460M, so the 16-MAC array lands at ~234 ms > 200 ms
// budget. This engine implements the specified 16-MAC architecture;
// closing the gap (32-MAC option from design.md 4.2 or a second
// engine core) is a system-level decision. Sharing one core across
// all four layers does NOT change this number (each layer still scans
// its own taps).
//
// Beat plan per output pixel per group (TDM channels 0..15 through
// requant_unit are hidden inside the next tap scan; conv1 stretches
// to the requant pace of 16):
//   beat 0        : acc bank <- bias (parallel load of 16 lanes)
//   beat 1..9Cin+1: tap scan (1 read address beat + 1 MAC beat pipe)
//   beat 9Cin+2   : snapshot acc -> drain bank, swap active bank
//   beats 0..15 of the drain overlap the NEXT pixel scan via the
//   requant_unit 16-beat TDM (1 channel per cycle).
//
// INTEGRATION ALIGNMENT POINTS (downstream contracts):
//   [wdma]  weight tap stream: w_valid/w_data carry one 16-lane tap
//           word per MAC beat, tap order (cin outer, dy*3+dx inner),
//           lane i = weight of output channel (grp*16+i). The group
//           contract streams (bias/mult/shft) target the shadow bank
//           and are re-armed per (row, group): grp_advance pulses at
//           every group boundary in scan order. wdma re-reads each
//           group's weights per row (row x group re-read volume is
//           within the DDR3 read budget; wbuf stays single-buffered
//           per design.md 4.1).
//   [pool_engine] egress stream: y_valid/y_u8 come out in scan order
//           (out_row, grp, col, lane 0..15) -- 16 channels of one
//           pixel per 16-beat TDM batch. Pool organizes its 2x2
//           windows per channel independently (max is channel-local).
//
// Clock domain: core_clk 125 MHz. MAC beat pipeline: read address
// (1 beat) -> synchronous RAM read + weight registration (1 beat) ->
// multiply-add registered into the s32 accumulator (1 beat), meeting
// the 8 ns stage budget.
//
// Reset: asynchronous-active-low; all counters and the FSM return to
// idle, line buffers keep old content (rewritten before use).
// ---------------------------------------------------------------------------

module conv_engine #(
    // Four logical layers share one physical core. Shapes are
    // compile-time per layer so the address arithmetic stays
    // constant-folded (no runtime multiplier appears on the
    // line-buffer address path). Layer ids match npu_top's conv_sel:
    //   0 = conv1 =   1/48 /64/258
    //   1 = conv2 =  48/96 /32/129
    //   2 = conv3 =  96/192/16/64
    //   3 = conv4 = 192/256/ 8/32
    parameter CIN0  = 1,      // layer 0 input channels
    parameter COUT0 = 48,     // layer 0 output channels (multiple of 16)
    parameter H0    = 64,     // layer 0 input rows (= output rows, pad-1 stride-1)
    parameter W0    = 258,    // layer 0 input cols (= output cols)
    parameter CIN1  = 48,     // layer 1 input channels
    parameter COUT1 = 96,     // layer 1 output channels (multiple of 16)
    parameter H1    = 32,     // layer 1 input rows
    parameter W1    = 129,    // layer 1 input cols
    parameter CIN2  = 96,     // layer 2 input channels
    parameter COUT2 = 192,    // layer 2 output channels (multiple of 16)
    parameter H2    = 16,     // layer 2 input rows
    parameter W2    = 64,     // layer 2 input cols
    parameter CIN3  = 192,    // layer 3 input channels
    parameter COUT3 = 256,    // layer 3 output channels (multiple of 16)
    parameter H3    = 8,      // layer 3 input rows
    parameter W3    = 32      // layer 3 input cols
) (
    // clock / reset (core_clk 125 MHz domain)
    input  wire               clk,
    input  wire               rst_n,

    // layer configuration stream (from npu_top, muxed by current layer)
    input  wire               cfg_valid,   // strobe: latch zp pair
    input  wire        [7:0]  cfg_zp_in,   // conv1: 49, others 0
    input  wire        [7:0]  cfg_zp_out,  // requant output zero point

    // layer id (0..3), latched on the layer start pulse. npu_top drives
    // the id of the conv layer it is about to start.
    input  wire        [1:0]  conv_sel,

    // layer control, one pair per logical layer
    input  wire               start0,     // pulse: reset layer 0 + scan state
    input  wire               start1,     // pulse: reset layer 1 + scan state
    input  wire               start2,     // pulse: reset layer 2 + scan state
    input  wire               start3,     // pulse: reset layer 3 + scan state
    output wire               done0,      // pulse: layer 0 drained
    output wire               done1,      // pulse: layer 1 drained
    output wire               done2,      // pulse: layer 2 drained
    output wire               done3,      // pulse: layer 3 drained

    // [ingress] activation row streams, u8 container domain, one per
    // layer. Raster order: column-major within a row -- col 0 carries
    // ch 0..CIN-1, then col 1, etc. One beat per cycle, no backpressure
    // (producer rate <= 1 beat/cycle; row boundaries derived by count).
    output wire        [15:0] x0_ingress_max_row,
    input  wire               x0_valid,
    input  wire        [7:0]  x0_u8,
    input  wire               x1_valid,
    input  wire        [7:0]  x1_u8,
    input  wire               x2_valid,
    input  wire        [7:0]  x2_u8,
    input  wire               x3_valid,
    input  wire        [7:0]  x3_u8,

    // [wdma alignment point] group contract stream, 48 beats per group
    // (16 x bias, 16 x M, 16 x shift), loaded into the shadow contract
    // bank; becomes active at the next grp_advance boundary.
    // Beat protocol (must match the shared beat counter in the loader):
    // exactly ONE valid strobe per beat, fixed order 16 x bias ->
    // 16 x M -> 16 x shift. Driving two valid strobes in the same beat
    // would advance the shared counter only once and leave the bank
    // partially loaded, so wdma must serialize the three sub-streams.
    input  wire               grp_start,   // pulse: restart shadow pointer
    input  wire               bias_valid,  // beats 0..15: bias_s32
    input  wire signed [31:0] bias_s32,
    input  wire               mult_valid,  // beats 0..15: M Q0.31
    input  wire signed [31:0] m_s32,
    input  wire               shft_valid,  // beats 0..15: shift (6-bit used)
    input  wire        [6:0]  shift,

    // [wdma alignment point] weight tap stream: one 16-lane tap word
    // per MAC beat, lane i = w[grp*16+i][cin][dy][dx], tap order
    // cin-major, dy*3+dx minor.
    input  wire               w_valid,
    input  wire        [127:0] w_data,     // {lane15, ..., lane1, lane0} s8
    output wire               w_ready,     // high during MAC consumption beats

    // [pool_engine alignment point] egress: requantized u8 stream in
    // scan order (out_row, grp, col, lane 0..15 TDM). Valid only while
    // the selected layer is scanning.
    output wire               y_valid,
    output wire        [7:0]  y_u8,

    // group boundary strobes, one per logical layer in scan order.
    output wire               adv0,
    output wire               adv1,
    output wire               adv2,
    output wire               adv3
);

    // -----------------------------------------------------------------------
    // Derived dimensions (constant function must precede its uses)
    // -----------------------------------------------------------------------
    // ceiling log2 with a 1-bit floor, so CIN = 1 (conv1) stays legal
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
            if (clog2 == 0)
                clog2 = 1;
        end
    endfunction

    function integer MAXI2;
        input integer a;
        input integer b;
        begin
            MAXI2 = (a > b) ? a : b;
        end
    endfunction

    localparam G0_GRP  = COUT0 / 16;           // 16-channel groups, layer 0
    localparam G1_GRP  = COUT1 / 16;
    localparam G2_GRP  = COUT2 / 16;
    localparam G3_GRP  = COUT3 / 16;
    localparam G0_TAP  = 9 * CIN0;             // taps per pixel per group
    localparam G1_TAP  = 9 * CIN1;
    localparam G2_TAP  = 9 * CIN2;
    localparam G3_TAP  = 9 * CIN3;
    localparam G0_LINE = CIN0 * W0;            // u8 words per line bank
    localparam G1_LINE = CIN1 * W1;
    localparam G2_LINE = CIN2 * W2;
    localparam G3_LINE = CIN3 * W3;

    localparam CMAX    = MAXI2(MAXI2(CIN0, CIN1), MAXI2(CIN2, CIN3));
    localparam HMAX    = MAXI2(MAXI2(H0,   H1),   MAXI2(H2,   H3));
    localparam WMAX    = MAXI2(MAXI2(W0,   W1),   MAXI2(W2,   W3));
    localparam TAPMAX  = MAXI2(MAXI2(G0_TAP, G1_TAP), MAXI2(G2_TAP, G3_TAP));
    localparam GRPMAX  = MAXI2(MAXI2(G0_GRP, G1_GRP), MAXI2(G2_GRP, G3_GRP));

    localparam AW0     = clog2(G0_LINE);        // layer 0 line address width
    localparam AW1     = clog2(G1_LINE);
    localparam AW2     = clog2(G2_LINE);
    localparam AW3     = clog2(G3_LINE);
    localparam RW      = clog2(WMAX);           // column index width
    localparam RC      = clog2(CMAX);           // channel index width
    localparam RR      = clog2(HMAX + 1);       // row counter width (0..HMAX)
    localparam RT      = clog2(TAPMAX + 3);     // tap scan counter width
    localparam RG      = clog2(GRPMAX);         // output group counter width

    localparam [15:0] W0V = W0;                 // 16-bit stride constants
    localparam [15:0] W1V = W1;
    localparam [15:0] W2V = W2;
    localparam [15:0] W3V = W3;
    localparam [RT-1:0] TAP0V = G0_TAP;
    localparam [RT-1:0] TAP1V = G1_TAP;
    localparam [RT-1:0] TAP2V = G2_TAP;
    localparam [RT-1:0] TAP3V = G3_TAP;
    localparam [RG-1:0] GRPL0 = G0_GRP - 1;     // last output group index
    localparam [RG-1:0] GRPL1 = G1_GRP - 1;
    localparam [RG-1:0] GRPL2 = G2_GRP - 1;
    localparam [RG-1:0] GRPL3 = G3_GRP - 1;

    // -----------------------------------------------------------------------
    // Layer configuration registers (shared, latched per layer_start)
    // -----------------------------------------------------------------------
    reg [7:0] zp_in_reg;    // ingress zero point (conv1: 49)
    reg [7:0] zp_out_reg;   // requant zero point

    // -----------------------------------------------------------------------
    // Scan control state (shared core). sel picks the layer whose shape
    // and line buffer the scan FSM currently walks; it is latched at
    // layer_start and stays put until the next start pulse.
    // -----------------------------------------------------------------------
    localparam PH_LOAD = 2'd0;      // acc bank <- bias (1 beat)
    localparam PH_SCAN = 2'd1;      // tap scan (TAP_NUM issues + pipe)
    localparam PH_SNAP = 2'd2;      // acc snapshot + bank swap (1 beat)

    reg  [1:0]        sel;            // 0..3: layer being scanned
    reg               run_reg;        // layer in progress
    wire [15:0] ingress_row_limit;
    assign ingress_row_limit = out_row_cnt + 16'd1;
    assign x0_ingress_max_row = ingress_row_limit;
    reg [RR-1:0]      out_row_cnt;    // 0..H-1
    reg [RG-1:0]      grp_cnt;        // 0..GRP_NUM-1
    reg [RW-1:0]      out_col_cnt;    // 0..W-1
    reg [RT-1:0]      tap_cnt;        // taps issued for current pixel
    reg [RT-1:0]      mac_cnt;        // MAC beats retired for current pixel
    reg [1:0]         phase_reg;      // PH_LOAD / PH_SCAN / PH_SNAP
    reg [1:0]         rd_bank_base;   // bank of window row (out_row-1)
    reg [1:0]         dy_cnt;         // window row offset 0..2
    reg [1:0]         dx_cnt;         // window col offset 0..2
    reg [RC-1:0]      cin_cnt;        // tap channel 0..CIN-1

    // any-start pulse and the layer id it carries into sel
    wire       any_start  = start0 | start1 | start2 | start3;

    // per-layer shape selectors (constants muxed by sel; 16-bit so the
    // conv1 width of 258 is not truncated)
    wire [15:0] s_h      = (sel == 2'd0) ? H0 : (sel == 2'd1) ? H1 :
                           (sel == 2'd2) ? H2 : H3;
    wire [15:0] s_w      = (sel == 2'd0) ? W0 : (sel == 2'd1) ? W1 :
                           (sel == 2'd2) ? W2 : W3;
    wire [RT-1:0] s_tap_last = (sel == 2'd0) ? TAP0V : (sel == 2'd1) ? TAP1V :
                               (sel == 2'd2) ? TAP2V : TAP3V;
    wire [RG-1:0] s_grp_last = (sel == 2'd0) ? GRPL0 : (sel == 2'd1) ? GRPL1 :
                               (sel == 2'd2) ? GRPL2 : GRPL3;

    // -----------------------------------------------------------------------
    // Sliding-window line buffers: FOUR independent sets of 3 rotating
    // banks (CIN x W_IN u8 words each). Ingress streams overlap between
    // adjacent layers, so the buffers cannot be merged; only the compute
    // core is shared. Bank = row mod 3. Write port: activation ingress.
    // Read port: tap scan (one bank, one word per beat). Pseudo-dual-port
    // per bank; the write row (scan row + 2) is never a window row, so
    // write and read never hit the same bank in the same cycle.
    // Pad-1 rows/cols are guarded read-side (return 0 in the signed MAC
    // domain) -- the neutral value, see header.
    // The read port of the three non-selected layers is parked at
    // address 0, so no bank is ever indexed out of range.
    // -----------------------------------------------------------------------
    reg [7:0] g0_bank0 [0:G0_LINE-1];
    reg [7:0] g0_bank1 [0:G0_LINE-1];
    reg [7:0] g0_bank2 [0:G0_LINE-1];
    reg [7:0] g1_bank0 [0:G1_LINE-1];
    reg [7:0] g1_bank1 [0:G1_LINE-1];
    reg [7:0] g1_bank2 [0:G1_LINE-1];
    reg [7:0] g2_bank0 [0:G2_LINE-1];
    reg [7:0] g2_bank1 [0:G2_LINE-1];
    reg [7:0] g2_bank2 [0:G2_LINE-1];
    reg [7:0] g3_bank0 [0:G3_LINE-1];
    reg [7:0] g3_bank1 [0:G3_LINE-1];
    reg [7:0] g3_bank2 [0:G3_LINE-1];

    reg [7:0] g0_dout0, g0_dout1, g0_dout2;   // synchronous read data
    reg [7:0] g1_dout0, g1_dout1, g1_dout2;
    reg [7:0] g2_dout0, g2_dout1, g2_dout2;
    reg [7:0] g3_dout0, g3_dout1, g3_dout2;

    // layer 0 ingress counters
    reg [1:0]        g0_wr_bank;      // bank being written (row mod 3)
    reg [RR-1:0]     g0_row;          // completed-row counter (0..H0)
    reg [RC-1:0]     g0_ch;           // ingress channel index within row
    reg [RW-1:0]     g0_col;          // ingress column index within row
    reg [HMAX-1:0]   g0_row_done;     // per input row completion bitmap

    // layer 1 ingress counters
    reg [1:0]        g1_wr_bank;
    reg [RR-1:0]     g1_row;
    reg [RC-1:0]     g1_ch;
    reg [RW-1:0]     g1_col;
    reg [HMAX-1:0]   g1_row_done;

    // layer 2 ingress counters
    reg [1:0]        g2_wr_bank;
    reg [RR-1:0]     g2_row;
    reg [RC-1:0]     g2_ch;
    reg [RW-1:0]     g2_col;
    reg [HMAX-1:0]   g2_row_done;

    // layer 3 ingress counters
    reg [1:0]        g3_wr_bank;
    reg [RR-1:0]     g3_row;
    reg [RC-1:0]     g3_ch;
    reg [RW-1:0]     g3_col;
    reg [HMAX-1:0]   g3_row_done;

    // -----------------------------------------------------------------------
    // Group contract registers, double-banked (active/shadow) -- shared.
    // -----------------------------------------------------------------------
    reg signed [31:0] bias_act [0:15];  // active:   current group
    reg signed [31:0] bias_shd [0:15];  // shadow:   loading next group
    reg signed [31:0] m_act     [0:15];
    reg signed [31:0] m_shd     [0:15];
    reg        [6:0]  shft_act  [0:15];
    reg        [6:0]  shft_shd  [0:15];
    reg        [5:0]  cload_cnt;         // shadow load pointer 0..47

    // tap address generation (registered for the 1-beat RAM latency)
    reg          rd_pad_q;            // pad guard (row/col outside window)
    reg [1:0]    rd_bank_q;           // bank of the window row
    reg [127:0]  w_data_q;            // tap weights aligned with RAM dout
    reg          w_vld_q;             // tap weight beat valid

    // group contract handshake state
    reg               grp_arm;        // active contract bank valid
    reg               shadow_rdy;     // shadow contract bank complete

    // layer completion bookkeeping
    reg [5:0]         fin_cnt;        // drain tail countdown after last pixel
    reg               fin_latched;    // last pixel issued, hold the scan idle
    reg               done_q;         // layer_done pulse (1 beat)
    reg               advance_q;       // grp_advance pulse (1 beat)

    // -----------------------------------------------------------------------
    // 16-lane s32 accumulators, ping-pong banks + drain snapshot
    // -----------------------------------------------------------------------
    reg signed [31:0] acc_a [0:15];
    reg signed [31:0] acc_b [0:15];
    reg               acc_sel;        // 0: A accumulates / B drains
    reg signed [31:0] acc_snap [0:15];

    // -----------------------------------------------------------------------
    // requant drain state (16-beat TDM through requant_unit)
    // -----------------------------------------------------------------------
    // T25 FIX: the group-boundary pixel is snapshotted on the same edge
    // that promotes the shadow contract, so the 16-beat drain would requant
    // the last pixel of a group with the NEXT group's M/shift (measured:
    // all 1300 conv1 residuals were exactly this, channel 32..47 of col 257
    // included).  Latch the parameters together with acc_snap instead.
    reg signed [31:0] m_drn    [0:15];
    reg        [6:0]  shft_drn [0:15];
    reg [4:0]   rhe_busy_cnt;         // 16 -> 0 countdown
    reg [3:0]   rhe_ch;               // drain channel index 0..15

    // -----------------------------------------------------------------------
    // requant_unit instance (TDM, one physical unit for 16 channels)
    // -----------------------------------------------------------------------
    wire signed [31:0] rq_acc_s32;   // operand muxes, driven in the body
    wire signed [31:0] rq_m_s32;
    wire        [6:0]  rq_shift;
    wire        [7:0]  rq_zp_out;
    wire               rq_in_valid;
    wire        [7:0]  rq_y_u8;
    wire               rq_y_valid;

    requant_unit u_requant (
        .clk       (clk),
        .rst_n     (rst_n),
        .acc_s32   (rq_acc_s32),
        .m_s32     (rq_m_s32),
        .shift     (rq_shift),
        .zp_out    (rq_zp_out),
        .in_valid  (rq_in_valid),
        .y_u8      (rq_y_u8),
        .out_valid (rq_y_valid)
    );

    // =======================================================================
    // BODY: control FSM, line-buffer plumbing, MAC array, requant drain
    // =======================================================================

    // mod-3 rotation helper for the line-bank pointers
    function [1:0] add3;
        input [1:0] a;
        input [1:0] b;
        reg [2:0] s;
        begin
            s = {1'b0, a} + {1'b0, b};
            add3 = (s >= 3'd3) ? (s - 3'd3) : s[1:0];
        end
    endfunction

    integer i;   // contract-bank loop variable

    // -----------------------------------------------------------------------
    // Layer configuration latch (protocol: cfg_valid before layer_start;
    // npu_top presents the current layer's values, so the latch holds for
    // the whole layer because the layer id is stable while it runs).
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            zp_in_reg  <= 8'd0;
            zp_out_reg <= 8'd0;
        end else if (cfg_valid) begin
            zp_in_reg  <= cfg_zp_in;
            zp_out_reg <= cfg_zp_out;
        end
    end

    // -----------------------------------------------------------------------
    // Ingress write paths: u8 container values into the rotating banks.
    // Beat order is column-major (col 0 carries ch 0..CIN-1, then
    // col 1, ...) -- matches the TDM group ordering of the upstream
    // pool/mel engines. One beat per cycle, no backpressure.
    // Each layer keeps its own counters and its own bank group, so the
    // pre-fill of layer N+1 proceeds while layer N is still scanning;
    // constant stride arithmetic (no runtime multiply) per layer.
    // -----------------------------------------------------------------------
    wire g0_wr_en = x0_valid && (g0_row != H0);
    wire g1_wr_en = x1_valid && (g1_row != H1);
    wire g2_wr_en = x2_valid && (g2_row != H2);
    wire g3_wr_en = x3_valid && (g3_row != H3);

    wire [15:0] g0_wr_off = {{(16-RC){1'b0}}, g0_ch} * W0V;
    wire [15:0] g1_wr_off = {{(16-RC){1'b0}}, g1_ch} * W1V;
    wire [15:0] g2_wr_off = {{(16-RC){1'b0}}, g2_ch} * W2V;
    wire [15:0] g3_wr_off = {{(16-RC){1'b0}}, g3_ch} * W3V;
    wire [15:0] g0_wr_sum = g0_wr_off + {{(16-RW){1'b0}}, g0_col};
    wire [15:0] g1_wr_sum = g1_wr_off + {{(16-RW){1'b0}}, g1_col};
    wire [15:0] g2_wr_sum = g2_wr_off + {{(16-RW){1'b0}}, g2_col};
    wire [15:0] g3_wr_sum = g3_wr_off + {{(16-RW){1'b0}}, g3_col};
    wire [AW0-1:0] g0_wr_addr = g0_wr_sum[AW0-1:0];
    wire [AW1-1:0] g1_wr_addr = g1_wr_sum[AW1-1:0];
    wire [AW2-1:0] g2_wr_addr = g2_wr_sum[AW2-1:0];
    wire [AW3-1:0] g3_wr_addr = g3_wr_sum[AW3-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g0_row      <= {RR{1'b0}};
            g0_ch       <= {RC{1'b0}};
            g0_col      <= {RW{1'b0}};
            g0_wr_bank  <= 2'd0;
            g0_row_done <= {HMAX{1'b0}};
        end else if (start0) begin
            g0_row      <= {RR{1'b0}};
            g0_ch       <= {RC{1'b0}};
            g0_col      <= {RW{1'b0}};
            g0_wr_bank  <= 2'd0;
            g0_row_done <= {HMAX{1'b0}};
        end else if (g0_wr_en) begin
            if ((g0_ch == CIN0 - 1) && (g0_col == W0 - 1)) begin
                g0_row_done[g0_row & (H0 - 1)] <= 1'b1;   // row complete
                g0_row     <= g0_row + 1'b1;
                g0_ch      <= {RC{1'b0}};
                g0_col     <= {RW{1'b0}};
                g0_wr_bank <= (g0_wr_bank == 2'd2) ? 2'd0 : g0_wr_bank + 2'd1;
            end else if (g0_ch == CIN0 - 1) begin
                g0_ch  <= {RC{1'b0}};
                g0_col <= g0_col + 1'b1;
            end else begin
                g0_ch <= g0_ch + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g1_row      <= {RR{1'b0}};
            g1_ch       <= {RC{1'b0}};
            g1_col      <= {RW{1'b0}};
            g1_wr_bank  <= 2'd0;
            g1_row_done <= {HMAX{1'b0}};
        end else if (start1) begin
            g1_row      <= {RR{1'b0}};
            g1_ch       <= {RC{1'b0}};
            g1_col      <= {RW{1'b0}};
            g1_wr_bank  <= 2'd0;
            g1_row_done <= {HMAX{1'b0}};
        end else if (g1_wr_en) begin
            if ((g1_ch == CIN1 - 1) && (g1_col == W1 - 1)) begin
                g1_row_done[g1_row & (H1 - 1)] <= 1'b1;   // row complete
                g1_row     <= g1_row + 1'b1;
                g1_ch      <= {RC{1'b0}};
                g1_col     <= {RW{1'b0}};
                g1_wr_bank <= (g1_wr_bank == 2'd2) ? 2'd0 : g1_wr_bank + 2'd1;
            end else if (g1_ch == CIN1 - 1) begin
                g1_ch  <= {RC{1'b0}};
                g1_col <= g1_col + 1'b1;
            end else begin
                g1_ch <= g1_ch + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g2_row      <= {RR{1'b0}};
            g2_ch       <= {RC{1'b0}};
            g2_col      <= {RW{1'b0}};
            g2_wr_bank  <= 2'd0;
            g2_row_done <= {HMAX{1'b0}};
        end else if (start2) begin
            g2_row      <= {RR{1'b0}};
            g2_ch       <= {RC{1'b0}};
            g2_col      <= {RW{1'b0}};
            g2_wr_bank  <= 2'd0;
            g2_row_done <= {HMAX{1'b0}};
        end else if (g2_wr_en) begin
            if ((g2_ch == CIN2 - 1) && (g2_col == W2 - 1)) begin
                g2_row_done[g2_row & (H2 - 1)] <= 1'b1;   // row complete
                g2_row     <= g2_row + 1'b1;
                g2_ch      <= {RC{1'b0}};
                g2_col     <= {RW{1'b0}};
                g2_wr_bank <= (g2_wr_bank == 2'd2) ? 2'd0 : g2_wr_bank + 2'd1;
            end else if (g2_ch == CIN2 - 1) begin
                g2_ch  <= {RC{1'b0}};
                g2_col <= g2_col + 1'b1;
            end else begin
                g2_ch <= g2_ch + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g3_row      <= {RR{1'b0}};
            g3_ch       <= {RC{1'b0}};
            g3_col      <= {RW{1'b0}};
            g3_wr_bank  <= 2'd0;
            g3_row_done <= {HMAX{1'b0}};
        end else if (start3) begin
            g3_row      <= {RR{1'b0}};
            g3_ch       <= {RC{1'b0}};
            g3_col      <= {RW{1'b0}};
            g3_wr_bank  <= 2'd0;
            g3_row_done <= {HMAX{1'b0}};
        end else if (g3_wr_en) begin
            if ((g3_ch == CIN3 - 1) && (g3_col == W3 - 1)) begin
                g3_row_done[g3_row & (H3 - 1)] <= 1'b1;   // row complete
                g3_row     <= g3_row + 1'b1;
                g3_ch      <= {RC{1'b0}};
                g3_col     <= {RW{1'b0}};
                g3_wr_bank <= (g3_wr_bank == 2'd2) ? 2'd0 : g3_wr_bank + 2'd1;
            end else if (g3_ch == CIN3 - 1) begin
                g3_ch  <= {RC{1'b0}};
                g3_col <= g3_col + 1'b1;
            end else begin
                g3_ch <= g3_ch + 1'b1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Tap read-address generation (combinational on the issue beat):
    // window position (out_row + dy - 1, out_col + dx - 1); pad guard
    // returns x_eff = 0 (the signed-domain neutral value). Row/col are
    // computed as unsigned sums so the -1 underflow maps to 0 == pad.
    // Only the selected layer's address is driven (the other three are
    // parked at 0 so their smaller banks are never out-of-range indexed).
    // -----------------------------------------------------------------------
    wire [RW+1:0] col_u   = {2'b00, out_col_cnt} + {{RW{1'b0}}, dx_cnt};
    wire          col_pad = (col_u == {(RW+2){1'b0}}) || (col_u > s_w);
    wire [RR+1:0] wy_u    = {2'b00, out_row_cnt} + {{RR{1'b0}}, dy_cnt};
    wire          wy_pad  = (wy_u == {(RR+2){1'b0}}) || (wy_u > s_h);
    wire          rd_pad_c  = wy_pad || col_pad;
    wire [1:0]    rd_bank_c = add3(rd_bank_base, dy_cnt);

    wire [RW-1:0] rd_col_off = col_u[RW-1:0] - 1'b1;

    wire [15:0] g0_rd_off = {{(16-RC){1'b0}}, cin_cnt} * W0V;
    wire [15:0] g1_rd_off = {{(16-RC){1'b0}}, cin_cnt} * W1V;
    wire [15:0] g2_rd_off = {{(16-RC){1'b0}}, cin_cnt} * W2V;
    wire [15:0] g3_rd_off = {{(16-RC){1'b0}}, cin_cnt} * W3V;
    wire [15:0] s_rd_off = (sel == 2'd0) ? g0_rd_off : (sel == 2'd1) ? g1_rd_off :
                           (sel == 2'd2) ? g2_rd_off : g3_rd_off;
    wire [15:0] s_rd_sum = s_rd_off + {{(16-RW){1'b0}}, rd_col_off};
    wire [AW0-1:0] g0_rd_addr = (rd_pad_c || (sel != 2'd0)) ? {AW0{1'b0}} : s_rd_sum[AW0-1:0];
    wire [AW1-1:0] g1_rd_addr = (rd_pad_c || (sel != 2'd1)) ? {AW1{1'b0}} : s_rd_sum[AW1-1:0];
    wire [AW2-1:0] g2_rd_addr = (rd_pad_c || (sel != 2'd2)) ? {AW2{1'b0}} : s_rd_sum[AW2-1:0];
    wire [AW3-1:0] g3_rd_addr = (rd_pad_c || (sel != 2'd3)) ? {AW3{1'b0}} : s_rd_sum[AW3-1:0];

    // line RAM banks: one write port (ingress) + one synchronous read
    // port (tap scan) each. Write row = scan row + 2, never a window row,
    // so write and read never touch the same bank in the same cycle.
    always @(posedge clk) begin
        if (g0_wr_en && (g0_wr_bank == 2'd0))
            g0_bank0[g0_wr_addr] <= x0_u8;
        g0_dout0 <= g0_bank0[g0_rd_addr];
    end
    always @(posedge clk) begin
        if (g0_wr_en && (g0_wr_bank == 2'd1))
            g0_bank1[g0_wr_addr] <= x0_u8;
        g0_dout1 <= g0_bank1[g0_rd_addr];
    end
    always @(posedge clk) begin
        if (g0_wr_en && (g0_wr_bank == 2'd2))
            g0_bank2[g0_wr_addr] <= x0_u8;
        g0_dout2 <= g0_bank2[g0_rd_addr];
    end
    always @(posedge clk) begin
        if (g1_wr_en && (g1_wr_bank == 2'd0))
            g1_bank0[g1_wr_addr] <= x1_u8;
        g1_dout0 <= g1_bank0[g1_rd_addr];
    end
    always @(posedge clk) begin
        if (g1_wr_en && (g1_wr_bank == 2'd1))
            g1_bank1[g1_wr_addr] <= x1_u8;
        g1_dout1 <= g1_bank1[g1_rd_addr];
    end
    always @(posedge clk) begin
        if (g1_wr_en && (g1_wr_bank == 2'd2))
            g1_bank2[g1_wr_addr] <= x1_u8;
        g1_dout2 <= g1_bank2[g1_rd_addr];
    end
    always @(posedge clk) begin
        if (g2_wr_en && (g2_wr_bank == 2'd0))
            g2_bank0[g2_wr_addr] <= x2_u8;
        g2_dout0 <= g2_bank0[g2_rd_addr];
    end
    always @(posedge clk) begin
        if (g2_wr_en && (g2_wr_bank == 2'd1))
            g2_bank1[g2_wr_addr] <= x2_u8;
        g2_dout1 <= g2_bank1[g2_rd_addr];
    end
    always @(posedge clk) begin
        if (g2_wr_en && (g2_wr_bank == 2'd2))
            g2_bank2[g2_wr_addr] <= x2_u8;
        g2_dout2 <= g2_bank2[g2_rd_addr];
    end
    always @(posedge clk) begin
        if (g3_wr_en && (g3_wr_bank == 2'd0))
            g3_bank0[g3_wr_addr] <= x3_u8;
        g3_dout0 <= g3_bank0[g3_rd_addr];
    end
    always @(posedge clk) begin
        if (g3_wr_en && (g3_wr_bank == 2'd1))
            g3_bank1[g3_wr_addr] <= x3_u8;
        g3_dout1 <= g3_bank1[g3_rd_addr];
    end
    always @(posedge clk) begin
        if (g3_wr_en && (g3_wr_bank == 2'd2))
            g3_bank2[g3_wr_addr] <= x3_u8;
        g3_dout2 <= g3_bank2[g3_rd_addr];
    end

    // -----------------------------------------------------------------------
    // Group contract loader. Exactly one valid strobe per beat, fixed
    // order 16 x bias -> 16 x M -> 16 x shift; the channel index is the
    // shared low nibble of the beat counter. First full round (48 beats)
    // fills the ACTIVE bank and arms the engine; every later round
    // fills the SHADOW bank. At a group boundary the shadow bank is
    // promoted to active (protocol: wdma completes the shadow load
    // before the engine reaches the boundary -- the >=435-cycle group
    // computation gives ample prefetch window).
    // -----------------------------------------------------------------------
    // The contract-bank always block below uses advance_now, so the net is
    // declared before it and assigned with the scan-control equations.
    wire advance_now;

    wire [3:0] cload_idx = cload_cnt[3:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cload_cnt <= 6'd0;
            grp_arm   <= 1'b0;
            shadow_rdy <= 1'b0;
            for (i = 0; i < 16; i = i + 1) begin
                bias_act[i] <= 32'sd0;
                bias_shd[i] <= 32'sd0;
                m_act[i]    <= 32'sd0;
                m_shd[i]    <= 32'sd0;
                shft_act[i] <= 7'd0;
                shft_shd[i] <= 7'd0;
            end
        end else if (any_start) begin
            cload_cnt  <= 6'd0;
            grp_arm    <= 1'b0;
            shadow_rdy <= 1'b0;
        end else begin
            if (bias_valid) begin
                if (!grp_arm) bias_act[cload_idx] <= bias_s32;
                else          bias_shd[cload_idx] <= bias_s32;
            end
            if (mult_valid) begin
                if (!grp_arm) m_act[cload_idx] <= m_s32;
                else          m_shd[cload_idx] <= m_s32;
            end
            if (shft_valid) begin
                if (!grp_arm) shft_act[cload_idx] <= shift;
                else          shft_shd[cload_idx] <= shift;
            end
            if (grp_start) begin
                cload_cnt <= 6'd0;
            end else if (bias_valid || mult_valid || shft_valid) begin
                if (cload_cnt == 6'd47) begin
                    cload_cnt <= 6'd0;
                    if (!grp_arm) grp_arm     <= 1'b1;
                    else          shadow_rdy  <= 1'b1;
                end else begin
                    cload_cnt <= cload_cnt + 6'd1;
                end
            end
            if (advance_now) begin
                shadow_rdy <= 1'b0;
                for (i = 0; i < 16; i = i + 1) begin
                    bias_act[i] <= bias_shd[i];
                    m_act[i]    <= m_shd[i];
                    shft_act[i] <= shft_shd[i];
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Scan control wires
    // -----------------------------------------------------------------------
    // window row availability: output row r needs input rows r-1..r+1,
    // i.e. row min(r+1, H-1) completed; row r+1 = H is pad (zero).
    // The index is masked to the layer's own bitmap so the unused
    // high counter states never address outside the array.
    wire row_rdy0 = (out_row_cnt == H0 - 1) ? g0_row_done[H0 - 1]
                   : g0_row_done[(out_row_cnt + 1'b1) & (H0 - 1)];
    wire row_rdy1 = (out_row_cnt == H1 - 1) ? g1_row_done[H1 - 1]
                   : g1_row_done[(out_row_cnt + 1'b1) & (H1 - 1)];
    wire row_rdy2 = (out_row_cnt == H2 - 1) ? g2_row_done[H2 - 1]
                   : g2_row_done[(out_row_cnt + 1'b1) & (H2 - 1)];
    wire row_rdy3 = (out_row_cnt == H3 - 1) ? g3_row_done[H3 - 1]
                   : g3_row_done[(out_row_cnt + 1'b1) & (H3 - 1)];
    wire row_ready = (sel == 2'd0) ? row_rdy0 : (sel == 2'd1) ? row_rdy1 :
                     (sel == 2'd2) ? row_rdy2 : row_rdy3;

    // issue window: cycles where a new tap address + weight pair can be
    // consumed (w_ready mirrors this to the wdma tap stream)
    wire issue_window = run_reg && (phase_reg == PH_SCAN)
                        && (tap_cnt != s_tap_last);
    wire issue_beat   = issue_window && w_valid;

    // pixel / group / layer boundary detection
    wire col_end      = (out_col_cnt == s_w - 1'b1);
    wire grp_end      = col_end && (grp_cnt == s_grp_last);
    wire layer_end    = grp_end && (out_row_cnt == s_h - 1'b1);
    wire need_advance = col_end && !layer_end;
    wire boundary_ok  = !need_advance || shadow_rdy;

    // phase transitions (requant drain must be idle before the snapshot
    // register is overwritten -- this stretches conv1 to 16 beats/px)
    wire snapshot_go  = run_reg && (phase_reg == PH_SNAP)
                        && (rhe_busy_cnt == 5'd0) && boundary_ok;
    assign advance_now = snapshot_go && need_advance;
    wire load_go      = run_reg && (phase_reg == PH_LOAD)
                        && row_ready && grp_arm && !fin_latched;

    // Layer completion: the last pixel of the layer is the one whose
    // snapshot fires with layer_end. From that beat the engine needs the
    // 16-beat TDM drain plus the 4-stage requant latency (20 beats) and
    // one more beat for the done register. Counting the tail avoids a
    // runtime H*W*COUT product comparator.
    wire fin_load     = snapshot_go && layer_end && (fin_cnt == 6'd0);
    wire layer_done_comb = run_reg && (fin_cnt == 6'd1);

    // -----------------------------------------------------------------------
    // Weight stream alignment: lock the 16-lane tap word and the read
    // guards one cycle so they line up with the synchronous RAM dout.
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_data_q  <= 128'd0;
            w_vld_q   <= 1'b0;
            rd_pad_q  <= 1'b0;
            rd_bank_q <= 2'd0;
        end else begin
            w_vld_q <= issue_beat;
            if (issue_beat) begin
                w_data_q  <= w_data;
                rd_pad_q  <= rd_pad_c;
                rd_bank_q <= rd_bank_c;
            end
        end
    end

    // MAC operand: live zp_in subtraction in the signed 9-bit domain
    // (u8 container store, see header storage-domain note)
    // -----------------------------------------------------------------------
    wire [7:0] g0_dout = (rd_bank_q == 2'd0) ? g0_dout0 :
                         (rd_bank_q == 2'd1) ? g0_dout1 : g0_dout2;
    wire [7:0] g1_dout = (rd_bank_q == 2'd0) ? g1_dout0 :
                         (rd_bank_q == 2'd1) ? g1_dout1 : g1_dout2;
    wire [7:0] g2_dout = (rd_bank_q == 2'd0) ? g2_dout0 :
                         (rd_bank_q == 2'd1) ? g2_dout1 : g2_dout2;
    wire [7:0] g3_dout = (rd_bank_q == 2'd0) ? g3_dout0 :
                         (rd_bank_q == 2'd1) ? g3_dout1 : g3_dout2;
    wire [7:0] ram_dout = (sel == 2'd0) ? g0_dout : (sel == 2'd1) ? g1_dout :
                          (sel == 2'd2) ? g2_dout : g3_dout;

    // -----------------------------------------------------------------------
    // MAC pipeline split (2026-10-29). The only failing path in the full NPU
    // build was
    //   DRM(CLKB->QB) -> ram_dout mux -> x_eff -> APM -> 32-bit carry tree -> acc
    // at -3.593 ns on core_clk (125 MHz), 13 logic levels with 56% of the
    // arrival spent on route delay: the row-buffer DRM and the adder tree
    // landed ~160 columns apart. Splitting it into
    //   DRM -> dout_q,  dout_q -> APM -> acc
    // keeps one tap per cycle in steady state; only a one-cycle bubble is
    // added at the end of each pixel scan. Registering only the row-buffer
    // read is enough because the DRM clock tree (CLKB) carries ~1.4 ns more
    // insertion delay than the fabric FF clock, and that skew -- not the
    // logic -- dominated the failing path.
    // -----------------------------------------------------------------------
    reg  [7:0]   dout_q;
    reg          rd_pad_q2;
    reg  [127:0] w_data_q2;
    reg          w_vld_q2;
    wire         mac_add = run_reg && w_vld_q2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_q    <= 8'd0;
            rd_pad_q2 <= 1'b0;
            w_data_q2 <= 128'd0;
            w_vld_q2  <= 1'b0;
        end else begin
            dout_q    <= ram_dout;
            rd_pad_q2 <= rd_pad_q;
            w_vld_q2  <= w_vld_q;
            if (w_vld_q) w_data_q2 <= w_data_q;
        end
    end

    // -----------------------------------------------------------------------
    wire signed [8:0] x_eff = rd_pad_q2 ? 9'sd0 :
            ($signed({1'b0, dout_q}) - $signed({1'b0, zp_in_reg}));

    // -----------------------------------------------------------------------
    // 16-lane INT8 MAC array with double-banked s32 accumulators
    // (design.md 4.2: 16 MAC/period, 8 APM 18x18 with 9x9 split = 2 int8
    // lanes per APM; plain signed multiply lets synthesis infer it)
    // -----------------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : mac_lane
            wire signed [7:0]  w_lane = w_data_q2[8*g +: 8];
            wire signed [16:0] lane_sum = x_eff * w_lane;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    acc_a[g]    <= 32'sd0;
                    acc_b[g]    <= 32'sd0;
                    acc_snap[g] <= 32'sd0;
                end else begin
                    // snapshot: drain bank <- active bank, then swap
                    if (snapshot_go) begin
                        acc_snap[g] <= acc_sel ? acc_b[g] : acc_a[g];
                        m_drn[g]    <= m_act[g];
                        shft_drn[g] <= shft_act[g];
                    end
                    // pixel start: accumulator <- rebuilt int32 bias
                    if (load_go) begin
                        if (!acc_sel) acc_a[g] <= bias_act[g];
                        else          acc_b[g] <= bias_act[g];
                    end else if (mac_add) begin
                        if (!acc_sel) acc_a[g] <= acc_a[g] + {{15{lane_sum[16]}}, lane_sum};
                        else          acc_b[g] <= acc_b[g] + {{15{lane_sum[16]}}, lane_sum};
                    end
                end
            end
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Drain tail counter: waits out the last pixel's 16-beat TDM requant
    // drain plus the 4-stage requant latency before layer_done.
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fin_cnt     <= 6'd0;
            fin_latched <= 1'b0;
        end else if (any_start) begin
            fin_cnt     <= 6'd0;
            fin_latched <= 1'b0;
        end else if (fin_load) begin
            fin_cnt     <= 6'd22;   // 16 drain beats + 5 latency + 1 register
            fin_latched <= 1'b1;
        end else if (fin_cnt != 6'd0) begin
            fin_cnt <= fin_cnt - 6'd1;
        end
    end

    // -----------------------------------------------------------------------
    // Main scan FSM. Pixel beat plan per group:
    //   PH_LOAD (1) -> PH_SCAN (TAP_NUM issues + 1 drain beat) ->
    //   PH_SNAP (1, gated by requant idle) -> next pixel.
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel          <= 2'd0;
            run_reg      <= 1'b0;
            phase_reg    <= PH_LOAD;
            out_row_cnt  <= {RR{1'b0}};
            grp_cnt      <= {RG{1'b0}};
            out_col_cnt  <= {RW{1'b0}};
            tap_cnt      <= {RT{1'b0}};
            mac_cnt      <= {RT{1'b0}};
            dy_cnt       <= 2'd0;
            dx_cnt       <= 2'd0;
            cin_cnt      <= {RC{1'b0}};
            rd_bank_base <= 2'd2;   // window row -1 (pad) virtual bank
            rhe_busy_cnt <= 5'd0;
            rhe_ch       <= 4'd0;
            acc_sel      <= 1'b0;
            done_q       <= 1'b0;
            advance_q    <= 1'b0;
        end else begin
            advance_q <= advance_now;
            done_q    <= layer_done_comb;
            if (any_start) begin
                sel          <= conv_sel;
                run_reg      <= 1'b1;
                phase_reg    <= PH_LOAD;
                out_row_cnt  <= {RR{1'b0}};
                grp_cnt      <= {RG{1'b0}};
                out_col_cnt  <= {RW{1'b0}};
                tap_cnt      <= {RT{1'b0}};
                mac_cnt      <= {RT{1'b0}};
                dy_cnt       <= 2'd0;
                dx_cnt       <= 2'd0;
                cin_cnt      <= {RC{1'b0}};
                rd_bank_base <= 2'd2;
                rhe_busy_cnt <= 5'd0;
                rhe_ch       <= 4'd0;
                acc_sel      <= 1'b0;
                done_q       <= 1'b0;
                advance_q    <= 1'b0;
            end else if (run_reg) begin
                if (layer_done_comb)
                    run_reg <= 1'b0;
                // ---- scan FSM ----
                if (load_go) begin
                    phase_reg <= PH_SCAN;
                    tap_cnt   <= {RT{1'b0}};
                    mac_cnt   <= {RT{1'b0}};
                    dy_cnt    <= 2'd0;
                    dx_cnt    <= 2'd0;
                    cin_cnt   <= {RC{1'b0}};
                end else if (phase_reg == PH_SCAN) begin
                    if (issue_beat) begin
                        tap_cnt <= tap_cnt + {{(RT-1){1'b0}}, 1'b1};
                        // tap order: cin outer, dy middle, dx inner
                        // (golden flatten order, dy*3+dx minor)
                        if (dx_cnt == 2'd2) begin
                            dx_cnt <= 2'd0;
                            if (dy_cnt == 2'd2) begin
                                dy_cnt <= 2'd0;
                                cin_cnt <= cin_cnt + 1'b1;
                            end else begin
                                dy_cnt <= dy_cnt + 2'd1;
                            end
                        end else begin
                            dx_cnt <= dx_cnt + 2'd1;
                        end
                    end
                    if (mac_add) begin
                        mac_cnt <= mac_cnt + 1'b1;
                        if (mac_cnt == s_tap_last - 1'b1)
                            phase_reg <= PH_SNAP;
                    end
                end else if (snapshot_go) begin
                    phase_reg    <= PH_LOAD;
                    acc_sel      <= ~acc_sel;
                    rhe_busy_cnt <= 5'd16;
                    rhe_ch       <= 4'd0;
                    // scan position advance: col -> grp -> row. The final
                    // row of the layer must NOT roll over (a stale row
                    // index would address past the row bitmap).
                    if (col_end) begin
                        out_col_cnt <= {RW{1'b0}};
                        if (grp_end) begin
                            grp_cnt <= {RG{1'b0}};
                            if (!layer_end) begin
                                rd_bank_base <= add3(rd_bank_base, 2'd1);
                                out_row_cnt  <= out_row_cnt + 1'b1;
                            end
                        end else begin
                            grp_cnt <= grp_cnt + 1'b1;
                        end
                    end else begin
                        out_col_cnt <= out_col_cnt + 1'b1;
                    end
                end
                // ---- requant drain: 16-beat TDM, hidden in the next
                // pixel's tap scan (snap gate keeps conv1 in lockstep)
                if (rhe_busy_cnt != 5'd0) begin
                    rhe_busy_cnt <= rhe_busy_cnt - 5'd1;
                    rhe_ch       <= rhe_ch + 4'd1;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // requant_unit operand muxes (TDM channel select) and egress wiring
    // -----------------------------------------------------------------------
    assign rq_acc_s32  = acc_snap[rhe_ch];
    assign rq_m_s32    = m_drn[rhe_ch];
    assign rq_shift    = shft_drn[rhe_ch];
    assign rq_zp_out   = zp_out_reg;
    assign rq_in_valid = (rhe_busy_cnt != 5'd0);

    assign y_valid     = rq_y_valid;
    assign y_u8        = rq_y_u8;
    assign done0       = done_q && (sel == 2'd0);
    assign done1       = done_q && (sel == 2'd1);
    assign done2       = done_q && (sel == 2'd2);
    assign done3       = done_q && (sel == 2'd3);
    assign adv0        = advance_q && (sel == 2'd0);
    assign adv1        = advance_q && (sel == 2'd1);
    assign adv2        = advance_q && (sel == 2'd2);
    assign adv3        = advance_q && (sel == 2'd3);
    assign w_ready     = issue_window;

endmodule