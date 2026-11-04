// ---------------------------------------------------------------------------
// tb_ui_render.sv -- ui_renderer four-layer compositing regression
//
// The UI bitstream already passed on the board (T9), so this TB is a
// regression guard for the two things a refactor can silently break:
//
//   1. compositor priority  bars > text > spectrogram > base/waveform
//      (ui_overlay header), checked pixel by pixel with distinctive RGB
//      constants per layer;
//   2. the 4-cycle rgb/de alignment: 3 stages in waveform_disp plus 1 in
//      ui_overlay.  The TB drives a real pixel raster and compares every
//      de_out pixel against the layer that was on 4 cycles earlier.
//
// Self-validation: swap the bars/text priority in ui_overlay and the
// x = 0..9 window check must fail; drop one pipe stage and the alignment
// check must fail.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_ui_render;

    localparam integer CLK_HALF = 5;

    localparam [23:0] SPEC_RGB = 24'h12_34_56;
    localparam [23:0] TEXT_RGB = 24'h65_43_21;
    localparam [23:0] BARS_RGB = 24'hAA_BB_CC;

    reg pix_clk = 1'b0;
    reg rst_pix_n = 1'b0;
    always #(CLK_HALF) pix_clk = ~pix_clk;

    reg  [10:0] pix_x = 11'd0;
    reg  [10:0] pix_y = 11'd0;
    reg         pix_de = 1'b0;
    reg         pix_hs = 1'b0;
    reg         pix_vs = 1'b0;

    wire [10:0] wave_rd_addr;
    wire        vsync_pulse;

    wire [23:0] rgb;
    wire        de_out;
    wire        hs_out;
    wire        vs_out;

    // Layer enables are a pure function of the pixel being emitted.  ui_overlay
    // samples them on the de_pipe[2] stage (3 cycles), so the enable must be
    // derived from the pixel driven 3 cycles ago (x_d3); the resulting rgb is
    // then registered once more and lands next to x_d4.
    reg spec_on, text_on, bars_on;
    always @* begin
        spec_on = (x_d3 < 11'd40);
        text_on = (x_d3 < 11'd20);
        bars_on = (x_d3 < 11'd10);
    end

    ui_renderer #(
        .WAVE_REGION_ROWS (11'd300)
    ) dut (
        .pix_clk        (pix_clk),
        .rst_pix_n      (rst_pix_n),
        .pix_x          (pix_x),
        .pix_y          (pix_y),
        .pix_de         (pix_de),
        .pix_hs         (pix_hs),
        .pix_vs         (pix_vs),
        .wave_rd_addr   (wave_rd_addr),
        .wave_min       (16'd0),
        .wave_max       (16'd0),
        .wave_valid     (1'b0),
        .mute_flag_sync (1'b0),
        .vsync_pulse    (vsync_pulse),
        .spec_rgb       (SPEC_RGB),
        .spec_on        (spec_on),
        .text_rgb       (TEXT_RGB),
        .text_on        (text_on),
        .bars_rgb       (BARS_RGB),
        .bars_on        (bars_on),
        .rgb            (rgb),
        .de_out         (de_out),
        .hs_out         (hs_out),
        .vs_out         (vs_out)
    );

    // -----------------------------------------------------------------
    // 4-cycle delay references (3 waveform stages + 1 overlay stage)
    // -----------------------------------------------------------------
    reg [10:0] x_d1, x_d2, x_d3, x_d4;
    reg        de_d1, de_d2, de_d3, de_d4;
    reg        hs_d1, hs_d2, hs_d3, hs_d4;

    always @(posedge pix_clk) begin
        if (!rst_pix_n) begin
            x_d1 <= 11'd0; x_d2 <= 11'd0; x_d3 <= 11'd0; x_d4 <= 11'd0;
            de_d1 <= 1'b0; de_d2 <= 1'b0; de_d3 <= 1'b0; de_d4 <= 1'b0;
            hs_d1 <= 1'b0; hs_d2 <= 1'b0; hs_d3 <= 1'b0; hs_d4 <= 1'b0;
        end else begin
            x_d1 <= pix_x;  x_d2 <= x_d1;  x_d3 <= x_d2;  x_d4 <= x_d3;
            de_d1 <= pix_de; de_d2 <= de_d1; de_d3 <= de_d2; de_d4 <= de_d3;
            hs_d1 <= pix_hs; hs_d2 <= hs_d1; hs_d3 <= hs_d2; hs_d4 <= hs_d3;
        end
    end

    // -----------------------------------------------------------------
    // Pixel checker
    // -----------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;
    integer pixels = 0;
    integer prio_mism = 0;
    integer align_mism = 0;
    reg [23:0] expect_rgb;

    always @(posedge pix_clk) begin
        if (rst_pix_n && de_out) begin
            pixels = pixels + 1;
            // reference pixel is the one driven 4 cycles ago
            if (x_d4 < 11'd10)       expect_rgb = BARS_RGB;
            else if (x_d4 < 11'd20)  expect_rgb = TEXT_RGB;
            else if (x_d4 < 11'd40)  expect_rgb = SPEC_RGB;
            else                     expect_rgb = 24'hxx_xx_xx;   // base layer

            if (x_d4 < 11'd40 && rgb !== expect_rgb) begin
                prio_mism = prio_mism + 1;
                if (prio_mism <= 5)
                    $display("MISMATCH_DETAIL ui x=%0d expected=%06h observed=%06h",
                             x_d4, expect_rgb, rgb);
            end

            // de_out must be pix_de delayed by exactly 4 cycles
            if (de_out !== de_d4) begin
                align_mism = align_mism + 1;
                if (align_mism <= 5)
                    $display("MISMATCH_DETAIL ui de alignment: de_out=%0b de_d4=%0b x=%0d",
                             de_out, de_d4, x_d4);
            end
        end
    end

    task automatic check;
        input [511:0] name;
        input         ok;
        begin
            checks = checks + 1;
            if (ok) $display("CHECK PASS: %0s", name);
            else begin
                errors = errors + 1;
                $display("CHECK FAIL: %0s", name);
            end
        end
    endtask

    // -----------------------------------------------------------------
    // Raster
    // -----------------------------------------------------------------
    integer i;

    initial begin
        $display("=== tb_ui_render start ===");
        rst_pix_n = 1'b0;
        repeat (6) @(posedge pix_clk);
        rst_pix_n = 1'b1;
        repeat (3) @(posedge pix_clk);

        // horizontal sync pulse, then one active line of 64 pixels
        pix_hs <= 1'b1;
        repeat (4) @(posedge pix_clk);
        pix_hs <= 1'b0;

        pix_de  <= 1'b1;
        for (i = 0; i < 64; i = i + 1) begin
            pix_x <= i[10:0];
            pix_y <= 11'd0;
            @(posedge pix_clk);
        end
        pix_de <= 1'b0;
        repeat (8) @(posedge pix_clk);

        $display("OBS: pixels=%0d prio_mism=%0d align_mism=%0d hs_out=%0b hs_d4=%0b",
                 pixels, prio_mism, align_mism, hs_out, hs_d4);
        check("64 active pixels observed", pixels >= 60);
        check("layer priority bars>text>spec holds", prio_mism == 0);
        check("rgb/de aligned to 4-cycle pipeline", align_mism == 0);

        $display("=== tb_ui_render done: %0d checks, %0d errors ===", checks, errors);
        if (errors == 0) begin
            $display("RESULT: PASS tb_ui_render");
            $finish;
        end else begin
            $display("RESULT: FAIL tb_ui_render (%0d errors)", errors);
            $fatal(1, "tb_ui_render failed");
        end
    end

    initial begin : watchdog
        #(2ms);
        $display("ERROR: tb_ui_render watchdog (pixels=%0d)", pixels);
        $fatal(1, "tb_ui_render timeout");
    end

endmodule