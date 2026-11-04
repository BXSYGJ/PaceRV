module feat_page_buf (
    input  wire        core_clk,
    input  wire        core_rst_n,
    input  wire        wr_en,
    input  wire [14:0] wr_addr,
    input  wire [7:0]  wr_data,
    input  wire        wr_page,
    input  wire        copy_done,

    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        frame_start,
    input  wire [14:0] rd_addr,
    output reg  [7:0]  rd_data,
    output reg         page_ready
);

    localparam DEPTH = 16512;

    reg [7:0] page0 [0:DEPTH-1];
    reg [7:0] page1 [0:DEPTH-1];
    reg published_page, publish_toggle;
    reg [1:0] publish_sync;
    reg publish_seen, pending_page, page_pending, front_page;
    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            published_page <= 1'b0;
            publish_toggle <= 1'b0;
        end else if (copy_done) begin
            published_page <= ~wr_page;
            publish_toggle <= ~publish_toggle;
        end
    end
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            publish_sync <= 2'b00;
            publish_seen <= 1'b0;
            pending_page <= 1'b0;
            page_pending <= 1'b0;
            front_page <= 1'b0;
            page_ready <= 1'b0;
        end else begin
            publish_sync <= {publish_sync[0], publish_toggle};
            if (publish_sync[1] != publish_seen) begin
                pending_page <= published_page;
                page_pending <= 1'b1;
                publish_seen <= publish_sync[1];
            end else if (frame_start && page_pending) begin
                front_page <= pending_page;
                page_pending <= 1'b0;
                page_ready <= 1'b1;
            end
        end
    end

    always @(posedge core_clk) begin
        if (wr_en) begin
            if (wr_page) page1[wr_addr] <= wr_data;
            else         page0[wr_addr] <= wr_data;
        end
    end

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) rd_data <= 8'd0;
        else if (!front_page) rd_data <= page0[rd_addr];
        else                 rd_data <= page1[rd_addr];
    end

endmodule
