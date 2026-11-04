module uart_debug (
    input  wire        clk,
    input  wire        rst_n,

    output reg  [7:0]  tx_byte_data,
    output reg         tx_byte_valid,
    input  wire        tx_byte_ready,

    input  wire [7:0]  rx_byte_data,
    input  wire        rx_byte_valid,

    input  wire [7:0]  dbg_line_wdata,
    input  wire        dbg_line_wvalid,
    output wire        dbg_line_wready,

    input  wire [2:0]  dbg_line_id,
    input  wire [31:0] dbg_line_arg,
    input  wire        dbg_line_fire,
    output wire        dbg_busy,

    output reg  [15:0] rx_byte_cnt

);

    localparam LINE_BOOT    = "INSTREC BOOT\n";
    localparam LINE_PLLERR  = "PLL LOCK ERR\n";
    localparam LINE_DDRTEST = "DDR3 SELFTEST...\n";
    localparam LINE_DDROK   = "DDROK\n";
    localparam LINE_DDRERR  = "DDR3 ERR @";
    localparam LINE_RUN     = "RUN\n";
    localparam LINE_DDRSTS  = "DDR3 STS ";

    localparam integer LINE_MAX = 24;

    localparam [4:0] LINE_LEN_BOOT    = 5'd13;
    localparam [4:0] LINE_LEN_PLLERR  = 5'd13;
    localparam [4:0] LINE_LEN_DDRTEST = 5'd17;
    localparam [4:0] LINE_LEN_DDROK   = 5'd6;
    localparam [4:0] LINE_LEN_DDRERR  = 5'd10;
    localparam [4:0] LINE_LEN_RUN     = 5'd4;
    localparam [4:0] LINE_LEN_DDRSTS  = 5'd9;

    localparam [2:0] LINE_ID_DDRERR = 3'd4;
    localparam [2:0] LINE_ID_DDRSTS = 3'd6;

    function [7:0] rom_char;
        input [2:0] id;
        input [4:0] idx;
        begin
            rom_char = 8'h20;
            case (id)
                3'd0: begin
                    case (idx)
                        5'd0: rom_char = 8'h49;
                        5'd1: rom_char = 8'h4e;
                        5'd2: rom_char = 8'h53;
                        5'd3: rom_char = 8'h54;
                        5'd4: rom_char = 8'h52;
                        5'd5: rom_char = 8'h45;
                        5'd6: rom_char = 8'h43;
                        5'd7: rom_char = 8'h20;
                        5'd8: rom_char = 8'h42;
                        5'd9: rom_char = 8'h4f;
                        5'd10: rom_char = 8'h4f;
                        5'd11: rom_char = 8'h54;
                        5'd12: rom_char = 8'h0a;
                        default: rom_char = 8'h20;
                    endcase
                end
                3'd1: begin
                    case (idx)
                        5'd0: rom_char = 8'h50;
                        5'd1: rom_char = 8'h4c;
                        5'd2: rom_char = 8'h4c;
                        5'd3: rom_char = 8'h20;
                        5'd4: rom_char = 8'h4c;
                        5'd5: rom_char = 8'h4f;
                        5'd6: rom_char = 8'h43;
                        5'd7: rom_char = 8'h4b;
                        5'd8: rom_char = 8'h20;
                        5'd9: rom_char = 8'h45;
                        5'd10: rom_char = 8'h52;
                        5'd11: rom_char = 8'h52;
                        5'd12: rom_char = 8'h0a;
                        default: rom_char = 8'h20;
                    endcase
                end
                3'd2: begin
                    case (idx)
                        5'd0: rom_char = 8'h44;
                        5'd1: rom_char = 8'h44;
                        5'd2: rom_char = 8'h52;
                        5'd3: rom_char = 8'h33;
                        5'd4: rom_char = 8'h20;
                        5'd5: rom_char = 8'h53;
                        5'd6: rom_char = 8'h45;
                        5'd7: rom_char = 8'h4c;
                        5'd8: rom_char = 8'h46;
                        5'd9: rom_char = 8'h54;
                        5'd10: rom_char = 8'h45;
                        5'd11: rom_char = 8'h53;
                        5'd12: rom_char = 8'h54;
                        5'd13: rom_char = 8'h2e;
                        5'd14: rom_char = 8'h2e;
                        5'd15: rom_char = 8'h2e;
                        5'd16: rom_char = 8'h0a;
                        default: rom_char = 8'h20;
                    endcase
                end
                3'd3: begin
                    case (idx)
                        5'd0: rom_char = 8'h44;
                        5'd1: rom_char = 8'h44;
                        5'd2: rom_char = 8'h52;
                        5'd3: rom_char = 8'h4f;
                        5'd4: rom_char = 8'h4b;
                        5'd5: rom_char = 8'h0a;
                        default: rom_char = 8'h20;
                    endcase
                end
                3'd4: begin
                    case (idx)
                        5'd0: rom_char = 8'h44;
                        5'd1: rom_char = 8'h44;
                        5'd2: rom_char = 8'h52;
                        5'd3: rom_char = 8'h33;
                        5'd4: rom_char = 8'h20;
                        5'd5: rom_char = 8'h45;
                        5'd6: rom_char = 8'h52;
                        5'd7: rom_char = 8'h52;
                        5'd8: rom_char = 8'h20;
                        5'd9: rom_char = 8'h40;
                        default: rom_char = 8'h20;
                    endcase
                end
                3'd5: begin
                    case (idx)
                        5'd0: rom_char = 8'h52;
                        5'd1: rom_char = 8'h55;
                        5'd2: rom_char = 8'h4e;
                        5'd3: rom_char = 8'h0a;
                        default: rom_char = 8'h20;
                    endcase
                end
                3'd6: begin

                    case (idx)
                        5'd0: rom_char = 8'h44;
                        5'd1: rom_char = 8'h44;
                        5'd2: rom_char = 8'h52;
                        5'd3: rom_char = 8'h33;
                        5'd4: rom_char = 8'h20;
                        5'd5: rom_char = 8'h53;
                        5'd6: rom_char = 8'h54;
                        5'd7: rom_char = 8'h53;
                        5'd8: rom_char = 8'h20;
                        default: rom_char = 8'h20;
                    endcase
                end
                default: rom_char = 8'h20;
            endcase
        end
    endfunction

    function [4:0] rom_len;
        input [2:0] id;
        begin
            case (id)
                3'd0:    rom_len = LINE_LEN_BOOT;
                3'd1:    rom_len = LINE_LEN_PLLERR;
                3'd2:    rom_len = LINE_LEN_DDRTEST;
                3'd3:    rom_len = LINE_LEN_DDROK;
                3'd4:    rom_len = LINE_LEN_DDRERR;
                3'd5:    rom_len = LINE_LEN_RUN;
                3'd6:    rom_len = LINE_LEN_DDRSTS;
                default: rom_len = LINE_LEN_RUN;
            endcase
        end
    endfunction

    function [7:0] hex_ascii;
        input [3:0] nib;
        begin
            hex_ascii = (nib >= 4'hA) ? (8'h41 + {4'd0, nib - 4'hA})
                                      : (8'h30 + {4'd0, nib});
        end
    endfunction

    reg [7:0] line_ram [0:127];
    reg [6:0] wr_cnt;
    reg       ram_pending;
    reg [6:0] ram_len;
    reg [6:0] ram_rd_idx;

    assign dbg_line_wready = ~ram_pending & ~rom_pending & (state == ST_IDLE);

    reg       rom_pending;
    reg [2:0] rom_id;
    reg [31:0] rom_arg;

    assign dbg_busy = ram_pending | rom_pending | (state != ST_IDLE) |
                      (wr_cnt != 7'd0);

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_RAM  = 3'd1;
    localparam [2:0] ST_ROM  = 3'd2;
    localparam [2:0] ST_HEX  = 3'd3;
    localparam [2:0] ST_EOL  = 3'd4;

    reg [2:0]  state;

    localparam [15:0] TX_GAP = 16'd12000;
    reg [15:0] gap_cnt;

    reg [4:0]  rom_idx;
    reg [3:0]  hex_left;
    reg [31:0] hex_shf;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cnt      <= 7'd0;
            ram_pending <= 1'b0;
            ram_len     <= 7'd0;
            ram_rd_idx  <= 7'd0;
            rom_pending <= 1'b0;
            rom_id      <= 3'd0;
            rom_arg     <= 32'd0;
            state       <= ST_IDLE;
            gap_cnt     <= 16'd0;
            rom_idx     <= 5'd0;
            hex_left    <= 4'd0;
            hex_shf     <= 32'd0;
            tx_byte_data  <= 8'd0;
            tx_byte_valid <= 1'b0;
            rx_byte_cnt   <= 16'd0;
        end else begin
            tx_byte_valid <= 1'b0;
            if (gap_cnt != 16'd0) gap_cnt <= gap_cnt - 16'd1;

            if (rx_byte_valid) begin
                rx_byte_cnt <= rx_byte_cnt + 16'd1;
            end

            if (dbg_line_wready && dbg_line_wvalid) begin
                line_ram[wr_cnt[6:0]] <= dbg_line_wdata;
                if (dbg_line_wdata == 8'h0A || wr_cnt == 7'd127) begin

                    ram_len     <= (wr_cnt == 7'd127) ? 7'd128
                                                      : wr_cnt + 7'd1;
                    ram_pending <= 1'b1;
                    wr_cnt      <= 7'd0;
                end else begin
                    wr_cnt <= wr_cnt + 7'd1;
                end
            end

            if (dbg_line_fire && !rom_pending && !ram_pending &&
                (state == ST_IDLE)) begin
                rom_pending <= 1'b1;
                rom_id      <= dbg_line_id;

                rom_arg     <= (dbg_line_id == LINE_ID_DDRSTS)
                               ? {dbg_line_arg[7:0], 24'd0}
                               : dbg_line_arg;
            end

            case (state)
                ST_IDLE: begin
                    if (ram_pending) begin
                        ram_rd_idx <= 7'd0;
                        state      <= ST_RAM;
                    end else if (rom_pending) begin
                        rom_idx <= 5'd0;
                        hex_shf <= rom_arg;
                        state   <= ST_ROM;
                    end
                end

                ST_RAM: begin

                    if (tx_byte_ready && gap_cnt == 16'd0) begin
                        tx_byte_data  <= line_ram[ram_rd_idx];
                        tx_byte_valid <= 1'b1;
                        gap_cnt       <= TX_GAP;
                        if (ram_rd_idx == ram_len - 7'd1) begin
                            state <= ST_IDLE;
                            ram_pending <= 1'b0;
                        end else begin
                            ram_rd_idx <= ram_rd_idx + 7'd1;
                        end
                    end
                end

                ST_ROM: begin

                    if (tx_byte_ready && gap_cnt == 16'd0) begin
                        tx_byte_data  <= rom_char(rom_id, rom_idx);
                        tx_byte_valid <= 1'b1;
                        gap_cnt       <= TX_GAP;
                        if (rom_id == LINE_ID_DDRERR &&
                            rom_idx == LINE_LEN_DDRERR - 5'd1) begin
                            hex_left <= 4'd8;
                            state    <= ST_HEX;
                        end else if (rom_id == LINE_ID_DDRSTS &&
                                     rom_idx == LINE_LEN_DDRSTS - 5'd1) begin

                            hex_left <= 4'd2;
                            state    <= ST_HEX;
                        end else if (rom_idx == rom_len(rom_id) - 5'd1) begin

                            state       <= ST_IDLE;
                            rom_pending <= 1'b0;
                        end else begin
                            rom_idx <= rom_idx + 5'd1;
                        end
                    end
                end

                ST_HEX: begin

                    if (tx_byte_ready && gap_cnt == 16'd0) begin
                        tx_byte_data  <= hex_ascii(hex_shf[31:28]);
                        tx_byte_valid <= 1'b1;
                        gap_cnt       <= TX_GAP;
                        hex_shf       <= {hex_shf[27:0], 4'd0};
                        if (hex_left == 4'd1) begin
                            state <= ST_EOL;
                        end else begin
                            hex_left <= hex_left - 4'd1;
                        end
                    end
                end

                ST_EOL: begin

                    if (tx_byte_ready && gap_cnt == 16'd0) begin
                        tx_byte_data  <= 8'h0A;
                        tx_byte_valid <= 1'b1;
                        gap_cnt       <= TX_GAP;
                        state         <= ST_IDLE;
                        rom_pending   <= 1'b0;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
