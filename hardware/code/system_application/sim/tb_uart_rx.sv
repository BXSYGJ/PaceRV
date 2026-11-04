`timescale 1ns/1ps
module tb_uart_rx;
    localparam integer BIT_CYCLES = 1085;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0;
    reg rxd = 1;
    wire [7:0] data;
    wire valid;
    reg [7:0] expected [0:511];
    integer received = 0;
    integer queued = 0;
    integer i;
    uart_rx dut(.clk(clk), .rst_n(rst_n), .uart_rxd(rxd),
                .byte_rdata(data), .byte_rvalid(valid));

    always @(negedge clk) begin
        if (rst_n && valid) begin
            if (received >= queued) $fatal(1, "unexpected RX byte %02x", data);
            if (data !== expected[received])
                $fatal(1, "RX byte %0d got %02x expected %02x", received, data, expected[received]);
            received = received + 1;
        end
    end

    task bit_time(input reg level);
        begin
            rxd = level;
            repeat (BIT_CYCLES) @(negedge clk);
        end
    endtask

    task send_byte(input reg [7:0] value, input reg good_stop);
        integer b;
        begin
            if (good_stop) begin
                expected[queued] = value;
                queued = queued + 1;
            end
            bit_time(0);
            for (b=0;b<8;b=b+1) bit_time(value[b]);
            bit_time(good_stop);
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst_n=1;
        bit_time(1);
        // Physical weight-upload SOF, little-endian sequence/length, payload.
        send_byte(8'haa, 1); send_byte(8'h55, 1);
        send_byte(8'h00, 1); send_byte(8'h00, 1);
        send_byte(8'h00, 1); send_byte(8'h01, 1);
        for (i=0;i<256;i=i+1) send_byte(i[7:0], 1);
        bit_time(1);
        if (received != queued) $fatal(1, "lost back-to-back byte got %0d expected %0d", received, queued);
        // A short false start and a low stop bit must not produce bytes.
        rxd=0; repeat(100) @(negedge clk); bit_time(1);
        send_byte(8'h96, 0);
        bit_time(1); bit_time(1);
        send_byte(8'ha5, 1);
        bit_time(1);
        // Reset halfway through a frame must cancel it and allow a fresh SOF.
        bit_time(0); bit_time(1);
        rst_n=0; repeat(5) @(negedge clk); rxd=1;
        rst_n=1; bit_time(1);
        send_byte(8'h55, 1); bit_time(1);
        if (received != queued) $fatal(1, "lost recovery byte");
        $display("RESULT: PASS uart_rx %0d bytes, all values, back-to-back, framing/glitch/reset", received);
        $finish;
    end
    initial begin #50000000; $fatal(1, "UART RX timeout"); end
endmodule
