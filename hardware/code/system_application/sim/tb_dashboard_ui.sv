`timescale 1ns/1ps
module tb_dashboard_ui;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 0;
    reg [10:0] x = 0, y = 0;
    reg de = 0, hs = 0, vs = 0;
    reg ready = 0;
    reg [3:0] cls = 4;
    reg [7:0] pct [0:7];
    wire [10:0] wave_addr;
    wire [14:0] spec_addr;
    reg [15:0] wave_min = 0, wave_max = 0;
    reg [7:0] spec_data = 0;
    wire [23:0] rgb;
    wire out_de, out_hs, out_vs, frame_start;
    dashboard_renderer #(.SIMULATION(1)) dut (
        .pix_clk(clk), .rst_pix_n(rst), .pix_x(x), .pix_y(y),
        .pix_de(de), .pix_hs(hs), .pix_vs(vs),
        .wave_rd_addr(wave_addr), .wave_min(wave_min), .wave_max(wave_max),
        .wave_valid(ready), .mute_flag_sync(1'b0),
        .spec_ram_addr(spec_addr), .spec_ram_data(spec_data),
        .feature_ready(ready), .result_ready(ready), .class_idx(cls),
        .pct0(pct[0]), .pct1(pct[1]), .pct2(pct[2]), .pct3(pct[3]),
        .pct4(pct[4]), .pct5(pct[5]), .pct6(pct[6]), .pct7(pct[7]),
        .vsync_pulse(frame_start), .rgb(rgb), .de_out(out_de), .hs_out(out_hs), .vs_out(out_vs)
    );
    integer amplitude, row, col, peak, energy;
    always @(posedge clk) begin
        // Deterministic input fixture: grouped note envelopes and harmonic ridges.
        amplitude = 800 + ((wave_addr / 30) % 7) * 900;
        if ((wave_addr % 320) < 230) amplitude = amplitude + 9000 - (wave_addr % 230)*25;
        wave_min <= -amplitude;
        wave_max <= amplitude;
        row = spec_addr / 258;
        col = spec_addr % 258;
        peak = (col / 48) % 3;
        energy = 22 + ((col*13+row*7)%19);
        if ((row >= 6+peak*3 && row < 10+peak*3) ||
            (row >= 18+peak*3 && row < 21+peak*3) ||
            (row >= 32+peak*2 && row < 34+peak*2)) energy = 210 - row;
        if (col % 48 > 37) energy = energy/2;
        spec_data <= energy;
    end
    reg [3:0] de_expected = 0, hs_expected = 0, vs_expected = 0;
    integer xq [0:3], yq [0:3];
    integer fd = 0, count = 0, frames = 0, checks = 0;
    integer i;
    reg [23:0] expected;
    always @(posedge clk) begin
        de_expected = {de_expected[2:0],de && rst};
        hs_expected = {hs_expected[2:0],hs && rst};
        vs_expected = {vs_expected[2:0],vs && rst};
        for (i=3;i>0;i=i-1) begin xq[i]=xq[i-1]; yq[i]=yq[i-1]; end
        xq[0]=x; yq[0]=y;
        if (rst) begin
            if (wave_addr > 1919 || spec_addr > 16511) $fatal(1,"RAM address out of bounds");
            if (x >= 128 && x < 1152 && y >= 288 && y < 448 && wave_addr !== ((x-128)*1920/1024)) $fatal(1,"Wave address mapping");
            if (x >= 128 && x < 1152 && y >= 672 && y < 928 && spec_addr !== ((63-(y-672)/4)*258+(x-128)*258/1024)) $fatal(1,"Spectrum orientation or extent");
        end
        #1;
        if (rst && {out_de,out_hs,out_vs} !== {de_expected[3],hs_expected[3],vs_expected[3]}) $fatal(1,"Four clock control alignment");
        if (out_de && fd != 0) begin
            $fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
            count = count + 1;
            if (xq[3] == 64 && yq[3] == 200 && rgb !== 24'h27364c) $fatal(1,"Card border alignment");
            if (xq[3] == 1200 && yq[3] == 600 && rgb !== 24'h0b1020) $fatal(1,"Inter-card drawing escaped");
            // Bar interiors contain no text; check exact fill/track transition.
            if (yq[3] == 486 && xq[3] >= 1280 && xq[3] < 1680) begin
                expected = ready && xq[3]-1280 < (pct[0]>100 ? 400 : pct[0]*4) ? (cls==0 ? 24'h36d6c5 : 24'h547d9d) : 24'h27364c;
                if (rgb !== expected) $fatal(1,"Bar width/zero/full-scale wrong x=%0d got=%h expected=%h",xq[3],rgb,expected);
                checks = checks + 1;
            end
        end
    end
    task render(input string name);
        integer xx, yy;
        begin
            fd = $fopen(name,"wb");
            if (!fd) $fatal(1,"Cannot open raster");
            $fwrite(fd,"P6\n1920 1080\n255\n");
            count = 0;
            for (yy=0;yy<1084;yy=yy+1)
                for (xx=0;xx<1936;xx=xx+1) begin
                    @(negedge clk);
                    x=xx; y=yy;
                    de=xx<1920 && yy<1080;
                    hs=xx>=1924; vs=yy>=1081;
                end
            @(negedge clk); de=0; hs=0; vs=0;
            repeat(6) @(negedge clk);
            $fclose(fd); fd=0;
            if (count != 2073600) $fatal(1,"Frame pixel count %0d",count);
            frames = frames+1;
        end
    endtask
    initial begin
        pct[0]=3; pct[1]=4; pct[2]=2; pct[3]=5;
        pct[4]=72; pct[5]=3; pct[6]=8; pct[7]=3;
        repeat(5) @(negedge clk); rst=1;
        render("build/sim/dashboard_ui/waiting.ppm");
        ready=1;
        render("build/sim/dashboard_ui/ready.ppm");
        cls=0; pct[0]=100; pct[4]=0;
        render("build/sim/dashboard_ui/full_scale.ppm");
        pct[0]=0;
        render("build/sim/dashboard_ui/zero.ppm");
        pct[0]=255;
        render("build/sim/dashboard_ui/clamped.ppm");
        if (checks != 2000) $fatal(1,"Insufficient bar checks");
        $display("RESULT: PASS dashboard_ui frames=%0d active_pixels=%0d bar_checks=%0d",frames,frames*2073600,checks);
        $finish;
    end
endmodule
