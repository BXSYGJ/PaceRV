`timescale 1ns/1ps
module rv32_soc #(
    parameter integer ENABLE_M=0,
    parameter integer ENABLE_C=0,
    parameter integer CLOCK_HZ=27000000,
    parameter integer BAUD=115200,
    parameter integer MEMORY_ADDRESS_BITS=14,
    parameter integer ENABLE_PREDICTOR=1,
    parameter integer LOAD_USE_BUBBLE=0,
    parameter integer FAST_ICACHE_HIT=0,
    parameter integer FAST_DCACHE_READ=0,
    parameter integer FAST_DCACHE_WRITE=0,
    parameter integer FETCH_OVERLAP=0,
    parameter integer DATA_OVERLAP=0,
    parameter integer EARLY_D_REQUEST=0,
    parameter integer BTB_INDEX_BITS=4,
    parameter integer ICACHE_SET_BITS=0,
    parameter integer CACHE_SET_BITS=4,
    parameter integer ENABLE_CACHE=1,
    parameter INIT_FILE=""
) (
    input wire clk,
    input wire rst_n,
    input wire serial_rx,
    output wire serial_tx,
    input wire [7:0] gpio_input,
    output wire [7:0] gpio_output,
    output wire [31:0] status_code,
    output reg maintenance_fault,
    output wire trace_valid,
    output wire [31:0] trace_pc,
    output wire [31:0] trace_instruction,
    output wire trap_valid,
    output wire [31:0] trap_cause,
    output wire [63:0] cycle_count,
    output wire [63:0] retired_count
);
    wire i_req_valid,i_req_ready,i_rsp_valid,i_rsp_ready,i_rsp_error;
    wire [31:0] i_rsp_pair_data;
    wire [1:0] i_rsp_is_c,i_rsp_pair_is_c;
    wire i_rsp_pair_valid;
    wire d_req_valid,d_req_ready,d_req_write,d_rsp_valid,d_rsp_ready,d_rsp_error;
    wire [31:0] i_req_address,i_req_pair_address,i_rsp_data,d_req_address,d_req_data,d_rsp_data;
    wire [3:0] d_req_strobe;
    wire maintenance_valid,maintenance_ready,memory_ready,memory_error;
    wire mmio_req_valid,mmio_req_ready,mmio_req_write,mmio_rsp_valid,mmio_rsp_ready,mmio_rsp_error;
    wire [31:0] mmio_req_address,mmio_req_data,mmio_rsp_data;
    wire [3:0] mmio_req_strobe;
    wire irq_external,irq_software,irq_timer;
    wire [63:0] timer_value;
    wire unused_trace_write;
    wire [4:0] unused_trace_rd,unused_pipeline_valid;
    wire [31:0] unused_trace_data,unused_trap_pc,unused_trap_value;
    wire [31:0] i_hits,i_misses,d_hits,d_misses,writebacks;
    wire [287:0] performance_values={writebacks,d_misses,d_hits,i_misses,i_hits,retired_count,cycle_count};
    localparam [31:0] PERFORMANCE_CONFIG=((ICACHE_SET_BITS!=0 && ICACHE_SET_BITS!=CACHE_SET_BITS ? ICACHE_SET_BITS : 0)<<12) | (FAST_DCACHE_WRITE!=0 && ENABLE_CACHE!=0 ? (1<<19) : 0) | (DATA_OVERLAP!=0 ? (1<<18) : 0) | ((BTB_INDEX_BITS==4 ? 0 : BTB_INDEX_BITS)<<20) | (MEMORY_ADDRESS_BITS<<24) | (ENABLE_C!=0 ? (1<<28) : 0) | (2<<16) | (CACHE_SET_BITS<<8) | (ENABLE_PREDICTOR!=0 ? 1 : 0) | (ENABLE_CACHE==0 ? 2 : 0) | (LOAD_USE_BUBBLE!=0 ? 4 : 0) | (FAST_ICACHE_HIT!=0 && ENABLE_CACHE!=0 ? 8 : 0) | (ENABLE_M!=0 ? 16 : 0) | (FETCH_OVERLAP!=0 ? 32 : 0) | (FAST_DCACHE_READ!=0 && ENABLE_CACHE!=0 ? 64 : 0) | (EARLY_D_REQUEST!=0 ? 128 : 0);
    assign maintenance_ready=memory_ready && !memory_error && !maintenance_fault;
    rv32_core #(.FETCH_ADDRESS_BITS(MEMORY_ADDRESS_BITS+2),.BTB_ADDRESS_BITS(MEMORY_ADDRESS_BITS+2),.BTB_INDEX_BITS(BTB_INDEX_BITS),.EARLY_D_REQUEST(EARLY_D_REQUEST),.FETCH_OVERLAP(FETCH_OVERLAP),.ENABLE_M(ENABLE_M),.ENABLE_C(ENABLE_C),.ENABLE_PREDICTOR(ENABLE_PREDICTOR),.LOAD_USE_BUBBLE(LOAD_USE_BUBBLE)) core(
        .i_rsp_pair_data(i_rsp_pair_data),.i_rsp_pair_valid(i_rsp_pair_valid),.i_rsp_is_c(i_rsp_is_c),.i_rsp_pair_is_c(i_rsp_pair_is_c),
        .clk(clk),.rst_n(rst_n),
        .i_req_valid(i_req_valid),.i_req_ready(i_req_ready),.i_req_address(i_req_address),.i_req_pair_address(i_req_pair_address),.i_rsp_valid(i_rsp_valid),.i_rsp_ready(i_rsp_ready),.i_rsp_data(i_rsp_data),.i_rsp_error(i_rsp_error),
        .d_req_valid(d_req_valid),.d_req_ready(d_req_ready),.d_req_address(d_req_address),.d_req_data(d_req_data),.d_req_strobe(d_req_strobe),.d_req_write(d_req_write),
        .d_rsp_valid(d_rsp_valid),.d_rsp_ready(d_rsp_ready),.d_rsp_data(d_rsp_data),.d_rsp_error(d_rsp_error),
        .maintenance_valid(maintenance_valid),.maintenance_ready(maintenance_ready),.timer_value(timer_value),.irq_external(irq_external),.irq_software(irq_software),.irq_timer(irq_timer),
        .trace_valid(trace_valid),.trace_pc(trace_pc),.trace_instruction(trace_instruction),.trace_write(unused_trace_write),.trace_rd(unused_trace_rd),.trace_data(unused_trace_data),
        .trap_valid(trap_valid),.trap_pc(unused_trap_pc),.trap_cause(trap_cause),.trap_value(unused_trap_value),.pipeline_valid(unused_pipeline_valid),.cycle_count(cycle_count),.retired_count(retired_count)
    );
    rv32_memory_system #(.ENABLE_C(ENABLE_C),.DATA_OVERLAP(DATA_OVERLAP),.MEMORY_ADDRESS_BITS(MEMORY_ADDRESS_BITS),.ICACHE_SET_BITS(ICACHE_SET_BITS),.CACHE_SET_BITS(CACHE_SET_BITS),.ENABLE_CACHE(ENABLE_CACHE),.FETCH_OVERLAP(FETCH_OVERLAP),.FAST_DCACHE_WRITE(FAST_DCACHE_WRITE),.FAST_DCACHE_READ(FAST_DCACHE_READ),.FAST_ICACHE_HIT(FAST_ICACHE_HIT),.INIT_FILE(INIT_FILE)) memory_system(
        .i_rsp_pair_data(i_rsp_pair_data),.i_rsp_pair_valid(i_rsp_pair_valid),.i_rsp_is_c(i_rsp_is_c),.i_rsp_pair_is_c(i_rsp_pair_is_c),
        .clk(clk),.rst_n(rst_n),
        .i_req_valid(i_req_valid),.i_req_ready(i_req_ready),.i_req_address(i_req_address),.i_req_pair_address(i_req_pair_address),.i_rsp_valid(i_rsp_valid),.i_rsp_ready(i_rsp_ready),.i_rsp_data(i_rsp_data),.i_rsp_error(i_rsp_error),
        .d_req_valid(d_req_valid),.d_req_ready(d_req_ready),.d_req_address(d_req_address),.d_req_write(d_req_write),.d_req_data(d_req_data),.d_req_strobe(d_req_strobe),
        .d_rsp_valid(d_rsp_valid),.d_rsp_ready(d_rsp_ready),.d_rsp_data(d_rsp_data),.d_rsp_error(d_rsp_error),
        .maintenance_valid(maintenance_valid && !maintenance_fault),.maintenance_ready(memory_ready),.maintenance_error(memory_error),
        .mmio_req_valid(mmio_req_valid),.mmio_req_ready(mmio_req_ready),.mmio_req_address(mmio_req_address),.mmio_req_write(mmio_req_write),.mmio_req_data(mmio_req_data),.mmio_req_strobe(mmio_req_strobe),
        .mmio_rsp_valid(mmio_rsp_valid),.mmio_rsp_ready(mmio_rsp_ready),.mmio_rsp_data(mmio_rsp_data),.mmio_rsp_error(mmio_rsp_error),
        .i_hit_count(i_hits),.i_miss_count(i_misses),.d_hit_count(d_hits),.d_miss_count(d_misses),.d_writeback_count(writebacks)
    );
    // The memory system registers each accepted MMIO request before peripheral acceptance.
    // Reading on the accepted core request settles native RAM one edge before scalar capture.
    wire snapshot_pre_read=d_req_valid && d_req_ready && !d_req_write;
    wire [2:0] snapshot_pre_word_index=d_req_address[4:2]^3'd4;
    rv32_peripherals #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD),.SNAPSHOT_EARLY_READ(1)) peripherals(
        .snapshot_pre_read(snapshot_pre_read),.snapshot_pre_word_index(snapshot_pre_word_index),
        .performance_values(performance_values),.performance_config(PERFORMANCE_CONFIG),
        .clk(clk),.rst_n(rst_n),.req_valid(mmio_req_valid),.req_ready(mmio_req_ready),.req_address(mmio_req_address),.req_write(mmio_req_write),.req_data(mmio_req_data),.req_strobe(mmio_req_strobe),
        .rsp_valid(mmio_rsp_valid),.rsp_ready(mmio_rsp_ready),.rsp_data(mmio_rsp_data),.rsp_error(mmio_rsp_error),
        .serial_rx(serial_rx),.serial_tx(serial_tx),.gpio_input(gpio_input),.gpio_output(gpio_output),.irq_external(irq_external),.irq_software(irq_software),.irq_timer(irq_timer),.timer_value(timer_value),.status_code(status_code)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) maintenance_fault<=0;
        else if(maintenance_valid && memory_ready && memory_error) maintenance_fault<=1;
    end
endmodule
