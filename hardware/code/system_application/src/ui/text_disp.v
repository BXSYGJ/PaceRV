// ---------------------------------------------------------------------------
// text_disp.v -- class label text overlay for the InstRec UI (M3)
//
// Draws the top-1 class name and its percentage as 8x16 glyphs in a fixed
// field of the 1920x1080 frame. The field origin is (X0, Y0) = (1200, 560)
// with LINE_H = 20 pixels per text line and a reserved 8-line block of
// 160 pixels (560..719, just above the bars_disp region at y = 700). Only
// line 0 (the top-1 class) is rendered today; the pitch is kept so a ranked
// list can be added later without moving the origin.
//
// Glyph source: font_rom (95 printable ASCII, 8x16, synchronous read).
// Label source: src/ui/class_labels.hex, 8 records of 32 ASCII chars
// (space padded, 256 bytes, scripts/gen_label_rom.py). One character is
// addressed as {(class_index[2:0]), char_column[4:0]}; char_column counts
// 8-pixel cells from X0.
//
// Layout of one line, columns in 8-pixel cells starting at X0:
//   [0 .. name_len-1]  class name, name_len from the table below
//   [name_len]         separator space
//   [name_len+1]       hundreds digit of the percentage (' ' when < 100)
//   [name_len+2]       tens digit (' ' when the value is a single digit)
//   [name_len+3]       ones digit
//   [name_len+4]       '%'
// The longest name is 25 chars, so the drawn field is at most 30 cells
// (240 pixels); the record stride stays 32 because it is a power of two.
//
// Latency: the label ROM word is selected combinationally from the pixel
// coordinates, font_rom adds one register stage for the glyph row, and the
// output stage adds one more. rgb / text_on therefore belong to the pixel
// presented two pix_clk cycles earlier; the caller must delay its de / hs /
// vs by 2 cycles (bars_disp is 1, ui_overlay adds 1 on top of its inputs).
// text_on is de-gated so it can be used directly as a compositor key.
// ---------------------------------------------------------------------------

// REGISTER_CHAR adds a character/geometry register before the font ROM.
// Its latency is three clocks; the default legacy path remains two clocks.
module text_disp #(
    parameter integer REGISTER_CHAR = 0
) (
    input  wire        pix_clk,
    input  wire        rst_pix_n,

    input  wire [10:0] pix_x,
    input  wire [10:0] pix_y,
    input  wire        de,

    // Top-1 class index (0..7) and its percentage (0..100, clamped).
    // Both must be static for the whole frame (latched by the caller).
    input  wire [7:0]  class_idx,
    input  wire [7:0]  pct,

    output reg  [23:0] rgb,
    output reg         text_on
);

    // ---- Field geometry (pixels) -----------------------------------------
    localparam [10:0] X0        = 11'd1200;  // left edge of the text field
    localparam [10:0] Y0        = 11'd560;   // top of text line 0
    localparam [10:0] LINE_H    = 11'd20;    // line pitch, 16 px glyph centred
    localparam [10:0] GLYPH_OFF = 11'd2;     // (LINE_H - 16) / 2
    localparam [10:0] FIELD_W   = 11'd240;   // 30 cells, 25 name + 5 pct

    localparam [23:0] TEXT_RGB  = 24'hFF_FF_FF;

    // ---- Label character ROM (8 records x 32 chars = 256 bytes) ----------
    reg [7:0] label_rom [0:255];

    initial begin
        $readmemh("src/ui/class_labels.hex", label_rom);
    end

    // ---- Inputs, clamped and indexed -------------------------------------
    wire [2:0] cls      = class_idx[2:0];
    wire [7:0] pct_val  = (pct > 8'd100) ? 8'd100 : pct;

    // Name length in characters per class, in the order of
    // scripts/outputs/layer_contract.json classes.names.
    reg [4:0] name_len;
    always @* begin
        case (cls)
            3'd0: name_len = 5'd8;    // clarinet
            3'd1: name_len = 5'd25;   // distorted electric guitar
            3'd2: name_len = 5'd13;   // female singer
            3'd3: name_len = 5'd5;    // flute
            3'd4: name_len = 5'd5;    // piano
            3'd5: name_len = 5'd15;   // tenor saxophone
            3'd6: name_len = 5'd7;    // trumpet
            default: name_len = 5'd6; // violin
        endcase
    end

    // ---- Percentage digits (comparison chain, no divider) ----------------
    wire       pct_hi  = (pct_val >= 8'd100);
    wire [7:0] pct_rem = pct_hi ? (pct_val - 8'd100) : pct_val;

    reg [3:0] pct_tens;
    always @* begin
        if      (pct_rem >= 8'd90) pct_tens = 4'd9;
        else if (pct_rem >= 8'd80) pct_tens = 4'd8;
        else if (pct_rem >= 8'd70) pct_tens = 4'd7;
        else if (pct_rem >= 8'd60) pct_tens = 4'd6;
        else if (pct_rem >= 8'd50) pct_tens = 4'd5;
        else if (pct_rem >= 8'd40) pct_tens = 4'd4;
        else if (pct_rem >= 8'd30) pct_tens = 4'd3;
        else if (pct_rem >= 8'd20) pct_tens = 4'd2;
        else if (pct_rem >= 8'd10) pct_tens = 4'd1;
        else                       pct_tens = 4'd0;
    end

    wire [6:0] tens_x8  = {pct_tens, 3'b000};            // tens * 8
    wire [4:0] tens_x2  = {pct_tens, 1'b0};              // tens * 2
    wire [7:0] tens_x10 = tens_x8 + {3'b000, tens_x2};   // tens * 10
    wire [3:0] pct_ones = pct_rem - tens_x10;            // 0..9

    wire show_tens = pct_hi || (pct_tens != 4'd0);

    // ---- Column of each percentage character ------------------------------
    // The last name cell (name_len-1) is followed by the separator at
    // column name_len, so the five-cell percentage field ends at
    // name_len + 4 = 29 for the longest name (25) and still fits FIELD_W.
    wire [5:0] col_sep  = {1'b0, name_len};
    wire [5:0] col_hund = col_sep  + 6'd1;
    wire [5:0] col_tens = col_hund + 6'd1;
    wire [5:0] col_ones = col_tens + 6'd1;
    wire [5:0] col_pct  = col_ones + 6'd1;

    // ---- Pixel position inside the field ---------------------------------
    wire [10:0] dx = pix_x - X0;
    wire [10:0] dy = pix_y - Y0;

    wire in_region = de && (pix_x >= X0) && (pix_y >= Y0) &&
                     (dx < FIELD_W) &&
                     (dy >= GLYPH_OFF) && (dy < (GLYPH_OFF + 11'd16));

    wire [4:0] char_col  = dx[7:3];            // 8 pixels per cell
    wire [3:0] glyph_row = dy[3:0] - 4'd2;     // row inside the 8x16 glyph
    wire [2:0] bit_idx   = ~dx[2:0];           // MSB is the leftmost pixel

    // ---- Character selection ---------------------------------------------
    reg [7:0] pct_code;
    wire is_label = (char_col < name_len);
    wire [7:0] char_code = is_label ? label_rom[{cls, char_col}] : pct_code;
    always @* begin
        if ({1'b0, char_col} == col_sep) begin
            pct_code = 8'd32;                                  // ' '
        end else if ({1'b0, char_col} == col_hund) begin
            pct_code = pct_hi ? 8'd49 : 8'd32;                 // '1' or ' '
        end else if ({1'b0, char_col} == col_tens) begin
            pct_code = show_tens ? {4'd3, pct_tens} : 8'd32;   // digit or ' '
        end else if ({1'b0, char_col} == col_ones) begin
            pct_code = {4'd3, pct_ones};                       // '0'..'9'
        end else if ({1'b0, char_col} == col_pct) begin
            pct_code = 8'd37;                                  // '%'
        end else begin
            pct_code = 8'd32;
        end
    end

    // ---- Glyph ROM (synchronous read, one cycle) -------------------------
    wire [7:0] glyph_bits;
    reg [7:0] label_char_r;
    reg label_select_r;
    // A synchronous label read isolates the class/column ROM decode.
    always @(posedge pix_clk) begin
        label_char_r <= label_rom[{cls, char_col}];
    end
    reg [7:0] char_code_r;
    reg [3:0] glyph_row_r;
    reg region_r;
    reg [2:0] bit_idx_r;
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            char_code_r <= 8'd32;
            label_select_r <= 1'b0;
            glyph_row_r <= 4'd0;
            region_r <= 1'b0;
            bit_idx_r <= 3'd0;
        end else begin
            char_code_r <= pct_code;
            label_select_r <= is_label;
            glyph_row_r <= glyph_row;
            region_r <= in_region;
            bit_idx_r <= bit_idx;
        end
    end

    font_rom u_font_rom (
        .pix_clk   (pix_clk),
        .char_code (REGISTER_CHAR ? (label_select_r ? label_char_r : char_code_r) : char_code),
        .row       (REGISTER_CHAR ? glyph_row_r : glyph_row),
        .bits      (glyph_bits)
    );

    // ---- Stage 1: align the pixel selection with the glyph data ----------
    reg        px_valid;
    reg  [2:0] px_bit;

    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            px_valid <= 1'b0;
            px_bit   <= 3'd0;
        end else begin
            px_valid <= REGISTER_CHAR ? region_r : in_region;
            px_bit   <= REGISTER_CHAR ? bit_idx_r : bit_idx;
        end
    end

    // ---- Stage 2: registered overlay output ------------------------------
    wire px_lit = px_valid && glyph_bits[px_bit];

    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            rgb     <= 24'd0;
            text_on <= 1'b0;
        end else begin
            rgb     <= px_lit ? TEXT_RGB : 24'd0;
            text_on <= px_lit;
        end
    end

endmodule
