// -----------------------------------------------------------------------------
// i2s_clk_gen - NCO-synthesized I2S master clocks (design.md Sec. 1.2 scheme B,
//               port contract Sec. 2.2.2, tasks.md T-M0-01)
// -----------------------------------------------------------------------------
// A 28-bit phase accumulator running on the 216 MHz clk_nco time base
// synthesizes the BCK half-period tick (bck_tick). A 5-bit frame phase
// counter (bck_phase, 0..31 = one LRCK half frame = 16 BCK periods =
// 32 half-period ticks) derives LRCK and the serial bit phase. All logic
// runs in the clk_nco domain; bck_tick is a same-domain enable pulse, so
// consumers (i2s_rx) work in a virtual 44.1 kHz-family domain with no
// metastability (design.md Sec. 1.2 "audio beat semantics").
//
// NCO step derivation (REQ-AUD-003):
//   F_bck_toggle = 2 x BCK = 2 x 1.4112 MHz = 2.8224 MHz
//   STEP = round(2^28 x 2822400 / 216000000)
//        = round(2^28 x 49 / 3750)          (2822400/216000000 = 49/3750)
//        = round(3507556.625) = 3507557
//   -> LRCK = 216e6 / (64 x STEP) = 44100.0047 Hz  (+0.107 ppm)
//   NOTE: design.md Sec. 1.2 lists STEP = 3509057, based on the literal
//   "2^28 x 0.013072". The exact ratio is 49/3750 = 0.0130667 (the
//   0.013072 literal is an arithmetic slip). STEP = 3509057 would give
//   LRCK = 44112.6 Hz (+285.8 ppm), uncomfortably close to the +/-500
//   ppm limit of REQ-AUD-003. The mathematically correct value 3507557
//   is used here; the deviation is recorded in the task report.
//
// Frequency error budget: accumulator rounding residual < 2^-28 relative
// (< 0.004 ppm); the dominant error is the 27 MHz crystal tolerance
// (typ. +/-50 ppm), well inside +/-500 ppm (REQ-AUD-002/003).
//
// Phase-to-waveform mapping (bit-level self-check table):
//   phase=2k   (even): BCK = 0 (low half of the BCK period)
//   phase=2k+1 (odd) : BCK = 1 (high half of the BCK period)
//   tick at phase even->odd = BCK RISING edge  (16 per half frame:
//                          0->1, 2->3, ..., 30->31)
//   tick at phase odd->even  = BCK FALLING edge (16 per half frame:
//                          1->2, 3->4, ..., 31->0)
//   phase 31 -> 0 tick: BCK falling edge AND LRCK toggle in the SAME
//   clk_nco cycle (Philips I2S: LRCK changes on BCK falling edge);
//   LRCK low = LEFT channel, LRCK high = RIGHT channel.
//   Reset state: phase=0, BCK=0, LRCK=0 (left); the first tick after
//   reset is therefore a BCK rising edge at phase 0->1.
//
// Timing note: the 28-bit adder carry chain (~1.5 ns) fits the 216 MHz
// period (4.63 ns). If PnR becomes tight, split the accumulator into a
// 14+14 two-stage pipeline (low half adds every cycle, high half
// increments on the low-half carry-out, tick = OR of both carries) -
// the long-term average frequency is unchanged. Reserved as an upgrade
// path; single-stage adder for now (see tasks.md T-M0-01 note).
//
// Port note: i2s_bck -> pin U20, i2s_lrck -> pin T20 (LVCMOS33); pin
// constraints are the responsibility of T-M0-09 (instrec_top.fdc).
// -----------------------------------------------------------------------------
module i2s_clk_gen #(
    // NCO step for BCK toggle rate 2.8224 MHz at 216 MHz time base:
    // round(2^28 x 49/3750) = 3507557 (see header note for derivation).
    parameter [27:0] NCO_STEP = 28'd3507557
) (
    input  wire       clk_nco,    // 216 MHz NCO time base (from audio_pll)
    input  wire       rst_n,      // clk_nco-domain reset, sync release
    output reg  [4:0] bck_phase,  // frame phase 0..31 (one half frame)
    output reg        bck_tick,   // BCK half-period enable pulse
    output reg        i2s_bck,    // I2S bit clock pin register (U20)
    output reg        i2s_lrck    // I2S frame clock pin register (T20)
);

    // ------------------------------------------------------------------
    // 28-bit phase accumulator: overflow flag = bck_tick (registered so
    // the tick, the phase counter and the pin registers all change in
    // the same clk_nco cycle).
    // ------------------------------------------------------------------
    reg [27:0] phase_acc;

    // Full-precision add: bit 28 is the wrap-around indicator.
    // Declared separately from the assign so lint tools read the
    // initializer expression as an expression, not a name list.
    wire [28:0] acc_ext;

    assign acc_ext = {1'b0, phase_acc} + {1'b0, NCO_STEP};

    always @(posedge clk_nco or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc <= 28'd0;
            bck_tick  <= 1'b0;
            bck_phase <= 5'd0;
            i2s_bck   <= 1'b0;   // BCK starts low
            i2s_lrck  <= 1'b0;   // LRCK starts low = LEFT channel
        end else begin
            // Tick is a single-cycle pulse: the overflow indicator is
            // registered, and phase_acc wraps naturally modulo 2^28.
            bck_tick <= acc_ext[28];
            phase_acc <= acc_ext[27:0];

            if (acc_ext[28]) begin
                // BCK toggles on every half-period tick (50% duty).
                i2s_bck <= ~i2s_bck;

                // Frame phase advances 0..31, one half frame = 32 ticks.
                if (bck_phase == 5'd31) begin
                    bck_phase <= 5'd0;
                    // LRCK toggles on the phase 31 -> 0 boundary, in the
                    // same cycle as the BCK falling edge (Philips).
                    i2s_lrck <= ~i2s_lrck;
                end else begin
                    bck_phase <= bck_phase + 5'd1;
                end
            end
        end
    end

endmodule