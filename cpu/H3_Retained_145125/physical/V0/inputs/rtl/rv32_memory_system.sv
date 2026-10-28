`timescale 1ns/1ps
module rv32_memory_system #(
    parameter integer MEMORY_ADDRESS_BITS=12,
    parameter integer ICACHE_SET_BITS=0,
    parameter integer CACHE_SET_BITS=4,
    parameter integer CACHE_WORD_BITS=2,
    parameter integer ENABLE_CACHE=1,
    parameter integer ENABLE_C=0,
    parameter integer FAST_ICACHE_HIT=0,
    parameter integer FAST_DCACHE_READ=0,
    parameter integer FAST_DCACHE_WRITE=0,
    parameter integer FETCH_OVERLAP=0,
    parameter integer DATA_OVERLAP=0,
    parameter INIT_FILE=""
) (
    input wire clk,
    input wire rst_n,
    input wire i_req_valid,
    output wire i_req_ready,
    input wire [31:0] i_req_address,
    input wire [31:0] i_req_pair_address,
    output wire i_rsp_valid,
    input wire i_rsp_ready,
    output wire [31:0] i_rsp_data,
    output wire [31:0] i_rsp_pair_data,
    output wire [1:0] i_rsp_is_c,i_rsp_pair_is_c,
    output wire i_rsp_pair_valid,
    output wire i_rsp_error,
    input wire d_req_valid,
    output wire d_req_ready,
    input wire [31:0] d_req_address,
    input wire d_req_write,
    input wire [31:0] d_req_data,
    input wire [3:0] d_req_strobe,
    output wire d_rsp_valid,
    input wire d_rsp_ready,
    output wire [31:0] d_rsp_data,
    output wire d_rsp_error,
    input wire maintenance_valid,
    output wire maintenance_ready,
    output reg maintenance_error,
    output wire mmio_req_valid,
    input wire mmio_req_ready,
    output wire [31:0] mmio_req_address,
    output wire mmio_req_write,
    output wire [31:0] mmio_req_data,
    output wire [3:0] mmio_req_strobe,
    input wire mmio_rsp_valid,
    output wire mmio_rsp_ready,
    input wire [31:0] mmio_rsp_data,
    input wire mmio_rsp_error,
    output wire [31:0] i_hit_count,
    output wire [31:0] i_miss_count,
    output wire [31:0] d_hit_count,
    output wire [31:0] d_miss_count,
    output wire [31:0] d_writeback_count
);
    localparam [1:0] NORMAL=0,CLEAN_DATA=1,INVALIDATE_INSTRUCTIONS=2,MAINTENANCE_DONE=3;
    reg [1:0] maintenance_state;
    localparam [0:0] SHADOW_MMIO=ENABLE_CACHE!=0 && DATA_OVERLAP!=0 && MEMORY_ADDRESS_BITS<=26;
    reg data_active,data_mmio;
    reg mmio_request_pending,mmio_request_write;
    reg [31:0] mmio_request_address,mmio_request_data;
    reg [3:0] mmio_request_strobe;
    wire request_mmio=|d_req_address[31:28];
    wire data_issue=(!data_active || (DATA_OVERLAP!=0 && d_rsp_valid && d_rsp_ready)) && maintenance_state==NORMAL && !maintenance_valid;
    wire [1:0] cache_req_valid,cache_req_ready,cache_req_write,cache_rsp_valid,cache_rsp_ready,cache_rsp_error;
    wire [31:0] cache_req_address[0:1],cache_req_data[0:1],cache_rsp_data[0:1];
    wire [31:0] cache_pair_data[0:1];
    wire [1:0] cache_is_c[0:1],cache_pair_is_c[0:1];
    wire [1:0] cache_pair_valid;
    wire [3:0] cache_req_strobe[0:1];
    wire [1:0] cache_flush_valid,cache_flush_ready,cache_flush_error;
    wire [31:0] cache_hits[0:1],cache_misses[0:1],cache_writebacks[0:1];
    wire [1:0] master_cmd_valid,master_cmd_ready,master_cmd_write,master_w_valid,master_w_ready,master_w_last;
    wire [1:0] master_b_valid,master_b_ready,master_b_error,master_r_valid,master_r_ready,master_r_last,master_r_error;
    wire [31:0] master_cmd_address[0:1],master_w_data[0:1],master_r_data[0:1];
    wire [7:0] master_cmd_length[0:1];
    wire cmd_valid,cmd_ready,cmd_write,w_valid,w_ready,w_last,b_valid,b_ready,b_error,r_valid,r_ready,r_last,r_error;
    wire [31:0] cmd_address,w_data,r_data;
    wire [7:0] cmd_length;
    wire [31:0] unused_instruction_writebacks=cache_writebacks[0];
    assign cache_req_valid[0]=i_req_valid;
    assign cache_req_address[0]=i_req_address;
    assign cache_req_write[0]=0;
    assign cache_req_data[0]=0;
    assign cache_req_strobe[0]=0;
    assign i_req_ready=cache_req_ready[0];
    assign i_rsp_valid=cache_rsp_valid[0];
    assign i_rsp_data=cache_rsp_data[0];
    assign i_rsp_pair_data=cache_pair_data[0];
    assign i_rsp_is_c=cache_is_c[0];
    assign i_rsp_pair_is_c=cache_pair_is_c[0];
    assign i_rsp_pair_valid=cache_pair_valid[0];
    assign i_rsp_error=cache_rsp_error[0];
    assign cache_rsp_ready[0]=i_rsp_ready;
    assign cache_req_valid[1]=d_req_valid && data_issue && (SHADOW_MMIO!=0 || !request_mmio);
    assign cache_req_address[1]=d_req_address;
    assign cache_req_write[1]=d_req_write;
    assign cache_req_data[1]=d_req_data;
    assign cache_req_strobe[1]=d_req_strobe;
    assign d_req_ready=data_issue && (request_mmio ? !mmio_request_pending : cache_req_ready[1]);
    assign d_rsp_valid=data_active && (data_mmio ? mmio_rsp_valid : cache_rsp_valid[1]);
    assign d_rsp_data=data_mmio ? mmio_rsp_data : cache_rsp_data[1];
    assign d_rsp_error=data_mmio ? mmio_rsp_error : cache_rsp_error[1];
    assign cache_rsp_ready[1]=(SHADOW_MMIO!=0 && data_mmio) || (data_active && !data_mmio && d_rsp_ready);
    assign mmio_req_valid=mmio_request_pending;
    assign mmio_req_address=mmio_request_address;
    assign mmio_req_write=mmio_request_write;
    assign mmio_req_data=mmio_request_data;
    assign mmio_req_strobe=mmio_request_strobe;
    assign mmio_rsp_ready=data_active && data_mmio && d_rsp_ready;
    assign cache_flush_valid[0]=maintenance_state==INVALIDATE_INSTRUCTIONS;
    assign cache_flush_valid[1]=maintenance_state==CLEAN_DATA;
    assign maintenance_ready=maintenance_state==MAINTENANCE_DONE;
    assign i_hit_count=cache_hits[0];
    assign i_miss_count=cache_misses[0];
    assign d_hit_count=cache_hits[1];
    assign d_miss_count=cache_misses[1];
    assign d_writeback_count=cache_writebacks[1];
    for(genvar cache_index=0;cache_index<2;cache_index=cache_index+1) begin : caches
        if(ENABLE_CACHE!=0) begin : enabled
        rv32_cache #(.USE_PRECOMPUTED_PAIR_ADDRESS(cache_index==0 ? 1 : 0),.FETCH_PAIR(cache_index==0 ? ENABLE_C : 0),.ADDRESS_BITS(MEMORY_ADDRESS_BITS+2),.SET_BITS(cache_index==0 && ICACHE_SET_BITS!=0 ? ICACHE_SET_BITS : CACHE_SET_BITS),.WORD_BITS(CACHE_WORD_BITS),.READ_ONLY(cache_index==0 ? 1 : 0),.READ_OVERLAP(cache_index==0 ? FETCH_OVERLAP : DATA_OVERLAP),.FAST_WRITE_HIT(cache_index==0 ? 0 : FAST_DCACHE_WRITE),.FAST_READ_HIT(cache_index==0 ? FAST_ICACHE_HIT : FAST_DCACHE_READ)) cache(
            .rsp_pair_data(cache_pair_data[cache_index]),.rsp_pair_valid(cache_pair_valid[cache_index]),
            .rsp_is_c(cache_is_c[cache_index]),.rsp_pair_is_c(cache_pair_is_c[cache_index]),
            .clk(clk),.rst_n(rst_n),.req_valid(cache_req_valid[cache_index]),.req_ready(cache_req_ready[cache_index]),
            .req_address(cache_req_address[cache_index]),.req_pair_address(cache_index==0 ? i_req_pair_address : 32'd0),.req_write(cache_req_write[cache_index]),
            .req_data(cache_req_data[cache_index]),.req_strobe(cache_req_strobe[cache_index]),
            .rsp_valid(cache_rsp_valid[cache_index]),.rsp_ready(cache_rsp_ready[cache_index]),
            .rsp_data(cache_rsp_data[cache_index]),.rsp_error(cache_rsp_error[cache_index]),
            .flush_valid(cache_flush_valid[cache_index]),.flush_ready(cache_flush_ready[cache_index]),.flush_error(cache_flush_error[cache_index]),
            .cmd_valid(master_cmd_valid[cache_index]),.cmd_ready(master_cmd_ready[cache_index]),.cmd_write(master_cmd_write[cache_index]),
            .cmd_address(master_cmd_address[cache_index]),.cmd_length(master_cmd_length[cache_index]),
            .w_valid(master_w_valid[cache_index]),.w_ready(master_w_ready[cache_index]),.w_data(master_w_data[cache_index]),.w_last(master_w_last[cache_index]),
            .b_valid(master_b_valid[cache_index]),.b_ready(master_b_ready[cache_index]),.b_error(master_b_error[cache_index]),
            .r_valid(master_r_valid[cache_index]),.r_ready(master_r_ready[cache_index]),.r_data(master_r_data[cache_index]),.r_last(master_r_last[cache_index]),.r_error(master_r_error[cache_index]),
            .hit_count(cache_hits[cache_index]),.miss_count(cache_misses[cache_index]),.writeback_count(cache_writebacks[cache_index])
        );
    end
        else begin : bypassed
            assign cache_pair_data[cache_index]=0;
            assign cache_is_c[cache_index]={cache_rsp_data[cache_index][17:16]!=2'b11,cache_rsp_data[cache_index][1:0]!=2'b11};
            assign cache_pair_is_c[cache_index]=2'b11;
            assign cache_pair_valid[cache_index]=0;
            rv32_uncached #(.READ_ONLY(cache_index==0 ? 1 : 0)) bridge(
                .clk(clk),.rst_n(rst_n),.req_valid(cache_req_valid[cache_index]),.req_ready(cache_req_ready[cache_index]),
                .req_address(cache_req_address[cache_index]),.req_write(cache_req_write[cache_index]),
                .req_data(cache_req_data[cache_index]),.req_strobe(cache_req_strobe[cache_index]),
                .rsp_valid(cache_rsp_valid[cache_index]),.rsp_ready(cache_rsp_ready[cache_index]),
                .rsp_data(cache_rsp_data[cache_index]),.rsp_error(cache_rsp_error[cache_index]),
                .flush_valid(cache_flush_valid[cache_index]),.flush_ready(cache_flush_ready[cache_index]),.flush_error(cache_flush_error[cache_index]),
                .cmd_valid(master_cmd_valid[cache_index]),.cmd_ready(master_cmd_ready[cache_index]),.cmd_write(master_cmd_write[cache_index]),
                .cmd_address(master_cmd_address[cache_index]),.cmd_length(master_cmd_length[cache_index]),
                .w_valid(master_w_valid[cache_index]),.w_ready(master_w_ready[cache_index]),.w_data(master_w_data[cache_index]),.w_last(master_w_last[cache_index]),
                .b_valid(master_b_valid[cache_index]),.b_ready(master_b_ready[cache_index]),.b_error(master_b_error[cache_index]),
                .r_valid(master_r_valid[cache_index]),.r_ready(master_r_ready[cache_index]),.r_data(master_r_data[cache_index]),.r_last(master_r_last[cache_index]),.r_error(master_r_error[cache_index]),
                .hit_count(cache_hits[cache_index]),.miss_count(cache_misses[cache_index]),.writeback_count(cache_writebacks[cache_index])
            );
        end
    end
    rv32_burst_arbiter arbiter(
        .clk(clk),.rst_n(rst_n),
        .a_cmd_valid(master_cmd_valid[0]),.a_cmd_ready(master_cmd_ready[0]),.a_cmd_write(master_cmd_write[0]),
        .a_cmd_address(master_cmd_address[0]),.a_cmd_length(master_cmd_length[0]),
        .a_w_valid(master_w_valid[0]),.a_w_ready(master_w_ready[0]),.a_w_data(master_w_data[0]),.a_w_last(master_w_last[0]),
        .a_b_valid(master_b_valid[0]),.a_b_ready(master_b_ready[0]),.a_b_error(master_b_error[0]),
        .a_r_valid(master_r_valid[0]),.a_r_ready(master_r_ready[0]),.a_r_data(master_r_data[0]),.a_r_last(master_r_last[0]),.a_r_error(master_r_error[0]),
        .b_cmd_valid(master_cmd_valid[1]),.b_cmd_ready(master_cmd_ready[1]),.b_cmd_write(master_cmd_write[1]),
        .b_cmd_address(master_cmd_address[1]),.b_cmd_length(master_cmd_length[1]),
        .b_w_valid(master_w_valid[1]),.b_w_ready(master_w_ready[1]),.b_w_data(master_w_data[1]),.b_w_last(master_w_last[1]),
        .b_b_valid(master_b_valid[1]),.b_b_ready(master_b_ready[1]),.b_b_error(master_b_error[1]),
        .b_r_valid(master_r_valid[1]),.b_r_ready(master_r_ready[1]),.b_r_data(master_r_data[1]),.b_r_last(master_r_last[1]),.b_r_error(master_r_error[1]),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_address(cmd_address),.cmd_length(cmd_length),
        .w_valid(w_valid),.w_ready(w_ready),.w_data(w_data),.w_last(w_last),
        .b_valid(b_valid),.b_ready(b_ready),.b_error(b_error),.r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),.r_error(r_error)
    );
    rv32_burst_ram #(.ADDRESS_BITS(MEMORY_ADDRESS_BITS),.BUFFER_BITS(CACHE_WORD_BITS),.INIT_FILE(INIT_FILE)) ram(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_address(cmd_address),.cmd_length(cmd_length),
        .w_valid(w_valid),.w_ready(w_ready),.w_data(w_data),.w_last(w_last),
        .b_valid(b_valid),.b_ready(b_ready),.b_error(b_error),.r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),.r_error(r_error)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            mmio_request_pending<=0; mmio_request_write<=0; mmio_request_address<=0; mmio_request_data<=0; mmio_request_strobe<=0;
        end else begin
            if(mmio_req_valid && mmio_req_ready) mmio_request_pending<=0;
            if(!mmio_request_pending) begin
                mmio_request_address<=d_req_address; mmio_request_write<=d_req_write;
                mmio_request_data<=d_req_data; mmio_request_strobe<=d_req_strobe;
            end
            if(d_req_valid && d_req_ready && request_mmio) mmio_request_pending<=1;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin data_active<=0; data_mmio<=0; maintenance_state<=NORMAL; maintenance_error<=0; end
        else begin

            if(d_rsp_valid && d_rsp_ready) data_active<=0;
            if(d_req_valid && d_req_ready) begin data_active<=1; data_mmio<=request_mmio; end

            case(maintenance_state)
                NORMAL: if(maintenance_valid && !data_active) begin maintenance_state<=CLEAN_DATA; maintenance_error<=0; end
                CLEAN_DATA: if(cache_flush_ready[1]) begin
                    maintenance_error<=cache_flush_error[1];
                    maintenance_state<=cache_flush_error[1] ? MAINTENANCE_DONE : INVALIDATE_INSTRUCTIONS;
                end
                INVALIDATE_INSTRUCTIONS: if(cache_flush_ready[0]) begin maintenance_error<=cache_flush_error[0]; maintenance_state<=MAINTENANCE_DONE; end
                MAINTENANCE_DONE: if(maintenance_valid) maintenance_state<=NORMAL;
                default: maintenance_state<=NORMAL;
            endcase
        end
    end
endmodule
