// ---------------------------------------------------------------------------
// tb_weight_loader.sv -- direct-drive testbench for src/ctrl/weight_loader.v
//
// Board symptom this TB replaces: the WOK line produced no reply in three
// board runs (T11/T20), so the write-then-read-back digest path was never
// proven.  Here the whole UART framing + DDR3 master-1 write/read-back loop
// runs against a behavioural controller:
//
//   write command -> len+1 wready_beat pulses, `done` on the last beat
//   read  command -> `done` first, then len+1 rd_valid beats from the model
//
// Checks:
//   A. four 256-byte chunks (seq 0..3) + end frame
//        -> 'K' after every chunk, "WOK <8hex>\n" once, weight_ok, no error,
//           frame_cnt = 4, digest identical to the byte-model accumulator
//   B. one chunk with a corrupted payload byte (CRC mismatch)
//        -> 'N', weight_err set, no weight_ok
//   C. replayed good chunk after the reset -> recovered ('K' again)
//
// The digest arithmetic is folded exactly like the RTL:
//   acc0 += beat[31:0]   + beat[159:128]
//   acc1 += beat[63:32]  + beat[191:160]
//   acc2 += beat[95:64]  + beat[223:192]
//   acc3 += beat[127:96] + beat[255:224]
//   digest = acc0 ^ acc1 ^ acc2 ^ acc3        (all modulo 2^32)
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_weight_loader;

    localparam integer CLK_HALF = 5;         // 100 MHz
    localparam integer CHUNK    = 256;       // bytes per frame
    localparam integer NCHUNK   = 4;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    // -----------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------
`ifdef PHYSICAL_UART_RX
    reg serial_rxd = 1'b1;
    wire rx_valid;
    wire [7:0] rx_data;
    uart_rx u_physical_rx(.clk(clk), .rst_n(rst_n), .uart_rxd(serial_rxd),
                          .byte_rdata(rx_data), .byte_rvalid(rx_valid));
`else
    reg         rx_valid = 1'b0;
    reg  [7:0]  rx_data  = 8'd0;
`endif

    wire        tx_valid;
    wire [7:0]  tx_data;
    reg         tx_ready = 1'b0;     // driven by the uart_tx stand-in below

    wire        cmd_valid;
    wire [36:0] cmd;
    wire [255:0] wdata;
    reg         wready_beat = 1'b0;
    reg         done        = 1'b0;

    wire        rd_ready;
    reg  [255:0] rd_data  = 256'd0;
    reg         rd_valid  = 1'b0;

    wire        busy;
    wire        weight_ok;
    wire        weight_err;
    wire [27:0] err_addr;
    wire [15:0] frame_cnt;
    wire [31:0] digest;

    weight_loader dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .rx_valid    (rx_valid),
        .rx_data     (rx_data),
        .tx_valid    (tx_valid),
        .tx_data     (tx_data),
        .tx_ready    (tx_ready),
        .cmd_valid   (cmd_valid),
        .cmd         (cmd),
        .wdata       (wdata),
        .wready_beat (wready_beat),
        .done        (done),
        .rd_ready    (rd_ready),
        .rd_data     (rd_data),
        .rd_valid    (rd_valid),
        .busy        (busy),
        .weight_ok   (weight_ok),
        .weight_err  (weight_err),
        .err_addr    (err_addr),
        .frame_cnt   (frame_cnt),
        .digest      (digest)
    );

    // -----------------------------------------------------------------
    // Payload image + byte-model DDR3 (4 x 256 B)
    // -----------------------------------------------------------------
    reg [7:0]  payload [0:NCHUNK*CHUNK-1];
    reg [31:0] mem32   [0:255];

    initial begin
`ifdef PHYSICAL_UART_RX
        $readmemh("build/sim/weight_loader_serial/payload.hex", payload);
`else
        $readmemh("build/sim/weight_loader/payload.hex", payload);
`endif
        $display("=== tb_weight_loader start ===");
    end

    // -----------------------------------------------------------------
    // DDR3 master-1 responder
    // -----------------------------------------------------------------
    localparam integer R_IDLE = 0;
    localparam integer R_DLY  = 1;
    localparam integer R_WB   = 2;
    localparam integer R_RB   = 3;

    reg [2:0]  rsp_state = R_IDLE;
    reg [36:0] c_cmd     = 37'd0;
    reg [27:0] c_addr    = 28'd0;
    reg [4:0]  beat      = 5'd0;
    reg [4:0]  nbeats    = 5'd0;
    integer    dly       = 0;
    integer    cool      = 0;

    // 256-bit beat <-> 8 x 32-bit word model helpers (word k = bits 32k)
    task automatic mem_wr;
        input [27:0]  addr;
        input [4:0]   idx;
        input [255:0] data;
        integer base;
        begin
            base = (addr[9:0] >> 2) + idx * 8;
            mem32[base + 0] <= data[31:0];
            mem32[base + 1] <= data[63:32];
            mem32[base + 2] <= data[95:64];
            mem32[base + 3] <= data[127:96];
            mem32[base + 4] <= data[159:128];
            mem32[base + 5] <= data[191:160];
            mem32[base + 6] <= data[223:192];
            mem32[base + 7] <= data[255:224];
        end
    endtask

    function [255:0] mem_rd;
        input [27:0] addr;
        input [4:0]  idx;
        integer base;
        begin
            base = (addr[9:0] >> 2) + idx * 8;
            mem_rd = {mem32[base + 7], mem32[base + 6], mem32[base + 5],
                      mem32[base + 4], mem32[base + 3], mem32[base + 2],
                      mem32[base + 1], mem32[base + 0]};
        end
    endfunction

    integer wr_beats = 0;
    integer rd_beats = 0;
    integer wr_cmds  = 0;
    integer rd_cmds  = 0;

    // rd_valid is presented by this model and sampled by the DUT on every
    // posedge; counting it at the same edge matches the DUT exactly.  The
    // pre-T29 counter lived inside R_RB and skipped the final beat (the last
    // rd_valid is presented one cycle before `done`), reporting 7 of 8.
    always @(posedge clk) begin
        if (rst_n && rd_valid) rd_beats <= rd_beats + 1;
    end

    // folded accumulator (mirror of the RTL, modulo 2^32)
    reg [31:0] acc0 = 32'd0, acc1 = 32'd0, acc2 = 32'd0, acc3 = 32'd0;
    wire [31:0] digest_c = acc0 ^ acc1 ^ acc2 ^ acc3;

    always @(posedge clk) begin
        done        <= 1'b0;
        wready_beat <= 1'b0;
        rd_valid    <= 1'b0;

        if (!rst_n) begin
            rsp_state <= R_IDLE;
            beat      <= 5'd0;
            dly       <= 0;
            cool      <= 0;
        end else begin
            case (rsp_state)
                R_IDLE: begin
                    if (cool > 0) begin
                        cool <= cool - 1;
                    end else if (cmd_valid) begin
                        c_cmd     <= cmd;
                        c_addr    <= cmd[35:8];
                        nbeats    <= cmd[7:0] + 5'd1;
                        beat      <= 5'd1;
                        dly       <= 2;
                        rsp_state <= R_DLY;
                        if (cmd[36]) wr_cmds <= wr_cmds + 1;
                        else         rd_cmds <= rd_cmds + 1;
                    end
                end
                R_DLY: begin
                    if (dly > 0) begin
                        dly <= dly - 1;
                    end else if (c_cmd[36]) begin
                        wready_beat <= 1'b1;    // beat 0 is consumed next cyc
                        rsp_state   <= R_WB;
                    end else begin
                        rd_data   <= mem_rd(c_addr, 5'd0);
                        rd_valid  <= 1'b1;      // beat 0 sampled next cycle
                        rsp_state <= R_RB;
                    end
                end
                R_WB: begin
                    // wready_beat is a register: this cycle the DUT samples
                    // the value set last cycle and consumes beat (beat-1).
                    mem_wr(c_addr, beat - 5'd1, wdata);
                    acc0 <= acc0 + wdata[31:0]   + wdata[159:128];
                    acc1 <= acc1 + wdata[63:32]  + wdata[191:160];
                    acc2 <= acc2 + wdata[95:64]  + wdata[223:192];
                    acc3 <= acc3 + wdata[127:96] + wdata[255:224];
                    wr_beats <= wr_beats + 1;

                    if (beat == nbeats) begin
                        done        <= 1'b1;    // last beat and done, same cycle
                        wready_beat <= 1'b0;
                        rsp_state   <= R_IDLE;
                        cool        <= 3;
                    end else begin
                        wready_beat <= 1'b1;
                        beat        <= beat + 5'd1;
                    end
                end
                R_RB: begin
                    // rd_data is a register: the beat presented last cycle
                    // is being sampled now (beat-1 already queued).
                    if (beat == nbeats) begin
                        done      <= 1'b1;      // last beat and done, same cycle
                        rsp_state <= R_IDLE;
                        cool      <= 3;
                    end else begin
                        rd_data   <= mem_rd(c_addr, beat[4:0]);
                        rd_valid  <= 1'b1;

                        beat      <= beat + 5'd1;
                    end
                end
                default: rsp_state <= R_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------
    // uart_tx stand-in (reference behaviour: src/ctrl/uart_tx.v:62-101)
    //
    // byte_wready is a REGISTERED ~busy, so it stays high for one extra
    // cycle after an accept, and the byte is only taken while !busy.
    // A constant-ready sink would capture weight_loader's held tx_valid
    // twice and print "KK" / "NN" for a single ACK -- that was the source
    // of the pre-T29 false failures; the RTL does not send twice.
    // -----------------------------------------------------------------
    localparam integer TX_FRAME = 40;        // scaled 10-bit frame time

    reg       tx_busy      = 1'b0;
    reg [7:0] tx_frame_cnt = 8'd0;

    wire tx_take = tx_valid && tx_ready && !tx_busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_ready     <= 1'b0;
            tx_busy      <= 1'b0;
            tx_frame_cnt <= 8'd0;
        end else begin
            tx_ready <= ~tx_busy;
            if (!tx_busy) begin
                if (tx_valid && tx_ready) begin
                    tx_busy      <= 1'b1;
                    tx_frame_cnt <= 8'd0;
                end
            end else if (tx_frame_cnt == TX_FRAME - 1) begin
                tx_busy      <= 1'b0;
                tx_frame_cnt <= 8'd0;
            end else begin
                tx_frame_cnt <= tx_frame_cnt + 8'd1;
            end
        end
    end

    // -----------------------------------------------------------------
    // UART sink (one captured byte per accepted frame)
    // -----------------------------------------------------------------
    reg [7:0] rx_text [0:63];
    integer   rx_len = 0;

    always @(posedge clk) begin
        if (tx_take && rx_len < 64) begin
            rx_text[rx_len] <= tx_data;
            rx_len <= rx_len + 1;
        end
    end

    // -----------------------------------------------------------------
    // Frame transmitter (UART model): AA 55 seq len payload crc
    // -----------------------------------------------------------------
    function [15:0] crc16_step;
        input [15:0] crc;
        input [7:0]  b;
        reg [15:0] c;
        integer i;
        begin
            c = crc ^ {b, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[15]) c = (c << 1) ^ 16'h1021;
                else       c = c << 1;
            end
            crc16_step = c;
        end
    endfunction

    task automatic send_byte;
        input [7:0] b;
        integer bit_index;
        begin
`ifdef PHYSICAL_UART_RX
            @(negedge clk);
            serial_rxd = 1'b0;
            repeat(1085) @(negedge clk);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                serial_rxd = b[bit_index];
                repeat(1085) @(negedge clk);
            end
            serial_rxd = 1'b1;
            repeat(1085) @(negedge clk);
`else
            rx_data  <= b;
            rx_valid <= 1'b1;
            @(posedge clk);
            rx_valid <= 1'b0;
            @(posedge clk);
`endif
        end
    endtask

    task automatic send_frame;
        input [15:0] seq;
        input        corrupt;      // flip one payload byte (CRC must fail)
        reg [15:0]   crc;
        integer      i;
        reg [7:0]    b;
        begin
            crc = 16'hFFFF;
            send_byte(8'hAA);
            send_byte(8'h55);
            send_byte(seq[7:0]);
            crc = crc16_step(crc, seq[7:0]);
            send_byte(seq[15:8]);
            crc = crc16_step(crc, seq[15:8]);
            send_byte(CHUNK[7:0]);                 // len low  = 0
            crc = crc16_step(crc, CHUNK[7:0]);
            send_byte(CHUNK[15:8]);                // len high = 1
            crc = crc16_step(crc, CHUNK[15:8]);
            for (i = 0; i < CHUNK; i = i + 1) begin
                // CRC always covers the ORIGINAL byte; the corrupted value
                // is only what goes out on the wire.  Folding the flipped
                // byte into the CRC as well (pre-T29 code) kept the frame
                // self-consistent, so weight_loader correctly accepted it
                // and weight_err stayed 0.
                b = payload[seq * CHUNK + i];
                crc = crc16_step(crc, b);
                if (corrupt && i == 37)
                    b = b ^ 8'h5A;
                send_byte(b);
            end
            send_byte(crc[7:0]);
            send_byte(crc[15:8]);
        end
    endtask

    task automatic send_end_frame;
        reg [15:0] crc;
        begin
            crc = 16'hFFFF;
            send_byte(8'hAA);
            send_byte(8'h55);
            send_byte(16'hFF);
            crc = crc16_step(crc, 8'hFF);
            send_byte(16'hFF);
            crc = crc16_step(crc, 8'hFF);
            send_byte(8'h00);
            crc = crc16_step(crc, 8'h00);
            send_byte(8'h00);
            crc = crc16_step(crc, 8'h00);
            send_byte(crc[7:0]);
            send_byte(crc[15:8]);
        end
    endtask

    // -----------------------------------------------------------------
    // Checks
    // -----------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;
    integer i;
    integer wok_len = 0;

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

    task automatic reset_dut;
        begin
            rst_n <= 1'b0;
`ifdef PHYSICAL_UART_RX
            serial_rxd <= 1'b1;
`else
            rx_valid <= 1'b0;
`endif
            repeat (5) @(posedge clk);
            rst_n <= 1'b1;
            repeat (3) @(posedge clk);
            rx_len = 0;
        end
    endtask

    // Real UART at 115200 / 125 MHz gives ~10868 core cycles per byte; this
    // TB sends one byte every 2 cycles (about 5400x faster).  weight_loader
    // does not sample rx while in S_WRITE / S_RD_* / S_ACK, so the next
    // frame must wait until the loader is back in S_IDLE -- otherwise the
    // following frames' header bytes are dropped and every frame after the
    // first is misaligned (pre-T29 evidence: only one write command issued).
    task automatic wait_loader_idle;
        begin
            while (busy) @(posedge clk);
            repeat (8) @(posedge clk);
        end
    endtask

    task automatic show_uart;
        integer j;
        begin
            $write("UART_TEXT: ");
            for (j = 0; j < rx_len; j = j + 1)
                if (rx_text[j] >= 8'h20 && rx_text[j] < 8'h7F)
                    $write("%c", rx_text[j]);
                else
                    $write("<%02X>", rx_text[j]);
            $write("\n");
        end
    endtask

    initial begin
        // -------------------------------------------------------------
        // A: four good chunks + end frame -> WOK
        // -------------------------------------------------------------
        reset_dut();
        for (i = 0; i < NCHUNK; i = i + 1) begin
            send_frame(i[15:0], 1'b0);
            wait_loader_idle();
        end
        send_end_frame();
        wait_loader_idle();

        // wait for weight_ok / weight_err
        i = 0;
        while (!weight_ok && !weight_err && i < 20000) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (16) @(posedge clk);

        $display("OBS A: frame_cnt=%0d weight_ok=%0b weight_err=%0b err_addr=%08h",
                 frame_cnt, weight_ok, weight_err, err_addr);
        $display("OBS A: rtl_digest=%08h tb_digest=%08h wr_cmds=%0d rd_cmds=%0d wr_beats=%0d rd_beats=%0d",
                 digest, digest_c, wr_cmds, rd_cmds, wr_beats, rd_beats);
        show_uart();

        check("A four chunks accepted (4 x 'K')",
              rx_len >= 5 &&
              rx_text[0] == 8'h4B && rx_text[1] == 8'h4B &&
              rx_text[2] == 8'h4B && rx_text[3] == 8'h4B);

        // ---- terminal "WOK <8hex>\n" line, byte by byte -----------------
        // RTL defect this TB now proves (deterministic, not a TB artefact):
        //   weight_loader drives tx_data <= tx_line[tx_pos] on EVERY cycle
        //   and advances tx_pos whenever tx_valid && tx_ready
        //   (weight_loader.v:363-374), but uart_tx accepts a byte only while
        //   !busy && wvalid && wready and keeps wready high for one extra
        //   cycle after an accept (uart_tx.v:72-79).  The loader therefore
        //   treats that extra ready cycle as a delivered byte although
        //   uart_tx did not take it -> every other character of the terminal
        //   line is dropped ("WOK 42851062\n" arrives as "WK4816\n").
        //   Reproduced with a REAL uart_tx instance as well as with the model
        //   above, and weight_upload.py:162 tests text.startswith('WOK'),
        //   which is why the board saw "no WOK reply".
        // The two checks below stay strict on purpose: fixing the RTL must
        // make them pass, loosening them would hide the board symptom.
        wok_len = rx_len - 4;
        $display("OBS A: terminal line bytes=%0d (expect 13)", wok_len);
        check("A terminal line starts with 'WOK'",
              wok_len >= 3 &&
              rx_text[4] == 8'h57 && rx_text[5] == 8'h4F && rx_text[6] == 8'h4B);
        check("A terminal line complete (13 = 'WOK ' + 8 hex + LF)",
              wok_len == 13 && rx_text[rx_len-1] == 8'h0A);

        check("A weight_ok", weight_ok === 1'b1 && weight_err === 1'b0);
        check("A frame_cnt = 4", frame_cnt == 16'd4);
        check("A write-then-read-back digest matches",
              digest === digest_c);
        check("A read-back covered all 4 chunks (rd_beats >= 32)",
              rd_beats >= 32);

        // -------------------------------------------------------------
        // B: corrupted chunk -> 'N'
        // -------------------------------------------------------------
        reset_dut();
        acc0 = 32'd0; acc1 = 32'd0; acc2 = 32'd0; acc3 = 32'd0;
        send_frame(16'd0, 1'b1);
        wait_loader_idle();
        $display("OBS B: weight_ok=%0b weight_err=%0b err_addr=%08h uart_len=%0d",
                 weight_ok, weight_err, err_addr, rx_len);
        show_uart();
        check("B corrupt CRC rejected (weight_err)", weight_err === 1'b1 && weight_ok === 1'b0);
        // One NAK byte: the uart_tx stand-in takes each byte exactly once.
        check("B NAK 'N' emitted", rx_len == 1 && rx_text[0] == 8'h4E);

        // -------------------------------------------------------------
        // C: recovery after reset
        // -------------------------------------------------------------
        reset_dut();
        acc0 = 32'd0; acc1 = 32'd0; acc2 = 32'd0; acc3 = 32'd0;
        send_frame(16'd0, 1'b0);
        wait_loader_idle();
        $display("OBS C: weight_ok=%0b weight_err=%0b frame_cnt=%0d uart_len=%0d",
                 weight_ok, weight_err, frame_cnt, rx_len);
        show_uart();
        // A single chunk never raises weight_ok: that flag only asserts after
        // the end frame's read-back digest check (weight_loader.v:344).  The
        // post-reset recovery property is therefore "the chunk is accepted",
        // i.e. one 'K', frame_cnt incremented and no error latched.
        check("C good chunk accepted after reset",
              rx_len == 1 && rx_text[0] == 8'h4B &&
              frame_cnt == 16'd1 && weight_err === 1'b0);

        $display("=== tb_weight_loader done: %0d checks, %0d errors ===", checks, errors);
        if (errors == 0) begin
            $display("RESULT: PASS tb_weight_loader");
            $finish;
        end else begin
            $display("RESULT: FAIL tb_weight_loader (%0d errors)", errors);
            $fatal(1, "tb_weight_loader failed");
        end
    end

    initial begin : watchdog
`ifdef PHYSICAL_UART_RX
        #(250ms);
`else
        #(50ms);
`endif
        $display("ERROR: tb_weight_loader watchdog (weight_ok=%0b weight_err=%0b frame_cnt=%0d busy=%0b)",
                 weight_ok, weight_err, frame_cnt, busy);
        $fatal(1, "tb_weight_loader timeout");
    end

endmodule
