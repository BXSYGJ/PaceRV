`timescale 1ns / 1ps

module audio_cdc_fifo #(

    parameter [3:0] ADDR_W = 4'd9,

    parameter [5:0] DATA_W = 6'd32
) (

    input  wire        clk_nco,

    input  wire        wr_rst_n,

    input  wire        pcm_valid,
    input  wire [15:0] pcm_l,
    input  wire [15:0] pcm_r,

    input  wire        i2s_lrck,

    input  wire        clk_core,

    input  wire        rd_rst_n,

    input  wire        rd_en,
    output wire [31:0] rd_data,
    output wire        rd_valid,

    output wire        empty,
    output wire        full,

    output wire [15:0] overflow_cnt
);

    localparam [3:0] PTR_W = ADDR_W + 4'd1;

    reg [31:0] mem [0:(1 << ADDR_W) - 1];

    reg [PTR_W-1:0] wr_bin;
    reg [PTR_W-1:0] wr_gray;

    wire wr_req = pcm_valid & ~i2s_lrck;

    function [PTR_W-1:0] bin2gray;
        input [PTR_W-1:0] bin_val;
        begin
            bin2gray = bin_val ^ (bin_val >> 1);
        end
    endfunction

    wire [PTR_W-1:0] rd_gray_wsync;
    reg full_w;

    wire wr_fire = wr_req & ~full_w;
    wire [PTR_W-1:0] wr_bin_next = wr_bin + wr_fire;
    wire [PTR_W-1:0] wr_gray_next = bin2gray(wr_bin_next);
    wire full_next = (wr_gray_next == {~rd_gray_wsync[PTR_W-1:PTR_W-2],
                                      rd_gray_wsync[PTR_W-3:0]});

    always @(posedge clk_nco or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin  <= {PTR_W{1'b0}};
            wr_gray <= {PTR_W{1'b0}};
            full_w  <= 1'b0;
        end else begin
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
            full_w  <= full_next;
        end
    end

    always @(posedge clk_nco) begin
        if (wr_fire)
            mem[wr_bin[ADDR_W-1:0]] <= {pcm_l, pcm_r};
    end

    reg [15:0] overflow_cnt_r;

    always @(posedge clk_nco or negedge wr_rst_n) begin
        if (!wr_rst_n)
            overflow_cnt_r <= 16'd0;
        else if (wr_req && full_w && (overflow_cnt_r != 16'hFFFF))
            overflow_cnt_r <= overflow_cnt_r + 16'd1;
    end

    assign overflow_cnt = overflow_cnt_r;

    reg [PTR_W-1:0] rd_bin;
    reg [PTR_W-1:0] rd_gray;

    wire [PTR_W-1:0] wr_gray_rsync;

    wire empty_r = (rd_gray == wr_gray_rsync);

    wire rd_fire = rd_en & ~empty_r;

    always @(posedge clk_core or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin  <= {PTR_W{1'b0}};
            rd_gray <= {PTR_W{1'b0}};
        end else if (rd_fire) begin
            rd_bin  <= rd_bin + {{(PTR_W-1){1'b0}}, 1'b1};
            rd_gray <= bin2gray(rd_bin + {{(PTR_W-1){1'b0}}, 1'b1});
        end
    end

    reg [PTR_W-1:0] rd_gray_sync1;
    reg [PTR_W-1:0] rd_gray_sync2;

    always @(posedge clk_nco or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_sync1 <= {PTR_W{1'b0}};
            rd_gray_sync2 <= {PTR_W{1'b0}};
        end else begin
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
        end
    end

    assign rd_gray_wsync = rd_gray_sync2;

    reg [PTR_W-1:0] wr_gray_sync1;
    reg [PTR_W-1:0] wr_gray_sync2;

    always @(posedge clk_core or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_sync1 <= {PTR_W{1'b0}};
            wr_gray_sync2 <= {PTR_W{1'b0}};
        end else begin
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end

    assign wr_gray_rsync = wr_gray_sync2;

    reg [31:0] rd_data_r;
    reg        rd_valid_r;

    always @(posedge clk_core or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_data_r  <= 32'd0;
            rd_valid_r <= 1'b0;
        end else begin
            rd_valid_r <= rd_fire;
            if (rd_fire)
                rd_data_r <= mem[rd_bin[ADDR_W-1:0]];
        end
    end

    assign rd_data  = rd_data_r;
    assign rd_valid = rd_valid_r;

    assign empty = empty_r;
    assign full  = full_w;

endmodule
