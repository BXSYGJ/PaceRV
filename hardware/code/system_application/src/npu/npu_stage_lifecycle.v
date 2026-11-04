module npu_stage_lifecycle (
    input wire clk, rst_n, inference_start,
    input wire [3:0] conv_start,
    input wire [3:0] pool_last_accepted,
    input wire gap_done,
    output wire [3:0] pool_arm,
    output wire gap_arm,
    output reg [3:0] pool_complete,
    output reg gap_complete
);
    assign pool_arm=conv_start;
    assign gap_arm=conv_start[3];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin pool_complete<=0;gap_complete<=0;end
        else begin
            for(i=0;i<4;i=i+1) begin
                if(inference_start || conv_start[i]) pool_complete[i]<=0;
                else if(pool_last_accepted[i]) pool_complete[i]<=1;
            end
            if(inference_start || conv_start[3]) gap_complete<=0;
            else if(gap_done) gap_complete<=1;
        end
    end
endmodule
