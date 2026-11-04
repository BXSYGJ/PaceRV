`timescale 1ns/1ps
module tb_requant_reset;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 0, valid = 0;
    reg signed [31:0] a = 0, m = 0;
    reg [6:0] shift = 40;
    reg [7:0] zp = 49;
    wire [7:0] y;
    wire ov;
    requant_unit dut(.clk(clk),.rst_n(rst),.acc_s32(a),.m_s32(m),
        .shift(shift),.zp_out(zp),.in_valid(valid),.y_u8(y),.out_valid(ov));
    function automatic [7:0] reference_value(input signed [31:0] aa, mm,
                                             input [6:0] ss, input [7:0] zz);
        reg signed [63:0] product, rounded, total;
        reg [63:0] magnitude, quotient, remainder, half_value;
        begin
            product = aa * mm;
            magnitude = product < 0 ? -product : product;
            quotient = magnitude >> ss;
            remainder = magnitude & ((64'd1 << ss) - 1);
            half_value = 64'd1 << (ss - 1);
            if (ss != 0 && (remainder > half_value ||
                           (remainder == half_value && quotient[0])))
                quotient = quotient + 1;
            rounded = product < 0 ? -$signed(quotient) : $signed(quotient);
            total = rounded + $signed({1'b0,zz});
            reference_value = total < 0 ? 0 : total > 255 ? 255 : total[7:0];
        end
    endfunction
    reg [3:0] expected_valid = 0;
    reg [7:0] expected_data [0:3];
    integer k, checked = 0, resets = 0;
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            expected_valid = 0;
        end else begin
            for (k = 3; k > 0; k = k - 1) expected_data[k] = expected_data[k-1];
            expected_data[0] = reference_value(a,m,shift,zp);
            expected_valid = {expected_valid[2:0],valid};
        end
        #1;
        if (ov !== expected_valid[3]) $fatal(1,"Reset/latency produced ghost valid");
        if (ov) begin
            if (y !== expected_data[3]) $fatal(1,"Requant mismatch got %d want %d",y,expected_data[3]);
            checked = checked + 1;
        end
    end
    integer i;
    reg [31:0] random_bits = 32'h12345678;
    initial begin
        repeat (4) @(negedge clk);
        rst = 1;
        for (i = 0; i < 1000; i = i + 1) begin
            @(negedge clk);
            random_bits = random_bits * 32'd1664525 + 32'd1013904223;
            a = random_bits;
            m = {1'b0,1'b1,random_bits[29:0]};
            shift = 37 + (i % 17);
            zp = i;
            valid = (i % 7 != 0);
            if (i % 37 == 19) begin
                #2; rst = 0;
                #2;
                if (ov) $fatal(1,"Asynchronous flush failed");
                @(negedge clk); rst = 1; resets = resets + 1;
            end
        end
        @(negedge clk); valid = 0;
        repeat (6) @(negedge clk);
        if (checked < 700 || resets < 20) $fatal(1,"Insufficient coverage");
        $display("RESULT: PASS requant_reset checked=%0d midflight_resets=%0d",checked,resets);
        $finish;
    end
endmodule
