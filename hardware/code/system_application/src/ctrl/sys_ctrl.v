module sys_ctrl #(

    parameter integer PLL_TIMEOUT_CYCLES = 125000000 * 5,
    parameter integer DDR_TIMEOUT_CYCLES = 12500000,

    parameter REQUIRE_WEIGHT = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        pll_locked,
    input  wire        ddrphy_cpd_lock,
    input  wire        ddr_init_done,
    input  wire        hdmi_init_over,
    input  wire        hdmi_init_fail,
    input  wire        sd_idle,
    input  wire [15:0] overflow_cnt,

    input  wire        weight_ok,
    input  wire        weight_err,
    output reg         weight_start,

    output reg         st_start,
    input  wire        st_done,
    input  wire        st_fail,
    input  wire [27:0] st_fail_addr,

    input  wire [2:0]  ddr_dbg_to_state,
    input  wire        ddr_to_err,
    input  wire [3:0]  ddr_cmd_to_err,

    output reg  [2:0]  dbg_line_id,
    output reg  [31:0] dbg_line_arg,
    output reg         dbg_line_fire,
    input  wire        dbg_busy,

    output reg         sys_run,
    output wire        safe_err,
    output wire [1:0]  stage_code,

    output reg         heartbeat,
    output reg         overflow_warn,

    input  wire        key1_n
);

    reg pll_locked_m, pll_locked_s;
    reg ddrphy_lock_m, ddrphy_lock_s;
    reg ddr_init_m, ddr_init_s;
    reg hdmi_over_m, hdmi_over_s;
    reg hdmi_fail_m, hdmi_fail_s;
    reg sd_idle_m, sd_idle_s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pll_locked_m <= 1'b0;
            pll_locked_s <= 1'b0;
            ddrphy_lock_m <= 1'b0;
            ddrphy_lock_s <= 1'b0;
            ddr_init_m    <= 1'b0;
            ddr_init_s    <= 1'b0;
            hdmi_over_m   <= 1'b0;
            hdmi_over_s   <= 1'b0;
            hdmi_fail_m   <= 1'b0;
            hdmi_fail_s   <= 1'b0;
            sd_idle_m     <= 1'b1;
            sd_idle_s     <= 1'b1;
        end else begin
            pll_locked_m <= pll_locked;
            pll_locked_s <= pll_locked_m;
            ddrphy_lock_m <= ddrphy_cpd_lock;
            ddrphy_lock_s <= ddrphy_lock_m;
            ddr_init_m    <= ddr_init_done;
            ddr_init_s    <= ddr_init_m;
            hdmi_over_m   <= hdmi_init_over;
            hdmi_over_s   <= hdmi_over_m;
            hdmi_fail_m   <= hdmi_init_fail;
            hdmi_fail_s   <= hdmi_fail_m;
            sd_idle_m     <= sd_idle;
            sd_idle_s     <= sd_idle_m;
        end
    end

    reg key1_m, key1_s, key1_stable, key1_prev;
    reg [23:0] key1_cnt;

    wire key1_press = key1_prev & ~key1_stable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key1_m      <= 1'b1;
            key1_s      <= 1'b1;
            key1_stable <= 1'b1;
            key1_prev   <= 1'b1;
            key1_cnt    <= 24'd0;
        end else begin
            key1_m <= key1_n;
            key1_s <= key1_m;
            key1_prev <= key1_stable;
            if (key1_s != key1_stable) begin
                if (key1_cnt == 24'd2500000) begin
                    key1_stable <= key1_s;
                    key1_cnt    <= 24'd0;
                end else begin
                    key1_cnt <= key1_cnt + 24'd1;
                end
            end else begin
                key1_cnt <= 24'd0;
            end
        end
    end

    localparam [2:0] ST_BOOT    = 3'd0;
    localparam [2:0] ST_PLL     = 3'd1;
    localparam [2:0] ST_DDR     = 3'd2;
    localparam [2:0] ST_DDW     = 3'd3;
    localparam [2:0] ST_RUN     = 3'd4;
    localparam [2:0] ST_SAFEERR = 3'd5;
    localparam [2:0] ST_WEIGHT  = 3'd6;
    localparam [2:0] ST_DDREP   = 3'd7;

    localparam [1:0] DDR_RES_NONE = 2'd0;
    localparam [1:0] DDR_RES_PASS = 2'd1;
    localparam [1:0] DDR_RES_FAIL = 2'd2;
    localparam [1:0] DDR_RES_TIME = 2'd3;

    wire [7:0] ddr_sts_code;

    assign ddr_sts_code = {ddr_cmd_to_err,
                           ddr_to_err,
                           ddr_dbg_to_state};

    reg [2:0]  state;
    reg [31:0] timeout_cnt;
    reg        err_latch;
    reg        started;

    reg [1:0]  ddr_result;
    reg [31:0] ddr_result_arg;
    reg        ddr_result_pending;
    reg        ddr_result_sent;
    reg        ddr_sts_armed;
    reg        ddr_sts_sent;

    assign safe_err   = err_latch;
    assign stage_code = (state == ST_BOOT)              ? 2'd00 :
                        (state == ST_PLL)               ? 2'd01 :
                        (state == ST_DDR || state == ST_DDW ||
                         state == ST_DDREP ||
                         state == ST_WEIGHT)            ? 2'd10 :
                        (state == ST_RUN)               ? 2'd11 : 2'd11;

    wire pll_all = pll_locked_s & ddrphy_lock_s & ddr_init_s &
                   hdmi_over_s & ~hdmi_fail_s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_BOOT;
            timeout_cnt  <= 32'd0;
            err_latch    <= 1'b0;
            started      <= 1'b0;
            ddr_result          <= DDR_RES_NONE;
            ddr_result_arg      <= 32'd0;
            ddr_result_pending  <= 1'b0;
            ddr_result_sent     <= 1'b0;
            ddr_sts_armed       <= 1'b0;
            ddr_sts_sent        <= 1'b0;
            st_start     <= 1'b0;
            sys_run      <= 1'b0;
            dbg_line_id  <= 3'd0;
            dbg_line_arg <= 32'd0;
            dbg_line_fire <= 1'b0;
        end else begin

            st_start      <= 1'b0;
            dbg_line_fire <= 1'b0;

            case (state)
                ST_BOOT: begin

                    if (!dbg_busy) begin
                        dbg_line_id   <= 3'd0;
                        dbg_line_fire <= 1'b1;
                        state         <= ST_PLL;
                        timeout_cnt   <= 32'd0;
                    end
                end

                ST_PLL: begin

                    if (hdmi_fail_s) begin
                        dbg_line_id   <= 3'd1;
                        dbg_line_fire <= 1'b1;
                        err_latch     <= 1'b1;
                        state         <= ST_SAFEERR;
                    end else if (pll_all) begin
                        timeout_cnt <= 32'd0;
                        state       <= ST_DDR;
                    end else if (timeout_cnt >= PLL_TIMEOUT_CYCLES) begin
                        dbg_line_id   <= 3'd1;
                        dbg_line_fire <= 1'b1;
                        err_latch     <= 1'b1;
                        state         <= ST_SAFEERR;
                    end else begin
                        timeout_cnt <= timeout_cnt + 32'd1;
                    end
                end

                ST_DDR: begin

                    if (!dbg_busy) begin
                        dbg_line_id   <= 3'd2;
                        ddr_result_pending <= 1'b0;
                        ddr_result_sent    <= 1'b0;
                        ddr_sts_armed      <= 1'b0;
                        ddr_sts_sent       <= 1'b0;
                        dbg_line_fire <= 1'b1;
                        st_start      <= 1'b1;
                        timeout_cnt   <= 32'd0;
                        started       <= 1'b0;
                        state         <= ST_DDW;
                    end
                end

                ST_DDW: begin

                    if (!started) begin

                        started <= 1'b1;
                    end else if (st_done) begin
                        ddr_result         <= DDR_RES_PASS;
                        ddr_result_arg     <= 32'd0;
                        ddr_result_pending <= 1'b1;
                        state              <= ST_DDREP;
                    end else if (st_fail) begin
                        ddr_result         <= DDR_RES_FAIL;
                        ddr_result_arg     <= {4'd0, st_fail_addr};
                        ddr_result_pending <= 1'b1;
                        state              <= ST_DDREP;
                    end else if (timeout_cnt >= DDR_TIMEOUT_CYCLES) begin
                        ddr_result         <= DDR_RES_TIME;
                        ddr_result_arg     <= 32'hFFFF_FFFF;
                        ddr_result_pending <= 1'b1;
                        state              <= ST_DDREP;
                    end else begin
                        timeout_cnt <= timeout_cnt + 32'd1;
                    end
                end

                ST_DDREP: begin

                    if (ddr_result_pending) begin
                        if (!dbg_busy) begin
                            ddr_result_pending <= 1'b0;
                            ddr_result_sent    <= 1'b1;
                            ddr_sts_armed      <= 1'b0;
                            dbg_line_fire      <= 1'b1;
                            if (ddr_result == DDR_RES_PASS) begin
                                dbg_line_id  <= 3'd3;
                                dbg_line_arg <= 32'd0;
                            end else begin
                                dbg_line_id  <= 3'd4;
                                dbg_line_arg <= ddr_result_arg;
                            end
                        end
                    end else if (ddr_result_sent && !ddr_sts_sent) begin

                        if (dbg_busy) begin
                            ddr_sts_armed <= 1'b1;
                        end else if (ddr_sts_armed) begin
                            dbg_line_id   <= 3'd6;
                            dbg_line_arg  <= {24'd0, ddr_sts_code};
                            dbg_line_fire <= 1'b1;
                            ddr_sts_sent  <= 1'b1;
                        end
                    end else if (ddr_result_sent) begin
                        if (ddr_result == DDR_RES_PASS) begin
                            state   <= ST_RUN;
                            sys_run <= 1'b1;
                        end else begin
                            err_latch <= 1'b1;
                            state     <= ST_SAFEERR;
                        end
                    end
                end

                ST_WEIGHT: begin

                    weight_start <= 1'b1;
                    if (weight_ok) begin
                        weight_start <= 1'b0;
                        state        <= ST_RUN;
                        sys_run      <= 1'b1;
                    end else if (weight_err) begin
                        weight_start <= 1'b0;
                        err_latch    <= 1'b1;
                        state        <= ST_SAFEERR;
                    end
                end

                ST_RUN: begin

                    if (key1_press) begin
                        sys_run <= 1'b0;
                        state   <= ST_DDR;
                    end
                end

                ST_SAFEERR: begin

                    state <= ST_SAFEERR;
                end

                default: state <= ST_BOOT;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            overflow_warn <= 1'b0;
        end else if (overflow_cnt != 16'd0) begin
            overflow_warn <= 1'b1;
        end
    end

    reg [25:0] hb_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hb_cnt     <= 26'd0;
            heartbeat  <= 1'b0;
        end else begin
            if (hb_cnt == 26'd62499999) begin
                hb_cnt    <= 26'd0;
                heartbeat <= ~heartbeat;
            end else begin
                hb_cnt <= hb_cnt + 26'd1;
            end
        end
    end

endmodule
