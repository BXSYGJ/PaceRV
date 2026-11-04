`timescale 1ns/1ps

module tb_ui_overlay;
    reg pix_clk = 1'b0;
    reg rst_pix_n = 1'b0;
    always #5 pix_clk = ~pix_clk;

    reg de = 1'b0;
    reg [23:0] base_rgb = 24'h101010;
    reg base_on = 1'b1;
    reg [23:0] spec_rgb = 24'h202020;
    reg spec_on = 1'b0;
    reg [23:0] text_rgb = 24'h303030;
    reg text_on = 1'b0;
    reg [23:0] bars_rgb = 24'h404040;
    reg bars_on = 1'b0;
    wire [23:0] rgb;
    wire de_out;
    integer errors = 0;
    integer checks = 0;

    ui_overlay dut (
        .pix_clk(pix_clk), .rst_pix_n(rst_pix_n), .de(de),
        .base_rgb(base_rgb), .base_on(base_on),
        .spec_rgb(spec_rgb), .spec_on(spec_on),
        .text_rgb(text_rgb), .text_on(text_on),
        .bars_rgb(bars_rgb), .bars_on(bars_on),
        .rgb(rgb), .de_out(de_out)
    );

    task automatic drive_and_check(input [23:0] expected, input de_in);
        begin
            @(negedge pix_clk);
            de = de_in;
            @(posedge pix_clk);
            #1;
            checks = checks + 1;
            if (rgb !== expected || de_out !== de_in) begin
                errors = errors + 1;
                $display("CHECK FAIL expected=%h/%b got=%h/%b", expected, de_in, rgb, de_out);
            end
        end
    endtask

    initial begin
        repeat (2) @(posedge pix_clk);
        rst_pix_n = 1'b1;

        drive_and_check(24'h101010, 1'b1);
        spec_on = 1'b1;
        drive_and_check(24'h202020, 1'b1);
        text_on = 1'b1;
        drive_and_check(24'h303030, 1'b1);
        bars_on = 1'b1;
        drive_and_check(24'h404040, 1'b1);
        drive_and_check(24'h404040, 1'b0);
        bars_on = 1'b0;
        text_on = 1'b0;
        spec_on = 1'b0;
        base_on = 1'b0;
        drive_and_check(24'h000000, 1'b0);

        if (errors == 0)
            $display("RESULT: PASS checks=%0d", checks);
        else
            $display("RESULT: FAIL errors=%0d checks=%0d", errors, checks);
        $finish;
    end
endmodule
