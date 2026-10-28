`timescale 1ns/1ps
module rv32_muldiv #(parameter integer PRECOMPUTE=0, parameter integer RETAIN_PREPARATION=0) (
    input wire clk,
    input wire rst_n,
    input wire cancel,
    input wire req_valid,
    input wire req_precomputed,
    output wire req_ready,
    input wire [2:0] req_operation,
    input wire [31:0] req_operand_a,
    input wire [31:0] req_operand_b,
    output wire rsp_valid,
    output wire rsp_available,
    input wire rsp_ready,
    output wire [31:0] rsp_data
);
    localparam [2:0] IDLE=0,PRODUCT=2,DIVIDE=3,DIVISION_RESULT=4,RESPONSE=5;
    reg [2:0] state;
    reg [2:0] operation;
    reg [31:0] product_low_low,product_high_high;
    reg signed [33:0] product_low_high,product_high_low;
    wire signed [16:0] request_low_a={1'b0,req_operand_a[15:0]};
    wire signed [16:0] request_low_b={1'b0,req_operand_b[15:0]};
    wire signed [16:0] request_high_a={((req_operation==1 || req_operation==2) && req_operand_a[31]),req_operand_a[31:16]};
    wire signed [16:0] request_high_b={(req_operation==1 && req_operand_b[31]),req_operand_b[31:16]};
    wire [47:0] product_cross_a={{14{product_low_high[33]}},product_low_high};
    wire [47:0] product_cross_b={{14{product_high_low[33]}},product_high_low};
    wire [47:0] product_outer={product_high_high,product_low_low[31:16]};
    wire [47:0] product_sum=product_cross_a^product_cross_b^product_outer;
    wire [47:0] product_carry=((product_cross_a & product_cross_b) |
        (product_cross_a & product_outer) | (product_cross_b & product_outer)) << 1;
    wire [47:0] product_upper=product_sum+product_carry;
    wire [63:0] product={product_upper,product_low_low[15:0]};
    reg [31:0] response_data;
    reg [31:0] divisor,quotient;
    reg [31:0] remainder;
    reg [4:0] division_step;
    reg quotient_negative,remainder_negative;
    wire signed_division=!req_operation[0];
    wire negative_a=signed_division && req_operand_a[31];
    wire negative_b=signed_division && req_operand_b[31];
    wire [32:0] trial_remainder={remainder[31:0],quotient[31]};
    // The extra leading bit exposes borrow while retaining the full trial value.
    wire [33:0] trial_difference={1'b0,trial_remainder}-{2'b0,divisor};
    wire unused_trial_difference_high=trial_difference[32];
    wire subtract_divisor=!trial_difference[33];
    assign req_ready=state==IDLE && !cancel;
    wire early_product=state==PRODUCT && (operation==0 || operation==3);
    wire immediate_product=PRECOMPUTE!=0 && state==IDLE && req_valid && req_precomputed && req_operation==0;
    assign rsp_available=state==RESPONSE || early_product ||
        (PRECOMPUTE!=0 && state==IDLE && req_precomputed && req_operation==0);
    assign rsp_valid=(state==RESPONSE || early_product || immediate_product) && !cancel;
    assign rsp_data=immediate_product ? product[31:0] :
        (early_product ? (operation==0 ? product[31:0] : product[63:32]) : response_data);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            product_low_low<=0; product_low_high<=0; product_high_low<=0; product_high_high<=0;
        end else if(state==IDLE && !(RETAIN_PREPARATION!=0 && PRECOMPUTE!=0 && req_precomputed)) begin
            // The owner token protects all four partial products during a wait.
            product_low_low<=req_operand_a[15:0]*req_operand_b[15:0];
            product_low_high<=request_low_a*request_high_b;
            product_high_low<=request_high_a*request_low_b;
            product_high_high<=request_high_a*request_high_b;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; operation<=0;
            divisor<=0; quotient<=0; remainder<=0; division_step<=0;
            quotient_negative<=0; remainder_negative<=0; response_data<=0;
        end else if(cancel) begin
            state<=IDLE;
        end else begin
            if(state==IDLE) begin
                operation<=req_operation;
                divisor<=negative_b ? -req_operand_b : req_operand_b;
                quotient<=negative_a ? -req_operand_a : req_operand_a;
                remainder<=0; division_step<=0;
                quotient_negative<=negative_a ^ negative_b;
                remainder_negative<=negative_a;
                response_data<=req_operation[1] ? req_operand_a : 32'hffffffff;
            end
            case(state)
                IDLE: if(req_valid) begin
                    if(immediate_product) begin
                        if(!rsp_ready) begin
                            response_data<=product[31:0];
                            state<=RESPONSE;
                        end
                    end else if(!req_operation[2]) begin
                        state<=PRODUCT;
                    end else if(req_operand_b==0) begin
                        state<=RESPONSE;
                    end else begin
                        state<=DIVIDE;
                    end
                end
                PRODUCT: begin
                    if(early_product) begin
                        if(rsp_ready) state<=IDLE;
                    end else begin
                        response_data<=product[63:32];
                        state<=RESPONSE;
                    end
                end
                DIVIDE: begin
                    quotient<={quotient[30:0],subtract_divisor};
                    remainder<=subtract_divisor ? trial_difference[31:0] : trial_remainder[31:0];
                    division_step<=division_step+1'b1;
                    if(division_step==31) state<=DIVISION_RESULT;
                end
                DIVISION_RESULT: begin
                    response_data<=operation[1] ? (remainder_negative ? -remainder[31:0] : remainder[31:0]) :
                        (quotient_negative ? -quotient : quotient);
                    state<=RESPONSE;
                end
                RESPONSE: if(rsp_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
