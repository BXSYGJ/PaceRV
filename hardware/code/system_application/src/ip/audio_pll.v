// -----------------------------------------------------------------------------
// audio_pll - 216 MHz time base for the I2S NCO (design.md Sec. 1.2, scheme B)
// -----------------------------------------------------------------------------
// Wraps the PDS clock-synthesis IP (GPLL instance, "GPLL_D" in the clock
// tree): 27 MHz reference in, 216 MHz integer multiply out (M=8, D=1, no
// fractional mode => zero theoretical error against the 27 MHz crystal).
// The instantiated module "pll_audio" is a PDS IP Compiler generated
// clock core (to be generated with PDS IP Compiler: 27 MHz input ->
// 216 MHz output, integer M=8/D=1, GPLL resource; artifact lands in
// ipcore/pll_audio/ during build integration T-M0-09). Until that
// artifact is generated, synthesis reporting an undefined-module for
// pll_audio is EXPECTED. Port names follow the verified demo core style
// ("pll u_pll(.clkin1/.clkout0/.lock)").
//
// Also produces the clk_nco-domain reset per design.md Sec. 1.3 reset tree:
// asynchronous assert (KEY0 system reset or GPLL lock loss - the safe
// state entry point of REQ-REL-001), two-FF synchronized release
// (REQ-SYS-002). While the PLL is unlocked the audio domain is held in
// reset even if clk_nco has already started toggling.
//
// Pin note (T-M0-09 fdc responsibility): clk_27m comes from the board
// oscillator on pin D18; no pin constraints live in this module.
// -----------------------------------------------------------------------------
module audio_pll (
    input  wire clk_27m,       // 27 MHz board oscillator (pin D18)
    input  wire rst_n,         // asynchronous system reset (KEY0, active low)
    output wire clk_nco,       // 216 MHz NCO time base (GPLL output)
    output wire pll_locked,    // GPLL lock status, raw from the IP
    output wire rst_sync_nco   // clk_nco-domain reset, sync release
);

    // ------------------------------------------------------------------
    // GPLL instantiation: PDS clock IP wrapper (generated core).
    // Core parameters: clkin 27 MHz, clkout0 216 MHz, integer mode
    // M=8 / D=1, 50% duty. Port names follow the demo "pll" core style.
    // ------------------------------------------------------------------
    pll_audio u_pll_audio (
        .clkin1  (clk_27m),
        .clkout0 (clk_nco),
        .lock    (pll_locked)
    );

    // ------------------------------------------------------------------
    // clk_nco-domain reset: async assert, sync release, lock-gated.
    // Two asynchronous assert sources (KEY0 system reset, PLL lock loss)
    // are written as multiple async reset events in the sensitivity
    // list (legal SV-2005); release is synchronized to clk_nco by a
    // two-stage pipe so no consumer sees a releasing edge near the
    // clock edge (metastability-free release).
    // ------------------------------------------------------------------
    reg [1:0] rst_sync_pipe;

    always @(posedge clk_nco or negedge rst_n or negedge pll_locked) begin
        if (!rst_n || !pll_locked) begin
            rst_sync_pipe <= 2'b00;
        end else begin
            rst_sync_pipe <= {rst_sync_pipe[0], 1'b1};
        end
    end

    assign rst_sync_nco = rst_sync_pipe[1];

endmodule