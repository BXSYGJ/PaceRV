`timescale 1ns/1ps
module rv32_machine #(
    parameter integer ENABLE_M=0,
    parameter integer ENABLE_C=0
) (
    input wire clk,
    input wire rst_n,
    input wire retire,
    input wire [63:0] timer_value,
    input wire irq_external,
    input wire irq_software,
    input wire irq_timer,
    input wire [11:0] read_address,
    input wire read_write_intent,
    output reg [31:0] read_data,
    output reg read_illegal,
    input wire write_valid,
    input wire [11:0] write_address,
    input wire [31:0] write_data,
    input wire trap_enter,
    input wire [31:0] trap_pc,
    input wire [31:0] trap_cause,
    input wire [31:0] trap_value,
    input wire return_from_trap,
    output wire [31:0] return_pc,
    output wire [31:0] trap_target,
    output wire interrupt_pending,
    output wire [31:0] interrupt_cause,
    output wire [63:0] cycle_count,
    output wire [63:0] retired_count
);
    reg machine_ie,machine_pie;
    reg [31:0] mtvec,mscratch,mepc,mcause,mtval,mie,mcounteren;
    reg [63:0] mcycle,minstret;
    wire [1:0] unused_trap_alignment=trap_pc[1:0];
    wire [31:0] mip={20'b0,irq_external,3'b0,irq_timer,3'b0,irq_software,3'b0};
    wire [31:0] pending=mip & mie;
    wire [31:0] mstatus={19'b0,2'b11,3'b0,machine_pie,3'b0,machine_ie,3'b0};
    assign cycle_count=mcycle;
    assign retired_count=minstret;
    assign return_pc=mepc;
    assign interrupt_pending=machine_ie && |pending;
    assign interrupt_cause=pending[11] ? 32'h8000000b : pending[3] ? 32'h80000003 : 32'h80000007;
    (* syn_keep=1 *) wire [31:0] trap_vector_sum={mtvec[31:2],2'b0} + ((mtvec[1:0]==1 && trap_cause[31]) ? {25'b0,trap_cause[4:0],2'b0} : 32'b0);
    assign trap_target=trap_vector_sum;
    always @* begin
        read_illegal=0;
        case(read_address)
            12'h300: read_data=mstatus;
            12'h301: read_data=ENABLE_C!=0 ? (ENABLE_M!=0 ? 32'h40001104 : 32'h40000104) :
                (ENABLE_M!=0 ? 32'h40001100 : 32'h40000100);
            12'h304: read_data=mie;
            12'h305: read_data=mtvec;
            12'h306: read_data=mcounteren;
            12'h340: read_data=mscratch;
            12'h341: read_data=mepc;
            12'h342: read_data=mcause;
            12'h343: read_data=mtval;
            12'h344: read_data=mip;
            12'hb00,12'hc00: read_data=mcycle[31:0];
            12'hb80,12'hc80: read_data=mcycle[63:32];
            12'hb02,12'hc02: read_data=minstret[31:0];
            12'hb82,12'hc82: read_data=minstret[63:32];
            12'hc01: read_data=timer_value[31:0];
            12'hc81: read_data=timer_value[63:32];
            12'hf11,12'hf12,12'hf13,12'hf14: read_data=0;
            default: begin read_data=0; read_illegal=1; end
        endcase
        if(read_write_intent && read_address[11:10]==2'b11) read_illegal=1;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            machine_ie<=0; machine_pie<=0;
            mtvec<=0; mscratch<=0; mepc<=0; mcause<=0; mtval<=0; mie<=0; mcounteren<=0;
            mcycle<=0; minstret<=0;
        end else begin
            mcycle<=mcycle+64'd1;
            if(retire) minstret<=minstret+64'd1;
            if(write_valid) begin
                case(write_address)
                    12'h300: begin machine_ie<=write_data[3]; machine_pie<=write_data[7]; end
                    12'h304: mie<=write_data & 32'h00000888;
                    12'h305: mtvec<={write_data[31:2],1'b0,(write_data[1:0]==1)};
                    12'h306: mcounteren<=write_data & 32'h7;
                    12'h340: mscratch<=write_data;
                    12'h341: mepc<=ENABLE_C!=0 ? {write_data[31:1],1'b0} : {write_data[31:2],2'b0};
                    12'h342: mcause<=write_data;
                    12'h343: mtval<=write_data;
                    12'hb00: mcycle<={mcycle[63:32],write_data};
                    12'hb80: mcycle<={write_data,mcycle[31:0]};
                    12'hb02: minstret<={minstret[63:32],write_data};
                    12'hb82: minstret<={write_data,minstret[31:0]};
                    default: begin end
                endcase
            end
            if(return_from_trap) begin machine_ie<=machine_pie; machine_pie<=1; end
            if(trap_enter) begin
                mepc<=ENABLE_C!=0 ? {trap_pc[31:1],1'b0} : {trap_pc[31:2],2'b0}; mcause<=trap_cause; mtval<=trap_value;
                machine_pie<=machine_ie; machine_ie<=0;
            end
        end
    end
endmodule
