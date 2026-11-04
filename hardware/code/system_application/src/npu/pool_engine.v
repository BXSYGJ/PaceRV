module pool_engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        layer_start,

    input  wire [15:0] cin,
    input  wire [15:0] w_in,
    input  wire [15:0] h_in,

    input  wire        y_valid,
    output wire        y_ready,
    input wire         p_ready,
    input  wire [7:0]  y_u8,

    output wire        p_valid,
    output wire [7:0]  p_u8,
    output wire        p_last
);

    reg p_valid_prod, p_last_prod;
    reg [7:0] p_u8_prod;
    reg [8:0] output_fifo [0:7];
    reg [2:0] fifo_wr, fifo_rd;
    reg [3:0] fifo_count, reserved;
    wire accept_y=y_valid && y_ready;
    wire pop=(fifo_count!=0) && p_ready;
    assign y_ready=(reserved<8) && !layer_start;
    assign p_valid=(fifo_count!=0);
    assign p_u8=output_fifo[fifo_rd][7:0];
    assign p_last=(fifo_count!=0) && output_fifo[fifo_rd][8];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin fifo_wr<=0; fifo_rd<=0; fifo_count<=0; reserved<=0; end
        else if(layer_start) begin fifo_wr<=0; fifo_rd<=0; fifo_count<=0; reserved<=0; end
        else begin
            if(p_valid_prod) begin
                output_fifo[fifo_wr]<={p_last_prod,p_u8_prod}; fifo_wr<=fifo_wr+1'b1;
            end
            if(pop) fifo_rd<=fifo_rd+1'b1;
            case({p_valid_prod,pop})
                2'b10:fifo_count<=fifo_count+1'b1;
                2'b01:fifo_count<=fifo_count-1'b1;
                default:fifo_count<=fifo_count;
            endcase
            case({fire_c,pop})
                2'b10:reserved<=reserved+1'b1;
                2'b01:reserved<=reserved-1'b1;
                default:reserved<=reserved;
            endcase
        end
    end

    localparam SEG = 4096;
    (* syn_ramstyle = "block_ram" *) reg [7:0] ev0_lo [0:SEG-1];
    (* syn_ramstyle = "block_ram" *) reg [7:0] ev0_hi [0:SEG-1];
    (* syn_ramstyle = "block_ram" *) reg [7:0] od0_lo [0:SEG-1];
    (* syn_ramstyle = "block_ram" *) reg [7:0] od0_hi [0:SEG-1];
    (* syn_ramstyle = "block_ram" *) reg [7:0] ev1_lo [0:SEG-1];
    (* syn_ramstyle = "block_ram" *) reg [7:0] ev1_hi [0:SEG-1];
    (* syn_ramstyle = "block_ram" *) reg [7:0] od1_lo [0:SEG-1];
    (* syn_ramstyle = "block_ram" *) reg [7:0] od1_hi [0:SEG-1];

    reg [3:0]  lane_cnt;
    reg [15:0] col_cnt;
    reg [7:0]  grp_cnt;
    reg [15:0] row_cnt;

    wire [15:0] out_w    = w_in >> 1;
    wire [15:0] out_h    = h_in >> 1;
    wire [15:0] col_last = (out_w << 1) - 16'd1;
    wire [15:0] row_last = (out_h << 1) - 16'd1;
    wire [15:0] col_all  = w_in - 16'd1;
    wire [15:0] grp_last = (cin >> 4) - 16'd1;

    reg [15:0] idx;
    reg [15:0] grp_base;
    wire [15:0] grp_step = out_w << 4;

    wire row_hi = row_cnt[0];
    wire col_hi = col_cnt[0];

    wire        wr_hi  = idx[12];
    wire [11:0] wr_off = idx[11:0];

    always @(posedge clk) begin
        if (accept_y && col_cnt <= col_last) begin
            if (!row_hi) begin
                if (!col_hi) begin
                    if (!wr_hi) ev0_lo[wr_off] <= y_u8;
                    else        ev0_hi[wr_off] <= y_u8;
                end else begin
                    if (!wr_hi) od0_lo[wr_off] <= y_u8;
                    else        od0_hi[wr_off] <= y_u8;
                end
            end else begin
                if (!col_hi) begin
                    if (!wr_hi) ev1_lo[wr_off] <= y_u8;
                    else        ev1_hi[wr_off] <= y_u8;
                end else begin
                    if (!wr_hi) od1_lo[wr_off] <= y_u8;
                    else        od1_hi[wr_off] <= y_u8;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (accept_y && !col_hi && (col_cnt <= col_last)) cur_prev[lane_cnt] <= y_u8;
    end

    reg [15:0] rd_idx_q;
    reg        rd_row_hi_q;
    reg [7:0]  y_d1, y_d2;
    reg        fire_d1, fire_d2;
    reg        last_d1, last_d2;
    reg [3:0]  lane_d1, lane_d2;

    reg [7:0]  prev_even_q, prev_odd_q;

    reg [7:0]  cur_prev [0:15];

    wire fire_c = accept_y && row_hi && col_hi && (col_cnt <= col_last);
    wire last_c = fire_c && (row_cnt == row_last) && (grp_cnt == grp_last[7:0]) &&
                  (col_cnt == col_last) && (lane_cnt == 4'd15);

    always @(posedge clk) begin
        rd_idx_q    <= idx;
        rd_row_hi_q <= row_hi;
        y_d1        <= y_u8;
        y_d2        <= y_d1;
        lane_d1     <= lane_cnt;
        lane_d2     <= lane_d1;
        fire_d1     <= layer_start ? 1'b0 : fire_c;
        fire_d2     <= layer_start ? 1'b0 : fire_d1;
        last_d1     <= layer_start ? 1'b0 : last_c;
        last_d2     <= layer_start ? 1'b0 : last_d1;
    end

    wire        rd_hi  = rd_idx_q[12];
    wire [11:0] rd_off = rd_idx_q[11:0];

    always @(posedge clk) begin
        if (!rd_row_hi_q) begin
            prev_even_q <= rd_hi ? ev1_hi[rd_off] : ev1_lo[rd_off];
            prev_odd_q  <= rd_hi ? od1_hi[rd_off] : od1_lo[rd_off];
        end else begin
            prev_even_q <= rd_hi ? ev0_hi[rd_off] : ev0_lo[rd_off];
            prev_odd_q  <= rd_hi ? od0_hi[rd_off] : od0_lo[rd_off];
        end
    end

    wire [7:0] cur_even_d = cur_prev[lane_d2];
    wire [7:0] m_prev = (prev_even_q > prev_odd_q) ? prev_even_q : prev_odd_q;
    wire [7:0] m_cur  = (cur_even_d  > y_d2)       ? cur_even_d  : y_d2;
    wire [7:0] p_max  = (m_prev      > m_cur)      ? m_prev      : m_cur;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lane_cnt <= 4'd0;
            col_cnt  <= 16'd0;
            grp_cnt  <= 8'd0;
            row_cnt  <= 16'd0;
            idx      <= 16'd0;
            grp_base <= 16'd0;
            p_valid_prod  <= 1'b0;
            p_u8_prod     <= 8'd0;
            p_last_prod   <= 1'b0;
        end else if (layer_start) begin
            lane_cnt <= 4'd0;
            col_cnt  <= 16'd0;
            grp_cnt  <= 8'd0;
            row_cnt  <= 16'd0;
            idx      <= 16'd0;
            grp_base <= 16'd0;
            p_valid_prod  <= 1'b0;
            p_last_prod   <= 1'b0;
        end else begin
            p_valid_prod <= fire_d2;
            if (fire_d2) p_u8_prod <= p_max;
            if (last_d2) p_last_prod <= 1'b1;

            if (accept_y) begin
                if (lane_cnt == 4'd15) begin
                    lane_cnt <= 4'd0;
                    if (col_cnt == col_all) begin
                        col_cnt <= 16'd0;
                        if (grp_cnt == grp_last[7:0]) begin
                            grp_cnt  <= 8'd0;
                            row_cnt  <= row_cnt + 16'd1;
                            idx      <= 16'd0;
                            grp_base <= 16'd0;
                        end else begin
                            grp_cnt  <= grp_cnt + 8'd1;
                            grp_base <= grp_base + grp_step;
                            idx      <= grp_base + grp_step;
                        end
                    end else begin
                        col_cnt <= col_cnt + 16'd1;
                        idx     <= grp_base + ((col_cnt + 16'd1) >> 1);
                    end
                end else begin
                    lane_cnt <= lane_cnt + 4'd1;
                    idx      <= idx + out_w;
                end
            end
        end
    end

endmodule
