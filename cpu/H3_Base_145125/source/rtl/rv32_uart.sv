`timescale 1ns/1ps
module rv32_uart #(
    parameter integer CLOCK_HZ=27000000,
    parameter integer BAUD=115200
) (
    input wire clk,
    input wire rst_n,
    input wire serial_rx,
    output wire serial_tx,
    input wire tx_valid,
    output wire tx_ready,
    input wire [7:0] tx_data,
    output reg tx_busy,
    output reg rx_valid,
    input wire rx_ready,
    output reg [7:0] rx_data,
    output reg framing_error,
    output reg overrun_error
);
    localparam integer DIVIDER=(CLOCK_HZ+BAUD/2)/BAUD;
    localparam integer COUNTER_BITS=$clog2(DIVIDER);
    localparam [31:0] RELOAD_VALUE=DIVIDER-1;
    localparam [31:0] HALF_RELOAD_VALUE=DIVIDER/2-1;
    localparam [2:0] IDLE=0,START=1,DATA=2,STOP=3,WAIT_HIGH=4;
    reg [COUNTER_BITS-1:0] tx_timer,rx_timer;
    reg [3:0] tx_bit;
    reg [2:0] rx_bit,rx_state;
    reg [9:0] tx_shift;
    reg [7:0] rx_shift;
    reg rx_meta,rx_sync;
    assign tx_ready=!tx_busy;
    assign serial_tx=tx_busy ? tx_shift[0] : 1'b1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            tx_busy<=0; tx_timer<=0; tx_bit<=0; tx_shift<=10'h3ff;
            rx_meta<=1; rx_sync<=1; rx_state<=IDLE; rx_timer<=0; rx_bit<=0; rx_shift<=0;
            rx_valid<=0; rx_data<=0; framing_error<=0; overrun_error<=0;
        end else begin
            rx_meta<=serial_rx; rx_sync<=rx_meta;
            framing_error<=0; overrun_error<=0;
            if(rx_valid && rx_ready) rx_valid<=0;
            if(!tx_busy) begin
                if(tx_valid) begin tx_shift<={1'b1,tx_data,1'b0}; tx_timer<=RELOAD_VALUE[COUNTER_BITS-1:0]; tx_bit<=0; tx_busy<=1; end
            end else if(tx_timer!=0) tx_timer<=tx_timer-1'b1;
            else begin
                tx_timer<=RELOAD_VALUE[COUNTER_BITS-1:0];
                if(tx_bit==9) tx_busy<=0;
                else begin tx_shift<={1'b1,tx_shift[9:1]}; tx_bit<=tx_bit+1'b1; end
            end
            case(rx_state)
                IDLE: if(!rx_sync) begin rx_state<=START; rx_timer<=HALF_RELOAD_VALUE[COUNTER_BITS-1:0]; end
                START: begin
                    if(rx_timer!=0) rx_timer<=rx_timer-1'b1;
                    else if(rx_sync) rx_state<=IDLE;
                    else begin rx_state<=DATA; rx_bit<=0; rx_timer<=RELOAD_VALUE[COUNTER_BITS-1:0]; end
                end
                DATA: begin
                    if(rx_timer!=0) rx_timer<=rx_timer-1'b1;
                    else begin
                        rx_shift[rx_bit]<=rx_sync; rx_timer<=RELOAD_VALUE[COUNTER_BITS-1:0];
                        if(rx_bit==7) rx_state<=STOP;
                        else rx_bit<=rx_bit+1'b1;
                    end
                end
                STOP: begin
                    if(rx_timer!=0) rx_timer<=rx_timer-1'b1;
                    else if(!rx_sync) begin framing_error<=1; rx_state<=WAIT_HIGH; end
                    else begin
                        if(!rx_valid || rx_ready) begin rx_valid<=1; rx_data<=rx_shift; end
                        else overrun_error<=1;
                        rx_state<=IDLE;
                    end
                end
                WAIT_HIGH: if(rx_sync) rx_state<=IDLE;
                default: rx_state<=IDLE;
            endcase
        end
    end
endmodule
