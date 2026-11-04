module wbuf #(
    parameter TAP_NUM = 1728,
    parameter LANES   = 16
) (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 grp_start,
    input  wire [15:0]          tap_num,

    input  wire                 ld_valid,
    input  wire [LANES*8-1:0]   ld_data,
    output wire                 ld_ready,

    output wire                 rd_valid,
    output wire [LANES*8-1:0]   rd_data,
    input  wire                 rd_ready,

    output wire                 load_active,
    output reg                  load_done
);

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_LOAD = 2'd1;
    localparam [1:0] S_RPY  = 2'd2;

    reg [1:0]               state;
    reg [10:0]              ld_cnt;
    reg [10:0]              rd_cnt;
    reg [LANES*8-1:0]       mem [0:TAP_NUM-1];
    reg [LANES*8-1:0]       rd_data_q;
    reg                     rd_vld_q;

    wire [15:0] ld_cnt_p1 = {5'd0, ld_cnt} + 16'd1;
    wire [15:0] rd_cnt_p1 = {5'd0, rd_cnt} + 16'd1;

    always @(posedge clk) begin
        if (ld_valid && (state == S_LOAD))
            mem[ld_cnt] <= ld_data;
    end

    always @(posedge clk) begin
        rd_data_q <= mem[(rd_valid && rd_ready) ? ((rd_cnt_p1 >= tap_num) ? 11'd0 : rd_cnt_p1) : rd_cnt];
        if (!rst_n || grp_start) rd_vld_q <= 1'b0;
        else rd_vld_q <= (state == S_RPY);
    end

    assign ld_ready    = (state == S_LOAD);
    assign load_active = (state == S_LOAD);

    assign rd_valid    = rd_vld_q && (state == S_RPY) && !grp_start;
    assign rd_data     = rd_data_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            ld_cnt    <= 11'd0;
            rd_cnt    <= 11'd0;
            load_done <= 1'b0;
        end else if (grp_start && (tap_num != 16'd0)) begin
            state     <= S_LOAD;
            ld_cnt    <= 11'd0;
            rd_cnt    <= 11'd0;
            load_done <= 1'b0;
        end else begin
            load_done <= 1'b0;
            case (state)
                S_IDLE: begin
                    state  <= S_IDLE;
                    ld_cnt <= 11'd0;
                    rd_cnt <= 11'd0;
                end

                S_LOAD: begin
                    if (ld_valid) begin
                        if (ld_cnt_p1 >= tap_num) begin
                            state     <= S_RPY;
                            ld_cnt    <= 11'd0;
                            rd_cnt    <= 11'd0;
                            load_done <= 1'b1;
                        end else begin
                            ld_cnt <= ld_cnt + 11'd1;
                        end
                    end
                end

                S_RPY: begin
                    if (rd_valid && rd_ready) begin
                        if (rd_cnt_p1 >= tap_num) rd_cnt <= 11'd0;
                        else                      rd_cnt <= rd_cnt + 11'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
