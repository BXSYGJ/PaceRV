`timescale 1ns/1ps
module rv32_peripherals #(
    parameter integer CLOCK_HZ=27000000,
    parameter integer BAUD=115200,
    parameter integer SNAPSHOT_EARLY_READ=0
) (
    input wire clk,
    input wire rst_n,
    input wire [287:0] performance_values,
    input wire [31:0] performance_config,
    input wire snapshot_pre_read,
    input wire [2:0] snapshot_pre_word_index,
    input wire req_valid,
    output wire req_ready,
    input wire [31:0] req_address,
    input wire req_write,
    input wire [31:0] req_data,
    input wire [3:0] req_strobe,
    output reg rsp_valid,
    input wire rsp_ready,
    output wire [31:0] rsp_data,
    output reg rsp_error,
    input wire serial_rx,
    output wire serial_tx,
    input wire [7:0] gpio_input,
    output reg [7:0] gpio_output,
    output wire irq_external,
    output reg irq_software,
    output reg irq_timer,
    output reg [63:0] timer_value,
    output reg [31:0] status_code
);
    localparam [31:0] STATUS=32'h10000000,VERSION=32'h10000004,
        UART_DATA=32'h10000100,UART_STATUS=32'h10000104,UART_CONTROL=32'h10000108,UART_ERRORS=32'h1000010c,
        GPIO_OUTPUT=32'h10000200,GPIO_INPUT=32'h10000204,GPIO_ENABLE=32'h10000208,GPIO_PENDING=32'h1000020c,
        TIME_LOW=32'h10000300,TIME_HIGH=32'h10000304,COMPARE_LOW=32'h10000308,COMPARE_HIGH=32'h1000030c,SOFTWARE_IRQ=32'h10000310;
    reg [7:0] gpio_meta,gpio_sync,gpio_previous,gpio_enable,gpio_pending;
    reg [1:0] uart_control,uart_errors;
    reg [63:0] timer_compare;
    // Native64-write/8-read snapshot storage; actual vendor timing model is required in simulation.
    reg [31:0] rsp_data_scalar;
    reg [31:0] snapshot_tail;
    reg snapshot_valid,snapshot_response_selected;
    wire snapshot_capture=request_fire && req_write && req_address==32'h10000400 && req_strobe[0] && req_data[0];
    wire snapshot_read=request_fire && !req_write && req_address[1:0]==0 && req_address>=32'h10000410 && req_address<=32'h1000042c;
    wire [2:0] snapshot_word_index=req_address[4:2]^3'd4;
    wire [31:0] snapshot_memory_word;
    wire [2:0] snapshot_ram_word_index=SNAPSHOT_EARLY_READ!=0 ? snapshot_pre_word_index : snapshot_word_index;
    wire snapshot_ram_read=SNAPSHOT_EARLY_READ!=0 ? snapshot_pre_read : snapshot_read;
    assign rsp_data=SNAPSHOT_EARLY_READ!=0 ? rsp_data_scalar :
        (snapshot_response_selected ? (snapshot_valid ? snapshot_memory_word : 32'b0) : rsp_data_scalar);
    generate for(genvar bank=0;bank<4;bank=bank+1) begin: snapshot_bank
        wire [63:0] stripe;
        for(genvar word_index=0;word_index<8;word_index=word_index+1) begin: snapshot_word
            assign stripe[word_index*8+:8]=performance_values[word_index*32+bank*8+:8];
        end
        wire [35:0] native_input_low={1'b0,stripe[31:24],1'b0,stripe[23:16],1'b0,stripe[15:8],1'b0,stripe[7:0]};
        wire [35:0] native_input_high={1'b0,stripe[63:56],1'b0,stripe[55:48],1'b0,stripe[47:40],1'b0,stripe[39:32]};
        wire [35:0] native_output;
        assign snapshot_memory_word[bank*8+:8]=native_output[7:0];
        GTP_DRM36K_E1 #(.GRS_EN("FALSE"), .DATA_WIDTH_A(64),.DATA_WIDTH_B(8),
            .RAM_MODE("SIMPLE_DUAL_PORT"),.WRITE_MODE_A("NORMAL_WRITE"),.WRITE_MODE_B("NORMAL_WRITE"),
            .DOA_REG(0),.DOB_REG(0),.RST_TYPE("ASYNC"),.RAM_CASCADE("NONE"),
            .ECC_WRITE_EN("FALSE"),.ECC_READ_EN("FALSE")) native_ram(
            .DOA(),.DOB(native_output),.DIA(native_input_low),.DIB(native_input_high),
            .ADDRA(16'h8000),.ADDRB({1'b1,9'b0,snapshot_ram_word_index,3'b000}),
            .ADDRA_HOLD(1'b0),.ADDRB_HOLD(1'b0),.CSA(3'b000),.CSB(3'b000),
            .BWEA(8'hff),.BWEB(4'b0000),.CLKA(clk),.CLKB(clk),
            .CEA(rst_n && snapshot_capture),.CEB(rst_n && snapshot_ram_read),.WEA(1'b1),.WEB(1'b0),
            .ORCEA(1'b0),.ORCEB(1'b0),.RSTA(1'b0),.RSTB(1'b0),.CINA(1'b0),.CINB(1'b0),
            .INJECT_SBITERR(1'b0),.INJECT_DBITERR(1'b0),.ECC_SBITERR(),.ECC_DBITERR(),
            .ECC_RDADDR(),.ECC_PARITY(),.COUTA(),.COUTB());
    end endgenerate
    reg [31:0] snapshot_sequence;
    wire uart_tx_ready,uart_tx_valid,uart_tx_busy,uart_rx_ready,uart_rx_valid,framing_error,overrun_error;
    wire [7:0] uart_tx_data,uart_rx_data,rx_fifo_data;
    wire tx_fifo_ready,rx_fifo_valid,rx_fifo_pop;
    wire [4:0] tx_count,rx_count;
    wire [31:0] write_mask={{8{req_strobe[3]}},{8{req_strobe[2]}},{8{req_strobe[1]}},{8{req_strobe[0]}}};
    wire uart_write=req_write && req_address==UART_DATA && req_strobe[0];
    wire request_fire=req_valid && req_ready;
    wire [7:0] pending_clear=(request_fire && req_write && req_address==GPIO_PENDING) ? req_data[7:0] & write_mask[7:0] : 8'b0;
    wire [1:0] errors_clear=(request_fire && req_write && req_address==UART_ERRORS) ? req_data[1:0] & write_mask[1:0] : 2'b0;
    wire uart_idle=!uart_tx_valid && !uart_tx_busy;
    assign req_ready=!rsp_valid && (!uart_write || tx_fifo_ready);
    assign rx_fifo_pop=request_fire && !req_write && req_address==UART_DATA && rx_fifo_valid;
    assign irq_external=(|(gpio_pending & gpio_enable)) || (uart_control[0] && rx_fifo_valid) || (uart_control[1] && uart_idle);
    (* syn_keep=1 *) wire [63:0] timer_incremented;
    assign timer_incremented[15:0]=timer_value[15:0]+16'd1;
    generate for(genvar timer_chunk=1;timer_chunk<4;timer_chunk=timer_chunk+1) begin: timer_prefix_increment
        assign timer_incremented[timer_chunk*16+:16]=timer_value[timer_chunk*16+:16]+{15'b0,(&timer_value[timer_chunk*16-1:0])};
    end endgenerate
    reg [63:0] timer_value_next,timer_compare_next;
    always @* begin
        timer_value_next=timer_incremented;
        timer_compare_next=timer_compare;
        if(request_fire && req_write) begin
            case(req_address)
                TIME_LOW: timer_value_next={timer_value[63:32],(timer_value[31:0] & ~write_mask) | (req_data & write_mask)};
                TIME_HIGH: timer_value_next={(timer_value[63:32] & ~write_mask) | (req_data & write_mask),timer_value[31:0]};
                COMPARE_LOW: timer_compare_next[31:0]=(timer_compare[31:0] & ~write_mask) | (req_data & write_mask);
                COMPARE_HIGH: timer_compare_next[63:32]=(timer_compare[63:32] & ~write_mask) | (req_data & write_mask);
                default: begin end
            endcase
        end
    end
    // Compare the values committed on this edge, including masked MMIO writes.
    // No timer state, response timing, interrupt latency, or capacity changes.
    wire timer_interrupt_next=timer_value_next>=timer_compare_next;
    rv32_fifo tx_fifo(.clk(clk),.rst_n(rst_n),.in_valid(request_fire && uart_write),.in_ready(tx_fifo_ready),.in_data(req_data[7:0]),
        .out_valid(uart_tx_valid),.out_ready(uart_tx_ready),.out_data(uart_tx_data),.count(tx_count));
    rv32_fifo rx_fifo(.clk(clk),.rst_n(rst_n),.in_valid(uart_rx_valid),.in_ready(uart_rx_ready),.in_data(uart_rx_data),
        .out_valid(rx_fifo_valid),.out_ready(rx_fifo_pop),.out_data(rx_fifo_data),.count(rx_count));
    rv32_uart #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) uart(.clk(clk),.rst_n(rst_n),.serial_rx(serial_rx),.serial_tx(serial_tx),
        .tx_valid(uart_tx_valid),.tx_ready(uart_tx_ready),.tx_data(uart_tx_data),.tx_busy(uart_tx_busy),
        .rx_valid(uart_rx_valid),.rx_ready(uart_rx_ready),.rx_data(uart_rx_data),.framing_error(framing_error),.overrun_error(overrun_error));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            rsp_valid<=0; rsp_data_scalar<=0; rsp_error<=0; gpio_output<=0; status_code<=0;
            gpio_meta<=0; gpio_sync<=0; gpio_previous<=0; gpio_enable<=0; gpio_pending<=0;
            snapshot_tail<=0; snapshot_valid<=0; snapshot_response_selected<=0; snapshot_sequence<=0;
            uart_control<=0; uart_errors<=0; timer_value<=0; timer_compare<=64'hffffffffffffffff; irq_software<=0; irq_timer<=0;
        end else begin
            gpio_meta<=gpio_input; gpio_sync<=gpio_meta; gpio_previous<=gpio_sync;
            gpio_pending<=(gpio_pending & ~pending_clear) | (gpio_sync & ~gpio_previous);
            uart_errors<=(uart_errors & ~errors_clear) | {overrun_error,framing_error};
            timer_value<=timer_value_next; timer_compare<=timer_compare_next; irq_timer<=timer_interrupt_next;
            if(rsp_valid && rsp_ready) rsp_valid<=0;
            if(request_fire) begin
                snapshot_response_selected<=snapshot_read;
                rsp_valid<=1; rsp_error<=0; rsp_data_scalar<=0;
                if(req_address[1:0]!=0) rsp_error<=1;
                else if(req_write) begin
                    case(req_address)
                        STATUS: status_code<=(status_code & ~write_mask) | (req_data & write_mask);
                        UART_DATA: begin end
                        UART_CONTROL: uart_control<=(uart_control & ~write_mask[1:0]) | (req_data[1:0] & write_mask[1:0]);
                        UART_ERRORS,GPIO_PENDING: begin end
                        GPIO_OUTPUT: gpio_output<=(gpio_output & ~write_mask[7:0]) | (req_data[7:0] & write_mask[7:0]);
                        GPIO_ENABLE: gpio_enable<=(gpio_enable & ~write_mask[7:0]) | (req_data[7:0] & write_mask[7:0]);
                        TIME_LOW,TIME_HIGH,COMPARE_LOW,COMPARE_HIGH: begin end
                        SOFTWARE_IRQ: if(req_strobe[0]) irq_software<=req_data[0];
                        32'h10000400: if(req_strobe[0] && req_data[0]) begin
                            snapshot_tail<=performance_values[287:256]; snapshot_valid<=1;
                            snapshot_sequence<=snapshot_sequence+1'b1;
                        end
                        default: rsp_error<=1;
                    endcase
                end else begin
                    case(req_address)
                        STATUS: rsp_data_scalar<=status_code;
                        VERSION: rsp_data_scalar<=32'h00010000;
                        UART_DATA: rsp_data_scalar<=rx_fifo_valid ? {24'b0,rx_fifo_data} : 32'hffffffff;
                        UART_STATUS: rsp_data_scalar<={26'b0,uart_errors[1],uart_errors[0],(rx_count==16),rx_fifo_valid,uart_idle,tx_fifo_ready};
                        UART_CONTROL: rsp_data_scalar<={30'b0,uart_control};
                        UART_ERRORS: rsp_data_scalar<={30'b0,uart_errors};
                        GPIO_OUTPUT: rsp_data_scalar<={24'b0,gpio_output};
                        GPIO_INPUT: rsp_data_scalar<={24'b0,gpio_sync};
                        GPIO_ENABLE: rsp_data_scalar<={24'b0,gpio_enable};
                        GPIO_PENDING: rsp_data_scalar<={24'b0,gpio_pending};
                        TIME_LOW: rsp_data_scalar<=timer_value[31:0];
                        TIME_HIGH: rsp_data_scalar<=timer_value[63:32];
                        COMPARE_LOW: rsp_data_scalar<=timer_compare[31:0];
                        COMPARE_HIGH: rsp_data_scalar<=timer_compare[63:32];
                        SOFTWARE_IRQ: rsp_data_scalar<={31'b0,irq_software};
                        32'h10000400: rsp_data_scalar<=snapshot_sequence;
                        32'h10000404: rsp_data_scalar<=performance_config;
                        32'h10000410: if(SNAPSHOT_EARLY_READ!=0) rsp_data_scalar<=snapshot_valid ? snapshot_memory_word : 32'b0;
                        32'h10000414: if(SNAPSHOT_EARLY_READ!=0) rsp_data_scalar<=snapshot_valid ? snapshot_memory_word : 32'b0;
                        32'h10000418: if(SNAPSHOT_EARLY_READ!=0) rsp_data_scalar<=snapshot_valid ? snapshot_memory_word : 32'b0;
                        32'h1000041c: if(SNAPSHOT_EARLY_READ!=0) rsp_data_scalar<=snapshot_valid ? snapshot_memory_word : 32'b0;
                        32'h10000420: if(SNAPSHOT_EARLY_READ!=0) rsp_data_scalar<=snapshot_valid ? snapshot_memory_word : 32'b0;
                        32'h10000424: if(SNAPSHOT_EARLY_READ!=0) rsp_data_scalar<=snapshot_valid ? snapshot_memory_word : 32'b0;
                        32'h10000428: if(SNAPSHOT_EARLY_READ!=0) rsp_data_scalar<=snapshot_valid ? snapshot_memory_word : 32'b0;
                        32'h1000042c: if(SNAPSHOT_EARLY_READ!=0) rsp_data_scalar<=snapshot_valid ? snapshot_memory_word : 32'b0;
                        32'h10000430: rsp_data_scalar<=snapshot_tail;
                        default: rsp_error<=1;
                    endcase
                end
            end
        end
    end
endmodule
