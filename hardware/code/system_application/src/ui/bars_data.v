module bars_data (
    input wire core_clk, core_rst_n,
    input wire probs_valid,
    input wire [7:0] probs_pct,
    input wire [3:0] probs_idx, top1,
    input wire pix_clk, pix_rst_n, frame_start,
    output reg [7:0] pct0, pct1, pct2, pct3, pct4, pct5, pct6, pct7,
    output reg frame_ready,
    output reg [3:0] frame_class
);
    reg [63:0] collect, snapshot, pending;
    reg [7:0] collected;
    reg [3:0] snapshot_class, pending_class;
    reg request_toggle, acknowledge, request_seen, pending_valid;
    reg [1:0] ack_sync, request_sync;
    wire [7:0] pct_clamped = (probs_pct > 8'd100) ? 8'd100 : probs_pct;
    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            collect <= 64'd0;
            collected <= 8'd0;
            snapshot <= 64'd0;
            snapshot_class <= 4'd0;
            request_toggle <= 1'b0;
            ack_sync <= 2'b00;
        end else begin
            ack_sync <= {ack_sync[0], acknowledge};
            if (probs_valid && probs_idx < 4'd8) begin
                collect[probs_idx * 8 +: 8] <= pct_clamped;
                if (probs_idx == 4'd0) collected <= 8'h01;
                else collected[probs_idx] <= 1'b1;
                if (probs_idx == 4'd7 && collected[6:0] == 7'h7f && ack_sync[1] == request_toggle) begin
                    snapshot <= {pct_clamped, collect[55:0]};
                    snapshot_class <= top1;
                    request_toggle <= ~request_toggle;
                    collected <= 8'd0;
                end
            end
        end
    end
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            request_sync <= 2'b00;
            request_seen <= 1'b0;
            acknowledge <= 1'b0;
            pending <= 64'd0;
            pending_class <= 4'd0;
            pending_valid <= 1'b0;
            pct0 <= 0; pct1 <= 0; pct2 <= 0; pct3 <= 0;
            pct4 <= 0; pct5 <= 0; pct6 <= 0; pct7 <= 0;
            frame_class <= 0;
            frame_ready <= 0;
        end else begin
            request_sync <= {request_sync[0], request_toggle};
            if (request_sync[1] != request_seen) begin
                pending <= snapshot;
                pending_class <= snapshot_class;
                pending_valid <= 1'b1;
                request_seen <= request_sync[1];
                acknowledge <= request_sync[1];
            end else if (frame_start && pending_valid) begin
                {pct7,pct6,pct5,pct4,pct3,pct2,pct1,pct0} <= pending;
                frame_class <= pending_class;
                frame_ready <= 1;
                pending_valid <= 1'b0;
            end
        end
    end
endmodule
