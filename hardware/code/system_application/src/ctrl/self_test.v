module self_test #(

    parameter [31:0] DDR_PATTERN  = 32'h5A5A_00FF,

    parameter [27:0] SELFTEST_BASE = 28'h0030_0000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        st_start,

    output reg         cmd_valid,
    output reg  [36:0] cmd,
    output wire [255:0] wdata,

    input  wire        wready_beat,
    output reg         rd_ready,
    input  wire [255:0] rd_data,
    input  wire        rd_valid,
    input  wire        done,

    output reg         st_done,
    output reg         st_fail,
    output reg  [27:0] st_fail_addr
);

    function [31:0] pat_word;
        input [9:0] w_idx;
        begin
            pat_word = DDR_PATTERN ^ {22'd0, w_idx};
        end
    endfunction

    localparam [3:0] BURST_LEN = 4'd15;

    reg [2:0]  cmd_idx;
    reg [3:0]  beat_idx;
    reg [6:0]  wrd_idx;
    reg [9:0]  exp_idx;

    wire [27:0] cmd_addr = SELFTEST_BASE + ({25'd0, cmd_idx} << 9);

    wire [255:0] exp_beat = {pat_word(exp_idx + 10'd7),
                              pat_word(exp_idx + 10'd6),
                              pat_word(exp_idx + 10'd5),
                              pat_word(exp_idx + 10'd4),
                              pat_word(exp_idx + 10'd3),
                              pat_word(exp_idx + 10'd2),
                              pat_word(exp_idx + 10'd1),
                              pat_word(exp_idx + 10'd0)};

    wire [9:0] wr_base = {cmd_idx, wrd_idx};

    assign wdata = {pat_word(wr_base + 10'd7),
                      pat_word(wr_base + 10'd6),
                      pat_word(wr_base + 10'd5),
                      pat_word(wr_base + 10'd4),
                      pat_word(wr_base + 10'd3),
                      pat_word(wr_base + 10'd2),
                      pat_word(wr_base + 10'd1),
                      pat_word(wr_base + 10'd0)};

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_WCMD = 3'd1;
    localparam [2:0] ST_WDATA = 3'd2;
    localparam [2:0] ST_RCMD = 3'd3;
    localparam [2:0] ST_RDATA = 3'd4;
    localparam [2:0] ST_END  = 3'd5;

    reg [2:0] state;
    reg       done_q;
    reg       done_qq;
    reg       rd_valid_q;
    reg [255:0] rd_data_q;

    always @(posedge clk) begin
        rd_data_q <= rd_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            cmd_valid    <= 1'b0;
            cmd          <= 37'd0;
            rd_ready     <= 1'b1;
            cmd_idx      <= 3'd0;
            beat_idx     <= 4'd0;
            wrd_idx      <= 7'd0;
            exp_idx      <= 10'd0;
            done_q       <= 1'b0;
            done_qq      <= 1'b0;
            rd_valid_q   <= 1'b0;
            st_done      <= 1'b0;
            st_fail      <= 1'b0;
            st_fail_addr <= 28'd0;
        end else begin

            done_q <= done && state == ST_RDATA;
            done_qq <= done_q;
            rd_valid_q <= rd_valid;

            case (state)
                ST_IDLE: begin
                    if (st_start) begin
                        cmd_idx      <= 3'd0;
                        beat_idx     <= 4'd0;
                        wrd_idx      <= 7'd0;
                        exp_idx      <= 10'd0;
                        st_done      <= 1'b0;
                        st_fail      <= 1'b0;
                        st_fail_addr <= 28'd0;
                        state        <= ST_WCMD;
                    end
                end

                ST_WCMD: begin

                    cmd       <= {1'b1, cmd_addr, 8'd15};
                    cmd_valid <= 1'b1;
                    beat_idx  <= 4'd0;
                    wrd_idx   <= 7'd0;
                    state     <= ST_WDATA;
                end

                ST_WDATA: begin

                    if (wready_beat) begin
                        if (beat_idx == 4'd15) begin
                            if (cmd_idx == 3'd7) begin
                                cmd_idx <= 3'd0;
                                state   <= ST_RCMD;
                            end else begin
                                cmd_idx <= cmd_idx + 3'd1;
                                state   <= ST_WCMD;
                            end
                        end else begin
                            beat_idx <= beat_idx + 4'd1;
                            wrd_idx  <= wrd_idx + 7'd8;
                        end
                    end else if (done) begin

                        st_done      <= 1'b0;
                        st_fail      <= 1'b1;
                        st_fail_addr <= cmd_addr;
                        state        <= ST_END;
                    end
                end

                ST_RCMD: begin

                    cmd       <= {1'b0, cmd_addr, 8'd15};
                    cmd_valid <= 1'b1;
                    exp_idx   <= {cmd_idx, 7'd0};
                    state     <= ST_RDATA;
                end

                ST_RDATA: begin

                    if (rd_valid_q) begin
                        if (rd_data_q != exp_beat) begin

                            st_done      <= 1'b0;
                            st_fail      <= 1'b1;
                            st_fail_addr <= cmd_addr;
                            state        <= ST_END;
                        end else if (exp_idx[6:0] == 7'd120) begin

                            if (cmd_idx == 3'd7) begin
                                st_fail <= 1'b0;
                                st_done <= 1'b1;
                                state   <= ST_END;
                            end else begin
                                cmd_idx <= cmd_idx + 3'd1;
                                state   <= ST_RCMD;
                            end
                        end else begin
                            exp_idx <= exp_idx + 10'd8;
                        end
                    end else if (done_qq) begin

                        st_done      <= 1'b0;
                        st_fail      <= 1'b1;
                        st_fail_addr <= cmd_addr;
                        state        <= ST_END;
                    end
                end

                ST_END: begin

                    if (st_start) begin
                        cmd_idx      <= 3'd0;
                        beat_idx     <= 4'd0;
                        wrd_idx      <= 7'd0;
                        exp_idx      <= 10'd0;
                        st_done      <= 1'b0;
                        st_fail      <= 1'b0;
                        st_fail_addr <= 28'd0;
                        state        <= ST_WCMD;
                    end
                end

                default: state <= ST_IDLE;
            endcase

            if (done) begin
                cmd_valid <= 1'b0;
            end
        end
    end

endmodule
