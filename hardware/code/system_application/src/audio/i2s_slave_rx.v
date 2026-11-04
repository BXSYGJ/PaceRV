module i2s_slave_rx #(
    parameter TIMEOUT_CYCLES = 216000
)(
    input wire clk_nco, input wire rst_n,
    input wire i2s_bck, input wire i2s_lrck, input wire i2s_sd,
    output reg [15:0] pcm_l, output reg [15:0] pcm_r,
    output reg pcm_valid, output reg sd_idle
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] bck_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] lrck_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sd_sync;
    reg bck_prev, channel, aligned, left_valid;
    reg [5:0] bit_count;
    reg [15:0] shift_word, left_word;
    reg [17:0] watchdog;
    always @(posedge clk_nco or negedge rst_n) begin
        if (!rst_n) begin
            bck_sync <= 0; lrck_sync <= 0; sd_sync <= 0;
            bck_prev <= 0; channel <= 0; aligned <= 0;
            left_valid <= 0; bit_count <= 0; shift_word <= 0;
            left_word <= 0; pcm_l <= 0; pcm_r <= 0;
            pcm_valid <= 0; sd_idle <= 1; watchdog <= 0;
        end else begin
            bck_sync <= {bck_sync[0], i2s_bck};
            lrck_sync <= {lrck_sync[0], i2s_lrck};
            sd_sync <= {sd_sync[0], i2s_sd};
            bck_prev <= bck_sync[1];
            pcm_valid <= 0;
            if (bck_sync[1] && !bck_prev) begin
                if (lrck_sync[1] != channel) begin

                    if (aligned && bit_count < 24) left_valid <= 0;
                    channel <= lrck_sync[1];
                    aligned <= 1;
                    bit_count <= 0;
                end else if (aligned) begin
                    if (bit_count < 16)
                        shift_word <= {shift_word[14:0], sd_sync[1]};
                    if (bit_count < 63) bit_count <= bit_count + 1'b1;
                    if (bit_count == 23) begin
                        if (!channel) begin
                            left_word <= shift_word;
                            left_valid <= 1;
                        end else if (left_valid) begin
                            pcm_l <= left_word;
                            pcm_r <= shift_word;
                            pcm_valid <= 1;
                            left_valid <= 0;
                            sd_idle <= 0;
                        end
                    end
                end
            end

            if (pcm_valid) watchdog <= 0;
            else if (watchdog == TIMEOUT_CYCLES-1) begin
                sd_idle <= 1; aligned <= 0; left_valid <= 0;
                bit_count <= 0; watchdog <= 0;
            end else watchdog <= watchdog + 1'b1;
        end
    end
endmodule
