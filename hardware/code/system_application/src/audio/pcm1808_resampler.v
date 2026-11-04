module pcm1808_resampler (
    input wire clk, input wire rst_n, input wire stream_idle,
    input wire in_valid, input wire [15:0] in_l, input wire [15:0] in_r,
    output reg out_valid, output reg [15:0] out_l, output reg [15:0] out_r,
    output reg overrun
);
    (* syn_ramstyle = "block_ram" *) reg signed [15:0] history_l [0:127];
    (* syn_ramstyle = "block_ram" *) reg signed [15:0] history_r [0:127];
    reg [6:0] wr_ptr, head, tap;
    reg [7:0] rate_acc, phase;
    reg [1:0] state;
    reg signed [15:0] history_read_l, history_read_r;
    reg [6:0] history_valid;
    wire signed [15:0] coeff;
    reg signed [31:0] product_l, product_r;
    reg signed [47:0] acc_l, acc_r;
    wire [8:0] rate_sum = {1'b0, rate_acc} + 9'd147;
    wire [6:0] history_addr = head - tap;
    wire signed [47:0] sum_l = acc_l + {{16{product_l[31]}}, product_l};
    wire signed [47:0] sum_r = acc_r + {{16{product_r[31]}}, product_r};
    pcm1808_coeff_rom u_coeff (.clk(clk), .phase(phase), .tap(tap), .coeff(coeff));

    always @(posedge clk) begin
        if (rst_n && !stream_idle && in_valid && state == 0) begin
            history_l[wr_ptr] <= in_l;
            history_r[wr_ptr] <= in_r;
        end
        history_read_l <= history_l[history_addr];
        history_read_r <= history_r[history_addr];
    end
    function [15:0] rounded;
        input signed [47:0] value;
        reg signed [47:0] integer_part;
        begin
            integer_part = value >>> 15;
            if (value[14:0] > 15'd16384 ||
                (value[14:0] == 15'd16384 && integer_part[0]))
                integer_part = integer_part + 1'b1;
            if (integer_part > 32767) rounded = 16'h7fff;
            else if (integer_part < -32768) rounded = 16'h8000;
            else rounded = integer_part[15:0];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0; head <= 0; tap <= 0; rate_acc <= 0; phase <= 0;
            state <= 0; history_valid <= 0;
            product_l <= 0; product_r <= 0; acc_l <= 0; acc_r <= 0;
            out_valid <= 0; out_l <= 0; out_r <= 0; overrun <= 0;
        end else if (stream_idle) begin
            wr_ptr <= 0; head <= 0; tap <= 0; rate_acc <= 0; phase <= 0;
            state <= 0; history_valid <= 0; out_valid <= 0; out_l <= 0; out_r <= 0;
            acc_l <= 0; acc_r <= 0; overrun <= 0;
        end else begin
            out_valid <= 0;
            if (in_valid) begin
                if (state != 0) overrun <= 1;
                else begin
                    if (history_valid < 96) history_valid <= history_valid + 1'b1;
                    head <= wr_ptr;
                    wr_ptr <= wr_ptr + 1'b1;
                    if (rate_sum >= 160) begin
                        rate_acc <= rate_sum - 9'd160;
                        phase <= rate_sum - 9'd160;
                        tap <= 0; acc_l <= 0; acc_r <= 0; state <= 1;
                    end else rate_acc <= rate_sum[7:0];
                end
            end
            case (state)
                1: begin
                    state <= 2;
                end
                2: begin
                    product_l <= (tap < history_valid ? history_read_l : 16'sd0) * coeff;
                    product_r <= (tap < history_valid ? history_read_r : 16'sd0) * coeff;
                    state <= 3;
                end
                3: begin
                    if (tap == 95) begin
                        out_l <= rounded(sum_l); out_r <= rounded(sum_r);
                        out_valid <= 1; state <= 0;
                    end else begin
                        acc_l <= sum_l; acc_r <= sum_r;
                        tap <= tap + 1'b1; state <= 1;
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule
