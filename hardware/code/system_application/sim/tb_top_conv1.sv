// ---------------------------------------------------------------------------
// tb_top_conv1.sv -- Verilator testbench for the conv1-only NPU bitstream
//
// Runs src/diag/top_npu_conv1_test.v end to end (no DDR3, no IP, only RTL
// plus hex_conv1/*.hex) and writes
//
//   build/sim_conv1_y.bin     all 792576 egress samples, one u8 per byte,
//                             in the (row, group, col, lane) order the
//                             compare_conv1.py sampling contract uses
//   build/sim_conv1_dbg.txt   contract banks and acc_snap[] at the first
//                             pixels, for a per-value diff against
//                             build/conv1_trace.py
//
// The simulation stops as soon as the last egress sample is captured, so
// the 1-second UART frame burst is never simulated.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top_conv1;

    localparam integer STREAM_END = 792576;

    reg        clk;
    reg        rst_n;
    wire [7:0] led;
    wire       uart_tx;

    integer    fd_y;
    integer    fd_dbg;
    integer    i;
    reg [31:0] n_samp;
    integer    trace_cnt;
    integer    mac_trace;
    integer    ro_done;

    top_npu_conv1_test u_dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .led     (led),
        .uart_tx (uart_tx)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;          // 100 MHz, the design is clock-rate agnostic

    initial begin
        n_samp = 32'd0;
        trace_cnt = 0;
        mac_trace = 0;
        ro_done = 0;
        fd_y   = $fopen("build/sim_conv1_y.bin", "wb");
        fd_dbg = $fopen("build/sim_conv1_dbg.txt", "w");
        if (fd_y == 0) begin
            $display("FATAL: cannot open build/sim_conv1_y.bin");
            $finish;
        end
        $fwrite(fd_dbg, "CONV1 SIM START\n");
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
    end

    // egress sample capture (one byte per y_valid beat)
    always @(posedge clk) begin
        if (rst_n && u_dut.y_valid && (n_samp < STREAM_END)) begin
            $fwrite(fd_y, "%c", u_dut.y_u8);
            n_samp = n_samp + 32'd1;
        end
    end

    // contract / accumulator probe: the first two rows, the first three
    // columns of every group.  Values are printed on the snapshot edge,
    // i.e. after the last tap of the pixel has been accumulated.
    always @(posedge clk) begin
        if (rst_n && u_dut.u_conv.snapshot_go &&
            (u_dut.u_conv.out_row_cnt < 2) &&
            ((u_dut.u_conv.out_col_cnt < 3) ||
             ((u_dut.u_conv.out_row_cnt == 0) &&
              (u_dut.u_conv.out_col_cnt >= 12'd255)))) begin
            $fwrite(fd_dbg, "SNAP row=%0d grp=%0d col=%0d\n",
                    u_dut.u_conv.out_row_cnt,
                    u_dut.u_conv.grp_cnt,
                    u_dut.u_conv.out_col_cnt);
            $fwrite(fd_dbg, "  bias:");
            for (i = 0; i < 16; i = i + 1)
                $fwrite(fd_dbg, " %0d", u_dut.u_conv.bias_act[i]);
            $fwrite(fd_dbg, "\n  M:");
            for (i = 0; i < 16; i = i + 1)
                $fwrite(fd_dbg, " %0d", u_dut.u_conv.m_act[i]);
            $fwrite(fd_dbg, "\n  sh:");
            for (i = 0; i < 16; i = i + 1)
                $fwrite(fd_dbg, " %0d", u_dut.u_conv.shft_act[i]);
            $fwrite(fd_dbg, "\n  acc:");
            for (i = 0; i < 16; i = i + 1)
                $fwrite(fd_dbg, " %0d", u_dut.u_conv.acc_snap[i]);
            $fwrite(fd_dbg, "\n");
        end
    end

    // per-beat contract loader trace (first group only, first beats)
    always @(posedge clk) begin
        if (rst_n && (u_dut.gt_step == 2'd1) && (u_dut.c_step < 6'd20) &&
            (u_dut.job_grp == 2'd0) && (trace_cnt < 120)) begin
            $fwrite(fd_dbg,
                    "CTR c_step=%0d ctr_addr=%0d dout=%0d gs=%0d bv=%0d mv=%0d sv=%0d cnt=%0d\n",
                    u_dut.c_step, u_dut.ctr_addr, u_dut.ctr_dout,
                    u_dut.grp_start, u_dut.bias_valid, u_dut.mult_valid,
                    u_dut.shft_valid, u_dut.u_conv.cload_cnt);
            trace_cnt = trace_cnt + 1;
        end
    end

    // MAC operand trace for the last column of row 0 (right border)
    always @(posedge clk) begin
        if (rst_n && u_dut.u_conv.mac_add &&
            (u_dut.u_conv.out_row_cnt == 0) &&
            (u_dut.u_conv.out_col_cnt == 12'd257) &&
            (u_dut.u_conv.grp_cnt == 0) && (mac_trace < 12)) begin
            $fwrite(fd_dbg, "MAC mc=%0d x=%0d w0=%0d |",
                    u_dut.u_conv.mac_cnt, u_dut.u_conv.x_eff,
                    u_dut.u_conv.w_data_q2[7:0]);
            mac_trace = mac_trace + 1;
        end
    end

    // readout completion marker
    always @(posedge clk) begin
        if (rst_n && (u_dut.ro_i == 5'd24) && (ro_done < 6)) begin
            $fwrite(fd_dbg, "RO base=%0d addr=%0d cyc=%0d d0=%0d d1=%0d d2=%0d |", u_dut.ro_base, u_dut.cap_rd_addr, cyc, u_dut.dsb[0], u_dut.dsb[1], u_dut.dsb[2]);
            ro_done = ro_done + 1;
        end
    end

    // per-frame readout payload (what dsb holds when the frame fires)
    always @(posedge clk) begin
        if (rst_n && u_dut.report_fire) begin
            $fwrite(fd_dbg, "FR f=%0d tag=%0d cyc=%0d d=", u_dut.fidx, u_dut.frame_tag, cyc);
            for (i = 0; i < 24; i = i + 1)
                $fwrite(fd_dbg, " %0d", u_dut.dsb[i]);
            $fwrite(fd_dbg, " |");
        end
    end

    // UART frame bytes: exactly the byte stream the board would transmit
    integer fd_uart;
    initial fd_uart = $fopen("build/sim_conv1_uart.bin", "wb");

    always @(posedge clk) begin
        if (rst_n && u_dut.tx_byte_valid && u_dut.tx_byte_ready)
            $fwrite(fd_uart, "%c", u_dut.tx_byte_data);
    end

    // Stop after the whole frame burst has gone out: the y-stream capture
    // finishes much earlier, but the readout + UART path is what the board
    // (and compare_conv1.py) actually scores.
    reg [31:0] cyc;
    initial cyc = 32'd0;
    always @(posedge clk) begin
        if (rst_n) cyc = cyc + 32'd1;
        if (u_dut.report_done || (cyc > 32'd40000000)) begin
            $fwrite(fd_dbg, "END y_cnt=%0d done=%0d samples=%0d report_done=%0d cyc=%0d |",
                    u_dut.y_cnt, u_dut.done_latched, n_samp, u_dut.report_done, cyc);
            $fclose(fd_y);
            $fclose(fd_uart);
            $fclose(fd_dbg);
            $display("TB: captured %0d samples, cycles=%0d", n_samp, cyc);
            $finish;
        end
    end

endmodule