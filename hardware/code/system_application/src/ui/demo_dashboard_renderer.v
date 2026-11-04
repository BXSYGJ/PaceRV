// demo_dashboard_renderer: labeled instrument recognition dashboard.
// Fixed 1080p dashboard. Graphics and text share a four-clock video latency.
// External waveform/feature memories have a one-clock read latency.
module demo_dashboard_renderer #(parameter SIMULATION = 0) (
    input wire pix_clk, rst_pix_n,
    input wire [10:0] pix_x, pix_y,
    input wire pix_de, pix_hs, pix_vs,
    output wire [10:0] wave_rd_addr,
    input wire [15:0] wave_min, wave_max,
    input wire wave_valid, mute_flag_sync,
    output wire [14:0] spec_ram_addr,
    input wire [7:0] spec_ram_data,
    input wire feature_ready, result_ready,
    input wire [3:0] class_idx,
    input wire [7:0] pct0, pct1, pct2, pct3, pct4, pct5, pct6, pct7,
    output wire vsync_pulse,
    output reg [23:0] rgb,
    output wire de_out, hs_out, vs_out
);
    wire in_wave = pix_x >= 128 && pix_x < 1152 && pix_y >= 288 && pix_y < 448;
    wire in_spec = pix_x >= 128 && pix_x < 1152 && pix_y >= 672 && pix_y < 928;
    wire [10:0] dx = pix_x - 11'd128;
    wire [18:0] spec_product = ({8'd0,dx} << 8) + ({8'd0,dx} << 1);
    wire [5:0] spec_row = 6'd63 - ((pix_y - 11'd672) >> 2);
    wire [14:0] row_ext = {9'd0,spec_row};
    wire [14:0] spec_col = {6'd0,spec_product[18:10]};
    wire [14:0] wave_product = ({4'd0,dx} << 4) - {4'd0,dx};
    assign wave_rd_addr = in_wave ? wave_product[13:3] : 11'd0;
    assign spec_ram_addr = in_spec ? (row_ext << 8) + (row_ext << 1) + spec_col : 15'd0;
    wire [63:0] percentages = {pct7,pct6,pct5,pct4,pct3,pct2,pct1,pct0};
    wire [23:0] text_rgb;
    wire text_on;
    demo_dashboard_text #(.SIMULATION(SIMULATION)) u_text (
        .pix_clk(pix_clk), .rst_pix_n(rst_pix_n), .pix_x(pix_x), .pix_y(pix_y),
        .pix_de(pix_de), .wave_valid(wave_valid), .feature_ready(feature_ready),
        .result_ready(result_ready), .class_idx(class_idx), .percentages(percentages),
        .rgb(text_rgb), .text_on(text_on)
    );
    reg [10:0] x_s1, y_s1;
    reg wave_s1, spec_s1, wave_ready_s1, spec_ready_s1, result_s1, mute_s1;
    reg [3:0] class_s1;
    reg [63:0] percentages_s1;
    reg [23:0] graph_s2, graph_s3, graph_color;
    reg [3:0] de_pipe, hs_pipe, vs_pipe;
    reg vs_d;
    reg [3:0] bar_row;
    reg [7:0] bar_pct;
    reg [10:0] bar_width;
    reg [6:0] pos_amp, neg_amp;
    reg [15:0] neg_magnitude;
    reg [23:0] heat;
    always @* begin
        // Features are standardized unsigned bytes, not calibrated dB.
        if (spec_ram_data < 64) heat = {8'h16, (8'h24 + (spec_ram_data >> 1)), (8'h40 + spec_ram_data)};
        else if (spec_ram_data < 128) heat = {8'h18, (8'h44 + spec_ram_data), 8'h90};
        else if (spec_ram_data < 192) heat = {(spec_ram_data - 8'd96), 8'hd6, (8'hff - spec_ram_data)};
        else heat = {8'hf2, (8'hff - (spec_ram_data >> 2)), 8'h59};
        graph_color = 24'h0b1020;
        if ((x_s1 >= 64 && x_s1 < 1184 && ((y_s1 >= 160 && y_s1 < 512) || (y_s1 >= 544 && y_s1 < 1008))) ||
            (x_s1 >= 1216 && x_s1 < 1856 && y_s1 >= 160 && y_s1 < 1008))
            graph_color = 24'h121c2d;
        if (((x_s1 == 64 || x_s1 == 1183) && ((y_s1 >= 160 && y_s1 < 512) || (y_s1 >= 544 && y_s1 < 1008))) ||
            ((y_s1 == 160 || y_s1 == 511 || y_s1 == 544 || y_s1 == 1007) && x_s1 >= 64 && x_s1 < 1184) ||
            ((x_s1 == 1216 || x_s1 == 1855) && y_s1 >= 160 && y_s1 < 1008) ||
            ((y_s1 == 160 || y_s1 == 1007) && x_s1 >= 1216 && x_s1 < 1856))
            graph_color = 24'h27364c;
        if (y_s1 == 143 && x_s1 >= 64 && x_s1 < 1856) graph_color = 24'h27364c;
        pos_amp = wave_max[15] ? 7'd0 : {1'b0,wave_max[14:9]};
        neg_magnitude = (~wave_min) + 16'd1;
        neg_amp = wave_min[15] ? neg_magnitude[15:9] : 7'd0;
        if (neg_amp > 64) neg_amp = 64;
        if (wave_s1) begin
            graph_color = 24'h0d1726;
            if (x_s1[7:0] == 128 || y_s1 == 304 || y_s1 == 368 || y_s1 == 432) graph_color = 24'h27364c;
            if (wave_ready_s1 && y_s1 >= (11'd368 - {4'd0,pos_amp}) && y_s1 <= (11'd368 + {4'd0,neg_amp}))
                graph_color = mute_s1 ? 24'h9aabc0 : 24'h36d6c5;
        end
        if (spec_s1) begin
            graph_color = 24'h0d1726;
            if (spec_ready_s1) graph_color = heat;
            else if (x_s1[7:0] == 128 || y_s1[5:0] == 32) graph_color = 24'h27364c;
        end
        bar_row = (y_s1 - 11'd448) >> 6;
        bar_pct = 0;
        if (bar_row < 8) bar_pct = percentages_s1[bar_row*8 +: 8];
        if (bar_pct > 100) bar_pct = 100;
        bar_width = {1'b0,bar_pct,2'b00};
        if (x_s1 >= 1280 && x_s1 < 1680 && y_s1 >= 480 && y_s1 < 940 && y_s1[5:0] >= 32 && y_s1[5:0] < 44 && bar_row < 8) begin
            graph_color = 24'h27364c;
            if (result_s1 && x_s1 - 1280 < bar_width)
                graph_color = bar_row == class_s1 ? 24'h36d6c5 : 24'h547d9d;
        end
        if (x_s1 >= 912 && x_s1 < 1104 && y_s1 >= 972 && y_s1 < 984) begin
            if (x_s1 < 960) graph_color = 24'h16345f;
            else if (x_s1 < 1008) graph_color = 24'h189e90;
            else if (x_s1 < 1056) graph_color = 24'h60d65f;
            else graph_color = 24'hf2c359;
        end
    end
    always @(posedge pix_clk) begin
        x_s1 <= pix_x; y_s1 <= pix_y;
        wave_s1 <= in_wave; spec_s1 <= in_spec;
        wave_ready_s1 <= wave_valid; spec_ready_s1 <= feature_ready;
        result_s1 <= result_ready && class_idx < 8;
        mute_s1 <= mute_flag_sync;
        class_s1 <= class_idx; percentages_s1 <= percentages;
        graph_s2 <= graph_color;
        graph_s3 <= graph_s2;
        rgb <= de_pipe[2] ? (text_on ? text_rgb : graph_s3) : 24'd0;
        de_pipe <= {de_pipe[2:0],pix_de};
        hs_pipe <= {hs_pipe[2:0],pix_hs};
        vs_pipe <= {vs_pipe[2:0],pix_vs};
        vs_d <= pix_vs;
        if (!rst_pix_n) begin
            de_pipe <= 0; hs_pipe <= 0; vs_pipe <= 0; vs_d <= 0; rgb <= 0;
        end
    end
    assign de_out = de_pipe[3];
    assign hs_out = hs_pipe[3];
    assign vs_out = vs_pipe[3];
    assign vsync_pulse = pix_vs && !vs_d;
endmodule
