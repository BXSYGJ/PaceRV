// -----------------------------------------------------------------------------
// File    : top_mel_test.v
// Module  : top_mel_test
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Task    : T23 - stand-alone Mel-engine validation bitstream.
// -----------------------------------------------------------------------------
// PURPOSE
//   Bring the whole Mel path onto the board WITHOUT external memory and
//   WITHOUT a real I2S microphone, and compare the exported feature image
//   byte-for-byte against reports/golden_ref/sine_440_full/feat.npy.
//
//   mel_engine (src/mel/mel_engine.v) reads its PCM window from the DDR3
//   master port m2 (516 reads of 256 samples), NOT from an I2S pin.  This
//   top level therefore replaces the DDR3 controller with an on-chip fake
//   PCM source that answers the m2 read commands with the exact samples the
//   golden generator used.  No DDR3 IP, no PLL and no DDR3 pin is
//   instantiated or constrained here, so this bitstream is independent of
//   the DDR3 bring-up line.
//
// GOLDEN GENERATION CONDITIONS (verified against tests/gen_test_audio.py
// and scripts/golden_pipeline.py, bit-exact)
//   sample rate        : 44100 Hz
//   channel / width    : mono, signed 16-bit PCM (NOT uint8; the uint8
//                        container belongs to the FEATURE domain and uses
//                        zp_in = 49)
//   generator          : t = n / 44100.0 (float64)
//                        pcm[n] = int16( round( sin(2*pi*440.0*t) * 32767 ) )
//   window length      : 132096 samples = 258 frames x hop 512 (3 s)
//   numpy round() is round-half-to-even, but a half-integer tie never
//   occurs here (|sin| * 32767 is irrational for all n), so a plain
//   round-half-up implementation is bit-identical.  Verified: the stored
//   tests/fixtures/sine_440_full.wav equals this formula for all 132096
//   samples.
//   PERIODICITY: 440/44100 = 22/2205, so the sample stream repeats with
//   period 2205 exactly (verified over all 132096 samples against the wav:
//   zero mismatches).  The ROM below is therefore only 2205 x 16 bit
//   (4410 B ~ 1 DRM) and is replayed cyclically by the fake source.
//
// DATA PATH
//   pcm_rom (2205 x 16) -> fake m2 read responder -> mel_engine.m2_rd_data
//   mel_engine          -> internal feature bank
//   mel_engine.feat_rd_addr / feat_rd_data -> hex streamer
//   hex streamer (16512 bytes, 2 hex digits each, one newline per 64-byte
//   frame) -> byte shim -> uart_tx (115200 8N1, C24)
//   diag_uart_report    -> two 91-byte STATUS frames (before / after the
//                          hex stream) with mel_cycles, command counts, the
//                          feature XOR/sum checksums and sticky status
//
// CYCLE BUDGET (27 MHz board clock, no PLL)
//   mel_engine header budget at 125 MHz is ~5.1 M cycles (ST_RUN fft-bound
//   259 x ~18.5 k = 4.79 M, ST_DB 66.3 k, ST_SPECEX 21 k, ST_STD 50 k).
//   At 27 MHz that is 5.1 M / 27 M = 189 ms.
//   The default mel_engine watchdog (25 M cycles) becomes 926 ms at 27 MHz,
//   4.9x above the expected 189 ms, so the default is kept.
//   This top level adds an independent 54 M cycle (2.0 s) run timeout so a
//   stalled engine still produces a STATUS frame instead of silence.
//
// UART TIME BUDGET
//   BAUD_DIV = round(27e6 / 115200) = 234 -> 115385 baud (+0.16 %, inside
//   the 8N1 receiver tolerance of 2-3 %).
//   hex payload : 16512 bytes x 2 chars = 33024 chars
//   258 newlines (one per 64-byte feature frame)          =   258
//   total                                                  = 33282 bytes
//   one 10-bit byte at 115385 baud = 86.67 us
//   33282 x 86.67 us = 2.885 s
//   plus two 91-byte diagnostic frames (7.9 ms each) and the 189 ms engine
//   run: whole test ~= 3.1 s after reset.
//
// LED MAP
//   led[0] free-running heartbeat       led[4] mel_engine watchdog sticky
//   led[1] mel_engine busy              led[5] top-level run timeout
//   led[2] mel_done seen (latched)      led[6] PCM address mismatch sticky
//   led[3] hex stream active            led[7] hex stream finished
//
// No string literal appears in this file: the feature hex stream and the
// diagnostic frames are built from explicit ASCII constants, following the
// uart_debug.v string-byte-order incident documented in the handoff notes.
// All logic is in the 27 MHz clk domain, reset is asynchronous active low.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module top_mel_test #(
    // 234 -> 27 MHz / 115200 (see the UART TIME BUDGET note above).
    parameter [15:0] BAUD_DIV           = 16'd234,
    // Independent top-level run timeout, 54 M cycles = 2.0 s at 27 MHz.
    parameter [31:0] RUN_TIMEOUT_CYCLES = 32'd54_000_000
) (
    input  wire       clk,        // 27 MHz board crystal (D18)
    input  wire       rst_n,      // asynchronous board reset (C22)
    output wire [7:0] led,        // progress LEDs
    output wire       uart_tx     // 115200 8N1 diagnostic pin (C24)
);

    // ------------------------------------------------------------------
    // Geometry constants.
    // ------------------------------------------------------------------
    localparam [15:0] FEAT_BYTES    = 16'd16512;  // 64 mel x 258 frames uint8
    localparam [14:0] FEAT_LAST     = 15'd16511;  // last logical element index
    // 2205 samples need 12 bits: the pre-T26 code declared this as
    // `localparam [10:0] PCM_ROM_LAST = 11'd2204`, which truncates to 156 and
    // (with an 11-bit samp_idx) made the ROM replay with a period of 157
    // samples instead of 2205 - a silent PCM corruption that no lexical lint
    // can see.  build/scan_sized_literals.py flags that class of bug.
    localparam [11:0] PCM_ROM_LAST  = 12'd2204;   // 44100 / 440 period - 1
    localparam [17:0] PCM_CMD_SAMP  = 18'd256;    // 16 beats x 16 samples
    localparam [9:0]  START_DLY     = 10'd1023;   // ~38 us wait after reset
    localparam [31:0] LINE_LOW_MASK = 32'd63;     // 64-byte feature frame

    // ------------------------------------------------------------------
    // Mel engine <-> fake PCM source wiring.
    // ------------------------------------------------------------------
    reg         win_tick;
    wire [15:0] win_id = 16'd0;

    wire         mel_m2_cmd_valid;
    wire [36:0]  mel_m2_cmd;
    wire [255:0] mel_m2_wdata;
    wire         mel_m2_wready;
    wire         mel_m2_rd_valid;
    wire         mel_m2_rd_ready;
    wire [255:0] mel_m2_rd_data;
    wire         mel_m2_done;

    wire         mel_npu_start;
    wire         mel_feat_page;
    reg  [14:0]  feat_rd_addr;
    wire [7:0]   feat_rd_data;
    wire         mel_done;
    wire [31:0]  mel_cycles;
    wire         mel_timeout;
    wire         mel_win_miss;
    wire         mel_busy;

    // ------------------------------------------------------------------
    // Fake PCM source state (declared up front: Verilog-2005 requires every
    // identifier to be declared before first use).
    // ------------------------------------------------------------------
    localparam [2:0] RS_IDLE = 3'd0;
    localparam [2:0] RS_LOAD = 3'd1;
    localparam [2:0] RS_ACK  = 3'd2;
    localparam [2:0] RS_BEAT = 3'd3;
    localparam [2:0] RS_WR   = 3'd4;

    reg [15:0]  pcm_rom [0:2204];
    // 256-sample staging for the command currently being served: one len=15
    // read command is 16 beats x 16 samples, so the responder fills the whole
    // command up front (like the real controller's read fifo, depth >= 16
    // beats) and only then emits rd_valid.  That is what lets m2_done stay
    // "after the last data beat", matching ddr3_ctrl_axi.v.
    reg [15:0]  pcm_buf [0:255];
    reg [2:0]   rs_state;
    reg [27:0]  rs_addr;
    reg [17:0]  glob_cnt;
    reg [11:0]  samp_idx;
    reg [8:0]   load_cnt;
    reg [3:0]   rs_beat_cnt;
    reg         rs_rd_valid;
    reg         rs_done;
    reg         rs_wready;
    reg         addr_err;
    reg [17:0]  addr_err_samp;
    reg [31:0]  wr_xor;
    reg [31:0]  wr_cmd_cnt;
    reg [31:0]  rd_cmd_cnt;

    wire [15:0]  rom_q;
    wire [255:0] beat_pack;
    wire [11:0]  samp_idx_inc;
    wire [7:0]   beat_base;

    // ------------------------------------------------------------------
    // Hex streamer state.
    // ------------------------------------------------------------------
    localparam [2:0] HS_IDLE = 3'd0;
    localparam [2:0] HS_ADDR = 3'd1;
    localparam [2:0] HS_WAIT = 3'd2;
    localparam [2:0] HS_HI   = 3'd3;
    localparam [2:0] HS_LO   = 3'd4;
    localparam [2:0] HS_NL   = 3'd5;
    localparam [2:0] HS_NEXT = 3'd6;
    localparam [2:0] HS_DONE = 3'd7;

    reg [2:0]   hs_state;
    reg [14:0]  hex_addr;
    reg [7:0]   byte_q;
    reg [31:0]  feat_xor;
    reg [31:0]  feat_sum;
    reg         hex_done;
    reg         owner_hex;      // 1 = hex streamer owns the UART
    reg [7:0]   hex_ch_data;
    wire        hex_ch_valid;

    // ------------------------------------------------------------------
    // UART byte shim state.
    // ------------------------------------------------------------------
    reg         shim_v;
    reg  [7:0]  shim_d;
    reg         shim_lockout;
    wire        uart_ready;
    wire [7:0]  src_data;
    wire        src_valid;
    wire        src_take;
    wire        diag_ready;
    wire        hex_acc;

    // ------------------------------------------------------------------
    // Diagnostic frame engine state.
    // ------------------------------------------------------------------
    localparam [2:0] MS_WAIT  = 3'd0;
    localparam [2:0] MS_RUN   = 3'd1;
    localparam [2:0] MS_STAT1 = 3'd2;
    localparam [2:0] MS_HEX   = 3'd3;
    localparam [2:0] MS_STAT2 = 3'd4;
    localparam [2:0] MS_HOLD  = 3'd5;

    reg [2:0]   ms_state;
    reg         diag_fire;
    reg [9:0]   start_cnt;
    reg         start_done;
    reg         mel_done_seen;
    reg         run_timeout;
    reg [31:0]  run_cnt;
    reg         stat_fired;
    reg         diag_seen_busy; // the current frame has actually started
    reg         hex_started;
    reg [23:0]  beat_cnt;

    wire        diag_busy;
    wire [7:0]  diag_tx_data;
    wire        diag_tx_valid;
    wire [31:0] stat_a;
    wire [31:0] stat_b;
    wire [31:0] stat_c;
    wire [31:0] stat_d;
    wire [31:0] stat_e;
    wire [31:0] stat_f;
    wire [7:0]  stat_g;
    wire [7:0]  stat_h;

    // ------------------------------------------------------------------
    // Mel engine.
    //
    // The three hex file paths are overridden to the "src/mel/..." form,
    // exactly like src/ctrl/instrec_top.v does: run_pds_full.ps1 copies
    // every <hex_dir>/*.hex into <work_dir>/<hex_dir>/, and PDS resolves
    // $readmemh paths against the work_dir root, so the bare defaults
    // ("hann_q15.hex") would fail with Verilog-3001.  The same prefix is
    // already hard-coded inside fft2048_sdf.v for the twiddle ROMs.
    // These are the ONLY string literals in this file and they are file
    // path arguments of $readmemh, never bytes on a wire (the uart_debug
    // string byte-order incident concerned transmitted text, not file
    // names).  See reports/mel_test_conclusion.md, deviation D-01.
    // ------------------------------------------------------------------
    mel_engine #(
        .HAN_HEX_FILE ("src/mel/hann_q15.hex"),
        .COO_HEX_FILE ("src/mel/mel_coo.hex"),
        .LUT_HEX_FILE ("src/mel/log2_lut.hex")
    ) u_mel_engine (
        .clk          (clk),
        .rst_n        (rst_n),
        .win_tick     (win_tick),
        .win_id       (win_id),
        .m2_cmd_valid (mel_m2_cmd_valid),
        .m2_cmd       (mel_m2_cmd),
        .m2_wdata     (mel_m2_wdata),
        .m2_wready    (mel_m2_wready),
        .m2_rd_valid  (mel_m2_rd_valid),
        .m2_rd_ready  (mel_m2_rd_ready),
        .m2_rd_data   (mel_m2_rd_data),
        .m2_done      (mel_m2_done),
        .npu_start    (mel_npu_start),
        .feat_page    (mel_feat_page),
        .feat_rd_addr (feat_rd_addr),
        .feat_rd_data (feat_rd_data),
        .mel_done     (mel_done),
        .mel_cycles   (mel_cycles),
        .mel_timeout  (mel_timeout),
        .win_miss     (mel_win_miss),
        .busy         (mel_busy)
    );

    // ------------------------------------------------------------------
    // Fake PCM source, part 1: the 2205-sample sine period ROM.
    //
    // pcm_rom[k] = int16( round( sin(2*pi*440*(k/44100)) * 32767 ) )
    // Reproduced exactly (see the header).  Because 440/44100 = 22/2205 the
    // stored 2205 samples tile the whole 132096-sample window with zero
    // difference (verified against the fixture wav over all 132096 samples).
    // ------------------------------------------------------------------
    initial begin
        pcm_rom[0] = 16'h0000; pcm_rom[1] = 16'h0805; pcm_rom[2] = 16'h1002; pcm_rom[3] = 16'h17EE; pcm_rom[4] = 16'h1FC3; pcm_rom[5] = 16'h2777;
        pcm_rom[6] = 16'h2F04; pcm_rom[7] = 16'h3662; pcm_rom[8] = 16'h3D89; pcm_rom[9] = 16'h4472; pcm_rom[10] = 16'h4B16; pcm_rom[11] = 16'h516F;
        pcm_rom[12] = 16'h5776; pcm_rom[13] = 16'h5D25; pcm_rom[14] = 16'h6276; pcm_rom[15] = 16'h6764; pcm_rom[16] = 16'h6BEA; pcm_rom[17] = 16'h7004;
        pcm_rom[18] = 16'h73AD; pcm_rom[19] = 16'h76E1; pcm_rom[20] = 16'h799E; pcm_rom[21] = 16'h7BE1; pcm_rom[22] = 16'h7DA7; pcm_rom[23] = 16'h7EEF;
        pcm_rom[24] = 16'h7FB7; pcm_rom[25] = 16'h7FFF; pcm_rom[26] = 16'h7FC6; pcm_rom[27] = 16'h7F0C; pcm_rom[28] = 16'h7DD3; pcm_rom[29] = 16'h7C1B;
        pcm_rom[30] = 16'h79E6; pcm_rom[31] = 16'h7737; pcm_rom[32] = 16'h7410; pcm_rom[33] = 16'h7074; pcm_rom[34] = 16'h6C67; pcm_rom[35] = 16'h67ED;
        pcm_rom[36] = 16'h630A; pcm_rom[37] = 16'h5DC4; pcm_rom[38] = 16'h5820; pcm_rom[39] = 16'h5222; pcm_rom[40] = 16'h4BD3; pcm_rom[41] = 16'h4537;
        pcm_rom[42] = 16'h3E55; pcm_rom[43] = 16'h3735; pcm_rom[44] = 16'h2FDD; pcm_rom[45] = 16'h2855; pcm_rom[46] = 16'h20A5; pcm_rom[47] = 16'h18D3;
        pcm_rom[48] = 16'h10E9; pcm_rom[49] = 16'h08EE; pcm_rom[50] = 16'h00E9; pcm_rom[51] = 16'hF8E4; pcm_rom[52] = 16'hF0E6; pcm_rom[53] = 16'hE8F7;
        pcm_rom[54] = 16'hE120; pcm_rom[55] = 16'hD967; pcm_rom[56] = 16'hD1D5; pcm_rom[57] = 16'hCA72; pcm_rom[58] = 16'hC344; pcm_rom[59] = 16'hBC54;
        pcm_rom[60] = 16'hB5A7; pcm_rom[61] = 16'hAF46; pcm_rom[62] = 16'hA935; pcm_rom[63] = 16'hA37C; pcm_rom[64] = 16'h9E20; pcm_rom[65] = 16'h9926;
        pcm_rom[66] = 16'h9494; pcm_rom[67] = 16'h906E; pcm_rom[68] = 16'h8CB8; pcm_rom[69] = 16'h8976; pcm_rom[70] = 16'h86AB; pcm_rom[71] = 16'h845A;
        pcm_rom[72] = 16'h8286; pcm_rom[73] = 16'h8130; pcm_rom[74] = 16'h8059; pcm_rom[75] = 16'h8003; pcm_rom[76] = 16'h802D; pcm_rom[77] = 16'h80D8;
        pcm_rom[78] = 16'h8203; pcm_rom[79] = 16'h83AD; pcm_rom[80] = 16'h85D3; pcm_rom[81] = 16'h8875; pcm_rom[82] = 16'h8B8F; pcm_rom[83] = 16'h8F1D;
        pcm_rom[84] = 16'h931E; pcm_rom[85] = 16'h978C; pcm_rom[86] = 16'h9C63; pcm_rom[87] = 16'hA19E; pcm_rom[88] = 16'hA738; pcm_rom[89] = 16'hAD2B;
        pcm_rom[90] = 16'hB372; pcm_rom[91] = 16'hBA05; pcm_rom[92] = 16'hC0DF; pcm_rom[93] = 16'hC7F9; pcm_rom[94] = 16'hCF4B; pcm_rom[95] = 16'hD6CE;
        pcm_rom[96] = 16'hDE7A; pcm_rom[97] = 16'hE648; pcm_rom[98] = 16'hEE30; pcm_rom[99] = 16'hF629; pcm_rom[100] = 16'hFE2D; pcm_rom[101] = 16'h0633;
        pcm_rom[102] = 16'h0E32; pcm_rom[103] = 16'h1623; pcm_rom[104] = 16'h1DFE; pcm_rom[105] = 16'h25BA; pcm_rom[106] = 16'h2D51; pcm_rom[107] = 16'h34BA;
        pcm_rom[108] = 16'h3BEE; pcm_rom[109] = 16'h42E6; pcm_rom[110] = 16'h499A; pcm_rom[111] = 16'h5005; pcm_rom[112] = 16'h561F; pcm_rom[113] = 16'h5BE2;
        pcm_rom[114] = 16'h6149; pcm_rom[115] = 16'h664E; pcm_rom[116] = 16'h6AEC; pcm_rom[117] = 16'h6F1F; pcm_rom[118] = 16'h72E2; pcm_rom[119] = 16'h7631;
        pcm_rom[120] = 16'h790A; pcm_rom[121] = 16'h7B68; pcm_rom[122] = 16'h7D4B; pcm_rom[123] = 16'h7EB0; pcm_rom[124] = 16'h7F95; pcm_rom[125] = 16'h7FFA;
        pcm_rom[126] = 16'h7FDE; pcm_rom[127] = 16'h7F42; pcm_rom[128] = 16'h7E25; pcm_rom[129] = 16'h7C8A; pcm_rom[130] = 16'h7A71; pcm_rom[131] = 16'h77DE;
        pcm_rom[132] = 16'h74D2; pcm_rom[133] = 16'h7150; pcm_rom[134] = 16'h6D5C; pcm_rom[135] = 16'h68FB; pcm_rom[136] = 16'h642F; pcm_rom[137] = 16'h5EFF;
        pcm_rom[138] = 16'h5970; pcm_rom[139] = 16'h5386; pcm_rom[140] = 16'h4D49; pcm_rom[141] = 16'h46BE; pcm_rom[142] = 16'h3FEB; pcm_rom[143] = 16'h38D9;
        pcm_rom[144] = 16'h318D; pcm_rom[145] = 16'h2A0F; pcm_rom[146] = 16'h2267; pcm_rom[147] = 16'h1A9D; pcm_rom[148] = 16'h12B7; pcm_rom[149] = 16'h0ABF;
        pcm_rom[150] = 16'h02BC; pcm_rom[151] = 16'hFAB7; pcm_rom[152] = 16'hF2B6; pcm_rom[153] = 16'hEAC3; pcm_rom[154] = 16'hE2E5; pcm_rom[155] = 16'hDB25;
        pcm_rom[156] = 16'hD38A; pcm_rom[157] = 16'hCC1B; pcm_rom[158] = 16'hC4E1; pcm_rom[159] = 16'hBDE2; pcm_rom[160] = 16'hB725; pcm_rom[161] = 16'hB0B2;
        pcm_rom[162] = 16'hAA8F; pcm_rom[163] = 16'hA4C1; pcm_rom[164] = 16'h9F4F; pcm_rom[165] = 16'h9A3F; pcm_rom[166] = 16'h9595; pcm_rom[167] = 16'h9156;
        pcm_rom[168] = 16'h8D86; pcm_rom[169] = 16'h8A29; pcm_rom[170] = 16'h8743; pcm_rom[171] = 16'h84D6; pcm_rom[172] = 16'h82E6; pcm_rom[173] = 16'h8172;
        pcm_rom[174] = 16'h807F; pcm_rom[175] = 16'h800B; pcm_rom[176] = 16'h8018; pcm_rom[177] = 16'h80A6; pcm_rom[178] = 16'h81B4; pcm_rom[179] = 16'h8341;
        pcm_rom[180] = 16'h854B; pcm_rom[181] = 16'h87D1; pcm_rom[182] = 16'h8AD0; pcm_rom[183] = 16'h8E44; pcm_rom[184] = 16'h922B; pcm_rom[185] = 16'h9681;
        pcm_rom[186] = 16'h9B40; pcm_rom[187] = 16'hA065; pcm_rom[188] = 16'hA5EA; pcm_rom[189] = 16'hABC9; pcm_rom[190] = 16'hB1FE; pcm_rom[191] = 16'hB880;
        pcm_rom[192] = 16'hBF4B; pcm_rom[193] = 16'hC657; pcm_rom[194] = 16'hCD9C; pcm_rom[195] = 16'hD515; pcm_rom[196] = 16'hDCB8; pcm_rom[197] = 16'hE47F;
        pcm_rom[198] = 16'hEC62; pcm_rom[199] = 16'hF458; pcm_rom[200] = 16'hFC5A; pcm_rom[201] = 16'h0460; pcm_rom[202] = 16'h0C62; pcm_rom[203] = 16'h1457;
        pcm_rom[204] = 16'h1C37; pcm_rom[205] = 16'h23FB; pcm_rom[206] = 16'h2B9B; pcm_rom[207] = 16'h330F; pcm_rom[208] = 16'h3A50; pcm_rom[209] = 16'h4156;
        pcm_rom[210] = 16'h481A; pcm_rom[211] = 16'h4E96; pcm_rom[212] = 16'h54C3; pcm_rom[213] = 16'h5A9B; pcm_rom[214] = 16'h6017; pcm_rom[215] = 16'h6533;
        pcm_rom[216] = 16'h69E9; pcm_rom[217] = 16'h6E34; pcm_rom[218] = 16'h7211; pcm_rom[219] = 16'h757B; pcm_rom[220] = 16'h786F; pcm_rom[221] = 16'h7AE9;
        pcm_rom[222] = 16'h7CE8; pcm_rom[223] = 16'h7E6A; pcm_rom[224] = 16'h7F6C; pcm_rom[225] = 16'h7FEE; pcm_rom[226] = 16'h7FF0; pcm_rom[227] = 16'h7F70;
        pcm_rom[228] = 16'h7E71; pcm_rom[229] = 16'h7CF2; pcm_rom[230] = 16'h7AF6; pcm_rom[231] = 16'h787E; pcm_rom[232] = 16'h758D; pcm_rom[233] = 16'h7226;
        pcm_rom[234] = 16'h6E4C; pcm_rom[235] = 16'h6A03; pcm_rom[236] = 16'h654F; pcm_rom[237] = 16'h6036; pcm_rom[238] = 16'h5ABB; pcm_rom[239] = 16'h54E6;
        pcm_rom[240] = 16'h4EBB; pcm_rom[241] = 16'h4841; pcm_rom[242] = 16'h417E; pcm_rom[243] = 16'h3A79; pcm_rom[244] = 16'h333A; pcm_rom[245] = 16'h2BC7;
        pcm_rom[246] = 16'h2428; pcm_rom[247] = 16'h1C65; pcm_rom[248] = 16'h1485; pcm_rom[249] = 16'h0C90; pcm_rom[250] = 16'h048F; pcm_rom[251] = 16'hFC89;
        pcm_rom[252] = 16'hF487; pcm_rom[253] = 16'hEC90; pcm_rom[254] = 16'hE4AD; pcm_rom[255] = 16'hDCE5; pcm_rom[256] = 16'hD541; pcm_rom[257] = 16'hCDC7;
        pcm_rom[258] = 16'hC680; pcm_rom[259] = 16'hBF73; pcm_rom[260] = 16'hB8A7; pcm_rom[261] = 16'hB223; pcm_rom[262] = 16'hABED; pcm_rom[263] = 16'hA60B;
        pcm_rom[264] = 16'hA084; pcm_rom[265] = 16'h9B5D; pcm_rom[266] = 16'h969B; pcm_rom[267] = 16'h9243; pcm_rom[268] = 16'h8E5A; pcm_rom[269] = 16'h8AE3;
        pcm_rom[270] = 16'h87E1; pcm_rom[271] = 16'h8559; pcm_rom[272] = 16'h834B; pcm_rom[273] = 16'h81BC; pcm_rom[274] = 16'h80AB; pcm_rom[275] = 16'h801A;
        pcm_rom[276] = 16'h800A; pcm_rom[277] = 16'h807B; pcm_rom[278] = 16'h816C; pcm_rom[279] = 16'h82DC; pcm_rom[280] = 16'h84CA; pcm_rom[281] = 16'h8734;
        pcm_rom[282] = 16'h8A17; pcm_rom[283] = 16'h8D71; pcm_rom[284] = 16'h913E; pcm_rom[285] = 16'h957B; pcm_rom[286] = 16'h9A23; pcm_rom[287] = 16'h9F31;
        pcm_rom[288] = 16'hA4A0; pcm_rom[289] = 16'hAA6C; pcm_rom[290] = 16'hB08D; pcm_rom[291] = 16'hB6FF; pcm_rom[292] = 16'hBDBA; pcm_rom[293] = 16'hC4B7;
        pcm_rom[294] = 16'hCBF0; pcm_rom[295] = 16'hD35E; pcm_rom[296] = 16'hDAF8; pcm_rom[297] = 16'hE2B8; pcm_rom[298] = 16'hEA95; pcm_rom[299] = 16'hF288;
        pcm_rom[300] = 16'hFA88; pcm_rom[301] = 16'h028E; pcm_rom[302] = 16'h0A91; pcm_rom[303] = 16'h1289; pcm_rom[304] = 16'h1A6F; pcm_rom[305] = 16'h223A;
        pcm_rom[306] = 16'h29E3; pcm_rom[307] = 16'h3162; pcm_rom[308] = 16'h38AF; pcm_rom[309] = 16'h3FC3; pcm_rom[310] = 16'h4697; pcm_rom[311] = 16'h4D24;
        pcm_rom[312] = 16'h5363; pcm_rom[313] = 16'h594E; pcm_rom[314] = 16'h5EE0; pcm_rom[315] = 16'h6412; pcm_rom[316] = 16'h68E0; pcm_rom[317] = 16'h6D44;
        pcm_rom[318] = 16'h713A; pcm_rom[319] = 16'h74BE; pcm_rom[320] = 16'h77CD; pcm_rom[321] = 16'h7A64; pcm_rom[322] = 16'h7C7F; pcm_rom[323] = 16'h7E1D;
        pcm_rom[324] = 16'h7F3D; pcm_rom[325] = 16'h7FDC; pcm_rom[326] = 16'h7FFB; pcm_rom[327] = 16'h7F99; pcm_rom[328] = 16'h7EB6; pcm_rom[329] = 16'h7D55;
        pcm_rom[330] = 16'h7B75; pcm_rom[331] = 16'h7919; pcm_rom[332] = 16'h7643; pcm_rom[333] = 16'h72F6; pcm_rom[334] = 16'h6F36; pcm_rom[335] = 16'h6B06;
        pcm_rom[336] = 16'h666A; pcm_rom[337] = 16'h6167; pcm_rom[338] = 16'h5C02; pcm_rom[339] = 16'h5641; pcm_rom[340] = 16'h5029; pcm_rom[341] = 16'h49C0;
        pcm_rom[342] = 16'h430D; pcm_rom[343] = 16'h3C17; pcm_rom[344] = 16'h34E4; pcm_rom[345] = 16'h2D7D; pcm_rom[346] = 16'h25E7; pcm_rom[347] = 16'h1E2B;
        pcm_rom[348] = 16'h1651; pcm_rom[349] = 16'h0E60; pcm_rom[350] = 16'h0661; pcm_rom[351] = 16'hFE5C; pcm_rom[352] = 16'hF658; pcm_rom[353] = 16'hEE5E;
        pcm_rom[354] = 16'hE676; pcm_rom[355] = 16'hDEA7; pcm_rom[356] = 16'hD6FA; pcm_rom[357] = 16'hCF76; pcm_rom[358] = 16'hC823; pcm_rom[359] = 16'hC108;
        pcm_rom[360] = 16'hBA2C; pcm_rom[361] = 16'hB397; pcm_rom[362] = 16'hAD4F; pcm_rom[363] = 16'hA759; pcm_rom[364] = 16'hA1BD; pcm_rom[365] = 16'h9C80;
        pcm_rom[366] = 16'h97A7; pcm_rom[367] = 16'h9336; pcm_rom[368] = 16'h8F33; pcm_rom[369] = 16'h8BA2; pcm_rom[370] = 16'h8886; pcm_rom[371] = 16'h85E1;
        pcm_rom[372] = 16'h83B8; pcm_rom[373] = 16'h820B; pcm_rom[374] = 16'h80DE; pcm_rom[375] = 16'h8030; pcm_rom[376] = 16'h8002; pcm_rom[377] = 16'h8056;
        pcm_rom[378] = 16'h812A; pcm_rom[379] = 16'h827D; pcm_rom[380] = 16'h844E; pcm_rom[381] = 16'h869C; pcm_rom[382] = 16'h8964; pcm_rom[383] = 16'h8CA4;
        pcm_rom[384] = 16'h9057; pcm_rom[385] = 16'h947B; pcm_rom[386] = 16'h990B; pcm_rom[387] = 16'h9E02; pcm_rom[388] = 16'hA35C; pcm_rom[389] = 16'hA913;
        pcm_rom[390] = 16'hAF22; pcm_rom[391] = 16'hB581; pcm_rom[392] = 16'hBC2C; pcm_rom[393] = 16'hC31B; pcm_rom[394] = 16'hCA47; pcm_rom[395] = 16'hD1AA;
        pcm_rom[396] = 16'hD93A; pcm_rom[397] = 16'hE0F2; pcm_rom[398] = 16'hE8C9; pcm_rom[399] = 16'hF0B8; pcm_rom[400] = 16'hF8B6; pcm_rom[401] = 16'h00BB;
        pcm_rom[402] = 16'h08BF; pcm_rom[403] = 16'h10BB; pcm_rom[404] = 16'h18A6; pcm_rom[405] = 16'h2077; pcm_rom[406] = 16'h2829; pcm_rom[407] = 16'h2FB2;
        pcm_rom[408] = 16'h370B; pcm_rom[409] = 16'h3E2C; pcm_rom[410] = 16'h450F; pcm_rom[411] = 16'h4BAD; pcm_rom[412] = 16'h51FF; pcm_rom[413] = 16'h57FE;
        pcm_rom[414] = 16'h5DA4; pcm_rom[415] = 16'h62ED; pcm_rom[416] = 16'h67D1; pcm_rom[417] = 16'h6C4E; pcm_rom[418] = 16'h705E; pcm_rom[419] = 16'h73FC;
        pcm_rom[420] = 16'h7726; pcm_rom[421] = 16'h79D8; pcm_rom[422] = 16'h7C10; pcm_rom[423] = 16'h7DCA; pcm_rom[424] = 16'h7F06; pcm_rom[425] = 16'h7FC3;
        pcm_rom[426] = 16'h7FFF; pcm_rom[427] = 16'h7FBA; pcm_rom[428] = 16'h7EF5; pcm_rom[429] = 16'h7DB0; pcm_rom[430] = 16'h7BED; pcm_rom[431] = 16'h79AD;
        pcm_rom[432] = 16'h76F2; pcm_rom[433] = 16'h73C1; pcm_rom[434] = 16'h701A; pcm_rom[435] = 16'h6C03; pcm_rom[436] = 16'h677F; pcm_rom[437] = 16'h6294;
        pcm_rom[438] = 16'h5D45; pcm_rom[439] = 16'h5798; pcm_rom[440] = 16'h5193; pcm_rom[441] = 16'h4B3C; pcm_rom[442] = 16'h4499; pcm_rom[443] = 16'h3DB2;
        pcm_rom[444] = 16'h368C; pcm_rom[445] = 16'h2F30; pcm_rom[446] = 16'h27A4; pcm_rom[447] = 16'h1FF0; pcm_rom[448] = 16'h181C; pcm_rom[449] = 16'h1030;
        pcm_rom[450] = 16'h0833; pcm_rom[451] = 16'h002F; pcm_rom[452] = 16'hF82A; pcm_rom[453] = 16'hF02D; pcm_rom[454] = 16'hE840; pcm_rom[455] = 16'hE06B;
        pcm_rom[456] = 16'hD8B5; pcm_rom[457] = 16'hD127; pcm_rom[458] = 16'hC9C8; pcm_rom[459] = 16'hC2A0; pcm_rom[460] = 16'hBBB6; pcm_rom[461] = 16'hB510;
        pcm_rom[462] = 16'hAEB5; pcm_rom[463] = 16'hA8AC; pcm_rom[464] = 16'hA2FC; pcm_rom[465] = 16'h9DA8; pcm_rom[466] = 16'h98B8; pcm_rom[467] = 16'h942F;
        pcm_rom[468] = 16'h9013; pcm_rom[469] = 16'h8C67; pcm_rom[470] = 16'h8930; pcm_rom[471] = 16'h8670; pcm_rom[472] = 16'h842B; pcm_rom[473] = 16'h8262;
        pcm_rom[474] = 16'h8117; pcm_rom[475] = 16'h804C; pcm_rom[476] = 16'h8001; pcm_rom[477] = 16'h8038; pcm_rom[478] = 16'h80EE; pcm_rom[479] = 16'h8225;
        pcm_rom[480] = 16'h83DA; pcm_rom[481] = 16'h860C; pcm_rom[482] = 16'h88B8; pcm_rom[483] = 16'h8BDD; pcm_rom[484] = 16'h8F76; pcm_rom[485] = 16'h9380;
        pcm_rom[486] = 16'h97F8; pcm_rom[487] = 16'h9CD8; pcm_rom[488] = 16'hA21C; pcm_rom[489] = 16'hA7BF; pcm_rom[490] = 16'hADBA; pcm_rom[491] = 16'hB408;
        pcm_rom[492] = 16'hBAA2; pcm_rom[493] = 16'hC182; pcm_rom[494] = 16'hC8A1; pcm_rom[495] = 16'hCFF8; pcm_rom[496] = 16'hD77F; pcm_rom[497] = 16'hDF2E;
        pcm_rom[498] = 16'hE6FF; pcm_rom[499] = 16'hEEE9; pcm_rom[500] = 16'hF6E4; pcm_rom[501] = 16'hFEE8; pcm_rom[502] = 16'h06ED; pcm_rom[503] = 16'h0EEB;
        pcm_rom[504] = 16'h16DB; pcm_rom[505] = 16'h1EB3; pcm_rom[506] = 16'h266D; pcm_rom[507] = 16'h2DFF; pcm_rom[508] = 16'h3564; pcm_rom[509] = 16'h3C93;
        pcm_rom[510] = 16'h4385; pcm_rom[511] = 16'h4A33; pcm_rom[512] = 16'h5096; pcm_rom[513] = 16'h56A8; pcm_rom[514] = 16'h5C64; pcm_rom[515] = 16'h61C2;
        pcm_rom[516] = 16'h66BE; pcm_rom[517] = 16'h6B52; pcm_rom[518] = 16'h6F7B; pcm_rom[519] = 16'h7334; pcm_rom[520] = 16'h7678; pcm_rom[521] = 16'h7946;
        pcm_rom[522] = 16'h7B99; pcm_rom[523] = 16'h7D71; pcm_rom[524] = 16'h7ECA; pcm_rom[525] = 16'h7FA3; pcm_rom[526] = 16'h7FFD; pcm_rom[527] = 16'h7FD5;
        pcm_rom[528] = 16'h7F2D; pcm_rom[529] = 16'h7E05; pcm_rom[530] = 16'h7C5E; pcm_rom[531] = 16'h7A3B; pcm_rom[532] = 16'h779C; pcm_rom[533] = 16'h7485;
        pcm_rom[534] = 16'h70F9; pcm_rom[535] = 16'h6CFB; pcm_rom[536] = 16'h688F; pcm_rom[537] = 16'h63BB; pcm_rom[538] = 16'h5E82; pcm_rom[539] = 16'h58EA;
        pcm_rom[540] = 16'h52F8; pcm_rom[541] = 16'h4CB4; pcm_rom[542] = 16'h4622; pcm_rom[543] = 16'h3F49; pcm_rom[544] = 16'h3831; pcm_rom[545] = 16'h30E0;
        pcm_rom[546] = 16'h295F; pcm_rom[547] = 16'h21B3; pcm_rom[548] = 16'h19E6; pcm_rom[549] = 16'h11FF; pcm_rom[550] = 16'h0A05; pcm_rom[551] = 16'h0202;
        pcm_rom[552] = 16'hF9FC; pcm_rom[553] = 16'hF1FC; pcm_rom[554] = 16'hEA0B; pcm_rom[555] = 16'hE230; pcm_rom[556] = 16'hDA72; pcm_rom[557] = 16'hD2DB;
        pcm_rom[558] = 16'hCB71; pcm_rom[559] = 16'hC43B; pcm_rom[560] = 16'hBD42; pcm_rom[561] = 16'hB68C; pcm_rom[562] = 16'hB020; pcm_rom[563] = 16'hAA04;
        pcm_rom[564] = 16'hA43F; pcm_rom[565] = 16'h9ED6; pcm_rom[566] = 16'h99CE; pcm_rom[567] = 16'h952E; pcm_rom[568] = 16'h90F8; pcm_rom[569] = 16'h8D33;
        pcm_rom[570] = 16'h89E1; pcm_rom[571] = 16'h8706; pcm_rom[572] = 16'h84A4; pcm_rom[573] = 16'h82BF; pcm_rom[574] = 16'h8157; pcm_rom[575] = 16'h806F;
        pcm_rom[576] = 16'h8007; pcm_rom[577] = 16'h8020; pcm_rom[578] = 16'h80B9; pcm_rom[579] = 16'h81D3; pcm_rom[580] = 16'h836B; pcm_rom[581] = 16'h8581;
        pcm_rom[582] = 16'h8812; pcm_rom[583] = 16'h8B1B; pcm_rom[584] = 16'h8E9A; pcm_rom[585] = 16'h928C; pcm_rom[586] = 16'h96EB; pcm_rom[587] = 16'h9BB4;
        pcm_rom[588] = 16'hA0E1; pcm_rom[589] = 16'hA66F; pcm_rom[590] = 16'hAC56; pcm_rom[591] = 16'hB292; pcm_rom[592] = 16'hB91B; pcm_rom[593] = 16'hBFEC;
        pcm_rom[594] = 16'hC6FE; pcm_rom[595] = 16'hCE48; pcm_rom[596] = 16'hD5C5; pcm_rom[597] = 16'hDD6C; pcm_rom[598] = 16'hE536; pcm_rom[599] = 16'hED1B;
        pcm_rom[600] = 16'hF512; pcm_rom[601] = 16'hFD15; pcm_rom[602] = 16'h051B; pcm_rom[603] = 16'h0D1B; pcm_rom[604] = 16'h150F; pcm_rom[605] = 16'h1CED;
        pcm_rom[606] = 16'h24AE; pcm_rom[607] = 16'h2C4A; pcm_rom[608] = 16'h33BA; pcm_rom[609] = 16'h3AF6; pcm_rom[610] = 16'h41F6; pcm_rom[611] = 16'h48B4;
        pcm_rom[612] = 16'h4F29; pcm_rom[613] = 16'h554F; pcm_rom[614] = 16'h5B1E; pcm_rom[615] = 16'h6092; pcm_rom[616] = 16'h65A5; pcm_rom[617] = 16'h6A51;
        pcm_rom[618] = 16'h6E93; pcm_rom[619] = 16'h7265; pcm_rom[620] = 16'h75C4; pcm_rom[621] = 16'h78AD; pcm_rom[622] = 16'h7B1D; pcm_rom[623] = 16'h7D11;
        pcm_rom[624] = 16'h7E87; pcm_rom[625] = 16'h7F7D; pcm_rom[626] = 16'h7FF4; pcm_rom[627] = 16'h7FE9; pcm_rom[628] = 16'h7F5E; pcm_rom[629] = 16'h7E54;
        pcm_rom[630] = 16'h7CC9; pcm_rom[631] = 16'h7AC2; pcm_rom[632] = 16'h783F; pcm_rom[633] = 16'h7543; pcm_rom[634] = 16'h71D1; pcm_rom[635] = 16'h6DED;
        pcm_rom[636] = 16'h699A; pcm_rom[637] = 16'h64DD; pcm_rom[638] = 16'h5FBA; pcm_rom[639] = 16'h5A37; pcm_rom[640] = 16'h545A; pcm_rom[641] = 16'h4E27;
        pcm_rom[642] = 16'h47A6; pcm_rom[643] = 16'h40DD; pcm_rom[644] = 16'h39D3; pcm_rom[645] = 16'h328F; pcm_rom[646] = 16'h2B17; pcm_rom[647] = 16'h2375;
        pcm_rom[648] = 16'h1BAE; pcm_rom[649] = 16'h13CC; pcm_rom[650] = 16'h0BD6; pcm_rom[651] = 16'h03D4; pcm_rom[652] = 16'hFBCE; pcm_rom[653] = 16'hF3CD;
        pcm_rom[654] = 16'hEBD8; pcm_rom[655] = 16'hE3F6; pcm_rom[656] = 16'hDC32; pcm_rom[657] = 16'hD491; pcm_rom[658] = 16'hCD1C; pcm_rom[659] = 16'hC5DA;
        pcm_rom[660] = 16'hBED2; pcm_rom[661] = 16'hB80C; pcm_rom[662] = 16'hB18F; pcm_rom[663] = 16'hAB60; pcm_rom[664] = 16'hA586; pcm_rom[665] = 16'hA008;
        pcm_rom[666] = 16'h9AEA; pcm_rom[667] = 16'h9631; pcm_rom[668] = 16'h91E4; pcm_rom[669] = 16'h8E04; pcm_rom[670] = 16'h8A98; pcm_rom[671] = 16'h87A1;
        pcm_rom[672] = 16'h8524; pcm_rom[673] = 16'h8322; pcm_rom[674] = 16'h819E; pcm_rom[675] = 16'h8098; pcm_rom[676] = 16'h8013; pcm_rom[677] = 16'h800F;
        pcm_rom[678] = 16'h808B; pcm_rom[679] = 16'h8188; pcm_rom[680] = 16'h8303; pcm_rom[681] = 16'h84FD; pcm_rom[682] = 16'h8772; pcm_rom[683] = 16'h8A60;
        pcm_rom[684] = 16'h8DC5; pcm_rom[685] = 16'h919C; pcm_rom[686] = 16'h95E3; pcm_rom[687] = 16'h9A94; pcm_rom[688] = 16'h9FAB; pcm_rom[689] = 16'hA524;
        pcm_rom[690] = 16'hAAF7; pcm_rom[691] = 16'hB120; pcm_rom[692] = 16'hB799; pcm_rom[693] = 16'hBE5A; pcm_rom[694] = 16'hC55D; pcm_rom[695] = 16'hCC9B;
        pcm_rom[696] = 16'hD40D; pcm_rom[697] = 16'hDBAB; pcm_rom[698] = 16'hE36E; pcm_rom[699] = 16'hEB4D; pcm_rom[700] = 16'hF341; pcm_rom[701] = 16'hFB42;
        pcm_rom[702] = 16'h0348; pcm_rom[703] = 16'h0B4B; pcm_rom[704] = 16'h1342; pcm_rom[705] = 16'h1B26; pcm_rom[706] = 16'h22EE; pcm_rom[707] = 16'h2A93;
        pcm_rom[708] = 16'h320E; pcm_rom[709] = 16'h3956; pcm_rom[710] = 16'h4064; pcm_rom[711] = 16'h4732; pcm_rom[712] = 16'h4DB8; pcm_rom[713] = 16'h53F0;
        pcm_rom[714] = 16'h59D4; pcm_rom[715] = 16'h5F5D; pcm_rom[716] = 16'h6486; pcm_rom[717] = 16'h694A; pcm_rom[718] = 16'h6DA5; pcm_rom[719] = 16'h7191;
        pcm_rom[720] = 16'h750B; pcm_rom[721] = 16'h780F; pcm_rom[722] = 16'h7A9A; pcm_rom[723] = 16'h7CAA; pcm_rom[724] = 16'h7E3D; pcm_rom[725] = 16'h7F50;
        pcm_rom[726] = 16'h7FE4; pcm_rom[727] = 16'h7FF7; pcm_rom[728] = 16'h7F89; pcm_rom[729] = 16'h7E9B; pcm_rom[730] = 16'h7D2E; pcm_rom[731] = 16'h7B43;
        pcm_rom[732] = 16'h78DC; pcm_rom[733] = 16'h75FB; pcm_rom[734] = 16'h72A4; pcm_rom[735] = 16'h6ED9; pcm_rom[736] = 16'h6A9F; pcm_rom[737] = 16'h65FA;
        pcm_rom[738] = 16'h60EE; pcm_rom[739] = 16'h5B80; pcm_rom[740] = 16'h55B7; pcm_rom[741] = 16'h4F97; pcm_rom[742] = 16'h4927; pcm_rom[743] = 16'h426E;
        pcm_rom[744] = 16'h3B72; pcm_rom[745] = 16'h343A; pcm_rom[746] = 16'h2CCE; pcm_rom[747] = 16'h2534; pcm_rom[748] = 16'h1D75; pcm_rom[749] = 16'h1599;
        pcm_rom[750] = 16'h0DA7; pcm_rom[751] = 16'h05A7; pcm_rom[752] = 16'hFDA1; pcm_rom[753] = 16'hF59E; pcm_rom[754] = 16'hEDA5; pcm_rom[755] = 16'hE5BF;
        pcm_rom[756] = 16'hDDF3; pcm_rom[757] = 16'hD649; pcm_rom[758] = 16'hCEC9; pcm_rom[759] = 16'hC77B; pcm_rom[760] = 16'hC066; pcm_rom[761] = 16'hB990;
        pcm_rom[762] = 16'hB302; pcm_rom[763] = 16'hACC0; pcm_rom[764] = 16'hA6D3; pcm_rom[765] = 16'hA13F; pcm_rom[766] = 16'h9C0B; pcm_rom[767] = 16'h973B;
        pcm_rom[768] = 16'h92D4; pcm_rom[769] = 16'h8EDC; pcm_rom[770] = 16'h8B55; pcm_rom[771] = 16'h8843; pcm_rom[772] = 16'h85AA; pcm_rom[773] = 16'h838C;
        pcm_rom[774] = 16'h81EB; pcm_rom[775] = 16'h80C9; pcm_rom[776] = 16'h8026; pcm_rom[777] = 16'h8005; pcm_rom[778] = 16'h8064; pcm_rom[779] = 16'h8143;
        pcm_rom[780] = 16'h82A2; pcm_rom[781] = 16'h847F; pcm_rom[782] = 16'h86D8; pcm_rom[783] = 16'h89AB; pcm_rom[784] = 16'h8CF5; pcm_rom[785] = 16'h90B3;
        pcm_rom[786] = 16'h94E1; pcm_rom[787] = 16'h997A; pcm_rom[788] = 16'h9E7B; pcm_rom[789] = 16'hA3DD; pcm_rom[790] = 16'hA99C; pcm_rom[791] = 16'hAFB3;
        pcm_rom[792] = 16'hB61A; pcm_rom[793] = 16'hBCCB; pcm_rom[794] = 16'hC3C0; pcm_rom[795] = 16'hCAF1; pcm_rom[796] = 16'hD258; pcm_rom[797] = 16'hD9ED;
        pcm_rom[798] = 16'hE1A8; pcm_rom[799] = 16'hE981; pcm_rom[800] = 16'hF171; pcm_rom[801] = 16'hF970; pcm_rom[802] = 16'h0175; pcm_rom[803] = 16'h0979;
        pcm_rom[804] = 16'h1174; pcm_rom[805] = 16'h195D; pcm_rom[806] = 16'h212C; pcm_rom[807] = 16'h28DA; pcm_rom[808] = 16'h305F; pcm_rom[809] = 16'h37B3;
        pcm_rom[810] = 16'h3ECF; pcm_rom[811] = 16'h45AC; pcm_rom[812] = 16'h4C43; pcm_rom[813] = 16'h528E; pcm_rom[814] = 16'h5885; pcm_rom[815] = 16'h5E23;
        pcm_rom[816] = 16'h6363; pcm_rom[817] = 16'h683E; pcm_rom[818] = 16'h6CB1; pcm_rom[819] = 16'h70B6; pcm_rom[820] = 16'h744B; pcm_rom[821] = 16'h776A;
        pcm_rom[822] = 16'h7A11; pcm_rom[823] = 16'h7C3D; pcm_rom[824] = 16'h7DEC; pcm_rom[825] = 16'h7F1D; pcm_rom[826] = 16'h7FCE; pcm_rom[827] = 16'h7FFE;
        pcm_rom[828] = 16'h7FAE; pcm_rom[829] = 16'h7EDD; pcm_rom[830] = 16'h7D8C; pcm_rom[831] = 16'h7BBE; pcm_rom[832] = 16'h7972; pcm_rom[833] = 16'h76AD;
        pcm_rom[834] = 16'h7370; pcm_rom[835] = 16'h6FC0; pcm_rom[836] = 16'h6B9E; pcm_rom[837] = 16'h6711; pcm_rom[838] = 16'h621C; pcm_rom[839] = 16'h5CC4;
        pcm_rom[840] = 16'h570F; pcm_rom[841] = 16'h5103; pcm_rom[842] = 16'h4AA5; pcm_rom[843] = 16'h43FB; pcm_rom[844] = 16'h3D0E; pcm_rom[845] = 16'h35E3;
        pcm_rom[846] = 16'h2E82; pcm_rom[847] = 16'h26F2; pcm_rom[848] = 16'h1F3B; pcm_rom[849] = 16'h1765; pcm_rom[850] = 16'h0F77; pcm_rom[851] = 16'h0779;
        pcm_rom[852] = 16'hFF74; pcm_rom[853] = 16'hF76F; pcm_rom[854] = 16'hEF74; pcm_rom[855] = 16'hE788; pcm_rom[856] = 16'hDFB6; pcm_rom[857] = 16'hD804;
        pcm_rom[858] = 16'hD07A; pcm_rom[859] = 16'hC91F; pcm_rom[860] = 16'hC1FC; pcm_rom[861] = 16'hBB18; pcm_rom[862] = 16'hB479; pcm_rom[863] = 16'hAE25;
        pcm_rom[864] = 16'hA824; pcm_rom[865] = 16'hA27C; pcm_rom[866] = 16'h9D31; pcm_rom[867] = 16'h984A; pcm_rom[868] = 16'h93CB; pcm_rom[869] = 16'h8FB9;
        pcm_rom[870] = 16'h8C18; pcm_rom[871] = 16'h88EB; pcm_rom[872] = 16'h8636; pcm_rom[873] = 16'h83FC; pcm_rom[874] = 16'h823E; pcm_rom[875] = 16'h80FF;
        pcm_rom[876] = 16'h8040; pcm_rom[877] = 16'h8001; pcm_rom[878] = 16'h8043; pcm_rom[879] = 16'h8105; pcm_rom[880] = 16'h8247; pcm_rom[881] = 16'h8408;
        pcm_rom[882] = 16'h8645; pcm_rom[883] = 16'h88FC; pcm_rom[884] = 16'h8C2C; pcm_rom[885] = 16'h8FCF; pcm_rom[886] = 16'h93E4; pcm_rom[887] = 16'h9865;
        pcm_rom[888] = 16'h9D4F; pcm_rom[889] = 16'hA29C; pcm_rom[890] = 16'hA846; pcm_rom[891] = 16'hAE49; pcm_rom[892] = 16'hB49E; pcm_rom[893] = 16'hBB3F;
        pcm_rom[894] = 16'hC225; pcm_rom[895] = 16'hC94A; pcm_rom[896] = 16'hD0A5; pcm_rom[897] = 16'hD830; pcm_rom[898] = 16'hDFE3; pcm_rom[899] = 16'hE7B6;
        pcm_rom[900] = 16'hEFA2; pcm_rom[901] = 16'hF79E; pcm_rom[902] = 16'hFFA3; pcm_rom[903] = 16'h07A8; pcm_rom[904] = 16'h0FA5; pcm_rom[905] = 16'h1792;
        pcm_rom[906] = 16'h1F68; pcm_rom[907] = 16'h271E; pcm_rom[908] = 16'h2EAD; pcm_rom[909] = 16'h360D; pcm_rom[910] = 16'h3D37; pcm_rom[911] = 16'h4423;
        pcm_rom[912] = 16'h4ACA; pcm_rom[913] = 16'h5127; pcm_rom[914] = 16'h5731; pcm_rom[915] = 16'h5CE4; pcm_rom[916] = 16'h623A; pcm_rom[917] = 16'h672D;
        pcm_rom[918] = 16'h6BB8; pcm_rom[919] = 16'h6FD6; pcm_rom[920] = 16'h7384; pcm_rom[921] = 16'h76BE; pcm_rom[922] = 16'h7981; pcm_rom[923] = 16'h7BC9;
        pcm_rom[924] = 16'h7D95; pcm_rom[925] = 16'h7EE3; pcm_rom[926] = 16'h7FB1; pcm_rom[927] = 16'h7FFE; pcm_rom[928] = 16'h7FCB; pcm_rom[929] = 16'h7F17;
        pcm_rom[930] = 16'h7DE4; pcm_rom[931] = 16'h7C32; pcm_rom[932] = 16'h7A03; pcm_rom[933] = 16'h7759; pcm_rom[934] = 16'h7437; pcm_rom[935] = 16'h70A0;
        pcm_rom[936] = 16'h6C98; pcm_rom[937] = 16'h6823; pcm_rom[938] = 16'h6345; pcm_rom[939] = 16'h5E03; pcm_rom[940] = 16'h5863; pcm_rom[941] = 16'h526A;
        pcm_rom[942] = 16'h4C1E; pcm_rom[943] = 16'h4585; pcm_rom[944] = 16'h3EA7; pcm_rom[945] = 16'h3789; pcm_rom[946] = 16'h3034; pcm_rom[947] = 16'h28AE;
        pcm_rom[948] = 16'h20FF; pcm_rom[949] = 16'h192F; pcm_rom[950] = 16'h1146; pcm_rom[951] = 16'h094B; pcm_rom[952] = 16'h0147; pcm_rom[953] = 16'hF941;
        pcm_rom[954] = 16'hF143; pcm_rom[955] = 16'hE953; pcm_rom[956] = 16'hE17A; pcm_rom[957] = 16'hD9C0; pcm_rom[958] = 16'hD22C; pcm_rom[959] = 16'hCAC7;
        pcm_rom[960] = 16'hC396; pcm_rom[961] = 16'hBCA3; pcm_rom[962] = 16'hB5F3; pcm_rom[963] = 16'hAF8E; pcm_rom[964] = 16'hA97A; pcm_rom[965] = 16'hA3BD;
        pcm_rom[966] = 16'h9E5C; pcm_rom[967] = 16'h995E; pcm_rom[968] = 16'h94C7; pcm_rom[969] = 16'h909C; pcm_rom[970] = 16'h8CE1; pcm_rom[971] = 16'h8999;
        pcm_rom[972] = 16'h86C9; pcm_rom[973] = 16'h8473; pcm_rom[974] = 16'h8299; pcm_rom[975] = 16'h813D; pcm_rom[976] = 16'h8060; pcm_rom[977] = 16'h8004;
        pcm_rom[978] = 16'h8029; pcm_rom[979] = 16'h80CE; pcm_rom[980] = 16'h81F3; pcm_rom[981] = 16'h8397; pcm_rom[982] = 16'h85B8; pcm_rom[983] = 16'h8854;
        pcm_rom[984] = 16'h8B68; pcm_rom[985] = 16'h8EF2; pcm_rom[986] = 16'h92ED; pcm_rom[987] = 16'h9756; pcm_rom[988] = 16'h9C28; pcm_rom[989] = 16'hA15F;
        pcm_rom[990] = 16'hA6F5; pcm_rom[991] = 16'hACE4; pcm_rom[992] = 16'hB327; pcm_rom[993] = 16'hB9B7; pcm_rom[994] = 16'hC08E; pcm_rom[995] = 16'hC7A5;
        pcm_rom[996] = 16'hCEF4; pcm_rom[997] = 16'hD675; pcm_rom[998] = 16'hDE20; pcm_rom[999] = 16'hE5EC; pcm_rom[1000] = 16'hEDD3; pcm_rom[1001] = 16'hF5CC;
        pcm_rom[1002] = 16'hFDD0; pcm_rom[1003] = 16'h05D5; pcm_rom[1004] = 16'h0DD5; pcm_rom[1005] = 16'h15C7; pcm_rom[1006] = 16'h1DA3; pcm_rom[1007] = 16'h2561;
        pcm_rom[1008] = 16'h2CF9; pcm_rom[1009] = 16'h3465; pcm_rom[1010] = 16'h3B9B; pcm_rom[1011] = 16'h4296; pcm_rom[1012] = 16'h494E; pcm_rom[1013] = 16'h4FBC;
        pcm_rom[1014] = 16'h55D9; pcm_rom[1015] = 16'h5BA1; pcm_rom[1016] = 16'h610C; pcm_rom[1017] = 16'h6616; pcm_rom[1018] = 16'h6AB9; pcm_rom[1019] = 16'h6EF0;
        pcm_rom[1020] = 16'h72B8; pcm_rom[1021] = 16'h760D; pcm_rom[1022] = 16'h78EB; pcm_rom[1023] = 16'h7B4F; pcm_rom[1024] = 16'h7D38; pcm_rom[1025] = 16'h7EA2;
        pcm_rom[1026] = 16'h7F8D; pcm_rom[1027] = 16'h7FF8; pcm_rom[1028] = 16'h7FE2; pcm_rom[1029] = 16'h7F4B; pcm_rom[1030] = 16'h7E35; pcm_rom[1031] = 16'h7C9F;
        pcm_rom[1032] = 16'h7A8D; pcm_rom[1033] = 16'h77FE; pcm_rom[1034] = 16'h74F8; pcm_rom[1035] = 16'h717B; pcm_rom[1036] = 16'h6D8D; pcm_rom[1037] = 16'h6930;
        pcm_rom[1038] = 16'h6469; pcm_rom[1039] = 16'h5F3E; pcm_rom[1040] = 16'h59B3; pcm_rom[1041] = 16'h53CD; pcm_rom[1042] = 16'h4D93; pcm_rom[1043] = 16'h470B;
        pcm_rom[1044] = 16'h403C; pcm_rom[1045] = 16'h392C; pcm_rom[1046] = 16'h31E3; pcm_rom[1047] = 16'h2A67; pcm_rom[1048] = 16'h22C1; pcm_rom[1049] = 16'h1AF8;
        pcm_rom[1050] = 16'h1314; pcm_rom[1051] = 16'h0B1C; pcm_rom[1052] = 16'h031A; pcm_rom[1053] = 16'hFB14; pcm_rom[1054] = 16'hF313; pcm_rom[1055] = 16'hEB1F;
        pcm_rom[1056] = 16'hE340; pcm_rom[1057] = 16'hDB7F; pcm_rom[1058] = 16'hD3E1; pcm_rom[1059] = 16'hCC71; pcm_rom[1060] = 16'hC534; pcm_rom[1061] = 16'hBE32;
        pcm_rom[1062] = 16'hB772; pcm_rom[1063] = 16'hB0FB; pcm_rom[1064] = 16'hAAD4; pcm_rom[1065] = 16'hA503; pcm_rom[1066] = 16'h9F8D; pcm_rom[1067] = 16'h9A78;
        pcm_rom[1068] = 16'h95C9; pcm_rom[1069] = 16'h9185; pcm_rom[1070] = 16'h8DB0; pcm_rom[1071] = 16'h8A4E; pcm_rom[1072] = 16'h8762; pcm_rom[1073] = 16'h84F0;
        pcm_rom[1074] = 16'h82F9; pcm_rom[1075] = 16'h8181; pcm_rom[1076] = 16'h8087; pcm_rom[1077] = 16'h800E; pcm_rom[1078] = 16'h8015; pcm_rom[1079] = 16'h809D;
        pcm_rom[1080] = 16'h81A5; pcm_rom[1081] = 16'h832C; pcm_rom[1082] = 16'h8531; pcm_rom[1083] = 16'h87B1; pcm_rom[1084] = 16'h8AAA; pcm_rom[1085] = 16'h8E1A;
        pcm_rom[1086] = 16'h91FB; pcm_rom[1087] = 16'h964C; pcm_rom[1088] = 16'h9B07; pcm_rom[1089] = 16'hA027; pcm_rom[1090] = 16'hA5A8; pcm_rom[1091] = 16'hAB83;
        pcm_rom[1092] = 16'hB1B4; pcm_rom[1093] = 16'hB833; pcm_rom[1094] = 16'hBEFA; pcm_rom[1095] = 16'hC603; pcm_rom[1096] = 16'hCD47; pcm_rom[1097] = 16'hD4BD;
        pcm_rom[1098] = 16'hDC5E; pcm_rom[1099] = 16'hE424; pcm_rom[1100] = 16'hEC06; pcm_rom[1101] = 16'hF3FB; pcm_rom[1102] = 16'hFBFD; pcm_rom[1103] = 16'h0403;
        pcm_rom[1104] = 16'h0C05; pcm_rom[1105] = 16'h13FA; pcm_rom[1106] = 16'h1BDC; pcm_rom[1107] = 16'h23A2; pcm_rom[1108] = 16'h2B43; pcm_rom[1109] = 16'h32B9;
        pcm_rom[1110] = 16'h39FD; pcm_rom[1111] = 16'h4106; pcm_rom[1112] = 16'h47CD; pcm_rom[1113] = 16'h4E4C; pcm_rom[1114] = 16'h547D; pcm_rom[1115] = 16'h5A58;
        pcm_rom[1116] = 16'h5FD9; pcm_rom[1117] = 16'h64F9; pcm_rom[1118] = 16'h69B4; pcm_rom[1119] = 16'h6E05; pcm_rom[1120] = 16'h71E6; pcm_rom[1121] = 16'h7556;
        pcm_rom[1122] = 16'h784F; pcm_rom[1123] = 16'h7ACF; pcm_rom[1124] = 16'h7CD4; pcm_rom[1125] = 16'h7E5B; pcm_rom[1126] = 16'h7F63; pcm_rom[1127] = 16'h7FEB;
        pcm_rom[1128] = 16'h7FF2; pcm_rom[1129] = 16'h7F79; pcm_rom[1130] = 16'h7E7F; pcm_rom[1131] = 16'h7D07; pcm_rom[1132] = 16'h7B10; pcm_rom[1133] = 16'h789E;
        pcm_rom[1134] = 16'h75B2; pcm_rom[1135] = 16'h7250; pcm_rom[1136] = 16'h6E7B; pcm_rom[1137] = 16'h6A37; pcm_rom[1138] = 16'h6588; pcm_rom[1139] = 16'h6073;
        pcm_rom[1140] = 16'h5AFD; pcm_rom[1141] = 16'h552C; pcm_rom[1142] = 16'h4F05; pcm_rom[1143] = 16'h488E; pcm_rom[1144] = 16'h41CE; pcm_rom[1145] = 16'h3ACC;
        pcm_rom[1146] = 16'h338F; pcm_rom[1147] = 16'h2C1F; pcm_rom[1148] = 16'h2481; pcm_rom[1149] = 16'h1CC0; pcm_rom[1150] = 16'h14E1; pcm_rom[1151] = 16'h0CED;
        pcm_rom[1152] = 16'h04EC; pcm_rom[1153] = 16'hFCE6; pcm_rom[1154] = 16'hF4E4; pcm_rom[1155] = 16'hECEC; pcm_rom[1156] = 16'hE508; pcm_rom[1157] = 16'hDD3F;
        pcm_rom[1158] = 16'hD599; pcm_rom[1159] = 16'hCE1D; pcm_rom[1160] = 16'hC6D4; pcm_rom[1161] = 16'hBFC4; pcm_rom[1162] = 16'hB8F5; pcm_rom[1163] = 16'hB26D;
        pcm_rom[1164] = 16'hAC33; pcm_rom[1165] = 16'hA64D; pcm_rom[1166] = 16'hA0C2; pcm_rom[1167] = 16'h9B97; pcm_rom[1168] = 16'h96D0; pcm_rom[1169] = 16'h9273;
        pcm_rom[1170] = 16'h8E85; pcm_rom[1171] = 16'h8B08; pcm_rom[1172] = 16'h8802; pcm_rom[1173] = 16'h8573; pcm_rom[1174] = 16'h8361; pcm_rom[1175] = 16'h81CB;
        pcm_rom[1176] = 16'h80B5; pcm_rom[1177] = 16'h801E; pcm_rom[1178] = 16'h8008; pcm_rom[1179] = 16'h8073; pcm_rom[1180] = 16'h815E; pcm_rom[1181] = 16'h82C8;
        pcm_rom[1182] = 16'h84B1; pcm_rom[1183] = 16'h8715; pcm_rom[1184] = 16'h89F3; pcm_rom[1185] = 16'h8D48; pcm_rom[1186] = 16'h9110; pcm_rom[1187] = 16'h9547;
        pcm_rom[1188] = 16'h99EA; pcm_rom[1189] = 16'h9EF4; pcm_rom[1190] = 16'hA45F; pcm_rom[1191] = 16'hAA27; pcm_rom[1192] = 16'hB044; pcm_rom[1193] = 16'hB6B2;
        pcm_rom[1194] = 16'hBD6A; pcm_rom[1195] = 16'hC465; pcm_rom[1196] = 16'hCB9B; pcm_rom[1197] = 16'hD307; pcm_rom[1198] = 16'hDA9F; pcm_rom[1199] = 16'hE25D;
        pcm_rom[1200] = 16'hEA39; pcm_rom[1201] = 16'hF22B; pcm_rom[1202] = 16'hFA2B; pcm_rom[1203] = 16'h0230; pcm_rom[1204] = 16'h0A34; pcm_rom[1205] = 16'h122D;
        pcm_rom[1206] = 16'h1A14; pcm_rom[1207] = 16'h21E0; pcm_rom[1208] = 16'h298B; pcm_rom[1209] = 16'h310C; pcm_rom[1210] = 16'h385B; pcm_rom[1211] = 16'h3F72;
        pcm_rom[1212] = 16'h4649; pcm_rom[1213] = 16'h4CD9; pcm_rom[1214] = 16'h531C; pcm_rom[1215] = 16'h590B; pcm_rom[1216] = 16'h5EA1; pcm_rom[1217] = 16'h63D8;
        pcm_rom[1218] = 16'h68AA; pcm_rom[1219] = 16'h6D13; pcm_rom[1220] = 16'h710E; pcm_rom[1221] = 16'h7498; pcm_rom[1222] = 16'h77AC; pcm_rom[1223] = 16'h7A48;
        pcm_rom[1224] = 16'h7C69; pcm_rom[1225] = 16'h7E0D; pcm_rom[1226] = 16'h7F32; pcm_rom[1227] = 16'h7FD7; pcm_rom[1228] = 16'h7FFC; pcm_rom[1229] = 16'h7FA0;
        pcm_rom[1230] = 16'h7EC3; pcm_rom[1231] = 16'h7D67; pcm_rom[1232] = 16'h7B8D; pcm_rom[1233] = 16'h7937; pcm_rom[1234] = 16'h7667; pcm_rom[1235] = 16'h731F;
        pcm_rom[1236] = 16'h6F64; pcm_rom[1237] = 16'h6B39; pcm_rom[1238] = 16'h66A2; pcm_rom[1239] = 16'h61A4; pcm_rom[1240] = 16'h5C43; pcm_rom[1241] = 16'h5686;
        pcm_rom[1242] = 16'h5072; pcm_rom[1243] = 16'h4A0D; pcm_rom[1244] = 16'h435D; pcm_rom[1245] = 16'h3C6A; pcm_rom[1246] = 16'h3539; pcm_rom[1247] = 16'h2DD4;
        pcm_rom[1248] = 16'h2640; pcm_rom[1249] = 16'h1E86; pcm_rom[1250] = 16'h16AD; pcm_rom[1251] = 16'h0EBD; pcm_rom[1252] = 16'h06BF; pcm_rom[1253] = 16'hFEB9;
        pcm_rom[1254] = 16'hF6B5; pcm_rom[1255] = 16'hEEBA; pcm_rom[1256] = 16'hE6D1; pcm_rom[1257] = 16'hDF01; pcm_rom[1258] = 16'hD752; pcm_rom[1259] = 16'hCFCC;
        pcm_rom[1260] = 16'hC877; pcm_rom[1261] = 16'hC159; pcm_rom[1262] = 16'hBA7B; pcm_rom[1263] = 16'hB3E2; pcm_rom[1264] = 16'hAD96; pcm_rom[1265] = 16'hA79D;
        pcm_rom[1266] = 16'hA1FD; pcm_rom[1267] = 16'h9CBB; pcm_rom[1268] = 16'h97DD; pcm_rom[1269] = 16'h9368; pcm_rom[1270] = 16'h8F60; pcm_rom[1271] = 16'h8BC9;
        pcm_rom[1272] = 16'h88A7; pcm_rom[1273] = 16'h85FD; pcm_rom[1274] = 16'h83CE; pcm_rom[1275] = 16'h821C; pcm_rom[1276] = 16'h80E9; pcm_rom[1277] = 16'h8035;
        pcm_rom[1278] = 16'h8002; pcm_rom[1279] = 16'h804F; pcm_rom[1280] = 16'h811D; pcm_rom[1281] = 16'h826B; pcm_rom[1282] = 16'h8437; pcm_rom[1283] = 16'h867F;
        pcm_rom[1284] = 16'h8942; pcm_rom[1285] = 16'h8C7C; pcm_rom[1286] = 16'h902A; pcm_rom[1287] = 16'h9448; pcm_rom[1288] = 16'h98D3; pcm_rom[1289] = 16'h9DC6;
        pcm_rom[1290] = 16'hA31C; pcm_rom[1291] = 16'hA8CF; pcm_rom[1292] = 16'hAED9; pcm_rom[1293] = 16'hB536; pcm_rom[1294] = 16'hBBDD; pcm_rom[1295] = 16'hC2C9;
        pcm_rom[1296] = 16'hC9F3; pcm_rom[1297] = 16'hD153; pcm_rom[1298] = 16'hD8E2; pcm_rom[1299] = 16'hE098; pcm_rom[1300] = 16'hE86E; pcm_rom[1301] = 16'hF05B;
        pcm_rom[1302] = 16'hF858; pcm_rom[1303] = 16'h005D; pcm_rom[1304] = 16'h0862; pcm_rom[1305] = 16'h105E; pcm_rom[1306] = 16'h184A; pcm_rom[1307] = 16'h201D;
        pcm_rom[1308] = 16'h27D0; pcm_rom[1309] = 16'h2F5B; pcm_rom[1310] = 16'h36B6; pcm_rom[1311] = 16'h3DDB; pcm_rom[1312] = 16'h44C1; pcm_rom[1313] = 16'h4B62;
        pcm_rom[1314] = 16'h51B7; pcm_rom[1315] = 16'h57BA; pcm_rom[1316] = 16'h5D64; pcm_rom[1317] = 16'h62B1; pcm_rom[1318] = 16'h679B; pcm_rom[1319] = 16'h6C1C;
        pcm_rom[1320] = 16'h7031; pcm_rom[1321] = 16'h73D4; pcm_rom[1322] = 16'h7704; pcm_rom[1323] = 16'h79BB; pcm_rom[1324] = 16'h7BF8; pcm_rom[1325] = 16'h7DB9;
        pcm_rom[1326] = 16'h7EFB; pcm_rom[1327] = 16'h7FBD; pcm_rom[1328] = 16'h7FFF; pcm_rom[1329] = 16'h7FC0; pcm_rom[1330] = 16'h7F01; pcm_rom[1331] = 16'h7DC2;
        pcm_rom[1332] = 16'h7C04; pcm_rom[1333] = 16'h79CA; pcm_rom[1334] = 16'h7715; pcm_rom[1335] = 16'h73E8; pcm_rom[1336] = 16'h7047; pcm_rom[1337] = 16'h6C35;
        pcm_rom[1338] = 16'h67B6; pcm_rom[1339] = 16'h62CF; pcm_rom[1340] = 16'h5D84; pcm_rom[1341] = 16'h57DC; pcm_rom[1342] = 16'h51DB; pcm_rom[1343] = 16'h4B87;
        pcm_rom[1344] = 16'h44E8; pcm_rom[1345] = 16'h3E04; pcm_rom[1346] = 16'h36E1; pcm_rom[1347] = 16'h2F86; pcm_rom[1348] = 16'h27FC; pcm_rom[1349] = 16'h204A;
        pcm_rom[1350] = 16'h1878; pcm_rom[1351] = 16'h108C; pcm_rom[1352] = 16'h0891; pcm_rom[1353] = 16'h008C; pcm_rom[1354] = 16'hF887; pcm_rom[1355] = 16'hF089;
        pcm_rom[1356] = 16'hE89B; pcm_rom[1357] = 16'hE0C5; pcm_rom[1358] = 16'hD90E; pcm_rom[1359] = 16'hD17E; pcm_rom[1360] = 16'hCA1D; pcm_rom[1361] = 16'hC2F2;
        pcm_rom[1362] = 16'hBC05; pcm_rom[1363] = 16'hB55B; pcm_rom[1364] = 16'hAEFD; pcm_rom[1365] = 16'hA8F1; pcm_rom[1366] = 16'hA33C; pcm_rom[1367] = 16'h9DE4;
        pcm_rom[1368] = 16'h98EF; pcm_rom[1369] = 16'h9462; pcm_rom[1370] = 16'h9040; pcm_rom[1371] = 16'h8C90; pcm_rom[1372] = 16'h8953; pcm_rom[1373] = 16'h868E;
        pcm_rom[1374] = 16'h8442; pcm_rom[1375] = 16'h8274; pcm_rom[1376] = 16'h8123; pcm_rom[1377] = 16'h8052; pcm_rom[1378] = 16'h8002; pcm_rom[1379] = 16'h8032;
        pcm_rom[1380] = 16'h80E3; pcm_rom[1381] = 16'h8214; pcm_rom[1382] = 16'h83C3; pcm_rom[1383] = 16'h85EF; pcm_rom[1384] = 16'h8896; pcm_rom[1385] = 16'h8BB5;
        pcm_rom[1386] = 16'h8F4A; pcm_rom[1387] = 16'h934F; pcm_rom[1388] = 16'h97C2; pcm_rom[1389] = 16'h9C9D; pcm_rom[1390] = 16'hA1DD; pcm_rom[1391] = 16'hA77B;
        pcm_rom[1392] = 16'hAD72; pcm_rom[1393] = 16'hB3BD; pcm_rom[1394] = 16'hBA54; pcm_rom[1395] = 16'hC131; pcm_rom[1396] = 16'hC84D; pcm_rom[1397] = 16'hCFA1;
        pcm_rom[1398] = 16'hD726; pcm_rom[1399] = 16'hDED4; pcm_rom[1400] = 16'hE6A3; pcm_rom[1401] = 16'hEE8C; pcm_rom[1402] = 16'hF687; pcm_rom[1403] = 16'hFE8B;
        pcm_rom[1404] = 16'h0690; pcm_rom[1405] = 16'h0E8F; pcm_rom[1406] = 16'h167F; pcm_rom[1407] = 16'h1E58; pcm_rom[1408] = 16'h2613; pcm_rom[1409] = 16'h2DA8;
        pcm_rom[1410] = 16'h350F; pcm_rom[1411] = 16'h3C40; pcm_rom[1412] = 16'h4335; pcm_rom[1413] = 16'h49E6; pcm_rom[1414] = 16'h504D; pcm_rom[1415] = 16'h5664;
        pcm_rom[1416] = 16'h5C23; pcm_rom[1417] = 16'h6185; pcm_rom[1418] = 16'h6686; pcm_rom[1419] = 16'h6B1F; pcm_rom[1420] = 16'h6F4D; pcm_rom[1421] = 16'h730B;
        pcm_rom[1422] = 16'h7655; pcm_rom[1423] = 16'h7928; pcm_rom[1424] = 16'h7B81; pcm_rom[1425] = 16'h7D5E; pcm_rom[1426] = 16'h7EBD; pcm_rom[1427] = 16'h7F9C;
        pcm_rom[1428] = 16'h7FFB; pcm_rom[1429] = 16'h7FDA; pcm_rom[1430] = 16'h7F37; pcm_rom[1431] = 16'h7E15; pcm_rom[1432] = 16'h7C74; pcm_rom[1433] = 16'h7A56;
        pcm_rom[1434] = 16'h77BD; pcm_rom[1435] = 16'h74AB; pcm_rom[1436] = 16'h7124; pcm_rom[1437] = 16'h6D2C; pcm_rom[1438] = 16'h68C5; pcm_rom[1439] = 16'h63F5;
        pcm_rom[1440] = 16'h5EC1; pcm_rom[1441] = 16'h592D; pcm_rom[1442] = 16'h5340; pcm_rom[1443] = 16'h4CFE; pcm_rom[1444] = 16'h4670; pcm_rom[1445] = 16'h3F9A;
        pcm_rom[1446] = 16'h3885; pcm_rom[1447] = 16'h3137; pcm_rom[1448] = 16'h29B7; pcm_rom[1449] = 16'h220D; pcm_rom[1450] = 16'h1A41; pcm_rom[1451] = 16'h125B;
        pcm_rom[1452] = 16'h0A62; pcm_rom[1453] = 16'h025F; pcm_rom[1454] = 16'hFA59; pcm_rom[1455] = 16'hF259; pcm_rom[1456] = 16'hEA67; pcm_rom[1457] = 16'hE28B;
        pcm_rom[1458] = 16'hDACC; pcm_rom[1459] = 16'hD332; pcm_rom[1460] = 16'hCBC6; pcm_rom[1461] = 16'hC48E; pcm_rom[1462] = 16'hBD92; pcm_rom[1463] = 16'hB6D9;
        pcm_rom[1464] = 16'hB069; pcm_rom[1465] = 16'hAA49; pcm_rom[1466] = 16'hA480; pcm_rom[1467] = 16'h9F12; pcm_rom[1468] = 16'h9A06; pcm_rom[1469] = 16'h9561;
        pcm_rom[1470] = 16'h9127; pcm_rom[1471] = 16'h8D5C; pcm_rom[1472] = 16'h8A05; pcm_rom[1473] = 16'h8724; pcm_rom[1474] = 16'h84BD; pcm_rom[1475] = 16'h82D2;
        pcm_rom[1476] = 16'h8165; pcm_rom[1477] = 16'h8077; pcm_rom[1478] = 16'h8009; pcm_rom[1479] = 16'h801C; pcm_rom[1480] = 16'h80B0; pcm_rom[1481] = 16'h81C3;
        pcm_rom[1482] = 16'h8356; pcm_rom[1483] = 16'h8566; pcm_rom[1484] = 16'h87F1; pcm_rom[1485] = 16'h8AF5; pcm_rom[1486] = 16'h8E6F; pcm_rom[1487] = 16'h925B;
        pcm_rom[1488] = 16'h96B6; pcm_rom[1489] = 16'h9B7A; pcm_rom[1490] = 16'hA0A3; pcm_rom[1491] = 16'hA62C; pcm_rom[1492] = 16'hAC10; pcm_rom[1493] = 16'hB248;
        pcm_rom[1494] = 16'hB8CE; pcm_rom[1495] = 16'hBF9C; pcm_rom[1496] = 16'hC6AA; pcm_rom[1497] = 16'hCDF2; pcm_rom[1498] = 16'hD56D; pcm_rom[1499] = 16'hDD12;
        pcm_rom[1500] = 16'hE4DA; pcm_rom[1501] = 16'hECBE; pcm_rom[1502] = 16'hF4B5; pcm_rom[1503] = 16'hFCB8; pcm_rom[1504] = 16'h04BE; pcm_rom[1505] = 16'h0CBF;
        pcm_rom[1506] = 16'h14B3; pcm_rom[1507] = 16'h1C92; pcm_rom[1508] = 16'h2455; pcm_rom[1509] = 16'h2BF3; pcm_rom[1510] = 16'h3365; pcm_rom[1511] = 16'h3AA3;
        pcm_rom[1512] = 16'h41A6; pcm_rom[1513] = 16'h4867; pcm_rom[1514] = 16'h4EE0; pcm_rom[1515] = 16'h5509; pcm_rom[1516] = 16'h5ADC; pcm_rom[1517] = 16'h6055;
        pcm_rom[1518] = 16'h656C; pcm_rom[1519] = 16'h6A1D; pcm_rom[1520] = 16'h6E64; pcm_rom[1521] = 16'h723B; pcm_rom[1522] = 16'h75A0; pcm_rom[1523] = 16'h788E;
        pcm_rom[1524] = 16'h7B03; pcm_rom[1525] = 16'h7CFD; pcm_rom[1526] = 16'h7E78; pcm_rom[1527] = 16'h7F75; pcm_rom[1528] = 16'h7FF1; pcm_rom[1529] = 16'h7FED;
        pcm_rom[1530] = 16'h7F68; pcm_rom[1531] = 16'h7E62; pcm_rom[1532] = 16'h7CDE; pcm_rom[1533] = 16'h7ADC; pcm_rom[1534] = 16'h785F; pcm_rom[1535] = 16'h7568;
        pcm_rom[1536] = 16'h71FC; pcm_rom[1537] = 16'h6E1C; pcm_rom[1538] = 16'h69CF; pcm_rom[1539] = 16'h6516; pcm_rom[1540] = 16'h5FF8; pcm_rom[1541] = 16'h5A7A;
        pcm_rom[1542] = 16'h54A0; pcm_rom[1543] = 16'h4E71; pcm_rom[1544] = 16'h47F4; pcm_rom[1545] = 16'h412E; pcm_rom[1546] = 16'h3A26; pcm_rom[1547] = 16'h32E4;
        pcm_rom[1548] = 16'h2B6F; pcm_rom[1549] = 16'h23CE; pcm_rom[1550] = 16'h1C0A; pcm_rom[1551] = 16'h1428; pcm_rom[1552] = 16'h0C33; pcm_rom[1553] = 16'h0432;
        pcm_rom[1554] = 16'hFC2C; pcm_rom[1555] = 16'hF42A; pcm_rom[1556] = 16'hEC34; pcm_rom[1557] = 16'hE452; pcm_rom[1558] = 16'hDC8B; pcm_rom[1559] = 16'hD4E9;
        pcm_rom[1560] = 16'hCD71; pcm_rom[1561] = 16'hC62D; pcm_rom[1562] = 16'hBF23; pcm_rom[1563] = 16'hB85A; pcm_rom[1564] = 16'hB1D9; pcm_rom[1565] = 16'hABA6;
        pcm_rom[1566] = 16'hA5C9; pcm_rom[1567] = 16'hA046; pcm_rom[1568] = 16'h9B23; pcm_rom[1569] = 16'h9666; pcm_rom[1570] = 16'h9213; pcm_rom[1571] = 16'h8E2F;
        pcm_rom[1572] = 16'h8ABD; pcm_rom[1573] = 16'h87C1; pcm_rom[1574] = 16'h853E; pcm_rom[1575] = 16'h8337; pcm_rom[1576] = 16'h81AC; pcm_rom[1577] = 16'h80A2;
        pcm_rom[1578] = 16'h8017; pcm_rom[1579] = 16'h800C; pcm_rom[1580] = 16'h8083; pcm_rom[1581] = 16'h8179; pcm_rom[1582] = 16'h82EF; pcm_rom[1583] = 16'h84E3;
        pcm_rom[1584] = 16'h8753; pcm_rom[1585] = 16'h8A3C; pcm_rom[1586] = 16'h8D9B; pcm_rom[1587] = 16'h916D; pcm_rom[1588] = 16'h95AF; pcm_rom[1589] = 16'h9A5B;
        pcm_rom[1590] = 16'h9F6E; pcm_rom[1591] = 16'hA4E2; pcm_rom[1592] = 16'hAAB1; pcm_rom[1593] = 16'hB0D7; pcm_rom[1594] = 16'hB74C; pcm_rom[1595] = 16'hBE0A;
        pcm_rom[1596] = 16'hC50A; pcm_rom[1597] = 16'hCC46; pcm_rom[1598] = 16'hD3B6; pcm_rom[1599] = 16'hDB52; pcm_rom[1600] = 16'hE313; pcm_rom[1601] = 16'hEAF1;
        pcm_rom[1602] = 16'hF2E5; pcm_rom[1603] = 16'hFAE5; pcm_rom[1604] = 16'h02EB; pcm_rom[1605] = 16'h0AEE; pcm_rom[1606] = 16'h12E5; pcm_rom[1607] = 16'h1ACA;
        pcm_rom[1608] = 16'h2294; pcm_rom[1609] = 16'h2A3B; pcm_rom[1610] = 16'h31B8; pcm_rom[1611] = 16'h3902; pcm_rom[1612] = 16'h4014; pcm_rom[1613] = 16'h46E5;
        pcm_rom[1614] = 16'h4D6E; pcm_rom[1615] = 16'h53AA; pcm_rom[1616] = 16'h5991; pcm_rom[1617] = 16'h5F1F; pcm_rom[1618] = 16'h644C; pcm_rom[1619] = 16'h6915;
        pcm_rom[1620] = 16'h6D74; pcm_rom[1621] = 16'h7166; pcm_rom[1622] = 16'h74E5; pcm_rom[1623] = 16'h77EE; pcm_rom[1624] = 16'h7A7F; pcm_rom[1625] = 16'h7C95;
        pcm_rom[1626] = 16'h7E2D; pcm_rom[1627] = 16'h7F47; pcm_rom[1628] = 16'h7FE0; pcm_rom[1629] = 16'h7FF9; pcm_rom[1630] = 16'h7F91; pcm_rom[1631] = 16'h7EA9;
        pcm_rom[1632] = 16'h7D41; pcm_rom[1633] = 16'h7B5C; pcm_rom[1634] = 16'h78FA; pcm_rom[1635] = 16'h761F; pcm_rom[1636] = 16'h72CD; pcm_rom[1637] = 16'h6F08;
        pcm_rom[1638] = 16'h6AD2; pcm_rom[1639] = 16'h6632; pcm_rom[1640] = 16'h612A; pcm_rom[1641] = 16'h5BC1; pcm_rom[1642] = 16'h55FC; pcm_rom[1643] = 16'h4FE0;
        pcm_rom[1644] = 16'h4974; pcm_rom[1645] = 16'h42BE; pcm_rom[1646] = 16'h3BC5; pcm_rom[1647] = 16'h348F; pcm_rom[1648] = 16'h2D25; pcm_rom[1649] = 16'h258E;
        pcm_rom[1650] = 16'h1DD0; pcm_rom[1651] = 16'h15F5; pcm_rom[1652] = 16'h0E04; pcm_rom[1653] = 16'h0604; pcm_rom[1654] = 16'hFDFE; pcm_rom[1655] = 16'hF5FB;
        pcm_rom[1656] = 16'hEE01; pcm_rom[1657] = 16'hE61A; pcm_rom[1658] = 16'hDE4D; pcm_rom[1659] = 16'hD6A1; pcm_rom[1660] = 16'hCF20; pcm_rom[1661] = 16'hC7CF;
        pcm_rom[1662] = 16'hC0B7; pcm_rom[1663] = 16'hB9DE; pcm_rom[1664] = 16'hB34C; pcm_rom[1665] = 16'hAD08; pcm_rom[1666] = 16'hA716; pcm_rom[1667] = 16'hA17E;
        pcm_rom[1668] = 16'h9C45; pcm_rom[1669] = 16'h9771; pcm_rom[1670] = 16'h9305; pcm_rom[1671] = 16'h8F07; pcm_rom[1672] = 16'h8B7B; pcm_rom[1673] = 16'h8864;
        pcm_rom[1674] = 16'h85C5; pcm_rom[1675] = 16'h83A2; pcm_rom[1676] = 16'h81FB; pcm_rom[1677] = 16'h80D3; pcm_rom[1678] = 16'h802B; pcm_rom[1679] = 16'h8003;
        pcm_rom[1680] = 16'h805D; pcm_rom[1681] = 16'h8136; pcm_rom[1682] = 16'h828F; pcm_rom[1683] = 16'h8467; pcm_rom[1684] = 16'h86BA; pcm_rom[1685] = 16'h8988;
        pcm_rom[1686] = 16'h8CCC; pcm_rom[1687] = 16'h9085; pcm_rom[1688] = 16'h94AE; pcm_rom[1689] = 16'h9942; pcm_rom[1690] = 16'h9E3E; pcm_rom[1691] = 16'hA39C;
        pcm_rom[1692] = 16'hA958; pcm_rom[1693] = 16'hAF6A; pcm_rom[1694] = 16'hB5CD; pcm_rom[1695] = 16'hBC7B; pcm_rom[1696] = 16'hC36D; pcm_rom[1697] = 16'hCA9C;
        pcm_rom[1698] = 16'hD201; pcm_rom[1699] = 16'hD993; pcm_rom[1700] = 16'hE14D; pcm_rom[1701] = 16'hE925; pcm_rom[1702] = 16'hF115; pcm_rom[1703] = 16'hF913;
        pcm_rom[1704] = 16'h0118; pcm_rom[1705] = 16'h091C; pcm_rom[1706] = 16'h1117; pcm_rom[1707] = 16'h1901; pcm_rom[1708] = 16'h20D2; pcm_rom[1709] = 16'h2881;
        pcm_rom[1710] = 16'h3008; pcm_rom[1711] = 16'h375F; pcm_rom[1712] = 16'h3E7E; pcm_rom[1713] = 16'h455E; pcm_rom[1714] = 16'h4BF8; pcm_rom[1715] = 16'h5246;
        pcm_rom[1716] = 16'h5841; pcm_rom[1717] = 16'h5DE4; pcm_rom[1718] = 16'h6328; pcm_rom[1719] = 16'h6808; pcm_rom[1720] = 16'h6C80; pcm_rom[1721] = 16'h708A;
        pcm_rom[1722] = 16'h7423; pcm_rom[1723] = 16'h7748; pcm_rom[1724] = 16'h79F4; pcm_rom[1725] = 16'h7C26; pcm_rom[1726] = 16'h7DDB; pcm_rom[1727] = 16'h7F12;
        pcm_rom[1728] = 16'h7FC8; pcm_rom[1729] = 16'h7FFF; pcm_rom[1730] = 16'h7FB4; pcm_rom[1731] = 16'h7EE9; pcm_rom[1732] = 16'h7D9E; pcm_rom[1733] = 16'h7BD5;
        pcm_rom[1734] = 16'h7990; pcm_rom[1735] = 16'h76D0; pcm_rom[1736] = 16'h7399; pcm_rom[1737] = 16'h6FED; pcm_rom[1738] = 16'h6BD1; pcm_rom[1739] = 16'h6748;
        pcm_rom[1740] = 16'h6258; pcm_rom[1741] = 16'h5D04; pcm_rom[1742] = 16'h5754; pcm_rom[1743] = 16'h514B; pcm_rom[1744] = 16'h4AF0; pcm_rom[1745] = 16'h444A;
        pcm_rom[1746] = 16'h3D60; pcm_rom[1747] = 16'h3638; pcm_rom[1748] = 16'h2ED9; pcm_rom[1749] = 16'h274B; pcm_rom[1750] = 16'h1F95; pcm_rom[1751] = 16'h17C0;
        pcm_rom[1752] = 16'h0FD3; pcm_rom[1753] = 16'h07D6; pcm_rom[1754] = 16'hFFD1; pcm_rom[1755] = 16'hF7CD; pcm_rom[1756] = 16'hEFD0; pcm_rom[1757] = 16'hE7E4;
        pcm_rom[1758] = 16'hE010; pcm_rom[1759] = 16'hD85C; pcm_rom[1760] = 16'hD0D0; pcm_rom[1761] = 16'hC974; pcm_rom[1762] = 16'hC24E; pcm_rom[1763] = 16'hBB67;
        pcm_rom[1764] = 16'hB4C4; pcm_rom[1765] = 16'hAE6D; pcm_rom[1766] = 16'hA868; pcm_rom[1767] = 16'hA2BB; pcm_rom[1768] = 16'h9D6C; pcm_rom[1769] = 16'h9881;
        pcm_rom[1770] = 16'h93FD; pcm_rom[1771] = 16'h8FE6; pcm_rom[1772] = 16'h8C3F; pcm_rom[1773] = 16'h890E; pcm_rom[1774] = 16'h8653; pcm_rom[1775] = 16'h8413;
        pcm_rom[1776] = 16'h8250; pcm_rom[1777] = 16'h810B; pcm_rom[1778] = 16'h8046; pcm_rom[1779] = 16'h8001; pcm_rom[1780] = 16'h803D; pcm_rom[1781] = 16'h80FA;
        pcm_rom[1782] = 16'h8236; pcm_rom[1783] = 16'h83F0; pcm_rom[1784] = 16'h8628; pcm_rom[1785] = 16'h88DA; pcm_rom[1786] = 16'h8C04; pcm_rom[1787] = 16'h8FA2;
        pcm_rom[1788] = 16'h93B2; pcm_rom[1789] = 16'h982F; pcm_rom[1790] = 16'h9D13; pcm_rom[1791] = 16'hA25C; pcm_rom[1792] = 16'hA802; pcm_rom[1793] = 16'hAE01;
        pcm_rom[1794] = 16'hB453; pcm_rom[1795] = 16'hBAF1; pcm_rom[1796] = 16'hC1D4; pcm_rom[1797] = 16'hC8F5; pcm_rom[1798] = 16'hD04E; pcm_rom[1799] = 16'hD7D7;
        pcm_rom[1800] = 16'hDF89; pcm_rom[1801] = 16'hE75A; pcm_rom[1802] = 16'hEF45; pcm_rom[1803] = 16'hF741; pcm_rom[1804] = 16'hFF45; pcm_rom[1805] = 16'h074A;
        pcm_rom[1806] = 16'h0F48; pcm_rom[1807] = 16'h1737; pcm_rom[1808] = 16'h1F0E; pcm_rom[1809] = 16'h26C6; pcm_rom[1810] = 16'h2E56; pcm_rom[1811] = 16'h35B9;
        pcm_rom[1812] = 16'h3CE5; pcm_rom[1813] = 16'h43D4; pcm_rom[1814] = 16'h4A7F; pcm_rom[1815] = 16'h50DE; pcm_rom[1816] = 16'h56ED; pcm_rom[1817] = 16'h5CA4;
        pcm_rom[1818] = 16'h61FE; pcm_rom[1819] = 16'h66F5; pcm_rom[1820] = 16'h6B85; pcm_rom[1821] = 16'h6FA9; pcm_rom[1822] = 16'h735C; pcm_rom[1823] = 16'h769C;
        pcm_rom[1824] = 16'h7964; pcm_rom[1825] = 16'h7BB2; pcm_rom[1826] = 16'h7D83; pcm_rom[1827] = 16'h7ED6; pcm_rom[1828] = 16'h7FAA; pcm_rom[1829] = 16'h7FFE;
        pcm_rom[1830] = 16'h7FD0; pcm_rom[1831] = 16'h7F22; pcm_rom[1832] = 16'h7DF5; pcm_rom[1833] = 16'h7C48; pcm_rom[1834] = 16'h7A1F; pcm_rom[1835] = 16'h777A;
        pcm_rom[1836] = 16'h745E; pcm_rom[1837] = 16'h70CD; pcm_rom[1838] = 16'h6CCA; pcm_rom[1839] = 16'h6859; pcm_rom[1840] = 16'h6380; pcm_rom[1841] = 16'h5E43;
        pcm_rom[1842] = 16'h58A7; pcm_rom[1843] = 16'h52B1; pcm_rom[1844] = 16'h4C69; pcm_rom[1845] = 16'h45D4; pcm_rom[1846] = 16'h3EF8; pcm_rom[1847] = 16'h37DD;
        pcm_rom[1848] = 16'h308A; pcm_rom[1849] = 16'h2906; pcm_rom[1850] = 16'h2159; pcm_rom[1851] = 16'h198A; pcm_rom[1852] = 16'h11A2; pcm_rom[1853] = 16'h09A8;
        pcm_rom[1854] = 16'h01A4; pcm_rom[1855] = 16'hF99F; pcm_rom[1856] = 16'hF1A0; pcm_rom[1857] = 16'hE9AF; pcm_rom[1858] = 16'hE1D5; pcm_rom[1859] = 16'hDA19;
        pcm_rom[1860] = 16'hD283; pcm_rom[1861] = 16'hCB1C; pcm_rom[1862] = 16'hC3E9; pcm_rom[1863] = 16'hBCF3; pcm_rom[1864] = 16'hB640; pcm_rom[1865] = 16'hAFD7;
        pcm_rom[1866] = 16'hA9BF; pcm_rom[1867] = 16'hA3FE; pcm_rom[1868] = 16'h9E99; pcm_rom[1869] = 16'h9996; pcm_rom[1870] = 16'h94FA; pcm_rom[1871] = 16'h90CA;
        pcm_rom[1872] = 16'h8D0A; pcm_rom[1873] = 16'h89BD; pcm_rom[1874] = 16'h86E7; pcm_rom[1875] = 16'h848B; pcm_rom[1876] = 16'h82AB; pcm_rom[1877] = 16'h814A;
        pcm_rom[1878] = 16'h8067; pcm_rom[1879] = 16'h8005; pcm_rom[1880] = 16'h8024; pcm_rom[1881] = 16'h80C3; pcm_rom[1882] = 16'h81E3; pcm_rom[1883] = 16'h8381;
        pcm_rom[1884] = 16'h859C; pcm_rom[1885] = 16'h8833; pcm_rom[1886] = 16'h8B42; pcm_rom[1887] = 16'h8EC6; pcm_rom[1888] = 16'h92BC; pcm_rom[1889] = 16'h9720;
        pcm_rom[1890] = 16'h9BEE; pcm_rom[1891] = 16'hA120; pcm_rom[1892] = 16'hA6B2; pcm_rom[1893] = 16'hAC9D; pcm_rom[1894] = 16'hB2DC; pcm_rom[1895] = 16'hB969;
        pcm_rom[1896] = 16'hC03D; pcm_rom[1897] = 16'hC751; pcm_rom[1898] = 16'hCE9E; pcm_rom[1899] = 16'hD61D; pcm_rom[1900] = 16'hDDC6; pcm_rom[1901] = 16'hE591;
        pcm_rom[1902] = 16'hED77; pcm_rom[1903] = 16'hF56F; pcm_rom[1904] = 16'hFD72; pcm_rom[1905] = 16'h0578; pcm_rom[1906] = 16'h0D78; pcm_rom[1907] = 16'h156B;
        pcm_rom[1908] = 16'h1D48; pcm_rom[1909] = 16'h2508; pcm_rom[1910] = 16'h2CA2; pcm_rom[1911] = 16'h3410; pcm_rom[1912] = 16'h3B49; pcm_rom[1913] = 16'h4246;
        pcm_rom[1914] = 16'h4901; pcm_rom[1915] = 16'h4F73; pcm_rom[1916] = 16'h5594; pcm_rom[1917] = 16'h5B60; pcm_rom[1918] = 16'h60CF; pcm_rom[1919] = 16'h65DD;
        pcm_rom[1920] = 16'h6A85; pcm_rom[1921] = 16'h6EC2; pcm_rom[1922] = 16'h728F; pcm_rom[1923] = 16'h75E9; pcm_rom[1924] = 16'h78CC; pcm_rom[1925] = 16'h7B36;
        pcm_rom[1926] = 16'h7D24; pcm_rom[1927] = 16'h7E94; pcm_rom[1928] = 16'h7F85; pcm_rom[1929] = 16'h7FF6; pcm_rom[1930] = 16'h7FE6; pcm_rom[1931] = 16'h7F55;
        pcm_rom[1932] = 16'h7E44; pcm_rom[1933] = 16'h7CB5; pcm_rom[1934] = 16'h7AA7; pcm_rom[1935] = 16'h781F; pcm_rom[1936] = 16'h751D; pcm_rom[1937] = 16'h71A6;
        pcm_rom[1938] = 16'h6DBD; pcm_rom[1939] = 16'h6965; pcm_rom[1940] = 16'h64A3; pcm_rom[1941] = 16'h5F7C; pcm_rom[1942] = 16'h59F5; pcm_rom[1943] = 16'h5413;
        pcm_rom[1944] = 16'h4DDD; pcm_rom[1945] = 16'h4759; pcm_rom[1946] = 16'h408D; pcm_rom[1947] = 16'h3980; pcm_rom[1948] = 16'h3239; pcm_rom[1949] = 16'h2ABF;
        pcm_rom[1950] = 16'h231B; pcm_rom[1951] = 16'h1B53; pcm_rom[1952] = 16'h1370; pcm_rom[1953] = 16'h0B79; pcm_rom[1954] = 16'h0377; pcm_rom[1955] = 16'hFB71;
        pcm_rom[1956] = 16'hF370; pcm_rom[1957] = 16'hEB7B; pcm_rom[1958] = 16'hE39B; pcm_rom[1959] = 16'hDBD8; pcm_rom[1960] = 16'hD439; pcm_rom[1961] = 16'hCCC6;
        pcm_rom[1962] = 16'hC587; pcm_rom[1963] = 16'hBE82; pcm_rom[1964] = 16'hB7BF; pcm_rom[1965] = 16'hB145; pcm_rom[1966] = 16'hAB1A; pcm_rom[1967] = 16'hA545;
        pcm_rom[1968] = 16'h9FCA; pcm_rom[1969] = 16'h9AB1; pcm_rom[1970] = 16'h95FD; pcm_rom[1971] = 16'h91B4; pcm_rom[1972] = 16'h8DDA; pcm_rom[1973] = 16'h8A73;
        pcm_rom[1974] = 16'h8782; pcm_rom[1975] = 16'h850A; pcm_rom[1976] = 16'h830E; pcm_rom[1977] = 16'h818F; pcm_rom[1978] = 16'h8090; pcm_rom[1979] = 16'h8010;
        pcm_rom[1980] = 16'h8012; pcm_rom[1981] = 16'h8094; pcm_rom[1982] = 16'h8196; pcm_rom[1983] = 16'h8318; pcm_rom[1984] = 16'h8517; pcm_rom[1985] = 16'h8791;
        pcm_rom[1986] = 16'h8A85; pcm_rom[1987] = 16'h8DEF; pcm_rom[1988] = 16'h91CC; pcm_rom[1989] = 16'h9617; pcm_rom[1990] = 16'h9ACD; pcm_rom[1991] = 16'h9FE9;
        pcm_rom[1992] = 16'hA565; pcm_rom[1993] = 16'hAB3D; pcm_rom[1994] = 16'hB16A; pcm_rom[1995] = 16'hB7E6; pcm_rom[1996] = 16'hBEAA; pcm_rom[1997] = 16'hC5B0;
        pcm_rom[1998] = 16'hCCF1; pcm_rom[1999] = 16'hD465; pcm_rom[2000] = 16'hDC05; pcm_rom[2001] = 16'hE3C9; pcm_rom[2002] = 16'hEBA9; pcm_rom[2003] = 16'hF39E;
        pcm_rom[2004] = 16'hFBA0; pcm_rom[2005] = 16'h03A6; pcm_rom[2006] = 16'h0BA8; pcm_rom[2007] = 16'h139E; pcm_rom[2008] = 16'h1B81; pcm_rom[2009] = 16'h2348;
        pcm_rom[2010] = 16'h2AEB; pcm_rom[2011] = 16'h3264; pcm_rom[2012] = 16'h39A9; pcm_rom[2013] = 16'h40B5; pcm_rom[2014] = 16'h4780; pcm_rom[2015] = 16'h4E02;
        pcm_rom[2016] = 16'h5437; pcm_rom[2017] = 16'h5A16; pcm_rom[2018] = 16'h5F9B; pcm_rom[2019] = 16'h64C0; pcm_rom[2020] = 16'h697F; pcm_rom[2021] = 16'h6DD5;
        pcm_rom[2022] = 16'h71BC; pcm_rom[2023] = 16'h7530; pcm_rom[2024] = 16'h782F; pcm_rom[2025] = 16'h7AB5; pcm_rom[2026] = 16'h7CBF; pcm_rom[2027] = 16'h7E4C;
        pcm_rom[2028] = 16'h7F5A; pcm_rom[2029] = 16'h7FE8; pcm_rom[2030] = 16'h7FF5; pcm_rom[2031] = 16'h7F81; pcm_rom[2032] = 16'h7E8E; pcm_rom[2033] = 16'h7D1A;
        pcm_rom[2034] = 16'h7B2A; pcm_rom[2035] = 16'h78BD; pcm_rom[2036] = 16'h75D7; pcm_rom[2037] = 16'h727A; pcm_rom[2038] = 16'h6EAA; pcm_rom[2039] = 16'h6A6B;
        pcm_rom[2040] = 16'h65C1; pcm_rom[2041] = 16'h60B1; pcm_rom[2042] = 16'h5B3F; pcm_rom[2043] = 16'h5571; pcm_rom[2044] = 16'h4F4E; pcm_rom[2045] = 16'h48DB;
        pcm_rom[2046] = 16'h421E; pcm_rom[2047] = 16'h3B1F; pcm_rom[2048] = 16'h33E5; pcm_rom[2049] = 16'h2C76; pcm_rom[2050] = 16'h24DB; pcm_rom[2051] = 16'h1D1B;
        pcm_rom[2052] = 16'h153D; pcm_rom[2053] = 16'h0D4A; pcm_rom[2054] = 16'h0549; pcm_rom[2055] = 16'hFD44; pcm_rom[2056] = 16'hF541; pcm_rom[2057] = 16'hED49;
        pcm_rom[2058] = 16'hE563; pcm_rom[2059] = 16'hDD99; pcm_rom[2060] = 16'hD5F1; pcm_rom[2061] = 16'hCE73; pcm_rom[2062] = 16'hC727; pcm_rom[2063] = 16'hC015;
        pcm_rom[2064] = 16'hB942; pcm_rom[2065] = 16'hB2B7; pcm_rom[2066] = 16'hAC7A; pcm_rom[2067] = 16'hA690; pcm_rom[2068] = 16'hA101; pcm_rom[2069] = 16'h9BD1;
        pcm_rom[2070] = 16'h9705; pcm_rom[2071] = 16'h92A4; pcm_rom[2072] = 16'h8EB0; pcm_rom[2073] = 16'h8B2E; pcm_rom[2074] = 16'h8822; pcm_rom[2075] = 16'h858F;
        pcm_rom[2076] = 16'h8376; pcm_rom[2077] = 16'h81DB; pcm_rom[2078] = 16'h80BE; pcm_rom[2079] = 16'h8022; pcm_rom[2080] = 16'h8006; pcm_rom[2081] = 16'h806B;
        pcm_rom[2082] = 16'h8150; pcm_rom[2083] = 16'h82B5; pcm_rom[2084] = 16'h8498; pcm_rom[2085] = 16'h86F6; pcm_rom[2086] = 16'h89CF; pcm_rom[2087] = 16'h8D1E;
        pcm_rom[2088] = 16'h90E1; pcm_rom[2089] = 16'h9514; pcm_rom[2090] = 16'h99B2; pcm_rom[2091] = 16'h9EB7; pcm_rom[2092] = 16'hA41E; pcm_rom[2093] = 16'hA9E1;
        pcm_rom[2094] = 16'hAFFB; pcm_rom[2095] = 16'hB666; pcm_rom[2096] = 16'hBD1A; pcm_rom[2097] = 16'hC412; pcm_rom[2098] = 16'hCB46; pcm_rom[2099] = 16'hD2AF;
        pcm_rom[2100] = 16'hDA46; pcm_rom[2101] = 16'hE202; pcm_rom[2102] = 16'hE9DD; pcm_rom[2103] = 16'hF1CE; pcm_rom[2104] = 16'hF9CD; pcm_rom[2105] = 16'h01D3;
        pcm_rom[2106] = 16'h09D7; pcm_rom[2107] = 16'h11D0; pcm_rom[2108] = 16'h19B8; pcm_rom[2109] = 16'h2186; pcm_rom[2110] = 16'h2932; pcm_rom[2111] = 16'h30B5;
        pcm_rom[2112] = 16'h3807; pcm_rom[2113] = 16'h3F21; pcm_rom[2114] = 16'h45FB; pcm_rom[2115] = 16'h4C8E; pcm_rom[2116] = 16'h52D5; pcm_rom[2117] = 16'h58C8;
        pcm_rom[2118] = 16'h5E62; pcm_rom[2119] = 16'h639D; pcm_rom[2120] = 16'h6874; pcm_rom[2121] = 16'h6CE2; pcm_rom[2122] = 16'h70E3; pcm_rom[2123] = 16'h7471;
        pcm_rom[2124] = 16'h778B; pcm_rom[2125] = 16'h7A2D; pcm_rom[2126] = 16'h7C53; pcm_rom[2127] = 16'h7DFD; pcm_rom[2128] = 16'h7F28; pcm_rom[2129] = 16'h7FD3;
        pcm_rom[2130] = 16'h7FFD; pcm_rom[2131] = 16'h7FA7; pcm_rom[2132] = 16'h7ED0; pcm_rom[2133] = 16'h7D7A; pcm_rom[2134] = 16'h7BA6; pcm_rom[2135] = 16'h7955;
        pcm_rom[2136] = 16'h768A; pcm_rom[2137] = 16'h7348; pcm_rom[2138] = 16'h6F92; pcm_rom[2139] = 16'h6B6C; pcm_rom[2140] = 16'h66DA; pcm_rom[2141] = 16'h61E0;
        pcm_rom[2142] = 16'h5C84; pcm_rom[2143] = 16'h56CB; pcm_rom[2144] = 16'h50BA; pcm_rom[2145] = 16'h4A59; pcm_rom[2146] = 16'h43AC; pcm_rom[2147] = 16'h3CBC;
        pcm_rom[2148] = 16'h358E; pcm_rom[2149] = 16'h2E2B; pcm_rom[2150] = 16'h2699; pcm_rom[2151] = 16'h1EE0; pcm_rom[2152] = 16'h1709; pcm_rom[2153] = 16'h0F1A;
        pcm_rom[2154] = 16'h071C; pcm_rom[2155] = 16'hFF17; pcm_rom[2156] = 16'hF712; pcm_rom[2157] = 16'hEF17; pcm_rom[2158] = 16'hE72D; pcm_rom[2159] = 16'hDF5B;
        pcm_rom[2160] = 16'hD7AB; pcm_rom[2161] = 16'hD023; pcm_rom[2162] = 16'hC8CB; pcm_rom[2163] = 16'hC1AB; pcm_rom[2164] = 16'hBAC9; pcm_rom[2165] = 16'hB42D;
        pcm_rom[2166] = 16'hADDE; pcm_rom[2167] = 16'hA7E0; pcm_rom[2168] = 16'hA23C; pcm_rom[2169] = 16'h9CF6; pcm_rom[2170] = 16'h9813; pcm_rom[2171] = 16'h9399;
        pcm_rom[2172] = 16'h8F8C; pcm_rom[2173] = 16'h8BF0; pcm_rom[2174] = 16'h88C9; pcm_rom[2175] = 16'h861A; pcm_rom[2176] = 16'h83E5; pcm_rom[2177] = 16'h822D;
        pcm_rom[2178] = 16'h80F4; pcm_rom[2179] = 16'h803A; pcm_rom[2180] = 16'h8001; pcm_rom[2181] = 16'h8049; pcm_rom[2182] = 16'h8111; pcm_rom[2183] = 16'h8259;
        pcm_rom[2184] = 16'h841F; pcm_rom[2185] = 16'h8662; pcm_rom[2186] = 16'h891F; pcm_rom[2187] = 16'h8C53; pcm_rom[2188] = 16'h8FFC; pcm_rom[2189] = 16'h9416;
        pcm_rom[2190] = 16'h989C; pcm_rom[2191] = 16'h9D8A; pcm_rom[2192] = 16'hA2DB; pcm_rom[2193] = 16'hA88A; pcm_rom[2194] = 16'hAE91; pcm_rom[2195] = 16'hB4EA;
        pcm_rom[2196] = 16'hBB8E; pcm_rom[2197] = 16'hC277; pcm_rom[2198] = 16'hC99E; pcm_rom[2199] = 16'hD0FC; pcm_rom[2200] = 16'hD889; pcm_rom[2201] = 16'hE03D;
        pcm_rom[2202] = 16'hE812; pcm_rom[2203] = 16'hEFFE; pcm_rom[2204] = 16'hF7FB;
    end

    assign rom_q        = pcm_rom[samp_idx];   // asynchronous ROM read
    assign samp_idx_inc = (samp_idx == PCM_ROM_LAST) ? 12'd0
                                                     : (samp_idx + 12'd1);

    // 256-bit beat, sample 0 in the low 16 bits (mel_engine lane contract:
    // `pc_lane = pc_beat_buf[samp_ph*16 +: 16]`, so lane 0 must be pcm[0]).
    assign beat_base = {rs_beat_cnt, 4'd0};
    assign beat_pack = {
        pcm_buf[beat_base + 8'd15], pcm_buf[beat_base + 8'd14],
        pcm_buf[beat_base + 8'd13], pcm_buf[beat_base + 8'd12],
        pcm_buf[beat_base + 8'd11], pcm_buf[beat_base + 8'd10],
        pcm_buf[beat_base + 8'd9],  pcm_buf[beat_base + 8'd8],
        pcm_buf[beat_base + 8'd7],  pcm_buf[beat_base + 8'd6],
        pcm_buf[beat_base + 8'd5],  pcm_buf[beat_base + 8'd4],
        pcm_buf[beat_base + 8'd3],  pcm_buf[beat_base + 8'd2],
        pcm_buf[beat_base + 8'd1],  pcm_buf[beat_base + 8'd0]
    };

    assign mel_m2_rd_valid = rs_rd_valid;
    assign mel_m2_rd_data  = beat_pack;
    assign mel_m2_done     = rs_done;
    assign mel_m2_wready   = rs_wready;

    // ------------------------------------------------------------------
    // Fake PCM source, part 2: m2 command responder.
    //
    // COMMAND LAYOUT (the bug this task fixes)
    //   mel_engine.v drives `m2_cmd = {wr, addr[27:0], len[7:0]}`:
    //     m2_cmd[36]    = wr
    //     m2_cmd[35:8]  = byte address
    //     m2_cmd[7:0]   = len (beats - 1)
    //   The pre-T26 responder read `m2_cmd[27:0]` as the address and
    //   compared `m2_cmd[18:1]` with the running sample counter.  Both are
    //   wrong field slices: bit 0 of m2_cmd is len[0], not addr[0].  For
    //   command 0 (addr 0, len 15) the old check compared 7 against 0, so
    //   addr_err latched on the very first command (board evidence:
    //   STATUS frame H bit3 = 1 with only 4 commands served).
    //   Correct slices: addr = m2_cmd[35:8], addr[18:1] = m2_cmd[26:9].
    //
    // READ COMMAND (m2_cmd[36] == 0), len must be 15 (16 beats):
    //   1. RS_LOAD : 256 cycles, stream the next 256 ROM samples into
    //                pcm_buf[0..255].  samp_idx walks the 2205-sample
    //                period cyclically, so the concatenation of all 516
    //                commands is exactly pcm[0..132095].
    //   2. RS_ACK  : one-cycle m2_done.  This is the "done after the last
    //                data beat" contract of ddr3_ctrl_axi.v expressed the
    //                other way round: the real controller hides the beats
    //                in its read fifo until done, this responder hides them
    //                in pcm_buf.  mel_engine leaves PC_CMD on done and only
    //                asserts m2_rd_ready in PC_BEAT, so edges issued before
    //                done would be lost.
    //   3. RS_BEAT : 16 beats, one per accepted m2_rd_ready.  rd_valid is
    //                held high (fifo-style) and beat_pack is combinationally
    //                aligned to rs_beat_cnt, so whenever mel_engine asserts
    //                m2_rd_ready it samples the correct beat.  The responder
    //                never throttles: it only advances on rd_ready, it never
    //                requires rd_ready to be low first.
    //   rd_cmd_cnt / glob_cnt count commands and samples for the STATUS frame.
    //
    // WRITE COMMAND (m2_cmd[36] == 1): the dB-spectrum export (1032 single
    //   beat len=0 commands).  Not part of the feature comparison, but each
    //   256-bit word is folded into a 32-bit XOR so the DONE frame proves all
    //   1032 exports carried stable data.  wready_beat is a one-cycle pulse
    //   per accepted beat and done coincides with the only (last) beat of a
    //   len=0 command, i.e. "after the last beat".
    //
    // Address self-check: mel_engine reads win_base (= 0, win_id is tied 0)
    // sequentially in 256-sample commands, so addr[18:1] of each read must
    // equal the running sample counter.  A mismatch latches addr_err
    // (led[6]) and records the offending sample index in addr_err_samp,
    // which the STATUS frame exports in field F.  The PCM is never silently
    // replaced by data from the wrong address.
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs_state      <= RS_IDLE;
            rs_addr       <= 28'd0;
            glob_cnt      <= 18'd0;
            samp_idx      <= 11'd0;
            load_cnt      <= 9'd0;
            rs_beat_cnt   <= 4'd0;
            rs_rd_valid   <= 1'b0;
            rs_done       <= 1'b0;
            rs_wready     <= 1'b0;
            addr_err      <= 1'b0;
            addr_err_samp <= 18'd0;
            wr_xor        <= 32'd0;
            wr_cmd_cnt    <= 32'd0;
            rd_cmd_cnt    <= 32'd0;
        end else begin
            rs_done   <= 1'b0;
            rs_wready <= 1'b0;
            case (rs_state)
                RS_IDLE: begin
                    rs_rd_valid <= 1'b0;
                    if (mel_m2_cmd_valid) begin
                        rs_addr <= mel_m2_cmd[35:8];
                        if (mel_m2_cmd[36]) begin
                            // Write command: fold the 256-bit beat, then ack.
                            wr_xor <= wr_xor
                                ^ mel_m2_wdata[31:0]
                                ^ mel_m2_wdata[63:32]
                                ^ mel_m2_wdata[95:64]
                                ^ mel_m2_wdata[127:96]
                                ^ mel_m2_wdata[159:128]
                                ^ mel_m2_wdata[191:160]
                                ^ mel_m2_wdata[223:192]
                                ^ mel_m2_wdata[255:224];
                            wr_cmd_cnt <= wr_cmd_cnt + 32'd1;
                            rs_wready  <= 1'b1;
                            rs_done    <= 1'b1;
                            rs_state   <= RS_WR;
                        end else begin
                            // Read command: cross-check the byte address
                            // against the expected sample index.  A len
                            // other than 15 would also break the 16-beat
                            // budget, so it latches the same sticky flag.
                            if (mel_m2_cmd[26:9] != glob_cnt) begin
                                addr_err <= 1'b1;
                                if (!addr_err)
                                    addr_err_samp <= mel_m2_cmd[26:9];
                            end
                            if (mel_m2_cmd[7:0] != 8'd15)
                                addr_err <= 1'b1;
                            glob_cnt    <= glob_cnt + PCM_CMD_SAMP;
                            rd_cmd_cnt  <= rd_cmd_cnt + 32'd1;
                            load_cnt    <= 9'd0;
                            rs_beat_cnt <= 4'd0;
                            rs_state    <= RS_LOAD;
                        end
                    end
                end
                RS_WR: begin
                    // Hold off until cmd_valid drops so one write command is
                    // acknowledged exactly once.
                    if (!mel_m2_cmd_valid)
                        rs_state <= RS_IDLE;
                end
                RS_LOAD: begin
                    // 256 samples of the current command, ROM is asynchronous.
                    pcm_buf[load_cnt[7:0]] <= rom_q;
                    samp_idx               <= samp_idx_inc;
                    if (load_cnt == 9'd255) begin
                        load_cnt    <= 9'd0;
                        rs_beat_cnt <= 4'd0;
                        rs_rd_valid <= 1'b1;   // first beat valid from RS_ACK on
                        rs_state    <= RS_ACK;
                    end else begin
                        load_cnt <= load_cnt + 9'd1;
                    end
                end
                RS_ACK: begin
                    rs_done  <= 1'b1;
                    rs_state <= RS_BEAT;
                end
                RS_BEAT: begin
                    rs_rd_valid <= 1'b1;
                    if (mel_m2_rd_ready) begin
                        if (rs_beat_cnt == 4'd15) begin
                            rs_beat_cnt <= 4'd0;
                            rs_rd_valid <= 1'b0;
                            rs_state    <= RS_IDLE;
                        end else begin
                            rs_beat_cnt <= rs_beat_cnt + 4'd1;
                        end
                    end
                end
                default: begin
                    rs_state <= RS_IDLE;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Uppercase hex digit of a 4-bit nibble (same arithmetic as
    // diag_uart_report.v / uart_debug.v, no lookup ROM).
    // ------------------------------------------------------------------
    function [7:0] hex_ascii;
        input [3:0] nib;
        begin
            hex_ascii = (nib >= 4'hA) ? (8'h41 + {4'd0, (nib - 4'hA)})
                                      : (8'h30 + {4'd0, nib});
        end
    endfunction

    // ------------------------------------------------------------------
    // Feature hex streamer.
    //
    // One feature element (uint8) is emitted as two uppercase hex digits,
    // high nibble first, and a newline closes every 64-element group (one
    // mel frame, frame-major order: element = frame*64 + mel).
    // feat_rd_addr -> mel_engine internal bank (+64 offset) -> 1-cycle
    // synchronous read -> feat_rd_data two cycles later.
    // ------------------------------------------------------------------
    always @* begin
        hex_ch_data = 8'h20;
        if (hs_state == HS_HI)
            hex_ch_data = hex_ascii(feat_rd_data[7:4]);
        else if (hs_state == HS_LO)
            hex_ch_data = hex_ascii(byte_q[3:0]);
        else if (hs_state == HS_NL)
            hex_ch_data = 8'h0A;
    end

    assign hex_ch_valid = (hs_state == HS_HI) || (hs_state == HS_LO)
                          || (hs_state == HS_NL);
    assign hex_acc      = src_take && owner_hex;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs_state     <= HS_IDLE;
            hex_addr     <= 15'd0;
            byte_q       <= 8'd0;
            feat_xor     <= 32'd0;
            feat_sum     <= 32'd0;
            hex_done     <= 1'b0;
            feat_rd_addr <= 15'd0;
        end else begin
            case (hs_state)
                HS_IDLE: begin
                    if (owner_hex) begin
                        hex_addr <= 15'd0;
                        hs_state <= HS_ADDR;
                    end
                end
                HS_ADDR: begin
                    feat_rd_addr <= hex_addr;
                    hs_state     <= HS_WAIT;
                end
                HS_WAIT: begin
                    // Bank read latency: the data appears in HS_HI.
                    hs_state <= HS_HI;
                end
                HS_HI: begin
                    if (hex_acc) begin
                        byte_q   <= feat_rd_data;
                        feat_xor <= feat_xor ^ {24'd0, feat_rd_data};
                        feat_sum <= feat_sum + {24'd0, feat_rd_data};
                        hs_state <= HS_LO;
                    end
                end
                HS_LO: begin
                    if (hex_acc) begin
                        if (hex_addr[5:0] == LINE_LOW_MASK[5:0])
                            hs_state <= HS_NL;
                        else
                            hs_state <= HS_NEXT;
                    end
                end
                HS_NL: begin
                    if (hex_acc)
                        hs_state <= HS_NEXT;
                end
                HS_NEXT: begin
                    if (hex_addr == FEAT_LAST) begin
                        hex_done <= 1'b1;
                        hs_state <= HS_DONE;
                    end else begin
                        hex_addr <= hex_addr + 15'd1;
                        hs_state <= HS_ADDR;
                    end
                end
                default: begin
                    hs_state <= HS_DONE;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // UART byte shim: exactly one uart_tx byte in flight plus a mandatory
    // idle cycle after every accepted byte.  uart_tx.byte_wready is a
    // register that still reads high on the cycle after an accept, so the
    // shim never presents the next byte on that cycle (D2 contract of
    // diag_uart_report.v, the hazard that broke uart_debug.v sequencing).
    // ------------------------------------------------------------------
    assign src_data   = owner_hex ? hex_ch_data : diag_tx_data;
    assign src_valid  = owner_hex ? hex_ch_valid : diag_tx_valid;
    assign src_take   = shim_v && uart_ready;
    assign diag_ready = src_take && !owner_hex;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shim_v       <= 1'b0;
            shim_d       <= 8'd0;
            shim_lockout <= 1'b0;
        end else begin
            if (shim_v) begin
                if (uart_ready) begin
                    shim_v       <= 1'b0;
                    shim_lockout <= 1'b1;
                end
            end else if (shim_lockout) begin
                shim_lockout <= 1'b0;
            end else if (src_valid) begin
                shim_d <= src_data;
                shim_v <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Diagnostic frame engine (two 91-byte frames: STATUS before the hex
    // stream, DONE after it).  frame_tag is 0 (DDR3DIAG) because
    // diag_uart_report.v offers four fixed tag names only; the meaning of
    // this design's frames is carried by the G byte (0x01 / 0x02).
    // ------------------------------------------------------------------
    assign stat_a = {16'd0, FEAT_BYTES};
    assign stat_b = (ms_state == MS_STAT2) ? feat_xor : mel_cycles;
    assign stat_c = (ms_state == MS_STAT2) ? feat_sum : rd_cmd_cnt;
    assign stat_d = (ms_state == MS_STAT2) ? wr_cmd_cnt : {14'd0, glob_cnt};
    assign stat_e = (ms_state == MS_STAT2) ? wr_xor : {31'd0, mel_feat_page};
    // STATUS field F: 0 unless the address self-check tripped, otherwise the
    // first offending sample index (addr[18:1] of the bad read command).
    // This is the primary evidence field for the T26 responder fix.
    assign stat_f = (ms_state == MS_STAT2) ? mel_cycles
                                           : {14'd0, addr_err_samp};
    assign stat_g = (ms_state == MS_STAT2) ? 8'h02 : 8'h01;
    assign stat_h = {
        hex_done,        // bit7
        mel_done_seen,   // bit6
        mel_timeout,     // bit5
        run_timeout,     // bit4
        addr_err,        // bit3
        mel_win_miss,    // bit2
        mel_busy,        // bit1
        1'b1             // bit0: design marker
    };

    diag_uart_report #(
        .BAUD_DIV ( BAUD_DIV[15:0] )
    ) u_diag (
        .clk           (clk),
        .rst_n         (rst_n),
        .fire          (diag_fire),
        .frame_tag     (2'd0),
        .f_a           (stat_a),
        .f_b           (stat_b),
        .f_c           (stat_c),
        .f_d           (stat_d),
        .f_e           (stat_e),
        .f_f           (stat_f),
        .f_g           (stat_g),
        .f_h           (stat_h),
        .busy          (diag_busy),
        .tx_byte_data  (diag_tx_data),
        .tx_byte_valid (diag_tx_valid),
        .tx_byte_ready (diag_ready)
    );

    uart_tx #(
        .BAUD_DIV ( BAUD_DIV[15:0] )
    ) u_uart_tx (
        .clk         (clk),
        .rst_n       (rst_n),
        .byte_wdata  (shim_d),
        .byte_wvalid (shim_v),
        .byte_wready (uart_ready),
        .uart_txd    (uart_tx)
    );

    // ------------------------------------------------------------------
    // Main sequencer.
    //   MS_WAIT  : settle, then pulse exactly one win_tick (3 s window)
    //   MS_RUN   : wait for mel_done or the 2 s top-level timeout
    //   MS_STAT1 : emit the STATUS frame, hand the UART to the streamer
    //   MS_HEX   : stream all 16512 feature bytes as hex
    //   MS_STAT2 : emit the DONE frame
    //   MS_HOLD  : park, LEDs stay lit
    // ms_stat2 selects which field set the frame engine renders; it is a
    // flag rather than a state so MS_STAT1 and MS_STAT2 share one branch.
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_state      <= MS_WAIT;

            start_cnt     <= 10'd0;
            start_done    <= 1'b0;
            win_tick      <= 1'b0;
            mel_done_seen <= 1'b0;
            run_timeout   <= 1'b0;
            run_cnt       <= 32'd0;
            diag_fire     <= 1'b0;
            stat_fired    <= 1'b0;
            diag_seen_busy <= 1'b0;
            hex_started   <= 1'b0;
            owner_hex     <= 1'b0;
            beat_cnt      <= 24'd0;
        end else begin
            win_tick  <= 1'b0;
            diag_fire <= 1'b0;
            beat_cnt  <= beat_cnt + 24'd1;

            if (mel_done)
                mel_done_seen <= 1'b1;
            if (owner_hex)
                hex_started <= 1'b1;

            case (ms_state)
                MS_WAIT: begin
                    // Hold the engine idle for ~38 us after the board reset
                    // releases, then start exactly one 3 s window.
                    if (start_cnt == START_DLY) begin
                        start_done <= 1'b1;
                        win_tick   <= 1'b1;
                        ms_state   <= MS_RUN;
                    end else begin
                        start_cnt <= start_cnt + 10'd1;
                    end
                end
                MS_RUN: begin
                    if (mel_done) begin
                        ms_state <= MS_STAT1;
                    end else if (run_cnt >= RUN_TIMEOUT_CYCLES) begin
                        run_timeout <= 1'b1;
                        ms_state    <= MS_STAT1;
                    end else begin
                        run_cnt <= run_cnt + 32'd1;
                    end
                end
                MS_STAT1: begin
                    // Fire once, wait until the frame has actually started
                    // (diag_busy rises one cycle AFTER the registered fire
                    // pulse), then wait for it to fully drain before the
                    // streamer takes the UART over.
                    if (!stat_fired) begin
                        if (!diag_busy) begin
                            diag_fire  <= 1'b1;
                            stat_fired <= 1'b1;
                        end
                    end else if (!diag_seen_busy) begin
                        if (diag_busy)
                            diag_seen_busy <= 1'b1;
                    end else if (!diag_busy && !shim_v && !shim_lockout) begin
                        owner_hex <= 1'b1;
                        ms_state  <= MS_HEX;
                    end
                end
                MS_HEX: begin
                    if (hex_done && !shim_v && !shim_lockout) begin
                        owner_hex  <= 1'b0;
                        stat_fired <= 1'b0;
                        ms_state   <= MS_STAT2;
                    end
                end
                MS_STAT2: begin
                    if (!stat_fired) begin
                        if (!diag_busy) begin
                            diag_fire      <= 1'b1;
                            stat_fired     <= 1'b1;
                            diag_seen_busy <= 1'b0;
                        end
                    end else if (!diag_seen_busy) begin
                        if (diag_busy)
                            diag_seen_busy <= 1'b1;
                    end else if (!diag_busy) begin
                        ms_state <= MS_HOLD;
                    end
                end
                default: begin
                    ms_state <= MS_HOLD;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Status LEDs.
    // ------------------------------------------------------------------
    assign led[0] = beat_cnt[23];
    assign led[1] = mel_busy;
    assign led[2] = mel_done_seen;
    assign led[3] = hex_started && (hs_state != HS_DONE);
    assign led[4] = mel_timeout;
    assign led[5] = run_timeout;
    assign led[6] = addr_err;
    assign led[7] = hex_done;

    // Observation taps kept alive for board probing.
    wire [1:0] unused_obs = {start_done, mel_npu_start};

endmodule