// -----------------------------------------------------------------------------
// File    : demo_spec_source.v
// Module  : demo_spec_source
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Contract: C-TOP-UI-DEMO@1 (plan revision P1, section 2.2.5)
//
// Purpose : On-chip fake Mel spectrogram page for the stand-alone UI demo
//           bitstream (T7). It replaces feat_page_buf / feat_copy_engine, so
//           spectrum_disp can be brought up on HDMI without any Mel / NPU /
//           DDR3 path.
//
// Read contract (see spectrum_disp.v header, EXIST-UI-LAYERS):
//   * spectrum_disp issues ram_addr (15-bit, row-major 64 x 258 page) from
//     its own registered address stage;
//   * ram_data must be a synchronous read return with exactly one pix_clk
//     cycle of latency  ->  ram_data is a pix_clk register here, loaded from
//     the SAME cycle's ram_addr decode, exactly like the BRAM read port of
//     feat_page_buf.v (whose rd_data is also one pix_clk register);
//   * page_ready is the page-available level  ->  constant 1.
//
// Fake page content (contract, section 2.2.5, fixed formula):
//   ram_data = ram_addr[14:7]
// With a row-major page of 258 entries per row, bits [14:7] address whole
// 128-entry groups, so the page shows 128 distinct horizontal bands
// (ram_addr[14:7] is monotonic in the row coordinate), which is enough to
// make spec_on / de_nonzero counters non-zero on every frame.
//
// No string literals, no clock domain other than pix_clk.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module demo_spec_source (
    // Pixel clock domain (148.5 MHz) and reset from hdmi_tx_if.
    input  wire        pix_clk,
    input  wire        rst_pix_n,

    // Page read address from spectrum_disp (row-major 64 x 258).
    input  wire [14:0] ram_addr,

    // Page read data, valid exactly one pix_clk cycle after ram_addr.
    output reg  [7:0]  ram_data,

    // Page-available level, quasi-static, always 1 for the fake page.
    output wire        page_ready
);

    // ------------------------------------------------------------------
    // Synchronous read: the register load is the one-cycle latency the
    // spectrum_disp read port expects.
    // ------------------------------------------------------------------
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n)
            ram_data <= 8'd0;
        else
            ram_data <= ram_addr[14:7];
    end

    // ------------------------------------------------------------------
    // Page is always valid once the pixel domain is out of reset.
    // ------------------------------------------------------------------
    assign page_ready = 1'b1;

endmodule