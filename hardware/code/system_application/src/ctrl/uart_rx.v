module uart_rx #(

    parameter integer BAUD_DIV = 1085
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       uart_rxd,
    output reg  [7:0] byte_rdata,
    output reg        byte_rvalid
);

    reg rxd_meta;
    reg rxd_sync;
    reg rxd_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_meta <= 1'b1;
            rxd_sync <= 1'b1;
            rxd_prev <= 1'b1;
        end else begin
            rxd_meta <= uart_rxd;
            rxd_sync <= rxd_meta;
            rxd_prev <= rxd_sync;
        end
    end

    wire start_edge = rxd_prev & ~rxd_sync;

    localparam integer START_MID = (BAUD_DIV + 1) / 2;

    reg [1:0]  state;
    reg [10:0] samp_cnt;
    reg [3:0]  bit_idx;
    reg [7:0]  shifter;

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_START = 2'd1;
    localparam [1:0] ST_DATA  = 2'd2;
    localparam [1:0] ST_STOP  = 2'd3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            samp_cnt  <= 11'd0;
            bit_idx   <= 4'd0;
            shifter   <= 8'd0;
            byte_rdata  <= 8'd0;
            byte_rvalid <= 1'b0;
        end else begin
            byte_rvalid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start_edge) begin
                        samp_cnt <= 11'd0;
                        state    <= ST_START;
                    end
                end

                ST_START: begin

                    if (samp_cnt == START_MID - 1) begin
                        samp_cnt <= 11'd0;
                        if (rxd_sync == 1'b0) begin
                            bit_idx <= 4'd0;
                            state   <= ST_DATA;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end else begin
                        samp_cnt <= samp_cnt + 11'd1;
                    end
                end

                ST_DATA: begin

                    if (samp_cnt == BAUD_DIV - 1) begin
                        samp_cnt <= 11'd0;
                        shifter  <= {rxd_sync, shifter[7:1]};
                        if (bit_idx == 4'd7) begin
                            state <= ST_STOP;
                        end else begin
                            bit_idx <= bit_idx + 4'd1;
                        end
                    end else begin
                        samp_cnt <= samp_cnt + 11'd1;
                    end
                end

                ST_STOP: begin

                    if (samp_cnt == BAUD_DIV - 1) begin
                        if (rxd_sync == 1'b1) begin
                            byte_rdata  <= shifter;
                            byte_rvalid <= 1'b1;
                        end

                        state <= ST_IDLE;
                    end else begin
                        samp_cnt <= samp_cnt + 11'd1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
