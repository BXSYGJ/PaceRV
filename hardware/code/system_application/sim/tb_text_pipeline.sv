`timescale 1ns/1ps
module tb_text_pipeline;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 0, de = 0;
    reg [10:0] x = 0, y = 0;
    reg [7:0] cls = 0, pct = 0;
    wire [23:0] old_rgb, new_rgb;
    wire old_on, new_on;
    text_disp legacy(.pix_clk(clk),.rst_pix_n(rst),.pix_x(x),.pix_y(y),
        .de(de),.class_idx(cls),.pct(pct),.rgb(old_rgb),.text_on(old_on));
    text_disp #(.REGISTER_CHAR(1)) piped(.pix_clk(clk),.rst_pix_n(rst),
        .pix_x(x),.pix_y(y),.de(de),.class_idx(cls),.pct(pct),
        .rgb(new_rgb),.text_on(new_on));
    reg [23:0] delayed_rgb = 0;
    reg delayed_on = 0;
    integer cycles = 0, pixels = 0;
    always @(posedge clk) begin
        #1;
        if (rst && cycles > 4) begin
            if (new_rgb !== delayed_rgb || new_on !== delayed_on)
                $fatal(1,"Character pipeline alignment failed at cycle %0d",cycles);
            if (new_on) pixels = pixels + 1;
        end
        delayed_rgb = old_rgb;
        delayed_on = old_on;
        cycles = cycles + 1;
    end
    integer c, p, yy, xx;
    initial begin
        repeat (5) @(negedge clk);
        rst = 1;
        for (c = 0; c < 8; c = c + 1)
            for (p = 0; p < 6; p = p + 1) begin
                cls = c;
                case (p)
                    0: pct = 0;
                    1: pct = 9;
                    2: pct = 10;
                    3: pct = 72;
                    4: pct = 100;
                    5: pct = 255;
                endcase
                for (yy = 558; yy < 582; yy = yy + 1)
                    for (xx = 1198; xx < 1442; xx = xx + 1) begin
                        @(negedge clk); x = xx; y = yy; de = 1;
                    end
            end
        @(negedge clk); de = 0;
        repeat (6) @(negedge clk);
        if (pixels < 1000) $fatal(1,"Font missing or all blank");
        $display("RESULT: PASS text_pipeline all 8 classes, percentages, geometry, blanking; lit=%0d",pixels);
        $finish;
    end
endmodule
