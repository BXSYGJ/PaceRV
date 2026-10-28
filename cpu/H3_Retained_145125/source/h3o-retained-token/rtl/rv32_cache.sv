`timescale 1ns/1ps
module rv32_cache #(
    parameter integer ADDRESS_BITS=32,
    parameter integer SET_BITS=4,
    parameter integer WORD_BITS=2,
    parameter integer READ_ONLY=0,
    parameter integer FETCH_PAIR=0,
    parameter integer USE_PRECOMPUTED_PAIR_ADDRESS=0,
    parameter integer FAST_READ_HIT=0,
    parameter integer FAST_WRITE_HIT=0,
    parameter integer READ_OVERLAP=0
) (
    input wire clk,
    input wire rst_n,
    input wire req_valid,
    output wire req_ready,
    input wire [31:0] req_address,
    input wire [31:0] req_pair_address,
    input wire req_write,
    input wire [31:0] req_data,
    input wire [3:0] req_strobe,
    output wire rsp_valid,
    input wire rsp_ready,
    output wire [31:0] rsp_data,
    output wire [31:0] rsp_pair_data,
    output wire [1:0] rsp_is_c,rsp_pair_is_c,
    output wire rsp_pair_valid,
    output wire rsp_error,
    input wire flush_valid,
    output wire flush_ready,
    output reg flush_error,
    output wire cmd_valid,
    input wire cmd_ready,
    output wire cmd_write,
    output wire [31:0] cmd_address,
    output wire [7:0] cmd_length,
    output wire w_valid,
    input wire w_ready,
    output wire [31:0] w_data,
    output wire w_last,
    input wire b_valid,
    output wire b_ready,
    input wire b_error,
    input wire r_valid,
    output wire r_ready,
    input wire [31:0] r_data,
    input wire r_last,
    input wire r_error,
    output reg [31:0] hit_count,
    output reg [31:0] miss_count,
    output reg [31:0] writeback_count
);
    localparam integer DIRECT_READ_RESPONSE=READ_ONLY!=0 && FAST_READ_HIT!=0;
    localparam integer SETS=1<<SET_BITS;
    localparam integer WORDS=1<<WORD_BITS;
    localparam integer LINES=2*SETS;
    localparam integer TAG_BITS=ADDRESS_BITS-2-SET_BITS-WORD_BITS;
    localparam [31:0] LINE_LENGTH=WORDS-1;
    localparam [3:0] IDLE=0,LOOKUP=1,WB_CMD=2,WB_DATA=3,WB_ACK=4,
        FILL_CMD=5,FILL_DATA=6,RESPONSE=7,FLUSH_SCAN=8,FLUSH_DONE=9;
    reg [3:0] stored_state;
    reg stored_rsp_error,request_check_pending;
    reg [31:0] request_error_address;
    reg [31:0] response_data;
    reg [31:0] response_pair_data;
    reg response_pair_available;
    wire current_pair_available;
    wire [LINES-1:0] dirty;
    wire replacement_dirty,scan_dirty;
    wire [LINES-1:0] valid;
    wire valid_ready;
    wire [LINES-1:0] unused_validity_view=valid;
    localparam PACKED_DVALID=(READ_ONLY==0 && SET_BITS>=4);
    localparam integer DVALID_GROUPS=PACKED_DVALID ? LINES/32 : 1;
    localparam integer DVALID_GROUP_BITS=(PACKED_DVALID && SET_BITS>4) ? SET_BITS-4 : 1;
    (* syn_ramstyle="lut_ram" *) reg [31:0] unused_writable_valid_storage[0:DVALID_GROUPS-1];
    wire replacement_valid,scan_valid;
    wire [1:0] unused_packed_lookup_valid0,unused_packed_lookup_valid1;
    wire unused_packed_query_half;
    (* syn_ramstyle="lut_ram" *) reg lru_storage[0:SETS-1];
    reg [TAG_BITS-1:0] tags[0:LINES-1];
    (* syn_maxfan=32 *) reg [31:0] request_address;
    reg [31:0] request_data,victim_base;
    reg [3:0] request_strobe;
    reg request_write,request_missed,flushing,fill_failed;
    wire request_input_error=request_check_pending && ((|request_error_address) || (READ_ONLY!=0 && request_write));
    wire [3:0] state=request_input_error ? RESPONSE : stored_state;
    assign rsp_error=request_input_error || stored_rsp_error;
    reg [SET_BITS:0] victim,scan_line;
    reg [WORD_BITS-1:0] beat;
    wire [SET_BITS-1:0] request_set=request_address[WORD_BITS+SET_BITS+1:WORD_BITS+2];
    wire [WORD_BITS-1:0] request_word=request_address[WORD_BITS+1:2];
    wire [TAG_BITS-1:0] request_tag=request_address[ADDRESS_BITS-1:WORD_BITS+SET_BITS+2];
    wire [SET_BITS:0] way0={1'b0,request_set},way1={1'b1,request_set};
    wire lookup_valid0,lookup_valid1;
    wire lookup_companion_valid0,lookup_companion_valid1;
    wire [TAG_BITS-1:0] lookup_tag0,lookup_tag1;
    wire hit0=lookup_valid0 && lookup_tag0==request_tag;
    wire hit1=lookup_valid1 && lookup_tag1==request_tag;
    wire [SET_BITS:0] hit_line=hit1 ? way1 : way0;
    wire [SET_BITS:0] replacement=!lookup_valid0 ? way0 : !lookup_valid1 ? way1 : {lru_storage[request_set],request_set};
    wire [31:0] current_word;
    wire [31:0] current_pair_word;
    wire [1:0] current_is_c,current_pair_is_c;
    function automatic [1:0] compact_halves(input [31:0] word_data);
        begin compact_halves={word_data[17:16]!=2'b11,word_data[1:0]!=2'b11}; end
    endfunction
    generate if(READ_ONLY==0) begin : ram_dirty
        (* syn_ramstyle="lut_ram" *) reg storage[0:LINES-1];
        assign replacement_dirty=storage[replacement];
        assign scan_dirty=storage[scan_line];
        wire store_dirty=state==LOOKUP && (hit0 || hit1) && request_write && |request_strobe;
        wire clear_dirty=(state==WB_ACK && b_valid && !b_error) ||
            (state==FILL_CMD && cmd_ready) ||
            (state==FILL_DATA && r_valid && r_last && !fill_failed && !r_error && last_beat) ||
            (state==FLUSH_SCAN && !(scan_valid && scan_dirty));
        wire [SET_BITS:0] write_line=state==LOOKUP ? hit_line : state==FLUSH_SCAN ? scan_line : victim;
        for(genvar dirty_index=0;dirty_index<LINES;dirty_index=dirty_index+1) begin : view
            assign dirty[dirty_index]=storage[dirty_index];
        end
        always @(posedge clk) if(rst_n && (store_dirty || clear_dirty)) storage[write_line]<=store_dirty;
    end else begin : clean_readonly
        assign dirty={LINES{1'b0}};
        assign replacement_dirty=0;
        assign scan_dirty=0;
    end endgenerate
    wire [31:0] byte_mask={{8{request_strobe[3]}},{8{request_strobe[2]}},{8{request_strobe[1]}},{8{request_strobe[0]}}};
    wire last_beat=&beat;
    wire [1:0] unused_request_alignment=request_address[1:0];
    assign req_ready=valid_ready && (state==IDLE || (READ_OVERLAP!=0 && rsp_valid && rsp_ready)) && !flush_valid;
    wire fast_lookup=((FAST_READ_HIT!=0 && !request_write) || (FAST_WRITE_HIT!=0 && request_write && READ_ONLY==0)) && state==LOOKUP;
    wire fast_hit=fast_lookup && (hit0 || hit1);
    assign rsp_valid=state==RESPONSE || fast_hit;
    assign rsp_data=rsp_error ? 32'b0 : (DIRECT_READ_RESPONSE!=0 || fast_lookup) ? current_word : response_data;
    assign rsp_pair_data=(DIRECT_READ_RESPONSE!=0 || fast_lookup) ? current_pair_word : response_pair_data;
    assign rsp_is_c=rsp_error ? 2'b11 : (DIRECT_READ_RESPONSE!=0 || fast_lookup) ? current_is_c : compact_halves(response_data);
    assign rsp_pair_is_c=(DIRECT_READ_RESPONSE!=0 || fast_lookup) ? current_pair_is_c : compact_halves(response_pair_data);
    assign rsp_pair_valid=READ_ONLY!=0 && FETCH_PAIR!=0 && !rsp_error &&
        ((DIRECT_READ_RESPONSE!=0 || fast_lookup) ? current_pair_available : response_pair_available);
    assign flush_ready=state==FLUSH_DONE;
    assign cmd_valid=state==WB_CMD || state==FILL_CMD;
    assign cmd_write=state==WB_CMD;
    assign cmd_address=state==WB_CMD ? victim_base : {request_address[31:WORD_BITS+2],{(WORD_BITS+2){1'b0}}};
    assign cmd_length=LINE_LENGTH[7:0];
    assign w_valid=state==WB_DATA;
    assign w_last=last_beat;
    assign b_ready=state==WB_ACK;
    assign r_ready=state==FILL_DATA;
    generate if(READ_ONLY==0 || FETCH_PAIR==0) begin : asynchronous_tags
        assign lookup_tag0=tags[way0];
        assign lookup_tag1=tags[way1];
    end endgenerate
    generate
        if(READ_ONLY!=0) begin : ram_valid
            // Adjacent sets have opposite parity, so one read from each parity
            // supplies demand and optional next-line validity without replication.
            localparam integer ROWS=SETS/2;
            localparam integer ROWS_PER_BANK=ROWS>128 ? 128 : ROWS;
            localparam integer OFFSET_BITS=$clog2(ROWS_PER_BANK);
            localparam integer BANKS=ROWS/ROWS_PER_BANK;
            localparam integer BANK_BITS=BANKS>1 ? $clog2(BANKS) : 1;
            wire [SETS-1:0] valid_way0,valid_way1;
            wire [BANKS-1:0] bank_valid0[0:1],bank_valid1[0:1];
            reg [BANK_BITS-1:0] read_bank[0:1];
            reg read_parity;
            reg clearing;
            reg [SET_BITS-1:0] clear_set;
            reg forward_valid0,forward_valid1;
            wire [SET_BITS-1:0] read_set=req_address[WORD_BITS+SET_BITS+1:WORD_BITS+2];
            wire [SET_BITS-1:0] odd_read_row=read_set>>1;
            // The even bank is used by an even demand set, or by the next
            // set of an odd demand only when the request crosses a line.
            // Other even-bank reads are unused, allowing the frontend's
            // precomputed next-word address to replace the late row increment.
            wire [31:0] validity_companion_address=USE_PRECOMPUTED_PAIR_ADDRESS!=0 ?
                req_pair_address : req_address+32'd4;
            wire [SET_BITS-1:0] even_read_row=(validity_companion_address>>(WORD_BITS+3)) & (ROWS-1);
            wire finish_fill=state==FILL_DATA && r_valid && r_last;
            wire fill_commit=finish_fill && last_beat && !r_error && !fill_failed;
            wire update_valid=(state==FILL_CMD && cmd_ready) || finish_fill || state==FLUSH_SCAN;
            wire update_way=state==FLUSH_SCAN ? scan_line[SET_BITS] : victim[SET_BITS];
            wire [SET_BITS-1:0] write_set=clearing ? clear_set :
                state==FLUSH_SCAN ? scan_line[SET_BITS-1:0] : victim[SET_BITS-1:0];
            wire [SET_BITS-1:0] write_row=write_set>>1;
            wire write_value=!clearing && fill_commit;
            assign valid_ready=!clearing;
            assign replacement_valid=valid[replacement];
            assign scan_valid=valid[scan_line];
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin clearing<=1; clear_set<=0; end
                else if(clearing) begin
                    if(&clear_set) clearing<=0;
                    else clear_set<=clear_set+1'b1;
                end
            end
            for(genvar parity=0;parity<2;parity=parity+1) begin : parity_banks
                wire [SET_BITS-1:0] read_row=parity==0 ? even_read_row : odd_read_row;
                always @(posedge clk) if(req_ready) read_bank[parity]<=read_row>>OFFSET_BITS;
                for(genvar bank=0;bank<BANKS;bank=bank+1) begin : banks
                    (* syn_ramstyle="lut_ram" *) reg storage0[0:ROWS_PER_BANK-1];
                    (* syn_ramstyle="lut_ram" *) reg storage1[0:ROWS_PER_BANK-1];
                    reg read0,read1;
                    wire selected_bank=write_set[0]==(parity!=0) && (write_row>>OFFSET_BITS)==bank;
                    always @(posedge clk) begin
                        if(rst_n && selected_bank) begin
                            if(clearing || (update_valid && !update_way))
                                storage0[write_row%ROWS_PER_BANK]<=write_value;
                            if(clearing || (update_valid && update_way))
                                storage1[write_row%ROWS_PER_BANK]<=write_value;
                        end
                        if(req_ready) begin
                            read0<=storage0[read_row%ROWS_PER_BANK];
                            read1<=storage1[read_row%ROWS_PER_BANK];
                        end
                    end
                    assign bank_valid0[parity][bank]=read0;
                    assign bank_valid1[parity][bank]=read1;
                    for(genvar offset=0;offset<ROWS_PER_BANK;offset=offset+1) begin : view
                        assign valid_way0[2*(bank*ROWS_PER_BANK+offset)+parity]=storage0[offset];
                        assign valid_way1[2*(bank*ROWS_PER_BANK+offset)+parity]=storage1[offset];
                    end
                end
            end
            always @(posedge clk) if(req_ready) read_parity<=read_set[0];
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin forward_valid0<=0; forward_valid1<=0; end
                else if(req_ready) begin forward_valid0<=0; forward_valid1<=0; end
                else if(fill_commit) begin
                    if(!victim[SET_BITS]) forward_valid0<=1;
                    else forward_valid1<=1;
                end
            end
            wire selected_valid0=read_parity ? bank_valid0[1][read_bank[1]] : bank_valid0[0][read_bank[0]];
            wire selected_valid1=read_parity ? bank_valid1[1][read_bank[1]] : bank_valid1[0][read_bank[0]];
            assign lookup_valid0=forward_valid0 || selected_valid0;
            assign lookup_valid1=forward_valid1 || selected_valid1;
            assign lookup_companion_valid0=read_parity ? bank_valid0[0][read_bank[0]] : bank_valid0[1][read_bank[1]];
            assign lookup_companion_valid1=read_parity ? bank_valid1[0][read_bank[0]] : bank_valid1[1][read_bank[1]];
            for(genvar valid_index=0;valid_index<SETS;valid_index=valid_index+1) begin : view
                assign valid[valid_index]=valid_way0[valid_index];
                assign valid[SETS+valid_index]=valid_way1[valid_index];
            end
        end else begin : register_valid
            assign lookup_companion_valid0=1'b0;
            assign lookup_companion_valid1=1'b0;
            assign valid_ready=1'b1;
            if(PACKED_DVALID) begin : packed_words
                reg [DVALID_GROUPS-1:0] group_valid;
                reg write_valid,write_value;
                wire [SET_BITS:0] metadata_index=state==LOOKUP ? replacement : state==FLUSH_SCAN ? scan_line : victim;
                wire [SET_BITS:0] write_index=state==FLUSH_SCAN ? scan_line : victim;
                wire [SET_BITS+5:0] unused_write_address={5'b0,write_index};
                wire [DVALID_GROUP_BITS-1:0] write_group=unused_write_address[DVALID_GROUP_BITS+4:5];
                wire [4:0] write_bit=unused_write_address[4:0];
                wire [SET_BITS-1:0] incoming_set=req_address[WORD_BITS+SET_BITS+1:WORD_BITS+2];
                wire [SET_BITS:0] read_index0=metadata_index;
                wire [SET_BITS:0] read_index1={1'b1,incoming_set};
                wire [SET_BITS+5:0] unused_read_address0={5'b0,read_index0};
                wire [SET_BITS+5:0] unused_read_address1={5'b0,read_index1};
                wire [DVALID_GROUP_BITS-1:0] read_group0=unused_read_address0[DVALID_GROUP_BITS+4:5];
                wire [DVALID_GROUP_BITS-1:0] read_group1=unused_read_address1[DVALID_GROUP_BITS+4:5];
                wire [4:0] read_bit0=unused_read_address0[4:0];
                wire [3:0] read_offset1=unused_read_address1[3:0];
                wire [31:0] read_word0=unused_writable_valid_storage[read_group0];
                wire [31:0] read_word1=unused_writable_valid_storage[read_group1];
                wire read_value0=group_valid[read_group0] && read_word0[read_bit0];
                // Query0 uses its own RAM read port. No incoming request address
                // enters replacement, flush or read-modify-write selection.
                wire [SET_BITS+5:0] unused_query_address0={6'b0,incoming_set};
                wire [DVALID_GROUP_BITS-1:0] query_group0=unused_query_address0[DVALID_GROUP_BITS+4:5];
                wire [4:0] query_bit0=unused_query_address0[4:0];
                wire [31:0] query_word0=unused_writable_valid_storage[query_group0];
                wire [15:0] query_word0_low=query_word0[15:0],query_word0_high=query_word0[31:16];
                wire [15:0] query_word1_low=read_word1[15:0],query_word1_high=read_word1[31:16];
                // The late incoming address selects16bits before the request edge.
                // The final half selection occurs after that same existing edge.
                wire query_value0_low=group_valid[query_group0] && query_word0_low[query_bit0[3:0]];
                wire query_value0_high=group_valid[query_group0] && query_word0_high[query_bit0[3:0]];
                wire query_value1_low=group_valid[read_group1] && query_word1_low[read_offset1];
                wire query_value1_high=group_valid[read_group1] && query_word1_high[read_offset1];
                assign unused_packed_lookup_valid0={query_value0_high,query_value0_low};
                assign unused_packed_lookup_valid1={query_value1_high,query_value1_low};
                assign unused_packed_query_half=query_bit0[4];
                reg [31:0] next_word;
                assign replacement_valid=read_value0;
                assign scan_valid=read_value0;
                for(genvar line=0;line<LINES;line=line+1) begin : view
                    assign valid[line]=group_valid[line/32] && unused_writable_valid_storage[line/32][line%32];
                end
                // Dedicated port0 serves only replacement, flush and read-modify-write.
                always @* begin
                    write_valid=0;write_value=0;
                    case(state)
                        WB_ACK: if(b_valid && !b_error) write_valid=1;
                        FILL_CMD: if(cmd_ready) write_valid=1;
                        FILL_DATA: if(r_valid && r_last) begin
                            write_valid=1;write_value=!fill_failed && !r_error && last_beat;
                        end
                        FLUSH_SCAN: if(!(scan_valid && scan_dirty)) write_valid=1;
                        default: begin end
                    endcase
                    next_word=group_valid[write_group] ? read_word0 : 32'b0;
                    next_word[write_bit]=write_value;
                end
                // Raw writes during reset stay masked; first post-reset write zeros stale word.
                always @(posedge clk) begin
                    if(write_valid) unused_writable_valid_storage[write_group]<=next_word;
                end
                always @(posedge clk or negedge rst_n) begin
                    if(!rst_n) group_valid<=0;
                    else if(write_valid) group_valid[write_group]<=1;
                end
            end else begin : bitmap
                reg [LINES-1:0] writable_valid;
                assign valid=writable_valid;
                assign replacement_valid=valid[replacement];
                assign scan_valid=valid[scan_line];
                always @(posedge clk or negedge rst_n) begin
                    if(!rst_n) writable_valid<=0;
                    else case(state)
                        WB_ACK: if(b_valid && !b_error) writable_valid[victim]<=0;
                        FILL_CMD: if(cmd_ready) writable_valid[victim]<=0;
                        FILL_DATA: if(r_valid && r_last)
                            writable_valid[victim]<=!fill_failed && !r_error && last_beat;
                        FLUSH_SCAN: if(!(scan_valid && scan_dirty)) writable_valid[scan_line]<=0;
                        default: begin end
                    endcase
                end
            end
            if(PACKED_DVALID) begin : packed_lookup
                wire fill_commit=state==FILL_DATA && r_valid && r_last && last_beat && !r_error && !fill_failed;
                reg [1:0] read_valid0,read_valid1;
                reg read_half;
                always @(posedge clk or negedge rst_n) begin
                    if(!rst_n) begin read_valid0<=0;read_valid1<=0;read_half<=0;end
                    else if(req_ready) begin
                        read_half<=unused_packed_query_half;
                        read_valid0<=unused_packed_lookup_valid0;
                        read_valid1<=unused_packed_lookup_valid1;
                    end else if(fill_commit) begin
                        if(!victim[SET_BITS]) read_valid0[read_half]<=1'b1;
                        else read_valid1[SET_BITS==4 ? 1'b1 : read_half]<=1'b1;
                    end
                end
                assign lookup_valid0=read_valid0[read_half];
                // For the32-line geometry, each way occupies one distinct half.
                assign lookup_valid1=read_valid1[SET_BITS==4 ? 1'b1 : read_half];
            end else if(READ_ONLY==0 && SET_BITS>4) begin : banked_valid
                localparam integer BANK_BITS=SET_BITS-4;
                localparam integer BANKS=1<<BANK_BITS;
                wire [3:0] valid_offset=req_address[WORD_BITS+5:WORD_BITS+2];
                wire [BANK_BITS-1:0] valid_bank=req_address[WORD_BITS+SET_BITS+1:WORD_BITS+6];
                wire fill_commit=state==FILL_DATA && r_valid && r_last && last_beat && !r_error && !fill_failed;
                reg [BANK_BITS-1:0] read_bank;
                wire [BANKS-1:0] read_valid0,read_valid1;
                always @(posedge clk or negedge rst_n) begin
                    if(!rst_n) read_bank<=0;
                    else if(req_ready) read_bank<=valid_bank;
                end
                for(genvar bank_index=0;bank_index<BANKS;bank_index=bank_index+1) begin : banks
                    reg valid0,valid1;
                    wire [15:0] bank_valid0=valid[bank_index*16+:16];
                    wire [15:0] bank_valid1=valid[SETS+bank_index*16+:16];
                    always @(posedge clk or negedge rst_n) begin
                        if(!rst_n) begin valid0<=0; valid1<=0; end
                        else if(req_ready) begin
                            valid0<=bank_valid0[valid_offset];
                            valid1<=bank_valid1[valid_offset];
                        end else if(fill_commit) begin
                            if(!victim[SET_BITS]) valid0<=1;
                            else valid1<=1;
                        end
                    end
                    assign read_valid0[bank_index]=valid0;
                    assign read_valid1[bank_index]=valid1;
                end
                assign lookup_valid0=read_valid0[read_bank];
                assign lookup_valid1=read_valid1[read_bank];
            end else begin : synchronous_valid
                wire [SET_BITS-1:0] valid_set=req_address[WORD_BITS+SET_BITS+1:WORD_BITS+2];
                wire [SET_BITS:0] valid_way0={1'b0,valid_set},valid_way1={1'b1,valid_set};
                wire fill_commit=state==FILL_DATA && r_valid && r_last && last_beat && !r_error && !fill_failed;
                reg read_valid0,read_valid1;
                always @(posedge clk or negedge rst_n) begin
                    if(!rst_n) begin read_valid0<=0; read_valid1<=0; end
                    else if(req_ready) begin
                        read_valid0<=valid[valid_way0];
                        read_valid1<=valid[valid_way1];
                    end else if(fill_commit) begin
                        if(!victim[SET_BITS]) read_valid0<=1;
                        else read_valid1<=1;
                    end
                end
                assign lookup_valid0=read_valid0;
                assign lookup_valid1=read_valid1;

            end
        end
    endgenerate
    generate if(READ_ONLY==0 || FETCH_PAIR==0) begin : no_companion
        assign current_pair_available=1'b0;
    end endgenerate
    generate
        if(READ_ONLY!=0 && FETCH_PAIR!=0) begin : synchronous_pair
            wire [SET_BITS+WORD_BITS-2:0] fill_index={victim[SET_BITS-1:0],beat[WORD_BITS-1:1]};
            wire fill_write=state==FILL_DATA && r_valid && !r_error && !fill_failed;
            // Each bank reads the consecutive word of its parity. Odd requests
            // may inspect the following line, but never allocate or refill it.
            wire [31:0] live_companion_address=USE_PRECOMPUTED_PAIR_ADDRESS!=0 ?
                req_pair_address : req_address+32'd4;
            // request_address is captured with zero upper ADDRESS_BITS bits.
            // Keep one overflow bit for the range test; 32-bit addresses wrap.
            localparam integer COMPANION_BITS=ADDRESS_BITS<32 ? ADDRESS_BITS+1 : 32;
            wire [COMPANION_BITS-1:0] compact_companion_address=
                {{(COMPANION_BITS-ADDRESS_BITS){1'b0}},request_address[ADDRESS_BITS-1:0]}+
                {{(COMPANION_BITS-3){1'b0}},3'd4};
            wire [31:0] companion_address;
            if(USE_PRECOMPUTED_PAIR_ADDRESS!=0 && FAST_READ_HIT!=0) begin : captured_companion
                reg [COMPANION_BITS-1:0] address;
                always @(posedge clk or negedge rst_n) begin
                    if(!rst_n) address<={{(COMPANION_BITS-3){1'b0}},3'd4};
                    else if(req_valid && req_ready) address<=req_pair_address[COMPANION_BITS-1:0];
                end
                assign companion_address={{(32-COMPANION_BITS){1'b0}},address};
            end else begin : computed_companion
                assign companion_address={{(32-COMPANION_BITS){1'b0}},compact_companion_address};
            end
            wire [TAG_BITS-1:0] companion_tag=companion_address[ADDRESS_BITS-1:WORD_BITS+SET_BITS+2];
            wire companion_valid0=lookup_companion_valid0;
            wire companion_valid1=lookup_companion_valid1;
            wire cross_line=&request_word;
            wire [TAG_BITS-1:0] bank_tag0[0:1],bank_tag1[0:1];
            wire companion_hit0=companion_valid0 && bank_tag0[0]==companion_tag;
            wire companion_hit1=companion_valid1 && bank_tag1[0]==companion_tag;
            wire select_companion_way1=cross_line ? companion_hit1 : hit1;
            assign current_pair_available=(companion_address >> ADDRESS_BITS)==0 &&
                (!cross_line || companion_hit0 || companion_hit1);
            assign lookup_tag0=request_word[0] ? bank_tag0[1] : bank_tag0[0];
            assign lookup_tag1=request_word[0] ? bank_tag1[1] : bank_tag1[0];
            wire [31:0] pair_word[0:1];
            wire [1:0] compact_way0[0:1],compact_way1[0:1];
            for(genvar bank=0;bank<2;bank=bank+1) begin : banks
                localparam integer BANK_WIDTH=32+TAG_BITS;
                wire [SET_BITS+WORD_BITS-2:0] bank_live_index=bank==0 ?
                    live_companion_address[WORD_BITS+SET_BITS+1:3] : req_address[WORD_BITS+SET_BITS+1:3];
                wire [SET_BITS+WORD_BITS-2:0] bank_request_index=bank==0 ?
                    companion_address[WORD_BITS+SET_BITS+1:3] : {request_set,request_word[WORD_BITS-1:1]};
                wire [SET_BITS+WORD_BITS-2:0] bank_read_index=req_ready ? bank_live_index : bank_request_index;
                (* syn_ramstyle="block_ram" *) reg [BANK_WIDTH-1:0] storage_way0[0:SETS*WORDS/2-1];
                (* syn_ramstyle="block_ram" *) reg [BANK_WIDTH-1:0] storage_way1[0:SETS*WORDS/2-1];
                reg [BANK_WIDTH-1:0] read_way0,read_way1,forward_data;
                wire [BANK_WIDTH-1:0] refill_data;
                reg forward_way0,forward_way1;
                (* syn_keep=1 *) wire [1:0] read_compact0=compact_halves(read_way0[31:0]);
                (* syn_keep=1 *) wire [1:0] read_compact1=compact_halves(read_way1[31:0]);
                (* syn_keep=1 *) wire [1:0] forward_compact=compact_halves(forward_data[31:0]);
                assign compact_way0[bank]=forward_way0 ? forward_compact : read_compact0;
                assign compact_way1[bank]=forward_way1 ? forward_compact : read_compact1;
                wire bank_write=fill_write && beat[0]==(bank!=0);
                assign refill_data={request_tag,r_data};
                assign bank_tag0[bank]=forward_way0 ? forward_data[BANK_WIDTH-1:32] : read_way0[BANK_WIDTH-1:32];
                assign bank_tag1[bank]=forward_way1 ? forward_data[BANK_WIDTH-1:32] : read_way1[BANK_WIDTH-1:32];
                always @(posedge clk) begin
                    if(rst_n && bank_write && !victim[SET_BITS]) storage_way0[fill_index]<=refill_data;
                    if(rst_n && bank_write && victim[SET_BITS]) storage_way1[fill_index]<=refill_data;
                    read_way0<=storage_way0[bank_read_index];
                    read_way1<=storage_way1[bank_read_index];
                    forward_data<=refill_data;
                end
                always @(posedge clk or negedge rst_n) begin
                    if(!rst_n) begin forward_way0<=0; forward_way1<=0; end
                    else begin
                        forward_way0<=bank_write && !victim[SET_BITS] && fill_index==bank_request_index;
                        forward_way1<=bank_write && victim[SET_BITS] && fill_index==bank_request_index;
                    end
                end
                wire selected_way1=(bank==0 && request_word[0]) ? select_companion_way1 : hit1;
                wire selected_forward=selected_way1 ? forward_way1 : forward_way0;
                wire [31:0] selected_read=selected_way1 ? read_way1[31:0] : read_way0[31:0];
                assign pair_word[bank]=selected_forward ? forward_data[31:0] : selected_read;
            end
            assign current_word=request_word[0] ? pair_word[1] : pair_word[0];
            assign current_pair_word=request_word[0] ? pair_word[0] : pair_word[1];
            (* syn_keep=1 *) wire [1:0] requested_compact0=request_word[0] ? compact_way0[1] : compact_way0[0];
            (* syn_keep=1 *) wire [1:0] requested_compact1=request_word[0] ? compact_way1[1] : compact_way1[0];
            assign current_is_c=hit1 ? requested_compact1 : requested_compact0;
            assign current_pair_is_c=request_word[0] ? (select_companion_way1 ? compact_way1[0] : compact_way0[0]) :
                (hit1 ? compact_way1[1] : compact_way0[1]);
            assign w_data=32'b0;
        end else if(READ_ONLY!=0) begin : synchronous_readonly
            assign current_pair_word=0;
            assign current_is_c=compact_halves(current_word);
            assign current_pair_is_c=2'b11;
            wire [63:0] unused_readonly_payload={request_data,byte_mask};
            (* syn_ramstyle="block_ram" *) reg [31:0] storage_way0[0:SETS*WORDS-1];
            (* syn_ramstyle="block_ram" *) reg [31:0] storage_way1[0:SETS*WORDS-1];
            reg [31:0] read_way0,read_way1,forward_data;
            reg forward_way0,forward_way1;
            wire [SET_BITS+WORD_BITS-1:0] read_index=req_ready ?
                req_address[WORD_BITS+SET_BITS+1:2] : {request_set,request_word};
            wire [SET_BITS+WORD_BITS-1:0] fill_index={victim[SET_BITS-1:0],beat};
            wire fill_write=state==FILL_DATA && r_valid && !r_error && !fill_failed;
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin end
                else if(fill_write && !victim[SET_BITS]) storage_way0[fill_index]<=r_data;
            end
            always @(posedge clk) begin
                read_way0<=storage_way0[read_index];
            end
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin end
                else if(fill_write && victim[SET_BITS]) storage_way1[fill_index]<=r_data;
            end
            always @(posedge clk) begin
                read_way1<=storage_way1[read_index];
            end
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin forward_way0<=0; forward_way1<=0; end
                else begin
                    forward_way0<=fill_write && !victim[SET_BITS] && fill_index==read_index;
                    forward_way1<=fill_write && victim[SET_BITS] && fill_index==read_index;
                end
            end
            always @(posedge clk) forward_data<=r_data;
            assign current_word=hit1 ? (forward_way1 ? forward_data : read_way1) :
                (forward_way0 ? forward_data : read_way0);
            assign w_data=32'b0;
        end else begin : synchronous_writable
            assign current_pair_word=0;
            assign current_is_c=compact_halves(current_word);
            assign current_pair_is_c=2'b11;
            (* syn_ramstyle="block_ram" *) reg [31:0] storage_way0[0:SETS*WORDS-1];
            (* syn_ramstyle="block_ram" *) reg [31:0] storage_way1[0:SETS*WORDS-1];
            reg [31:0] read_way0,read_way1,forward_data;
            reg forward_way0,forward_way1;
            wire store_hit=state==LOOKUP && (hit0 || hit1) && request_write && |request_strobe;
            wire store_fill=state==FILL_DATA && r_valid && !r_error && !fill_failed;
            wire store_way=store_hit ? hit_line[SET_BITS] : victim[SET_BITS];
            wire [SET_BITS+WORD_BITS-1:0] store_index=store_hit ?
                {request_set,request_word} : {victim[SET_BITS-1:0],beat};
            wire [31:0] store_data=store_hit ?
                (current_word & ~byte_mask) | (request_data & byte_mask) : r_data;
            wire writeback_read=state==WB_CMD || state==WB_DATA;
            wire [WORD_BITS-1:0] read_beat=state==WB_CMD ? {WORD_BITS{1'b0}} :
                state==WB_DATA && w_ready && !last_beat ? beat+1'b1 : beat;
            wire [SET_BITS+WORD_BITS-1:0] read_index=req_ready ?
                req_address[WORD_BITS+SET_BITS+1:2] : writeback_read ?
                {victim[SET_BITS-1:0],read_beat} : {request_set,request_word};
            wire [31:0] word_way0=forward_way0 ? forward_data : read_way0;
            wire [31:0] word_way1=forward_way1 ? forward_data : read_way1;
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin end
                else if((store_hit || store_fill) && !store_way) storage_way0[store_index]<=store_data;
            end
            always @(posedge clk) begin
                read_way0<=storage_way0[read_index];
            end
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin end
                else if((store_hit || store_fill) && store_way) storage_way1[store_index]<=store_data;
            end
            always @(posedge clk) begin
                read_way1<=storage_way1[read_index];
            end
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin forward_way0<=0; forward_way1<=0; end
                else begin
                    forward_way0<=(store_hit || store_fill) && !store_way && store_index==read_index;
                    forward_way1<=(store_hit || store_fill) && store_way && store_index==read_index;
                end
            end
            always @(posedge clk) forward_data<=store_data;
            wire read_select0=!hit1 && !forward_way0;
            wire read_select1=hit1 && !forward_way1;
            wire read_forward=hit1 ? forward_way1 : forward_way0;
            assign current_word=(read_way0 & {32{read_select0}}) |
                (read_way1 & {32{read_select1}}) | (forward_data & {32{read_forward}});
            assign w_data=victim[SET_BITS] ? word_way1 : word_way0;
        end
    endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin end
        else if(state==LOOKUP && (hit0 || hit1)) lru_storage[request_set]<=!hit_line[SET_BITS];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            stored_state<=IDLE;
            request_check_pending<=0; request_error_address<=0;
            request_address<=0; request_data<=0; request_strobe<=0; request_write<=0;
            request_missed<=0; flushing<=0; fill_failed<=0;
            victim<=0; victim_base<=0; scan_line<=0; beat<=0;
            response_data<=0; response_pair_data<=0; response_pair_available<=0; stored_rsp_error<=0; flush_error<=0;
            hit_count<=0; miss_count<=0; writeback_count<=0;
        end else begin
            request_check_pending<=req_valid && req_ready;
            if(request_input_error) stored_rsp_error<=1;
            case(state)
                IDLE: begin
                    if(flush_valid) begin
                        flushing<=1; scan_line<=0; flush_error<=0; stored_state<=FLUSH_SCAN;
                    end
                end
                LOOKUP: begin
                    if(hit0 || hit1) begin
                        response_data<=current_word; response_pair_data<=current_pair_word; response_pair_available<=current_pair_available; stored_rsp_error<=0;
                        if(!request_missed) hit_count<=hit_count+1;
                        if(DIRECT_READ_RESPONSE!=0) begin
                            // A read-only hit can hold its synchronous bank outputs
                            // in LOOKUP. No refill, write or new accepted request can
                            // modify those words while the response is stalled.
                            // Reuse the existing miss/accounted flag so hit_count
                            // increments once, not on every stalled response cycle.
                            request_missed<=1;
                            stored_state<=rsp_ready ? IDLE : LOOKUP;
                        end else stored_state<=fast_hit && rsp_ready ? IDLE : RESPONSE;
                    end else begin
                        request_missed<=1; miss_count<=miss_count+1;
                        victim<=replacement;
                        victim_base<=READ_ONLY!=0 ? 32'b0 : {{(32-ADDRESS_BITS){1'b0}},tags[replacement],request_set,{(WORD_BITS+2){1'b0}}};
                        beat<=0;
                        stored_state<=(replacement_valid && replacement_dirty) ? WB_CMD : FILL_CMD;
                    end
                end
                WB_CMD: if(cmd_ready) begin beat<=0; stored_state<=WB_DATA; end
                WB_DATA: if(w_ready) begin
                    if(last_beat) stored_state<=WB_ACK;
                    else beat<=beat+1'b1;
                end
                WB_ACK: if(b_valid) begin
                    if(b_error) begin
                        if(flushing) begin flush_error<=1; stored_state<=FLUSH_DONE; end
                        else begin response_data<=0; stored_rsp_error<=1; stored_state<=RESPONSE; end
                    end else begin
                        writeback_count<=writeback_count+1;
                        if(flushing) begin
                            if(&scan_line) stored_state<=FLUSH_DONE;
                            else begin scan_line<=scan_line+1'b1; stored_state<=FLUSH_SCAN; end
                        end else stored_state<=FILL_CMD;
                    end
                end
                FILL_CMD: if(cmd_ready) begin
                     fill_failed<=0; beat<=0; stored_state<=FILL_DATA;
                end
                FILL_DATA: if(r_valid) begin
                    if(r_error || r_last!=last_beat) fill_failed<=1;
                    if(r_last) begin
                        if(fill_failed || r_error || !last_beat) begin
                             response_data<=0; stored_rsp_error<=1; stored_state<=RESPONSE;
                        end else begin
                            tags[victim]<=request_tag;
                            stored_state<=LOOKUP;
                        end
                    end else if(!last_beat) beat<=beat+1'b1;
                end
                RESPONSE: stored_state<=rsp_ready ? IDLE : RESPONSE;
                FLUSH_SCAN: begin
                    if(scan_valid && scan_dirty) begin
                        victim<=scan_line;
                        victim_base<=READ_ONLY!=0 ? 32'b0 : {{(32-ADDRESS_BITS){1'b0}},tags[scan_line],scan_line[SET_BITS-1:0],{(WORD_BITS+2){1'b0}}};
                        stored_state<=WB_CMD;
                    end else begin
                        if(&scan_line) stored_state<=FLUSH_DONE;
                        else scan_line<=scan_line+1'b1;
                    end
                end
                FLUSH_DONE: if(flush_valid) stored_state<=IDLE;
                default: stored_state<=IDLE;
            endcase
            if(req_ready) begin
                request_error_address<=req_address & ((32'hffffffff<<ADDRESS_BITS) | 32'h3);
                request_address<={{(32-ADDRESS_BITS){1'b0}},req_address[ADDRESS_BITS-1:0]}; request_data<=req_data;
                request_strobe<=req_strobe; request_write<=req_write;
            end
            if(req_valid && req_ready) begin
                request_missed<=0; flushing<=0; stored_rsp_error<=0;
                stored_state<=LOOKUP;
            end
        end
    end
endmodule
