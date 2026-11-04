// demo_dashboard_text: labeled instrument recognition dashboard.
// Tile and font ROMs use synchronous reads without payload resets.
// Latency: tile lookup, glyph lookup, ink/color output (three clocks).
module demo_dashboard_text #(parameter SIMULATION = 0) (
    input wire pix_clk, rst_pix_n,
    input wire [10:0] pix_x, pix_y,
    input wire pix_de, wave_valid, feature_ready, result_ready,
    input wire [3:0] class_idx,
    input wire [63:0] percentages,
    output reg [23:0] rgb,
    output reg text_on
);
    reg [15:0] tiles [0:4095];
    reg [15:0] font_bits [0:8191];
    reg [7:0] ascii_ids [0:127];
    reg [7:0] class_ids [0:255];
    initial begin
        $readmemh("src/ui/demo_dashboard_tiles.hex", tiles);
        $readmemh("src/ui/demo_dashboard_font.hex", font_bits);
        $readmemh("src/ui/demo_dashboard_ascii.hex", ascii_ids);
        $readmemh("src/ui/demo_dashboard_classes.hex", class_ids);
    end
    wire [11:0] tile_row = {6'd0, pix_y[10:5]};
    wire [11:0] tile_addr = (tile_row << 7) - (tile_row << 3) + {5'd0,pix_x[10:4]};
    reg [15:0] tile_s1, bits_s2;
    reg [4:0] row_s1;
    reg [3:0] bit_s1, bit_s2;
    reg [5:0] big_y_s1;
    reg [4:0] big_x_s1;
    reg de_s1, de_s2, enabled;
    reg wave_s1, feature_s1, result_s1;
    reg [3:0] class_s1;
    // Format all lanes before tile selection to shorten the tile-to-font path.
    // This register replaces percentages_s1; video latency stays unchanged.
    reg [31:0] formatted_pct [0:7];
    integer pct_lane;
    function [31:0] format_percent;
        input [7:0] value;
        input valid;
        reg [7:0] clamped;
        reg [6:0] hundreds, tens, ones;
        begin
            clamped = value > 100 ? 8'd100 : value;
            hundreds = valid && clamped == 100 ? 7'd49 : 7'd32;
            tens = !valid ? 7'd45 : (clamped >= 10 ? 7'd48 + (clamped/10)%10 : 7'd32);
            ones = !valid ? 7'd45 : 7'd48 + clamped%10;
            format_percent = {ascii_ids[37],ascii_ids[ones],ascii_ids[tens],ascii_ids[hundreds]};
        end
    endfunction
    always @(posedge pix_clk) begin
        for (pct_lane = 0; pct_lane < 8; pct_lane = pct_lane + 1)
            formatted_pct[pct_lane] <= format_percent(percentages[pct_lane*8 +: 8],result_ready && class_idx < 8);
    end
    reg [23:0] color_s2, selected_color;
    reg [7:0] glyph;
    reg [3:0] slot;
    reg [4:0] selected_row;
    reg [3:0] selected_bit;
    always @* begin
        glyph = tile_s1[7:0];
        selected_row = row_s1;
        selected_bit = bit_s1;
        enabled = 1'b1;
        slot = tile_s1[7:4];
        case (tile_s1[15:12])
            4'd1: selected_color = 24'heaf0f7;
            4'd3: selected_color = 24'h36d6c5;
            4'd4: selected_color = 24'hf2ba59;
            default: selected_color = 24'h9aabc0;
        endcase
        case (tile_s1[11:8])
            4'd1: begin
                glyph = class_ids[{(result_s1 && class_s1 < 8) ? class_s1 : 4'd8,tile_s1[3:0]}];
                selected_row = big_y_s1[5:1];
                selected_bit = ~big_x_s1[4:1];
                if (!result_s1) selected_color = 24'h9aabc0;
            end
            4'd2: begin
                if (slot == 8) slot = class_s1;
                if (slot < 8) glyph = formatted_pct[slot][tile_s1[1:0]*8 +: 8];
                else glyph = formatted_pct[0][tile_s1[1:0]*8 +: 8];
                if (result_s1 && slot == class_s1) selected_color = 24'h36d6c5;
            end
            4'd4: enabled = !wave_s1;
            4'd5: enabled = !feature_s1;
            4'd6: enabled = SIMULATION != 0;
            default: enabled = 1'b1;
        endcase
    end
    always @(posedge pix_clk) begin
        tile_s1 <= tiles[tile_addr];
        row_s1 <= pix_y[4:0];
        bit_s1 <= ~pix_x[3:0];
        big_y_s1 <= pix_y[5:0];
        big_x_s1 <= pix_x[4:0];
        wave_s1 <= wave_valid;
        feature_s1 <= feature_ready;
        result_s1 <= result_ready && class_idx < 8;
        class_s1 <= class_idx;
        bits_s2 <= font_bits[{glyph,selected_row}];
        bit_s2 <= selected_bit;
        color_s2 <= selected_color;
        de_s1 <= pix_de && pix_x < 1920 && pix_y < 1080;
        de_s2 <= de_s1 && enabled;
        text_on <= de_s2 && bits_s2[bit_s2];
        rgb <= color_s2;
        if (!rst_pix_n) begin
            de_s1 <= 0;
            de_s2 <= 0;
            text_on <= 0;
        end
    end
endmodule
