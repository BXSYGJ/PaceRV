// ---------------------------------------------------------------------------
// wbuf.v -- single-group weight cache for the InstRec INT8 NPU (T-M2-02b)
//
// conv_engine consumes one 16-lane weight tap per MAC beat, so one weight
// group of tap_num taps is needed once per output pixel: W_IN replays per
// (row, group) boundary. wdma streams each group once, so without a cache
// the pixel replay would have to be re-read from DDR3 (conv4 alone:
// 27,648 B x 32 pixels per boundary). wbuf holds the deepest group
// (conv4, 9 * CIN = 1728 taps = 27,648 B) and replays it on chip.
//
// Behaviour:
//   grp_start   : re-arm and start loading a new group
//   load side   : ld_ready is high while loading; tap_num beats are written
//                 into mem[0..tap_num-1] with a synchronous write
//   replay side : after load_done, mem[0..tap_num-1] is replayed in order;
//                 rd_cnt wraps at tap_num, so one wrap == one output pixel
//   ld_ready is low while replaying, which is the group token that keeps
//   wdma from overwriting the group before the caller re-arms grp_start.
//
// rd_data is a registered synchronous read (one beat), so the array maps to
// block RAM instead of distributed LUTRAM.
// ---------------------------------------------------------------------------

module wbuf #(
    parameter TAP_NUM = 1728,   // deepest group (conv4: 9 * 192 taps)
    parameter LANES   = 16      // int8 weight lanes per tap word
) (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 grp_start,  // pulse: re-arm, load new group
    input  wire [15:0]          tap_num,    // active group length, 0 = idle

    // load side (wdma weight stream)
    input  wire                 ld_valid,
    input  wire [LANES*8-1:0]   ld_data,
    output wire                 ld_ready,

    // replay side (conv_engine / fc_engine weight stream)
    output wire                 rd_valid,
    output wire [LANES*8-1:0]   rd_data,
    input  wire                 rd_ready,

    output wire                 load_active,
    output reg                  load_done   // pulse: group fully loaded
);

    localparam [1:0] S_IDLE = 2'd0;   // waiting for grp_start
    localparam [1:0] S_LOAD = 2'd1;   // accepting tap_num taps from wdma
    localparam [1:0] S_RPY  = 2'd2;   // replaying to the MAC window

    // mem depth is TAP_NUM = 1728, so an 11-bit index covers every group
    reg [1:0]               state;
    reg [10:0]              ld_cnt;
    reg [10:0]              rd_cnt;
    reg [LANES*8-1:0]       mem [0:TAP_NUM-1];
    reg [LANES*8-1:0]       rd_data_q;
    reg                     rd_vld_q;

    wire [15:0] ld_cnt_p1 = {5'd0, ld_cnt} + 16'd1;
    wire [15:0] rd_cnt_p1 = {5'd0, rd_cnt} + 16'd1;

    // -----------------------------------------------------------------------
    // Synchronous write (load) and synchronous registered read (replay).
    // Both ports run off the same clock; the write only lands in S_LOAD and
    // the read only follows the replay pointer.
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (ld_valid && (state == S_LOAD))
            mem[ld_cnt] <= ld_data;
    end

    always @(posedge clk) begin
        rd_data_q <= mem[(state == S_RPY && rd_vld_q && rd_ready) ? ((rd_cnt_p1 >= tap_num) ? 11'd0 : rd_cnt_p1) : rd_cnt];
        rd_vld_q  <= (state == S_RPY);
    end

    assign ld_ready    = (state == S_LOAD);
    assign load_active = (state == S_LOAD);
    // grp_start masks the replay beat on its own cycle: the state register
    // only leaves S_RPY on the next edge, so an un-masked rd_valid could
    // hand one stale tap to a MAC window that is already re-arming.
    assign rd_valid    = rd_vld_q && !(grp_start && (tap_num != 16'd0));
    assign rd_data     = rd_data_q;

    // -----------------------------------------------------------------------
    // Group state machine. grp_start has priority in every state so a new
    // group can never inherit the previous group's replay pointer.
    // -----------------------------------------------------------------------
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
                    if (rd_vld_q && rd_ready) begin
                        if (rd_cnt_p1 >= tap_num) rd_cnt <= 11'd0;
                        else                      rd_cnt <= rd_cnt + 11'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule