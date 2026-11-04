// -----------------------------------------------------------------------------
// File    : demo_wave_source.v
// Module  : demo_wave_source
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Contract: C-TOP-UI-DEMO@1 (plan revision P1, section 2.2.5)
//
// Purpose : On-chip fake waveform envelope source for the stand-alone UI
//           demo bitstream (T7). It replaces the audio_sink column buffer
//           that normally feeds waveform_disp, so the M3 pixel pipeline can
//           be brought up on HDMI without any audio / DDR3 / NPU path.
//
// Read contract (see waveform_disp.v header, EXIST-UI-LAYERS):
//   * wave_rd_addr is a purely combinational copy of pix_x, presented in
//     the same cycle as pix_x (combinational inside ui_renderer);
//   * wave_min / wave_max must be valid exactly one pix_clk cycle after the
//     address and hold for that one cycle  ->  both are pix_clk registers
//     here, loaded with the combinational decode of the SAME cycle's
//     wave_rd_addr;
//   * wave_valid is a quasi-static column-buffer-ready level  ->  tied to
//     a constant 1, because the fake data is always available.
//
// Fake envelope formula (contract, section 2.2.5):
//   tri(addr) = (addr < 960) ? addr : (1919 - addr)     -> 0..959
//   amp       = tri * 16                                -> 0..15344
//   wave_max  = amp                                     (16-bit, zero extended)
//   wave_min  = -amp                                    (16-bit two's complement)
//
// Overflow proof (no clamp needed anywhere):
//   wave_rd_addr is 11 bits, so tri is at most 2047 for any address value
//   (the subtraction wraps modulo 2048 when addr > 1919, which can only
//   happen while pix_de = 0, where waveform_disp ignores the data). The
//   shift gives amp <= 2047 * 16 = 32752 < 32768, so amp always fits in the
//   positive half of a 16-bit two's complement word; -amp therefore always
//   fits as well and wave_min / wave_max can never overflow. For the
//   active-area addresses 0..1919 that waveform_disp actually uses, amp is
//   bounded by 959 * 16 = 15344, i.e. 47 percent of the positive range.
//
// No string literals, no clock domain other than pix_clk.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module demo_wave_source (
    // Pixel clock domain (148.5 MHz) and reset from hdmi_tx_if.
    input  wire        pix_clk,
    input  wire        rst_pix_n,

    // Column read address, combinational copy of pix_x (0..1919 active).
    input  wire [10:0] wave_rd_addr,

    // Envelope pair, valid exactly one pix_clk cycle after the address.
    output reg  [15:0] wave_min,   // int16 negative lobe
    output reg  [15:0] wave_max,   // int16 positive lobe

    // Column-ready level, quasi-static, always 1 for the fake source.
    output wire        wave_valid
);

    // ------------------------------------------------------------------
    // Stage 1: combinatorial triangle decode of the current address.
    // ------------------------------------------------------------------
    wire [10:0] tri_val = (wave_rd_addr < 11'd960) ? wave_rd_addr
                                                  : (11'd1919 - wave_rd_addr);

    // amp = tri * 16 = tri << 4, 15 bits (max 32752, see the header proof).
    wire [14:0] amp = {tri_val, 4'd0};

    // ------------------------------------------------------------------
    // Stage 2: register the envelope pair. Placing the registers here makes
    // the producer latency exactly one pix_clk cycle, which is what the
    // waveform_disp read contract requires.
    // ------------------------------------------------------------------
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            wave_max <= 16'd0;
            wave_min <= 16'd0;
        end else begin
            wave_max <= {1'b0, amp};
            wave_min <= (~{1'b0, amp}) + 16'd1;   // -amp, two's complement
        end
    end

    // ------------------------------------------------------------------
    // Column buffer is always ready: the data is generated on chip.
    // ------------------------------------------------------------------
    assign wave_valid = 1'b1;

endmodule