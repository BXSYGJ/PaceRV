module uart_tx #(

    parameter integer BAUD_DIV = 1085
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] byte_wdata,
    input  wire       byte_wvalid,
    output reg        byte_wready,
    output reg        uart_txd
);

    localparam [3:0] BIT_START = 4'd0;
    localparam [3:0] BIT_STOP  = 4'd9;

    reg [3:0]  bit_idx;
    reg [10:0] div_cnt;
    reg [7:0]  tx_byte;
    reg        busy;

    wire tx_bit;

    assign tx_bit = (bit_idx == BIT_START) ? 1'b0 :
                    (bit_idx == BIT_STOP)  ? 1'b1 :
                    tx_byte[bit_idx - 4'd1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_idx     <= 4'd0;
            div_cnt     <= 11'd0;
            tx_byte     <= 8'd0;
            busy        <= 1'b0;
            byte_wready <= 1'b0;
            uart_txd    <= 1'b1;
        end else begin

            byte_wready <= ~busy;

            if (!busy) begin
                if (byte_wvalid && byte_wready) begin
                    tx_byte <= byte_wdata;
                    bit_idx <= BIT_START;
                    div_cnt <= 11'd0;
                    busy    <= 1'b1;

                end else begin
                    uart_txd <= 1'b1;
                end
            end else begin
                uart_txd <= tx_bit;
                if (div_cnt == BAUD_DIV - 1) begin
                    div_cnt <= 11'd0;
                    if (bit_idx == BIT_STOP) begin
                        busy <= 1'b0;
                    end else begin
                        bit_idx <= bit_idx + 4'd1;
                    end
                end else begin
                    div_cnt <= div_cnt + 11'd1;
                end
            end
        end
    end

endmodule
