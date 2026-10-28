`timescale 1ns/1ps
module rv32_btb #(
    parameter integer INDEX_BITS=4,
    parameter integer ADDRESS_BITS=32,
    parameter integer HASH_INDEX=1,
    parameter integer HASH_ROTATE=4,
    parameter integer HISTORY_BITS=3,
    parameter integer COUNTER_BITS=2,
    parameter integer RETURN_STACK_DEPTH=0
) (
    input wire clk,
    input wire rst_n,
    input wire invalidate,
    input wire [31:0] fetch_pc,
    output wire predicted_taken,
    output wire [31:0] predicted_target,
    output wire prediction_hit,
    output wire return_stack_available,
    output wire [31:0] return_stack_target,
    input wire update_valid,
    input wire [31:0] update_pc,
    input wire [31:0] update_target,
    input wire update_taken,
    input wire update_conditional,
    input wire update_return,
    input wire stack_push,
    input wire stack_pop,
    input wire [31:0] stack_push_address
);
    localparam integer ENTRIES=1<<INDEX_BITS;
    localparam integer TAG_BITS=ADDRESS_BITS-1-INDEX_BITS;
    localparam integer PATTERNS=1<<HISTORY_BITS;
    localparam integer ROTATE=HASH_ROTATE%INDEX_BITS;
    localparam [COUNTER_BITS-1:0] WEAK_TAKEN={1'b1,{(COUNTER_BITS-1){1'b0}}};
    localparam [COUNTER_BITS-1:0] WEAK_NOT_TAKEN={1'b0,{(COUNTER_BITS-1){1'b1}}};
    (* syn_ramstyle="lut_ram" *) reg valid_storage[0:ENTRIES-1];
    (* syn_ramstyle="lut_ram" *) reg direction_storage[0:ENTRIES-1];
    reg clearing;
    reg [INDEX_BITS-1:0] clear_index;
    wire fetch_tag_match,update_tag_match;
    reg [ADDRESS_BITS-2:0] targets [0:ENTRIES-1];
    reg [HISTORY_BITS-1:0] history [0:ENTRIES-1];
    reg conditional [0:ENTRIES-1];
    reg return_entry [0:ENTRIES-1];
    wire stack_available;
    assign return_stack_available=stack_available && !invalidate;
    assign return_stack_target=stack_target;
    wire [31:0] stack_target;
    wire [INDEX_BITS-1:0] fetch_hash=fetch_pc[2*INDEX_BITS:INDEX_BITS+1];
    wire [INDEX_BITS-1:0] update_hash=update_pc[2*INDEX_BITS:INDEX_BITS+1];
    wire [INDEX_BITS-1:0] fetch_fold=(fetch_hash << ROTATE) | (fetch_hash >> (INDEX_BITS-ROTATE));
    wire [INDEX_BITS-1:0] update_fold=(update_hash << ROTATE) | (update_hash >> (INDEX_BITS-ROTATE));
    (* syn_maxfan=24 *) wire [INDEX_BITS-1:0] fetch_index=fetch_pc[INDEX_BITS:1] ^
        (HASH_INDEX!=0 ? fetch_fold : {INDEX_BITS{1'b0}});
    wire [INDEX_BITS-1:0] update_index=update_pc[INDEX_BITS:1] ^
        (HASH_INDEX!=0 ? update_fold : {INDEX_BITS{1'b0}});
    wire [TAG_BITS-1:0] fetch_tag=fetch_pc[ADDRESS_BITS-1:INDEX_BITS+1];
    wire [TAG_BITS-1:0] update_tag=update_pc[ADDRESS_BITS-1:INDEX_BITS+1];
    wire train_update=update_valid && !clearing && !invalidate && (update_pc >> ADDRESS_BITS)==0 &&
        (update_target >> ADDRESS_BITS)==0 && update_pc[0]==0 && update_target[0]==0;
    wire allocate_entry=!valid_storage[update_index] || !update_tag_match ||
        conditional[update_index]!=update_conditional;
    wire [PATTERNS-1:0] pattern_prediction;
    wire [PATTERNS-1:0] next_pattern_prediction;
    wire [HISTORY_BITS-1:0] prior_history=history[update_index];
    wire run_saturated=(prior_history | {1'b1,{(HISTORY_BITS-1){1'b0}}})=={HISTORY_BITS{1'b1}};
    wire [HISTORY_BITS-1:0] next_history=prior_history[HISTORY_BITS-1]==update_taken ?
        (run_saturated ? prior_history : prior_history+{{(HISTORY_BITS-1){1'b0}},1'b1}) :
        {update_taken,{(HISTORY_BITS-1){1'b0}}};
    assign prediction_hit=!clearing && !invalidate && (fetch_pc >> ADDRESS_BITS)==0 && valid_storage[fetch_index] &&
        fetch_tag_match && fetch_pc[0]==0;
    assign predicted_taken=prediction_hit && direction_storage[fetch_index];
    assign predicted_target=(stack_available && return_entry[fetch_index]) ?
        stack_target : {{(32-ADDRESS_BITS){1'b0}},targets[fetch_index],1'b0};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clearing<=1;
            clear_index<=0;
        end else if (invalidate) begin
            clearing<=1;
            clear_index<=0;
        end else if(clearing) begin
            if(&clear_index) clearing<=0;
            else clear_index<=clear_index+1'b1;
        end
    end
    always @(posedge clk) begin
        if(clearing || train_update)
            valid_storage[clearing ? clear_index : update_index]<=!clearing;
        if(train_update)
            direction_storage[update_index]<=!update_conditional ||
                (allocate_entry ? update_taken : next_pattern_prediction[next_history]);
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
        end else if (train_update) begin
            targets[update_index]<=update_target[ADDRESS_BITS-1:1];
            conditional[update_index]<=update_conditional;
            return_entry[update_index]<=update_return && !update_conditional;
            if (allocate_entry)
                history[update_index]<=update_conditional ? {update_taken,{(HISTORY_BITS-1){1'b0}}} : {HISTORY_BITS{1'b0}};
            else if (update_conditional)
                history[update_index]<=next_history;
        end
    end
    // Low index bits select a one-bit tag comparison, not 28 RAM addresses.
    generate if(INDEX_BITS>2) begin: interleaved_tags
        localparam integer ROW_BITS=INDEX_BITS-2;
        (* syn_keep=1 *) wire [3:0] fetch_matches;
        (* syn_keep=1 *) wire [3:0] update_matches;
        genvar bank;
        for(bank=0;bank<4;bank=bank+1) begin: tag_bank
            (* syn_ramstyle="lut_ram" *) reg [TAG_BITS-1:0] tags[0:(1<<ROW_BITS)-1];
            assign fetch_matches[bank]=tags[fetch_index[INDEX_BITS-1:2]]==fetch_tag;
            assign update_matches[bank]=tags[update_index[INDEX_BITS-1:2]]==update_tag;
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin
                end else if(train_update && update_index[1:0]==bank)
                    tags[update_index[INDEX_BITS-1:2]]<=update_tag;
            end
        end
        assign fetch_tag_match=fetch_matches[fetch_index[1:0]];
        assign update_tag_match=update_matches[update_index[1:0]];
    end else begin: small_tags
        reg [TAG_BITS-1:0] tags[0:ENTRIES-1];
        assign fetch_tag_match=tags[fetch_index]==fetch_tag;
        assign update_tag_match=tags[update_index]==update_tag;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
            end else if(train_update) tags[update_index]<=update_tag;
        end
    end endgenerate
    generate if (RETURN_STACK_DEPTH>0) begin: return_stack
        localparam integer COUNT_BITS=$clog2(RETURN_STACK_DEPTH+1);
        localparam [COUNT_BITS-1:0] CAPACITY=RETURN_STACK_DEPTH[COUNT_BITS-1:0];
        reg [COUNT_BITS-1:0] count;
        reg [31:0] addresses [0:RETURN_STACK_DEPTH-1];
        integer stack_index;
        assign stack_available=count!=0;
        assign stack_target=addresses[0];
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                count<=0;
            end else if (invalidate) begin
                count<=0;
            end else if (stack_push) begin
                addresses[0]<=stack_push_address;
                if (!stack_pop || count==0) begin
                    if (count<CAPACITY) count<=count+1'b1;
                    for (stack_index=1;stack_index<RETURN_STACK_DEPTH;stack_index=stack_index+1)
                        addresses[stack_index]<=addresses[stack_index-1];
                end
            end else if (stack_pop && count!=0) begin
                count<=count-1'b1;
                for (stack_index=0;stack_index<RETURN_STACK_DEPTH-1;stack_index=stack_index+1)
                    addresses[stack_index]<=addresses[stack_index+1];
            end
        end
    end else begin: no_return_stack
        assign stack_available=1'b0;
        assign stack_target=32'd0;
    end endgenerate
    genvar pattern;
    generate for (pattern=0;pattern<PATTERNS;pattern=pattern+1) begin: pattern_banks
        localparam [HISTORY_BITS-1:0] PATTERN_INDEX=pattern[HISTORY_BITS-1:0];
        reg [COUNTER_BITS-1:0] counters [0:ENTRIES-1];
        assign pattern_prediction[pattern]=counters[fetch_index][COUNTER_BITS-1];
        assign next_pattern_prediction[pattern]=history[update_index]==PATTERN_INDEX ?
            (update_taken ? counters[update_index]>=WEAK_NOT_TAKEN : counters[update_index]>WEAK_TAKEN) :
            counters[update_index][COUNTER_BITS-1];
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
            end else if (!invalidate && train_update) begin
                if (allocate_entry)
                    counters[update_index]<=update_taken ? WEAK_TAKEN : WEAK_NOT_TAKEN;
                else if (update_conditional && history[update_index]==PATTERN_INDEX) begin
                    if (update_taken && counters[update_index]!={COUNTER_BITS{1'b1}})
                        counters[update_index]<=counters[update_index]+{{(COUNTER_BITS-1){1'b0}},1'b1};
                    else if (!update_taken && counters[update_index]!={COUNTER_BITS{1'b0}})
                        counters[update_index]<=counters[update_index]-{{(COUNTER_BITS-1){1'b0}},1'b1};
                end
            end
        end
    end endgenerate
endmodule
