// Module: top_pcm1808_probe. Stand-alone real-input diagnostic. No DDR, NPU or simulated audio.
module top_pcm1808_probe (
    input wire clk, input wire rst_n,
    input wire i2s_bck, input wire i2s_lrck, input wire i2s_sd,
    output wire uart_tx, output wire [7:0] led
);
    reg [1:0] reset_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reset_sync <= 0;
        else reset_sync <= {reset_sync[0],1'b1};
    end
    wire reset_ok = reset_sync[1];
    wire [15:0] sample_l, sample_r, filtered_l, filtered_r;
    wire sample_valid, idle, filtered_valid, overrun;
    i2s_slave_rx #(.TIMEOUT_CYCLES(27000)) u_rx (
        .clk_nco(clk), .rst_n(reset_ok), .i2s_bck(i2s_bck),
        .i2s_lrck(i2s_lrck), .i2s_sd(i2s_sd),
        .pcm_l(sample_l), .pcm_r(sample_r), .pcm_valid(sample_valid), .sd_idle(idle));
    pcm1808_resampler u_resampler (
        .clk(clk), .rst_n(reset_ok), .stream_idle(idle),
        .in_valid(sample_valid), .in_l(sample_l), .in_r(sample_r),
        .out_valid(filtered_valid), .out_l(filtered_l), .out_r(filtered_r), .overrun(overrun));
    reg [24:0] timer;
    reg [31:0] input_count, output_count, nonzero_count, last_pair;
    reg signed [15:0] sample_min, sample_max;
    reg [31:0] input_q, output_q, nonzero_q, range_q, last_q;
    reg [7:0] flags_q;
    reg fire, heartbeat;
    always @(posedge clk or negedge reset_ok) begin
        if (!reset_ok) begin
            timer <= 0; input_count <= 0; output_count <= 0; nonzero_count <= 0;
            sample_min <= 16'sh7fff; sample_max <= 16'sh8000; last_pair <= 0;
            input_q <= 0; output_q <= 0; nonzero_q <= 0; range_q <= 0;
            last_q <= 0; flags_q <= 0; fire <= 0; heartbeat <= 0;
        end else begin
            fire <= 0;
            if (sample_valid) begin
                input_count <= input_count + 1'b1;
                if (sample_l != 0 || sample_r != 0) nonzero_count <= nonzero_count + 1'b1;
                if ($signed(sample_l) < sample_min) sample_min <= sample_l;
                if ($signed(sample_l) > sample_max) sample_max <= sample_l;
            end
            if (filtered_valid) begin
                output_count <= output_count + 1'b1;
                last_pair <= {filtered_l,filtered_r};
            end
            if (timer == 26999999) begin
                timer <= 0; fire <= 1; heartbeat <= !heartbeat;
                input_q <= input_count; output_q <= output_count;
                nonzero_q <= nonzero_count; range_q <= {sample_min,sample_max};
                last_q <= last_pair; flags_q <= {6'b0,overrun,idle};
                input_count <= sample_valid ? 1 : 0;
                output_count <= filtered_valid ? 1 : 0;
                nonzero_count <= sample_valid && (sample_l != 0 || sample_r != 0) ? 1 : 0;
                sample_min <= sample_valid ? sample_l : 16'sh7fff;
                sample_max <= sample_valid ? sample_l : 16'sh8000;
            end else timer <= timer + 1'b1;
        end
    end
    wire [7:0] tx_data;
    wire tx_valid, tx_ready, report_busy;
    // Existing generic format uses UIDEMO tag; A=50434D38 identifies PCM8.
    diag_uart_report #(.BAUD_DIV(234)) u_report (
        .clk(clk), .rst_n(reset_ok), .fire(fire), .frame_tag(2'd1),
        .f_a(32'h50434d38), .f_b(input_q), .f_c(output_q),
        .f_d(nonzero_q), .f_e(range_q), .f_f(last_q), .f_g(flags_q), .f_h(8'd27),
        .busy(report_busy), .tx_byte_data(tx_data), .tx_byte_valid(tx_valid), .tx_byte_ready(tx_ready));
    uart_tx #(.BAUD_DIV(234)) u_tx (
        .clk(clk), .rst_n(reset_ok), .byte_wdata(tx_data), .byte_wvalid(tx_valid),
        .byte_wready(tx_ready), .uart_txd(uart_tx));
    assign led = {4'b0,overrun,!idle,nonzero_q != 0,heartbeat};
endmodule
