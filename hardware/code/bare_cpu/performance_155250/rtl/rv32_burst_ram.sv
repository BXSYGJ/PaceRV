`timescale 1ns/1ps
module rv32_burst_ram #(
    parameter integer ADDRESS_BITS=12,
    parameter integer BUFFER_BITS=4,
    parameter INIT_FILE=""
) (
    input wire clk,
    input wire rst_n,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire cmd_write,
    input wire [31:0] cmd_address,
    input wire [7:0] cmd_length,
    input wire w_valid,
    output wire w_ready,
    input wire [31:0] w_data,
    input wire w_last,
    output reg b_valid,
    input wire b_ready,
    output reg b_error,
    output reg r_valid,
    input wire r_ready,
    output reg [31:0] r_data,
    output reg r_last,
    output reg r_error
);
    localparam integer MEMORY_WORDS=1<<ADDRESS_BITS;
    localparam integer BUFFER_WORDS=1<<BUFFER_BITS;
    localparam [32:0] MEMORY_BYTES=33'd4<<ADDRESS_BITS;
    localparam [2:0] IDLE=0,READ=1,WRITE=2,COMMIT=3,ACK=4;
    reg [2:0] state;
    reg [31:0] memory[0:MEMORY_WORDS-1];
    reg [31:0] staging[0:BUFFER_WORDS-1];
    reg [ADDRESS_BITS-1:0] base_word;
    reg [7:0] length,beat;
    reg bad_command,bad_write;
    integer init_index;
    wire [32:0] end_address={1'b0,cmd_address}+(({25'b0,cmd_length}+33'd1)<<2);
    wire command_error=cmd_address[1:0]!=0 || end_address>MEMORY_BYTES || {24'b0,cmd_length}>=BUFFER_WORDS;
    wire [31:0] unused_beat_extension={24'b0,beat};
    wire [ADDRESS_BITS-1:0] memory_index=base_word+unused_beat_extension[ADDRESS_BITS-1:0];
    wire read_advance=state==READ && (!r_valid || r_ready) && !(r_valid && r_ready && r_last);
    assign cmd_ready=state==IDLE;
    assign w_ready=state==WRITE;
    initial begin
        if(INIT_FILE!="") $readmemh(INIT_FILE,memory);
        else begin
            for(init_index=0;init_index<MEMORY_WORDS;init_index=init_index+1) memory[init_index]=0;
        end
    end
    always @(posedge clk) begin
        if(state==WRITE && w_valid) staging[beat[BUFFER_BITS-1:0]]<=w_data;
        if(state==COMMIT) memory[memory_index]<=staging[beat[BUFFER_BITS-1:0]];
        if(read_advance) r_data<=bad_command ? 32'b0 : memory[memory_index];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; base_word<=0; length<=0; beat<=0; bad_command<=0; bad_write<=0;
            b_valid<=0; b_error<=0; r_valid<=0; r_last<=0; r_error<=0;
        end else begin
            case(state)
                IDLE: if(cmd_valid) begin
                    base_word<=cmd_address[ADDRESS_BITS+1:2]; length<=cmd_length; beat<=0;
                    bad_command<=command_error; bad_write<=0;
                    state<=cmd_write ? WRITE : READ;
                end
                READ: begin
                    if(r_valid && r_ready && r_last) begin r_valid<=0; state<=IDLE; end
                    else if(read_advance) begin
                        r_valid<=1; r_last<=beat==length; r_error<=bad_command;
                        if(beat!=length) beat<=beat+1'b1;
                    end
                end
                WRITE: if(w_valid) begin
                    if(w_last!=(beat==length)) bad_write<=1;
                    if(w_last) begin
                        if(bad_command || bad_write || beat!=length) begin b_valid<=1; b_error<=1; state<=ACK; end
                        else begin beat<=0; state<=COMMIT; end
                    end else if(beat!=length) beat<=beat+1'b1;
                end
                COMMIT: begin
                    if(beat==length) begin b_valid<=1; b_error<=0; state<=ACK; end
                    else beat<=beat+1'b1;
                end
                ACK: if(b_ready) begin b_valid<=0; state<=IDLE; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
