`timescale 1ns / 1ps

module ddr3_ctrl_axi #(

    parameter AXI_USER_AP = 1'b1,

    parameter DUMMY_WSTRB_ALL1 = 1'b0,

    parameter integer AXI_TO_LIMIT = 4096,

    parameter integer P3_QUOTA_TIMEOUT = 125000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [3:0]  cmd_valid,
    input  wire [36:0] m0_cmd,
    input  wire [36:0] m1_cmd,
    input  wire [36:0] m2_cmd,
    input  wire [36:0] m3_cmd,
    input  wire [255:0] m0_wdata,
    input  wire [255:0] m1_wdata,
    input  wire [255:0] m2_wdata,
    input  wire [255:0] m3_wdata,
    output wire [3:0]  wready_beat,
    input  wire [3:0]  rd_ready,
    output wire [255:0] rd_data_0,
    output wire [255:0] rd_data_1,
    output wire [255:0] rd_data_2,
    output wire [255:0] rd_data_3,
    output wire [3:0]  rd_valid,
    output wire [3:0]  done,

    output wire [31:0] wait_cnt_0,
    output wire [31:0] wait_cnt_1,
    output wire [31:0] wait_cnt_2,
    output wire [31:0] wait_cnt_3,
    output wire [3:0]  addr_err,
    output wire        to_err,
    output wire [3:0]  cmd_to_err,
    output wire [2:0]  dbg_to_state,
    output wire [7:0]  wlast_miss_cnt,

    output wire [27:0] axi_awaddr,
    output wire        axi_awuser_ap,
    output wire [3:0]  axi_awuser_id,
    output wire [3:0]  axi_awlen,
    output wire        axi_awvalid,
    input  wire        axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0] axi_wstrb,
    input  wire        axi_wready,
    input  wire [3:0]  axi_wusero_id,
    input  wire        axi_wusero_last,
    output wire [27:0] axi_araddr,
    output wire        axi_aruser_ap,
    output wire [3:0]  axi_aruser_id,
    output wire [3:0]  axi_arlen,
    output wire        axi_arvalid,
    input  wire        axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire [3:0]  axi_rid,
    input  wire        axi_rlast,
    input  wire        axi_rvalid
);

    localparam [3:0] S_IDLE    = 4'd0;
    localparam [3:0] S_AW      = 4'd1;
    localparam [3:0] S_W       = 4'd2;
    localparam [3:0] S_WLAST   = 4'd3;
    localparam [3:0] S_DW_AW   = 4'd4;
    localparam [3:0] S_DW_W    = 4'd5;
    localparam [3:0] S_AR      = 4'd6;
    localparam [3:0] S_R       = 4'd7;
    localparam [3:0] S_R_DRAIN = 4'd8;

    reg [3:0]  state;
    reg        cur_wr;
    reg [27:0] cur_addr;
    reg [7:0]  cur_len;
    reg [1:0]  cur_master;
    reg [1:0]  cur_rd_master;
    reg [3:0]  beat_cnt;
    reg [3:0]  wlast_window;
    reg        wlast_seen;
    reg [12:0] axi_to_cnt;
    reg        to_err_r;
    reg [3:0]  cmd_to_err_r;
    reg [2:0]  dbg_to_state_r;
    reg [7:0]  wlast_miss_cnt_r;

    localparam RD_FIFO_DEPTH = 16;
    reg [255:0] rd_fifo_mem [0:RD_FIFO_DEPTH-1];
    reg [3:0]   rd_fifo_wr_ptr;
    reg [3:0]   rd_fifo_rd_ptr;
    reg [4:0]   rd_fifo_count;

    wire [3:0]  grant;
    wire        grant_wr;
    wire [27:0] grant_addr;
    wire [7:0]  grant_len;
    wire        fifo_empty = (rd_fifo_count == 5'd0);

    wire        cmd_busy = (state != S_IDLE);
    wire [3:0]  arb_valid = cmd_valid &
                            ~(cmd_busy ? (4'b0001 << cur_master) : 4'b0000);

    wire arb_en = (state == S_IDLE) && (grant_wr || fifo_empty);

    ddr3_arbiter #(
        .P3_QUOTA_TIMEOUT (P3_QUOTA_TIMEOUT)
    ) u_arbiter (
        .clk         (clk),
        .rst_n       (rst_n),
        .arb_en      (arb_en),
        .cmd_valid   (arb_valid),
        .m0_cmd      (m0_cmd),
        .m1_cmd      (m1_cmd),
        .m2_cmd      (m2_cmd),
        .m3_cmd      (m3_cmd),
        .grant       (grant),
        .grant_wr    (grant_wr),
        .grant_addr  (grant_addr),
        .grant_len   (grant_len),
        .wait_cnt_0  (wait_cnt_0),
        .wait_cnt_1  (wait_cnt_1),
        .wait_cnt_2  (wait_cnt_2),
        .wait_cnt_3  (wait_cnt_3),
        .addr_err    (addr_err)
    );

    assign axi_awvalid   = (state == S_AW) || (state == S_DW_AW);
    assign axi_awaddr    = cur_addr;
    assign axi_awuser_ap = AXI_USER_AP;
    assign axi_awuser_id = {2'b00, cur_master};
    assign axi_awlen     = (state == S_DW_AW) ? 4'd0 : cur_len[3:0];

    assign axi_wdata     = (state == S_DW_W) ? 256'd0 :
                           (cur_master == 2'd0) ? m0_wdata :
                           (cur_master == 2'd1) ? m1_wdata :
                           (cur_master == 2'd2) ? m2_wdata : m3_wdata;
    assign axi_wstrb     = (state == S_DW_W)
                           ? (DUMMY_WSTRB_ALL1 ? 32'hFFFFFFFF : 32'h00000000)
                           : 32'hFFFFFFFF;

    assign axi_arvalid   = (state == S_AR);
    assign axi_araddr    = cur_addr;
    assign axi_aruser_ap = AXI_USER_AP;
    assign axi_aruser_id = {2'b00, cur_master};
    assign axi_arlen     = cur_len[3:0];

    assign wready_beat = (state == S_W && axi_wready) ? (4'b0001 << cur_master)
                                                       : 4'b0000;

    wire rd_fifo_pop = (rd_fifo_count != 5'd0) && rd_ready[cur_rd_master];
    wire [255:0] rd_fifo_head = rd_fifo_mem[rd_fifo_rd_ptr];

    assign rd_valid = (rd_fifo_count != 5'd0) ? (4'b0001 << cur_rd_master)
                                              : 4'b0000;
    assign rd_data_0 = rd_fifo_head;
    assign rd_data_1 = rd_fifo_head;
    assign rd_data_2 = rd_fifo_head;
    assign rd_data_3 = rd_fifo_head;

    wire write_cmpl = (state == S_W) && axi_wready && (beat_cnt == cur_len[3:0]);
    wire read_cmpl  = (state == S_R) && axi_rvalid && axi_rlast;
    wire to_abort   = (axi_to_cnt >= AXI_TO_LIMIT[12:0]) &&
                      (state != S_IDLE) && (state != S_WLAST) &&
                      (state != S_R_DRAIN);
    wire done_pulse = write_cmpl || read_cmpl || to_abort;
    assign done = done_pulse ? (4'b0001 << cur_master) : 4'b0000;

    assign to_err        = to_err_r;
    assign cmd_to_err    = cmd_to_err_r;
    assign dbg_to_state  = dbg_to_state_r;
    assign wlast_miss_cnt = wlast_miss_cnt_r;

    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            cur_wr          <= 1'b0;
            cur_addr        <= 28'd0;
            cur_len         <= 8'd0;
            cur_master      <= 2'd0;
            cur_rd_master   <= 2'd0;
            beat_cnt        <= 4'd0;
            wlast_window    <= 4'd0;
            wlast_seen      <= 1'b0;
            axi_to_cnt      <= 13'd0;
            to_err_r        <= 1'b0;
            cmd_to_err_r    <= 4'b0000;
            dbg_to_state_r  <= 3'd0;
            wlast_miss_cnt_r<= 8'd0;
            rd_fifo_wr_ptr  <= 4'd0;
            rd_fifo_rd_ptr  <= 4'd0;
            rd_fifo_count   <= 5'd0;
        end else begin

            if ((state == S_R) && axi_rvalid) begin
                rd_fifo_mem[rd_fifo_wr_ptr] <= axi_rdata;
                rd_fifo_wr_ptr <= rd_fifo_wr_ptr + 4'd1;
            end
            if (rd_fifo_pop) begin
                rd_fifo_rd_ptr <= rd_fifo_rd_ptr + 4'd1;
            end
            case ({(state == S_R) && axi_rvalid, rd_fifo_pop})
                2'b10:   rd_fifo_count <= rd_fifo_count + 5'd1;
                2'b01:   rd_fifo_count <= rd_fifo_count - 5'd1;
                default: rd_fifo_count <= rd_fifo_count;
            endcase

            if (state == S_WLAST) begin
                if (axi_wusero_last) begin
                    wlast_seen <= 1'b1;
                end
                if (wlast_window == 4'd3) begin
                    if (!wlast_seen && !axi_wusero_last) begin
                        wlast_miss_cnt_r <= wlast_miss_cnt_r + 8'd1;
                    end
                    state <= S_IDLE;
                end else begin
                    wlast_window <= wlast_window + 4'd1;
                end
            end

            if ((state == S_AW) || (state == S_W) || (state == S_DW_AW) ||
                (state == S_DW_W) || (state == S_AR) ||
                ((state == S_R) && !axi_rvalid)) begin
                axi_to_cnt <= axi_to_cnt + 13'd1;
            end else begin
                axi_to_cnt <= 13'd0;
            end

            case (state)
                S_IDLE: begin
                    if (grant != 4'b0000) begin

                        cur_wr     <= grant_wr;
                        cur_addr   <= grant_addr;
                        cur_len    <= grant_len;
                        for (k = 0; k < 4; k = k + 1) begin
                            if (grant[k]) begin
                                cur_master <= k[1:0];
                            end
                        end
                        if (!grant_wr) begin

                            if (grant[0]) cur_rd_master <= 2'd0;
                            if (grant[1]) cur_rd_master <= 2'd1;
                            if (grant[2]) cur_rd_master <= 2'd2;
                            if (grant[3]) cur_rd_master <= 2'd3;
                        end
                        beat_cnt   <= 4'd0;
                        axi_to_cnt <= 13'd0;
                        wlast_seen <= 1'b0;
                        wlast_window <= 4'd0;
                        if (grant_wr) begin
                            state <= S_AW;
                        end else begin
                            state <= S_DW_AW;
                        end
                    end
                end

                S_AW: begin
                    if (axi_awready) begin
                        axi_to_cnt <= 13'd0;
                        state <= S_W;
                    end else if (axi_to_cnt >= AXI_TO_LIMIT[12:0]) begin
                        to_err_r       <= 1'b1;
                        cmd_to_err_r[cur_master] <= 1'b1;
                        dbg_to_state_r <= S_AW;
                        state          <= S_IDLE;
                    end
                end

                S_W: begin
                    if (axi_wready) begin
                        axi_to_cnt <= 13'd0;
                        beat_cnt   <= beat_cnt + 4'd1;
                        if (beat_cnt == cur_len[3:0]) begin

                            wlast_window <= 4'd0;
                            wlast_seen   <= 1'b0;
                            state        <= S_WLAST;
                        end
                    end else if (axi_to_cnt >= AXI_TO_LIMIT[12:0]) begin
                        to_err_r       <= 1'b1;
                        cmd_to_err_r[cur_master] <= 1'b1;
                        dbg_to_state_r <= S_W;
                        state          <= S_IDLE;
                    end
                end

                S_DW_AW: begin
                    if (axi_awready) begin
                        axi_to_cnt <= 13'd0;
                        state <= S_DW_W;
                    end else if (axi_to_cnt >= AXI_TO_LIMIT[12:0]) begin
                        to_err_r       <= 1'b1;
                        cmd_to_err_r[cur_master] <= 1'b1;
                        dbg_to_state_r <= S_DW_AW;
                        state          <= S_IDLE;
                    end
                end

                S_DW_W: begin
                    if (axi_wready) begin

                        axi_to_cnt <= 13'd0;
                        state <= S_AR;
                    end else if (axi_to_cnt >= AXI_TO_LIMIT[12:0]) begin
                        to_err_r       <= 1'b1;
                        cmd_to_err_r[cur_master] <= 1'b1;
                        dbg_to_state_r <= S_DW_W;
                        state          <= S_IDLE;
                    end
                end

                S_AR: begin
                    if (axi_arready) begin
                        axi_to_cnt <= 13'd0;
                        state <= S_R;
                    end else if (axi_to_cnt >= AXI_TO_LIMIT[12:0]) begin
                        to_err_r       <= 1'b1;
                        cmd_to_err_r[cur_master] <= 1'b1;
                        dbg_to_state_r <= S_AR;
                        state          <= S_IDLE;
                    end
                end

                S_R: begin
                    if (axi_rvalid) begin
                        axi_to_cnt <= 13'd0;
                        if (axi_rlast) begin

                            state <= S_IDLE;
                        end
                    end else if (axi_to_cnt >= AXI_TO_LIMIT[12:0]) begin
                        to_err_r       <= 1'b1;
                        cmd_to_err_r[cur_master] <= 1'b1;
                        dbg_to_state_r <= S_R;

                        state          <= S_R_DRAIN;
                    end
                end

                S_R_DRAIN: begin

                    if (axi_rvalid && axi_rlast) begin
                        state <= S_IDLE;
                    end
                end

                S_WLAST: begin

                    if (wlast_window == 4'd3) begin
                        state <= S_IDLE;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
