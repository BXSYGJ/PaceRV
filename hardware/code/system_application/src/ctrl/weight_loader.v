module weight_loader #(
    parameter [27:0] BASE_ADDR = 28'd0
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        rx_valid,
    input  wire [7:0]  rx_data,

    output reg         tx_valid,
    output reg  [7:0]  tx_data,
    input  wire        tx_ready,

    output reg         cmd_valid,
    output reg  [36:0] cmd,
    output reg  [255:0] wdata,
    input  wire        wready_beat,
    input  wire        done,

    output reg         rd_ready,
    input  wire [255:0] rd_data,
    input  wire        rd_valid,

    output reg         busy,
    output reg         weight_ok,
    output reg         weight_err,
    output reg  [27:0] err_addr,
    output reg  [15:0] frame_cnt,
    output reg  [31:0] digest
);

    localparam [4:0] S_IDLE  = 5'd0;
    localparam [4:0] S_SOF1  = 5'd1;
    localparam [4:0] S_SEQ0  = 5'd2;
    localparam [4:0] S_SEQ1  = 5'd3;
    localparam [4:0] S_LEN0  = 5'd4;
    localparam [4:0] S_LEN1  = 5'd5;
    localparam [4:0] S_PAY   = 5'd6;
    localparam [4:0] S_CRC0  = 5'd7;
    localparam [4:0] S_CRC1  = 5'd8;
    localparam [4:0] S_CHECK = 5'd9;
    localparam [4:0] S_WRITE = 5'd10;
    localparam [4:0] S_ACK   = 5'd11;
    localparam [4:0] S_NAK   = 5'd12;
    localparam [4:0] S_END   = 5'd13;
    localparam [4:0] S_TX    = 5'd14;
    localparam [4:0] S_FIN   = 5'd15;
    localparam [4:0] S_RD_SET= 5'd16;
    localparam [4:0] S_RD_BEAT=5'd17;
    localparam [4:0] S_RD_CHK= 5'd18;

    reg [4:0]   state;
    reg [15:0]  seq_rx;
    reg [15:0]  len_rx;
    reg [15:0]  pay_idx;
    reg [15:0]  crc_rx;
    reg [15:0]  crc_calc;
    reg [7:0]   beat_idx;
    reg [255:0] beat_buf [0:7];

    reg [31:0]  acc0, acc1, acc2, acc3;
    reg [31:0]  racc0, racc1, racc2, racc3;
    reg [15:0]  rd_seq;
    reg [15:0]  last_len;

    reg [7:0]   tx_line [0:12];
    reg [3:0]   tx_pos;

    reg         tx_pend;
    reg         tx_saw_low;

    function [15:0] crc16_step;
        input [15:0] crc;
        input [7:0]  b;
        reg [15:0] c;
        integer i;
        begin
            c = crc ^ {b, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[15]) c = (c << 1) ^ 16'h1021;
                else       c = c << 1;
            end
            crc16_step = c;
        end
    endfunction

    function [7:0] hex_ascii;
        input [3:0] n;
        begin
            hex_ascii = (n < 4'd10) ? (8'h30 + {4'd0, n})
                                    : (8'h37 + {4'd0, n});
        end
    endfunction

    wire [255:0] wdata_c = beat_buf[beat_idx[2:0]];

    wire [8:0]  beat_num_c = {1'b0, len_rx[15:5]} + (|len_rx[4:0] ? 9'd1 : 9'd0);
    wire [7:0]  cmd_len_c  = beat_num_c[7:0] - 8'd1;
    wire [27:0] cmd_addr_c = BASE_ADDR + {4'd0, seq_rx, 8'd0};

    wire [31:0] digest_c = acc0 ^ acc1 ^ acc2 ^ acc3;
    wire [31:0] rdigest_c = racc0 ^ racc1 ^ racc2 ^ racc3;
    wire [15:0] rd_len_c = (rd_seq + 16'd1 == frame_cnt) ? last_len : 16'd256;
    wire [8:0]  rd_beats_c = {1'b0, rd_len_c[15:5]} + (|rd_len_c[4:0] ? 9'd1 : 9'd0);
    wire [7:0]  rd_cmd_len_c = rd_beats_c[7:0] - 8'd1;

    always @* wdata = wdata_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            seq_rx     <= 16'd0;
            len_rx     <= 16'd0;
            pay_idx    <= 16'd0;
            crc_rx     <= 16'd0;
            crc_calc   <= 16'hFFFF;
            beat_idx   <= 8'd0;
            cmd_valid  <= 1'b0;
            cmd        <= 37'd0;
            tx_valid   <= 1'b0;
            tx_data    <= 8'd0;
            tx_pos     <= 4'd0;
            tx_pend    <= 1'b0;
            tx_saw_low <= 1'b0;
            busy       <= 1'b0;
            weight_ok  <= 1'b0;
            weight_err <= 1'b0;
            err_addr   <= 28'd0;
            frame_cnt  <= 16'd0;
            acc0       <= 32'd0;
            acc1       <= 32'd0;
            acc2       <= 32'd0;
            acc3       <= 32'd0;
            racc0      <= 32'd0;
            racc1      <= 32'd0;
            racc2      <= 32'd0;
            racc3      <= 32'd0;
            rd_seq     <= 16'd0;
            last_len   <= 16'd0;
            rd_ready   <= 1'b0;
        end else begin
            tx_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (rx_valid && rx_data == 8'hAA) begin
                        busy     <= 1'b1;
                        state    <= S_SOF1;
                        crc_calc <= 16'hFFFF;
                        weight_err <= 1'b0;
                    end
                end

                S_SOF1: begin
                    if (rx_valid) begin
                        if (rx_data == 8'h55) state <= S_SEQ0;
                        else                  state <= S_IDLE;
                    end
                end

                S_SEQ0: begin
                    if (rx_valid) begin
                        seq_rx   <= {8'd0, rx_data};
                        crc_calc <= crc16_step(crc_calc, rx_data);
                        state    <= S_SEQ1;
                    end
                end

                S_SEQ1: begin
                    if (rx_valid) begin
                        seq_rx   <= {rx_data, seq_rx[7:0]};
                        crc_calc <= crc16_step(crc_calc, rx_data);
                        state    <= S_LEN0;
                    end
                end

                S_LEN0: begin
                    if (rx_valid) begin
                        len_rx   <= {8'd0, rx_data};
                        crc_calc <= crc16_step(crc_calc, rx_data);
                        state    <= S_LEN1;
                    end
                end

                S_LEN1: begin
                    if (rx_valid) begin
                        len_rx   <= {rx_data, len_rx[7:0]};
                        crc_calc <= crc16_step(crc_calc, rx_data);
                        pay_idx  <= 16'd0;
                        if (rx_data == 8'd0 && len_rx[7:0] == 8'd0)
                            state <= S_CRC0;
                        else
                            state <= S_PAY;
                    end
                end

                S_PAY: begin
                    if (rx_valid) begin
                        beat_buf[pay_idx[7:5]][(pay_idx[4:0] * 8) +: 8] <= rx_data;
                        crc_calc <= crc16_step(crc_calc, rx_data);
                        pay_idx  <= pay_idx + 16'd1;
                        if (pay_idx + 16'd1 == len_rx)
                            state <= S_CRC0;
                    end
                end

                S_CRC0: begin
                    if (rx_valid) begin
                        crc_rx <= {8'd0, rx_data};
                        state  <= S_CRC1;
                    end
                end

                S_CRC1: begin
                    if (rx_valid) begin
                        crc_rx <= {rx_data, crc_rx[7:0]};
                        state  <= S_CHECK;
                    end
                end

                S_CHECK: begin
                    if (crc_rx != crc_calc) begin
                        weight_err <= 1'b1;
                        err_addr   <= cmd_addr_c;
                        state      <= S_NAK;
                    end else if (len_rx == 16'd0) begin

                        rd_seq <= 16'd0;
                        racc0  <= 32'd0;
                        racc1  <= 32'd0;
                        racc2  <= 32'd0;
                        racc3  <= 32'd0;
                        state  <= S_RD_SET;
                    end else if (seq_rx != frame_cnt) begin
                        weight_err <= 1'b1;
                        err_addr   <= cmd_addr_c;
                        state      <= S_NAK;
                    end else begin
                        beat_idx  <= 8'd0;
                        last_len  <= len_rx;
                        cmd       <= {1'b1, cmd_addr_c, cmd_len_c};
                        cmd_valid <= 1'b1;
                        state     <= S_WRITE;
                    end
                end

                S_WRITE: begin
                    if (wready_beat) begin
                        acc0 <= acc0 + wdata[31:0]   + wdata[159:128];
                        acc1 <= acc1 + wdata[63:32]  + wdata[191:160];
                        acc2 <= acc2 + wdata[95:64]  + wdata[223:192];
                        acc3 <= acc3 + wdata[127:96] + wdata[255:224];
                        beat_idx <= beat_idx + 8'd1;
                    end
                    if (done) begin
                        cmd_valid <= 1'b0;
                        frame_cnt <= frame_cnt + 16'd1;
                        state     <= S_ACK;
                    end
                end

                S_ACK: begin

                    if (!tx_pend) begin
                        if (tx_ready) begin
                            tx_data    <= 8'h4B;
                            tx_valid   <= 1'b1;
                            tx_pend    <= 1'b1;
                            tx_saw_low <= 1'b0;
                        end
                    end else if (!tx_ready) begin
                        tx_saw_low <= 1'b1;
                    end else if (tx_saw_low) begin
                        tx_pend    <= 1'b0;
                        tx_saw_low <= 1'b0;
                        state      <= S_IDLE;
                    end
                end

                S_NAK: begin

                    if (!tx_pend) begin
                        if (tx_ready) begin
                            tx_data    <= 8'h4E;
                            tx_valid   <= 1'b1;
                            tx_pend    <= 1'b1;
                            tx_saw_low <= 1'b0;
                        end
                    end else if (!tx_ready) begin
                        tx_saw_low <= 1'b1;
                    end else if (tx_saw_low) begin
                        tx_pend    <= 1'b0;
                        tx_saw_low <= 1'b0;
                        state      <= S_IDLE;
                    end
                end

                S_RD_SET: begin
                    if (rd_seq == frame_cnt) begin
                        state <= S_RD_CHK;
                    end else begin
                        cmd       <= {1'b0, (BASE_ADDR + {4'd0, rd_seq, 8'd0}), rd_cmd_len_c};
                        cmd_valid <= 1'b1;
                        rd_ready  <= 1'b1;
                        state     <= S_RD_BEAT;
                    end
                end

                S_RD_BEAT: begin
                    if (rd_valid) begin
                        racc0 <= racc0 + rd_data[31:0]   + rd_data[159:128];
                        racc1 <= racc1 + rd_data[63:32]  + rd_data[191:160];
                        racc2 <= racc2 + rd_data[95:64]  + rd_data[223:192];
                        racc3 <= racc3 + rd_data[127:96] + rd_data[255:224];
                    end
                    if (done) begin
                        cmd_valid <= 1'b0;
                        rd_ready  <= 1'b0;
                        rd_seq    <= rd_seq + 16'd1;
                        state     <= S_RD_SET;
                    end
                end

                S_RD_CHK: begin
                    tx_line[0] <= 8'h57;
                    tx_line[1] <= 8'h4F;
                    tx_line[2] <= 8'h4B;
                    tx_line[3] <= 8'h20;
                    if (rdigest_c != digest_c) begin
                        tx_line[1] <= 8'h45;
                        tx_line[2] <= 8'h52;
                        tx_line[3] <= 8'h52;
                        weight_err <= 1'b1;
                        err_addr   <= BASE_ADDR + {4'd0, rd_seq, 8'd0};
                    end else begin
                        weight_ok <= 1'b1;
                    end
                    tx_line[4]  <= hex_ascii(rdigest_c[31:28]);
                    tx_line[5]  <= hex_ascii(rdigest_c[27:24]);
                    tx_line[6]  <= hex_ascii(rdigest_c[23:20]);
                    tx_line[7]  <= hex_ascii(rdigest_c[19:16]);
                    tx_line[8]  <= hex_ascii(rdigest_c[15:12]);
                    tx_line[9]  <= hex_ascii(rdigest_c[11:8]);
                    tx_line[10] <= hex_ascii(rdigest_c[7:4]);
                    tx_line[11] <= hex_ascii(rdigest_c[3:0]);
                    tx_line[12] <= 8'h0A;
                    tx_pos      <= 4'd0;
                    state       <= S_END;
                end

                S_END: begin
                    tx_pend    <= 1'b0;
                    tx_saw_low <= 1'b0;
                    state      <= S_TX;
                end

                S_TX: begin

                    if (!tx_pend) begin
                        if (tx_ready) begin
                            tx_data    <= tx_line[tx_pos];
                            tx_valid   <= 1'b1;
                            tx_pend    <= 1'b1;
                            tx_saw_low <= 1'b0;
                        end
                    end else if (!tx_ready) begin
                        tx_saw_low <= 1'b1;
                    end else if (tx_saw_low) begin
                        tx_pend    <= 1'b0;
                        tx_saw_low <= 1'b0;
                        if (tx_pos == 4'd12) begin
                            state     <= S_FIN;
                            weight_ok <= 1'b1;
                        end else begin
                            tx_pos <= tx_pos + 4'd1;
                        end
                    end
                end

                S_FIN: begin
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    always @* digest = digest_c;

endmodule
