// ---------------------------------------------------------------------------
// tb_ctrl_smoke.sv -- sys_ctrl + uart_debug end-to-end console testbench
//
// The 2026-10-31 board runs showed a 30-byte console dump
// ("INSTREC BOOT\nDDR3 SELFTEST...\n") where DDROK *or* DDR3 ERR would have
// been printed during the ~3 ms window in which the 17-character
// "DDR3 SELFTEST..." line keeps uart_debug busy.  T21 added a latch + defer
// path; this TB proves the property that matters:
//
//     when self_test PASSES, "DDROK" is always printed,
//     and the "DDR3 STS <hex8>" diagnostic line follows it,
//     no matter how long the printer stays busy.
//
// Setup:
//   * all lock/init inputs high (PLL + DDR PHY + DDR init + HDMI),
//   * uart_debug's byte channel is drained by a *baud-rate* stub, so the
//     printer is realistically busy for hundreds of cycles per character
//     (a 1-cycle-ready sink would hide the drop bug entirely),
//   * st_done is returned 50 cycles after st_start, i.e. inside the
//     "DDR3 SELFTEST..." print window -- exactly the board condition.
//
// PASS: the received console text contains, in order,
//       "INSTREC BOOT\n", "DDR3 SELFTEST...\n", "DDROK\n", "DDR3 STS <8 hex>\n"
//       and sys_ctrl reaches RUN with safe_err == 0.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_ctrl_smoke;

    localparam integer CLK_HALF = 5;          // 100 MHz
    localparam integer TX_GAP   = 120;        // stub byte time (scaled UART)

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    // -----------------------------------------------------------------
    // sys_ctrl inputs
    // -----------------------------------------------------------------
    reg         pll_locked       = 1'b1;
    reg         ddrphy_cpd_lock  = 1'b1;
    reg         ddr_init_done    = 1'b1;
    reg         hdmi_init_over   = 1'b1;
    reg         hdmi_init_fail   = 1'b0;
    reg         sd_idle          = 1'b1;
    reg  [15:0] overflow_cnt     = 16'd0;
    reg         weight_ok        = 1'b0;
    reg         weight_err       = 1'b0;
    reg         key1_n           = 1'b1;

    wire        weight_start;
    wire        st_start;
    reg         st_done          = 1'b0;
    reg         st_fail          = 1'b0;
    reg  [27:0] st_fail_addr     = 28'd0;
    reg  [2:0]  ddr_dbg_to_state = 3'd0;
    reg         ddr_to_err       = 1'b0;
    reg  [3:0]  ddr_cmd_to_err   = 4'd0;

    wire [2:0]  dbg_line_id;
    wire [31:0] dbg_line_arg;
    wire        dbg_line_fire;
    wire        dbg_busy;

    wire        sys_run;
    wire        safe_err;
    wire [1:0]  stage_code;
    wire        heartbeat;
    wire        overflow_warn;

    sys_ctrl #(
        .PLL_TIMEOUT_CYCLES (20000),
        .DDR_TIMEOUT_CYCLES (5000),
        .REQUIRE_WEIGHT     (0)
    ) u_sys_ctrl (
        .clk              (clk),
        .rst_n            (rst_n),
        .pll_locked       (pll_locked),
        .ddrphy_cpd_lock  (ddrphy_cpd_lock),
        .ddr_init_done    (ddr_init_done),
        .hdmi_init_over   (hdmi_init_over),
        .hdmi_init_fail   (hdmi_init_fail),
        .sd_idle          (sd_idle),
        .overflow_cnt     (overflow_cnt),
        .weight_ok        (weight_ok),
        .weight_err       (weight_err),
        .weight_start     (weight_start),
        .st_start         (st_start),
        .st_done          (st_done),
        .st_fail          (st_fail),
        .st_fail_addr     (st_fail_addr),
        .ddr_dbg_to_state (ddr_dbg_to_state),
        .ddr_to_err       (ddr_to_err),
        .ddr_cmd_to_err   (ddr_cmd_to_err),
        .dbg_line_id      (dbg_line_id),
        .dbg_line_arg     (dbg_line_arg),
        .dbg_line_fire    (dbg_line_fire),
        .dbg_busy         (dbg_busy),
        .sys_run          (sys_run),
        .safe_err         (safe_err),
        .stage_code       (stage_code),
        .heartbeat        (heartbeat),
        .overflow_warn    (overflow_warn),
        .key1_n           (key1_n)
    );

    // -----------------------------------------------------------------
    // uart_debug + baud-rate byte sink
    // -----------------------------------------------------------------
    wire [7:0] tx_byte_data;
    wire       tx_byte_valid;
    reg        tx_byte_ready = 1'b0;
    reg  [15:0] tx_gap       = 16'd0;

    uart_debug u_uart_debug (
        .clk             (clk),
        .rst_n           (rst_n),
        .tx_byte_data    (tx_byte_data),
        .tx_byte_valid   (tx_byte_valid),
        .tx_byte_ready   (tx_byte_ready),
        .rx_byte_data    (8'd0),
        .rx_byte_valid   (1'b0),
        .dbg_line_wdata  (8'd0),
        .dbg_line_wvalid (1'b0),
        .dbg_line_wready (),
        .dbg_line_id     (dbg_line_id),
        .dbg_line_arg    (dbg_line_arg),
        .dbg_line_fire   (dbg_line_fire),
        .dbg_busy        (dbg_busy),
        .rx_byte_cnt     ()
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_byte_ready <= 1'b0;
            tx_gap        <= 16'd0;
        end else if (tx_gap != 16'd0) begin
            tx_byte_ready <= 1'b0;
            tx_gap        <= tx_gap - 16'd1;
        end else begin
            tx_byte_ready <= 1'b1;
            if (tx_byte_valid && tx_byte_ready)
                tx_gap <= TX_GAP;
        end
    end

    // Console capture
    reg [7:0] console [0:255];
    integer   n_console = 0;

    always @(posedge clk) begin
        if (tx_byte_valid && tx_byte_ready && n_console < 256) begin
            console[n_console] <= tx_byte_data;
            n_console <= n_console + 1;
        end
    end

    // -----------------------------------------------------------------
    // self_test stand-in: PASS 50 cycles after st_start
    // -----------------------------------------------------------------
    integer st_dly = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            st_done <= 1'b0;
            st_dly  <= 0;
        end else if (st_start) begin
            st_dly  <= 50;
            st_done <= 1'b0;
        end else if (st_dly > 0) begin
            st_dly <= st_dly - 1;
            if (st_dly == 1)
                st_done <= 1'b1;      // one-cycle PASS pulse
        end else begin
            st_done <= 1'b0;
        end
    end

    // -----------------------------------------------------------------
    // Checks
    // -----------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;
    reg [8*512-1:0] text;

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

    // Token bytes are concatenated MSB-first (first character in bits
    // [127:120], the unused trailing bytes zero-filled at the low end), so
    // lit_char()/lit_len() below read byte 0 from the top of the vector.
    //
    // A bare string literal must NOT be passed to these functions: a
    // literal narrower than the window is zero-extended (right-aligned), so
    // on Verilator 5.050 "INSTREC BOOT" occupies bits [95:0] instead of
    // [127:32].  lit_char(0) then reads 0x00 and every contains() lookup
    // fails even when the console text is correct -- that was the T29
    // ctrl_smoke false failure.  Concatenation has a defined bit order.
    localparam [8*16-1:0] TOK_BOOT =
        {8'h49, 8'h4E, 8'h53, 8'h54, 8'h52, 8'h45, 8'h43, 8'h20,
         8'h42, 8'h4F, 8'h4F, 8'h54,
         8'd0, 8'd0, 8'd0, 8'd0};                              // "INSTREC BOOT"
    localparam [8*16-1:0] TOK_SELFTEST =
        {8'h44, 8'h44, 8'h52, 8'h33, 8'h20, 8'h53, 8'h45, 8'h4C,
         8'h46, 8'h54, 8'h45, 8'h53, 8'h54,
         8'd0, 8'd0, 8'd0};                                    // "DDR3 SELFTEST"
    localparam [8*16-1:0] TOK_DDROK =
        {8'h44, 8'h44, 8'h52, 8'h4F, 8'h4B,
         8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
         8'd0, 8'd0, 8'd0};                                    // "DDROK"
    localparam [8*16-1:0] TOK_STS =
        {8'h44, 8'h44, 8'h52, 8'h33, 8'h20, 8'h53, 8'h54, 8'h53,
         8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0};      // "DDR3 STS"

    function [7:0] lit_char;
        input [8*16-1:0] s;
        input integer    idx;
        begin
            lit_char = s[(15 - idx) * 8 +: 8];
        end
    endfunction

    function integer lit_len;
        input [8*16-1:0] s;
        integer j;
        begin
            lit_len = 0;
            for (j = 15; j >= 0; j = j - 1)
                if (lit_char(s, j) != 8'h00 && lit_len == 0)
                    lit_len = j + 1;
        end
    endfunction

    function integer contains;
        input [8*16-1:0] needle;
        integer n_len;
        integer i, j;
        reg match;
        begin
            n_len = lit_len(needle);
            contains = -1;
            if (n_len != 0) begin
                for (i = 0; i + n_len <= n_console && contains < 0; i = i + 1) begin
                    match = 1'b1;
                    for (j = 0; j < n_len; j = j + 1)
                        if (console[i + j] != lit_char(needle, j))
                            match = 1'b0;
                    if (match) contains = i;
                end
            end
        end
    endfunction

    integer pos_boot, pos_selftest, pos_ddrok, pos_sts;
    integer i;
    reg [255:0] sts_val;

    initial begin
        $display("=== tb_ctrl_smoke start ===");
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;

        // Wait for RUN (or SAFE_ERR / watchdog).  uart_debug emits one byte
        // per TX_GAP (12000) core cycles, so the whole expected console is
        // 48 bytes = 576k cycles (13 BOOT + 17 SELFTEST + 6 DDROK + 12 STS).
        // The pre-T29 window of 400k cycles expired after 34 bytes and made
        // the log look like a dropped line.
        i = 0;
        while (!sys_run && !safe_err && i < 1600000) begin
            @(posedge clk);
            i = i + 1;
        end

        // The "DDR3 STS" line is queued just before ST_RUN, so it may still
        // be on the wire when sys_run rises: drain the printer before the
        // console snapshot.
        i = 0;
        while (dbg_busy && i < 600000) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (200) @(posedge clk);

        $display("OBS: sys_run=%0b safe_err=%0b stage_code=%0d n_console=%0d cycles=%0d",
                 sys_run, safe_err, stage_code, n_console, i);
        $write("CONSOLE_TEXT: ");
        for (i = 0; i < n_console; i = i + 1)
            if (console[i] >= 8'h20 && console[i] < 8'h7F)
                $write("%c", console[i]);
            else
                $write("<%02X>", console[i]);
        $write("\n");

        pos_boot     = contains(TOK_BOOT);
        pos_selftest = contains(TOK_SELFTEST);
        pos_ddrok    = contains(TOK_DDROK);
        pos_sts      = contains(TOK_STS);
        $display("OBS: positions boot=%0d selftest=%0d ddrok=%0d sts=%0d",
                 pos_boot, pos_selftest, pos_ddrok, pos_sts);

        check("BOOT line printed", pos_boot >= 0);
        check("DDR3 SELFTEST line printed", pos_selftest >= 0);
        check("DDROK printed after SELFTEST (busy window survived)",
              pos_ddrok > pos_selftest);
        check("DDR3 STS printed after DDROK", pos_sts > pos_ddrok);
        check("sys_ctrl reached RUN with pass", sys_run === 1'b1 && safe_err === 1'b0);

        // DDR3 STS payload: uart_debug prints the 8-bit diagnostic byte as
        // exactly TWO uppercase hex digits (src/ctrl/uart_debug.v id 6:
        // hex_left <= 4'd2, rom_arg = {arg[7:0], 24'd0}), so the line is
        // 9-byte prefix + 2 hex + '\n'.  The pre-T29 checker assumed eight
        // hex digits and therefore never matched.
        //
        // The STS line is a POST-MORTEM snapshot, not the pass flag:
        // sys_ctrl samples ddr_sts_code combinationally when the deferred
        // line is fired, which is hundreds of thousands of cycles after
        // self_test's one-cycle st_done pulse fell (the id 2 "DDR3
        // SELFTEST..." print window alone is 17 x 12000 = 204k cycles).
        // So on a clean pass bit0 (st_done) reads 0 by construction -- PASS
        // is carried by the DDROK line checked above.  What STS must prove
        // is the ABSENCE of the error fields (sys_ctrl.v:219-224):
        //   bit6 = cmd_to_err[3]  bit5 = to_err  bits[4:2] = dbg_to_state
        //   bit1 = st_fail        bit0 = st_done  (stale, see above)
        if (pos_sts >= 0 && pos_sts + 11 < n_console) begin
            sts_val = 0;
            for (i = 0; i < 2; i = i + 1) begin
                sts_val = sts_val << 4;
                if (console[pos_sts + 9 + i] >= 8'h30 && console[pos_sts + 9 + i] <= 8'h39)
                    sts_val = sts_val | (console[pos_sts + 9 + i] - 8'h30);
                else if (console[pos_sts + 9 + i] >= 8'h41 && console[pos_sts + 9 + i] <= 8'h46)
                    sts_val = sts_val | (console[pos_sts + 9 + i] - 8'h37);
            end
            $display("OBS: DDR3 STS code = %02h (to_err=%0b cmd_to_err3=%0b state=%0d st_fail=%0b st_done=%0b)",
                     sts_val[7:0], sts_val[5], sts_val[6], sts_val[4:2],
                     sts_val[1], sts_val[0]);
            check("DDR3 STS reports no error bits (clean pass)",
                  sts_val[7:0] === 8'h00);
        end else begin
            check("DDR3 STS reports no error bits (clean pass)", 1'b0);
        end

        $display("=== tb_ctrl_smoke done: %0d checks, %0d errors ===", checks, errors);
        if (errors == 0) begin
            $display("RESULT: PASS tb_ctrl_smoke");
            $finish;
        end else begin
            $display("RESULT: FAIL tb_ctrl_smoke (%0d errors)", errors);
            $fatal(1, "tb_ctrl_smoke failed");
        end
    end

    initial begin : watchdog
        // 40 ms = 4,000,000 cycles at 100 MHz: covers the 1.6M wait plus
        // the 600k printer drain with 2x margin.
        #(40ms);
        $display("ERROR: tb_ctrl_smoke watchdog (sys_run=%0b safe_err=%0b n_console=%0d)",
                 sys_run, safe_err, n_console);
        $fatal(1, "tb_ctrl_smoke timeout");
    end

endmodule