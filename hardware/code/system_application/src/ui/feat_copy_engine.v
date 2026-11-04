module feat_copy_engine #(
    parameter integer SOURCE_FRAME_MAJOR = 0
) (
    input  wire        core_clk,
    input  wire        core_rst_n,

    input  wire        start,
    input  wire        busy_in,

    output reg  [14:0] src_addr,
    output reg         src_en,
    input  wire [7:0]  src_data,

    output reg  [14:0] dst_addr,
    output reg  [7:0]  dst_data,
    output reg         dst_we,
    output reg         dst_page,

    output reg         done
);

    localparam DEPTH = 16512;

    reg [14:0] idx;
    reg [14:0] idx_q;
    reg        run;
    reg        fin;
    reg        rd_pending;
    wire [14:0] display_addr = {idx_q[5:0], 8'd0} +
                              {8'd0, idx_q[5:0], 1'd0} +
                              {6'd0, idx_q[14:6]};

    always @* begin
        src_addr = (idx < DEPTH) ? idx : 15'd0;
        src_en = run && !busy_in && (idx < DEPTH);
    end

    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            idx      <= 15'd0;
            idx_q    <= 15'd0;
            run      <= 1'b0;
            fin      <= 1'b0;
            rd_pending <= 1'b0;
            dst_addr <= 15'd0;
            dst_data <= 8'd0;
            dst_we   <= 1'b0;
            dst_page <= 1'b0;
            done     <= 1'b0;
        end else begin
            dst_we <= 1'b0;
            done   <= 1'b0;
            rd_pending <= src_en;

            if (!run) begin
                if (start && !busy_in) begin
                    run      <= 1'b1;
                    idx      <= 15'd0;
                    idx_q    <= 15'd0;
                    fin      <= 1'b0;
                end
            end else begin
                if (src_en) begin
                    idx_q <= idx;
                    idx <= idx + 15'd1;
                end
                if (rd_pending) begin
                    dst_addr <= SOURCE_FRAME_MAJOR ? display_addr : idx_q;
                    dst_data <= src_data;
                    dst_we   <= 1'b1;
                    if (idx_q == DEPTH - 1) fin <= 1'b1;
                end
                if (fin) begin
                    run      <= 1'b0;
                    fin      <= 1'b0;
                    dst_page <= ~dst_page;
                    done     <= 1'b1;
                end
            end
        end
    end

endmodule
