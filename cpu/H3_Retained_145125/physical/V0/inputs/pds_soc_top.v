module pds_soc_top (
    input wire clk,
    input wire rst_n,
    input wire key,
    input wire uart_rx,
    output wire uart_tx,
    output wire [7:0] led
);
    wire cpu_clk,clock_locked;
    generate
        if(145125000==27000000) begin : direct_clock
            assign cpu_clk=clk;
            assign clock_locked=1'b1;
        end else begin : multiplied_clock
            rv32_pll #(.CLOCK_HZ(145125000)) clock_source(
                .reference_clk(clk),.reset(~rst_n),.cpu_clk(cpu_clk),.locked(clock_locked)
            );
        end
    endgenerate
    rv32_board_top #(.DATA_OVERLAP(1),.BTB_INDEX_BITS(8),.EARLY_D_REQUEST(1),.FAST_DCACHE_WRITE(1),.FAST_DCACHE_READ(1),.FETCH_OVERLAP(1),.ENABLE_M(1),.ENABLE_C(1),.CLOCK_HZ(145125000),.INIT_FILE("E:/AAAFPGA-builds/h3o-retained-eligibility-token/physical/rvc-physical-20261008T023702Z-253f7758/inputs/firmware.hex"),.ENABLE_PREDICTOR(1),.LOAD_USE_BUBBLE(1),.FAST_ICACHE_HIT(1),.ICACHE_SET_BITS(9),.CACHE_SET_BITS(6),.ENABLE_CACHE(1),.UART_BAUD(9600)) board(
        .clk(cpu_clk),.rst_n(rst_n & clock_locked),.key(key),.uart_rx(uart_rx),.uart_tx(uart_tx),.led(led)
    );
endmodule
