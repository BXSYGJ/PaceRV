// ---------------------------------------------------------------------------
// npu_top.v -- InstRec INT8 NPU top level (T-M2-06 integration skeleton)
//
// Chain: conv1 -> pool1 -> conv2 -> pool2 -> conv3 -> pool3 -> conv4 ->
//        pool4 -> gap -> fc1 -> fc2 -> softmax.
//
// Fully wired here: activation stream between stages, layer sequencer,
// GAP result capture, FC input replay, fc2 -> softmax logits bus.
//
// Deliberately left as tie-offs (single remaining producer):
//   * the 48-beat group contract (16 bias / 16 M / 16 shift) for
//     conv_engine, and the per-channel M/shift contract for fc_engine;
//   * wdma currently streams weight taps only, so all contract inputs are
//     tied to zero. The sequencer/topology is final; only the contract
//     loader remains.
//
// Budget: 200 ms at 125 MHz = 25,000,000 cycles; timeout_flag latches at
// 2x that (REQ-REL-002).
// ---------------------------------------------------------------------------

module npu_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         busy,
    output reg         done,
    output reg  [31:0] npu_cycles,
    output reg         timeout_flag,

    // Mel feature read port: address now, data next cycle (mel_engine's
    // bank is a 1-cycle synchronous read).
    output wire [14:0] feat_rd_addr,
    input  wire [7:0]  feat_rd_data,
    output wire        feat_rd_en,

    output wire        rd_cmd_valid,
    output wire [36:0] rd_cmd,
    input  wire        rd_ready,
    input  wire [255:0] rd_data,
    input  wire        rd_valid,
    input  wire        rd_done,

    output wire act_cmd_valid, act_cmd_write,
    output wire [31:0] act_cmd_addr,
    input wire act_cmd_ready,
    output wire act_wr_valid,
    output wire [255:0] act_wr_data,
    input wire act_wr_ready,
    input wire act_rd_valid,
    input wire [255:0] act_rd_data,
    output wire        probs_valid,
    output wire [7:0]  probs_pct,
    output wire [3:0]  probs_idx,
    output wire [3:0]  top1
);

    localparam [31:0] TIMEOUT_CYCLES = 32'd50_000_000;

    localparam [3:0] L_CONV1 = 4'd0;
    localparam [3:0] L_POOL1 = 4'd1;
    localparam [3:0] L_CONV2 = 4'd2;
    localparam [3:0] L_POOL2 = 4'd3;
    localparam [3:0] L_CONV3 = 4'd4;
    localparam [3:0] L_POOL3 = 4'd5;
    localparam [3:0] L_CONV4 = 4'd6;
    localparam [3:0] L_POOL4 = 4'd7;
    localparam [3:0] L_GAP   = 4'd8;
    localparam [3:0] L_FC1   = 4'd9;
    localparam [3:0] L_FC2   = 4'd10;
    localparam [3:0] L_SM    = 4'd11;

    reg [3:0] layer;
    reg [1:0] settle;
    reg       layer_pulse;

    wire conv1_start = (layer == L_CONV1) && layer_pulse;
    wire pool1_start = (layer == L_POOL1) && layer_pulse;
    wire conv2_start = (layer == L_CONV2) && layer_pulse;
    wire pool2_start = (layer == L_POOL2) && layer_pulse;
    wire conv3_start = (layer == L_CONV3) && layer_pulse;
    wire pool3_start = (layer == L_POOL3) && layer_pulse;
    wire conv4_start = (layer == L_CONV4) && layer_pulse;
    wire pool4_start = (layer == L_POOL4) && layer_pulse;
    wire gap_start   = (layer == L_GAP)   && layer_pulse;
    wire fc1_start   = (layer == L_FC1)   && layer_pulse;
    wire fc2_start   = (layer == L_FC2)   && layer_pulse;

    wire conv1_done, pool1_done, conv2_done, pool2_done;
    wire conv3_done, pool3_done, conv4_done, pool4_done;
    wire gap_done, fc1_done, fc2_done, sm_done;

    wire       c1_v; wire [7:0] c1_d;
    wire       p1_v; wire [7:0] p1_d;
    wire       c2_v; wire [7:0] c2_d;
    wire       p2_v; wire [7:0] p2_d;
    wire       c3_v; wire [7:0] c3_d;
    wire       p3_v; wire [7:0] p3_d;
    wire       c4_v; wire [7:0] c4_d;
    wire       p4_v; wire [7:0] p4_d;

    wire        w_valid;
    wire [127:0] w_data;
    wire        grp_start;
    wire        wdma_done;
    wire        wl_b_valid, wl_m_valid, wl_s_valid;
    wire signed [31:0] wl_bias, wl_m;
    wire [6:0]  wl_shift;

    // Only the conv instance owning the current layer may consume the
    // 48-beat contract; all four share the same data bus.
    wire cb1 = wl_b_valid && (layer == L_CONV1);
    wire cm1 = wl_m_valid && (layer == L_CONV1);
    wire cs1 = wl_s_valid && (layer == L_CONV1);
    wire cb2 = wl_b_valid && (layer == L_CONV2);
    wire cm2 = wl_m_valid && (layer == L_CONV2);
    wire cs2 = wl_s_valid && (layer == L_CONV2);
    wire cb3 = wl_b_valid && (layer == L_CONV3);
    wire cm3 = wl_m_valid && (layer == L_CONV3);
    wire cs3 = wl_s_valid && (layer == L_CONV3);
    wire cb4 = wl_b_valid && (layer == L_CONV4);
    wire cm4 = wl_m_valid && (layer == L_CONV4);
    wire cs4 = wl_s_valid && (layer == L_CONV4);
    wire fb1 = wl_b_valid && (layer == L_FC1);
    wire fm1 = wl_m_valid && (layer == L_FC1);
    wire fs1 = wl_s_valid && (layer == L_FC1);
    wire fb2 = wl_b_valid && (layer == L_FC2);
    wire fm2 = wl_m_valid && (layer == L_FC2);
    wire fs2 = wl_s_valid && (layer == L_FC2);
    wire        wdma_busy;
    wire        conv_grp_adv = (layer == L_CONV1) ? conv_grpadv[0] :
                               (layer == L_CONV2) ? conv_grpadv[1] :
                               (layer == L_CONV3) ? conv_grpadv[2] :
                               (layer == L_CONV4) ? conv_grpadv[3] : 1'b0;
    wire [3:0]  conv_wready;
    wire [1:0]  fc_wready;
    wire [1:0] fc_grp_advance;
    wire [3:0]  conv_grpadv;
    wire [15:0] gap_unused_rdata;

    // Tap-stream back-pressure: the engine that owns the current layer is
    // the only one whose MAC window may consume w_data. Conv/fc engines all
    // publish w_ready = (their own MAC window), and exactly one of them runs
    // per layer, so the layer select below picks the live one. FC layers
    // reuse conv_wready[0]/[1] (fc1/fc2 drive those two bits); the remaining
    // layers never stream weights (wdma_start only arms the six weight layers).
    wire conv_wready_mux = (layer == L_CONV1) ? conv_wready[0] :
                           (layer == L_CONV2) ? conv_wready[1] :
                           (layer == L_CONV3) ? conv_wready[2] :
                           (layer == L_CONV4) ? conv_wready[3] :
                           (layer == L_FC1)   ? fc_wready[0] :
                           (layer == L_FC2)   ? fc_wready[1] : 1'b0;

    // -----------------------------------------------------------------------
    // Weight group cache (wbuf). wdma streams each (row, group) weight group
    // once; conv_engine needs the same group once per output pixel, so wbuf
    // holds the group on chip and replays it. tap_num tracks the layer's
    // tap count (9 / 432 / 864 / 1728 / 256 / 128); the memory depth is
    // fixed at the deepest group (1728 taps).
    // -----------------------------------------------------------------------
    wire [15:0] wbuf_tap_num = (layer == L_CONV1) ? 16'd9    :
                               (layer == L_CONV2) ? 16'd432  :
                               (layer == L_CONV3) ? 16'd864  :
                               (layer == L_CONV4) ? 16'd1728 :
                               (layer == L_FC1)   ? 16'd256  :
                               (layer == L_FC2)   ? 16'd128  : 16'd0;

    wire stream_layer = (layer == L_CONV1) || (layer == L_CONV2) ||
                        (layer == L_CONV3) || (layer == L_CONV4) ||
                        (layer == L_FC1)   || (layer == L_FC2);

    // Conv layers own one weight group per (row, group) boundary, so wbuf
    // reloads on the conv group-boundary pulse (grp_advance). fc_engine keeps
    // a 1:1 group rhythm with wdma, so its reload follows wdma's grp_start.
    // The layer-start pulse seeds group 0 for both cases.
    wire wbuf_grp_start = (layer_pulse && stream_layer) ? 1'b1 :
                          (layer == L_FC1) ? fc_grp_advance[0] :
                          (layer == L_FC2) ? fc_grp_advance[1] :
                          conv_grp_adv;

    wire         wbuf_ld_ready;
    wire         wbuf_rd_valid;
    wire [127:0] wbuf_rd_data;
    wire         wbuf_load_done;
    wire         wbuf_load_active;

    // Only wbuf can back-pressure wdma. Non-stream layers (pool/gap/softmax)
    // release the DMA so its group walk always reaches S_DONE instead of
    // stalling on a cache that is not loading.
    wire wdma_w_ready = stream_layer ? wbuf_ld_ready : 1'b1;

    // wdma numbers its layer geometries 0..5 (conv1..conv4, fc1, fc2), which
    // is NOT the sequencer's layer encoding (0/2/4/6/9/10). Map before the
    // instantiation so the tap count of one group matches wbuf_tap_num.
    wire [3:0] wdma_layer_id = (layer == L_CONV1) ? 4'd0 :
                               (layer == L_CONV2) ? 4'd1 :
                               (layer == L_CONV3) ? 4'd2 :
                               (layer == L_CONV4) ? 4'd3 :
                               (layer == L_FC1)   ? 4'd4 :
                               (layer == L_FC2)   ? 4'd5 : 4'd0;

    // Only the six weight layers arm the DMA; pool/gap/softmax must not,
    // otherwise the group walk starts from a geometry that has no consumer.
    wire wdma_start = layer_pulse && ((layer == L_CONV1) ||
                                      (layer == L_CONV2) ||
                                      (layer == L_CONV3) ||
                                      (layer == L_CONV4) ||
                                      (layer == L_FC1)   ||
                                      (layer == L_FC2));

    wdma u_wdma (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (wdma_start),
        .layer_id     (wdma_layer_id),
        .rd_cmd_valid (rd_cmd_valid),
        .rd_cmd       (rd_cmd),
        .rd_ready     (rd_ready),
        .rd_data      (rd_data),
        .rd_valid     (rd_valid),
        .rd_done      (rd_done),
        .w_valid      (w_valid),
        .w_data       (w_data),
        .w_ready      (wdma_w_ready),
        .grp_advance  (conv_grp_adv),
        .grp_start    (grp_start),
        .b_valid      (wl_b_valid), .bias_s32 (wl_bias),
        .m_valid      (wl_m_valid), .m_s32    (wl_m),
        .s_valid      (wl_s_valid), .shift    (wl_shift),
        .busy         (wdma_busy),
        .done         (wdma_done)
    );

    // Shared weight group cache: exactly one conv/fc engine streams weights
    // per layer, so a single cache serves all six weight consumers. The
    // replay side is flow-controlled by the active engine's w_ready.
    wbuf u_wbuf (
        .clk         (clk),
        .rst_n       (rst_n),
        .grp_start   (wbuf_grp_start),
        .tap_num     (wbuf_tap_num),
        .ld_valid    (w_valid),
        .ld_data     (w_data),
        .ld_ready    (wbuf_ld_ready),
        .rd_valid    (wbuf_rd_valid),
        .rd_data     (wbuf_rd_data),
        .rd_ready    (conv_wready_mux),
        .load_active (wbuf_load_active),
        .load_done   (wbuf_load_done)
    );

    // Feature replay: 64x258 uint8 stream read from mel_engine.
    reg [14:0] feat_addr;
    reg        feat_run, feat_dv;
    reg [6:0] feat_row;
    reg [8:0] feat_col;
    wire [15:0] conv1_ingress_max_row;
    wire feat_safe = {9'd0, feat_row} <= conv1_ingress_max_row;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feat_addr <= 15'd0;
            feat_row <= 7'd0;
            feat_col <= 9'd0;
            feat_run  <= 1'b0;
            feat_dv   <= 1'b0;
        end else if (conv1_start) begin
            feat_addr <= 15'd0;
            feat_row <= 7'd0;
            feat_col <= 9'd0;
            feat_run  <= 1'b1;
            feat_dv   <= 1'b0;
        end else if (feat_run && feat_safe) begin
            feat_dv <= 1'b1;
            if (feat_col == 9'd257) begin
                feat_col <= 9'd0;
                feat_row <= feat_row + 7'd1;
            end else feat_col <= feat_col + 9'd1;
            if (feat_addr == 15'd16511) feat_run <= 1'b0;
            else                        feat_addr <= feat_addr + 15'd1;
        end else begin
            feat_dv <= 1'b0;
        end
    end
    assign feat_rd_addr = feat_addr;
    assign feat_rd_en   = feat_run && feat_safe;

    // -----------------------------------------------------------------------
    // Single shared conv core: conv1..conv4 all time-share one 16-lane
    // MAC/requant core. The sequencer is serial, so no two layers ever scan
    // at the same time; every layer still owns its own line buffer and
    // ingress counters, because the pool egress of layer i overlaps the scan
    // of layer i and feeds conv i+1 (see the conv_engine.v header). Only the
    // compute core is time-shared, never the row buffers.
    // conv_sel picks the layer's compile-time shape set and its own
    // three-bank row-buffer group; the core latches it at the layer start.
    // The layer-dependent zero point rides the shared cfg port: conv1 is
    // the only layer with a non-zero zp_in, latched at layer_start.
    // -----------------------------------------------------------------------
    wire       core_y_valid;
    wire [7:0] core_y_u8;
    wire       core_w_ready;
    wire [7:0] conv_zp_in = (layer == L_CONV1) ? 8'd49 : 8'd0;
    wire [1:0] conv_sel = (layer == L_CONV1) ? 2'd0 :
                          (layer == L_CONV2) ? 2'd1 :
                          (layer == L_CONV3) ? 2'd2 : 2'd3;

    conv_engine #(
        .CIN0(1),   .COUT0(48),  .H0(64), .W0(258),
        .CIN1(48),  .COUT1(96),  .H1(32), .W1(129),
        .CIN2(96),  .COUT2(192), .H2(16), .W2(64),
        .CIN3(192), .COUT3(256), .H3(8),  .W3(32)
    ) u_conv (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(1'b1), .cfg_zp_in(conv_zp_in), .cfg_zp_out(8'd0),
        .conv_sel(conv_sel),
        .start0(conv1_start), .start1(conv2_start),
        .start2(conv3_start), .start3(conv4_start),
        .done0(conv1_done), .done1(conv2_done),
        .done2(conv3_done), .done3(conv4_done),
        .x0_ingress_max_row(conv1_ingress_max_row),
        .x0_valid(feat_dv), .x0_u8(feat_rd_data),
        .x1_valid(s0_out_valid && layer==L_CONV2), .x1_u8(s0_out_data),
        .x2_valid(s1_out_valid), .x2_u8(s1_out_data),
        .x3_valid(s0_out_valid && layer==L_CONV4), .x3_u8(s0_out_data),
        .grp_start(grp_start),
        .bias_valid(cb1 | cb2 | cb3 | cb4), .bias_s32(wl_bias),
        .mult_valid(cm1 | cm2 | cm3 | cm4), .m_s32(wl_m),
        .shft_valid(cs1 | cs2 | cs3 | cs4), .shift(wl_shift),
        .w_valid(wbuf_rd_valid), .w_data(wbuf_rd_data), .w_ready(core_w_ready),
        .y_valid(core_y_valid), .y_u8(core_y_u8), .y_ready(pool_y_ready),
        .adv0(conv_grpadv[0]), .adv1(conv_grpadv[1]),
        .adv2(conv_grpadv[2]), .adv3(conv_grpadv[3])
    );

    wire s0_row_done,s1_row_done;
    wire s0_in_ready,s1_in_ready,s0_out_valid,s1_out_valid;
    wire [7:0] s0_out_data,s1_out_data;
    wire [15:0] s0_replay_row,s1_replay_row;
    wire s0_store_done,s1_store_done,s0_error,s1_error,mux_error;
    reg s0_write_complete,s1_write_complete;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin s0_write_complete<=0;s1_write_complete<=0;end
        else begin
            if(conv1_start || conv3_start) s0_write_complete<=0;
            else if(s0_store_done && (pool_sel1 || pool_sel3)) s0_write_complete<=1;
            if(conv2_start) s1_write_complete<=0;
            else if(s1_store_done && pool_sel2) s1_write_complete<=1;
        end
    end
    wire s0_cmd_valid,s0_cmd_write,s0_cmd_ready,s0_wr_valid,s0_wr_ready,s0_rd_valid;
    wire [31:0] s0_cmd_addr;
    wire [255:0] s0_wr_data,s0_rd_data;
    wire s1_cmd_valid,s1_cmd_write,s1_cmd_ready,s1_wr_valid,s1_wr_ready,s1_rd_valid;
    wire [31:0] s1_cmd_addr;
    wire [255:0] s1_wr_data,s1_rd_data;
    activation_row_store_dynamic u_store0 (
        .cfg_layer((pool_sel3 || pool_sel4) ? 2'd2 : 2'd0), .cfg_base(32'h00400000), .replay_row(s0_replay_row),
        .clk(clk),.rst_n(rst_n),.start(conv1_start | conv2_start | conv3_start | conv4_start),
        .read_mode((layer==L_CONV2 || layer==L_CONV4)),.row_credit(s0_replay_row<=conv1_ingress_max_row),
        .in_valid(p1_v | p3_v),.in_data(pool_p_u8),.in_ready(s0_in_ready),
        .cmd_valid(s0_cmd_valid),.cmd_write(s0_cmd_write),.cmd_addr(s0_cmd_addr),.cmd_ready(s0_cmd_ready),
        .wr_valid(s0_wr_valid),.wr_data(s0_wr_data),.wr_ready(s0_wr_ready),
        .rd_valid(s0_rd_valid),.rd_data(s0_rd_data),
        .out_valid(s0_out_valid),.out_data(s0_out_data),.out_ready(1'b1),
        .row_done(s0_row_done),.done(s0_store_done),.protocol_error(s0_error)
    );
    activation_row_store_dynamic u_store1 (
        .cfg_layer(2'd1), .cfg_base(32'h00440000), .replay_row(s1_replay_row),
        .clk(clk),.rst_n(rst_n),.start(conv2_start | conv3_start),
        .read_mode((layer==L_CONV3)),.row_credit(s1_replay_row<=conv1_ingress_max_row),
        .in_valid(p2_v),.in_data(pool_p_u8),.in_ready(s1_in_ready),
        .cmd_valid(s1_cmd_valid),.cmd_write(s1_cmd_write),.cmd_addr(s1_cmd_addr),.cmd_ready(s1_cmd_ready),
        .wr_valid(s1_wr_valid),.wr_data(s1_wr_data),.wr_ready(s1_wr_ready),
        .rd_valid(s1_rd_valid),.rd_data(s1_rd_data),
        .out_valid(s1_out_valid),.out_data(s1_out_data),.out_ready(1'b1),
        .row_done(s1_row_done),.done(s1_store_done),.protocol_error(s1_error)
    );
    activation_store_mux u_act_mux (.clk(clk),.rst_n(rst_n),.protocol_error(mux_error),
        .s0_cmd_valid(s0_cmd_valid),
        .s0_cmd_write(s0_cmd_write),
        .s0_cmd_addr(s0_cmd_addr),
        .s0_cmd_ready(s0_cmd_ready),
        .s0_wr_valid(s0_wr_valid),
        .s0_wr_data(s0_wr_data),
        .s0_wr_ready(s0_wr_ready),
        .s0_rd_valid(s0_rd_valid),
        .s0_rd_data(s0_rd_data),
        .s1_cmd_valid(s1_cmd_valid),
        .s1_cmd_write(s1_cmd_write),
        .s1_cmd_addr(s1_cmd_addr),
        .s1_cmd_ready(s1_cmd_ready),
        .s1_wr_valid(s1_wr_valid),
        .s1_wr_data(s1_wr_data),
        .s1_wr_ready(s1_wr_ready),
        .s1_rd_valid(s1_rd_valid),
        .s1_rd_data(s1_rd_data),
        .act_cmd_valid(act_cmd_valid),
        .act_cmd_write(act_cmd_write),
        .act_cmd_addr(act_cmd_addr),
        .act_cmd_ready(act_cmd_ready),
        .act_wr_valid(act_wr_valid),
        .act_wr_data(act_wr_data),
        .act_wr_ready(act_wr_ready),
        .act_rd_valid(act_rd_valid),
        .act_rd_data(act_rd_data)
    );
    // Every conv layer shares the one core's tap window (w_ready is the
    // MAC issue window of the layer currently scanning, and only one layer
    // scans at a time).
    assign conv_wready[0] = core_w_ready;
    assign conv_wready[1] = core_w_ready;
    assign conv_wready[2] = core_w_ready;
    assign conv_wready[3] = core_w_ready;

    // -----------------------------------------------------------------------
    // Single shared pool_engine. The sequencer runs exactly one layer at a
    // time, so the four pooling stages can share one instance instead of
    // keeping four sets of line banks. The select window spans the producing
    // conv layer and the following pool layer: the pool consumes the conv
    // egress stream while that conv layer is still active and finishes its
    // two-beat drain inside the pool layer.
    // -----------------------------------------------------------------------
    wire pool_sel1 = (layer == L_CONV1) || (layer == L_POOL1);
    wire pool_sel2 = (layer == L_CONV2) || (layer == L_POOL2);
    wire pool_sel3 = (layer == L_CONV3) || (layer == L_POOL3);
    wire pool_sel4 = (layer == L_CONV4) || (layer == L_POOL4);

    reg [15:0] pool_cin;
    reg [15:0] pool_win;
    reg [15:0] pool_hin;

    // Geometry of the pooling stage that owns the select window (same shape
    // as the conv layer feeding it). The shared bank capacity in pool_engine
    // covers the deepest stage: conv1's 48 * 129 = 6192 bytes.
    always @* begin
        if (pool_sel1) begin
            pool_cin = 16'd48;
            pool_win = 16'd258;
            pool_hin = 16'd64;
        end else if (pool_sel2) begin
            pool_cin = 16'd96;
            pool_win = 16'd129;
            pool_hin = 16'd32;
        end else if (pool_sel3) begin
            pool_cin = 16'd192;
            pool_win = 16'd64;
            pool_hin = 16'd16;
        end else begin
            pool_cin = 16'd256;
            pool_win = 16'd32;
            pool_hin = 16'd8;
        end
    end

    wire       pool_y_valid = (pool_sel1 && c1_v) || (pool_sel2 && c2_v) ||
                              (pool_sel3 && c3_v) || (pool_sel4 && c4_v);
    wire [7:0] pool_y_u8    = pool_sel1 ? c1_d : pool_sel2 ? c2_d :
                              pool_sel3 ? c3_d : c4_d;
    wire       pool_start = conv1_start | conv2_start | conv3_start | conv4_start;
    wire pool_y_ready;

    wire       pool_p_valid;
    wire [7:0] pool_p_u8;
    wire       pool_p_last;

    pool_engine u_pool (
        .clk(clk), .rst_n(rst_n), .layer_start(pool_start),
        .cin(pool_cin), .w_in(pool_win), .h_in(pool_hin),
        .y_valid(pool_y_valid), .y_u8(pool_y_u8), .y_ready(pool_y_ready),
        .p_ready((pool_sel1 || pool_sel3) ? s0_in_ready : pool_sel2 ? s1_in_ready : 1'b1),
        .p_valid(pool_p_valid), .p_u8(pool_p_u8), .p_last(pool_p_last)
    );

    // Route the shared pool output back to the stage that owns the current
    // window. The four select windows are mutually exclusive, so each
    // consumer sees exactly the stream its own pool stage used to produce.
    assign p1_v       = pool_p_valid && pool_sel1;
    assign p1_d       = pool_p_u8;
    assign pool1_done = s0_write_complete;
    assign p2_v       = pool_p_valid && pool_sel2;
    assign p2_d       = pool_p_u8;
    assign pool2_done = s1_write_complete;
    assign p3_v       = pool_p_valid && pool_sel3;
    assign p3_d       = pool_p_u8;
    assign pool3_done = s0_write_complete;
    assign p4_v       = pool_p_valid && pool_sel4;
    assign p4_d       = pool_p_u8;
    assign pool4_done = pool_complete[3];

    // The single shared core emits its egress while the owning layer's
    // select window is open, so c1..c4 all alias the one core stream. The
    // pool select gates below keep each stage on its own layer window.
    assign c1_v = core_y_valid;
    assign c1_d = core_y_u8;
    assign c2_v = core_y_valid;
    assign c2_d = core_y_u8;
    assign c3_v = core_y_valid;
    assign c3_d = core_y_u8;
    assign c4_v = core_y_valid;
    assign c4_d = core_y_u8;

    wire [3:0] pool_complete,pool_arm_unused;
    wire gap_complete,gap_arm_unused;
    wire pool_accept_last=pool_p_valid && pool_p_last && ((pool_sel1 || pool_sel3) ? s0_in_ready : pool_sel2 ? s1_in_ready : 1'b1);
    npu_stage_lifecycle u_lifecycle(.clk(clk),.rst_n(rst_n),.inference_start(start && !busy),
        .conv_start({conv4_start,conv3_start,conv2_start,conv1_start}),
        .pool_last_accepted({pool_accept_last && pool_sel4,pool_accept_last && pool_sel3,pool_accept_last && pool_sel2,pool_accept_last && pool_sel1}),
        .gap_done(gap_done),.pool_arm(pool_arm_unused),.gap_arm(gap_arm_unused),
        .pool_complete(pool_complete),.gap_complete(gap_complete));
    wire        gap_we;
    wire [7:0]  gap_waddr;
    wire [15:0] gap_wdata;

    gap_unit #(.CIN(256), .H_IN(4), .W_IN(16)) u_gap (
        .clk(clk), .rst_n(rst_n), .layer_start(conv4_start),
        .y_valid(p4_v), .y_u8(p4_d),
        .g_raddr(8'd0), .g_rdata(gap_unused_rdata),
        .gap_done(gap_done),
        .gap_waddr(gap_waddr), .gap_we(gap_we), .gap_wdata(gap_wdata)
    );

    // Capture GAP results, then replay them into fc1 (256 beats).
    reg [15:0] gap_buf [0:255];
    always @(posedge clk) begin
        if (gap_we) gap_buf[gap_waddr] <= gap_wdata;
    end

    reg [7:0] fc_x_cnt;
    reg       fc_x_run;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fc_x_cnt <= 8'd0;
            fc_x_run <= 1'b0;
        end else if (fc1_start) begin
            fc_x_cnt <= 8'd0;
            fc_x_run <= 1'b1;
        end else if (fc_x_run) begin
            if (fc_x_cnt == 8'd255) fc_x_run <= 1'b0;
            else                    fc_x_cnt <= fc_x_cnt + 8'd1;
        end
    end

    wire        fc1_x_valid = fc_x_run;
    wire [15:0] fc1_x_s16   = gap_buf[fc_x_cnt];

    wire       fc1_y_valid;
    wire [7:0] fc1_y;
    wire       fc2_y_valid;
    wire [7:0] fc2_y;

    fc_engine #(.CIN(256), .COUT(128), .ZP_IN(8'd0), .ZP_OUT(8'd0)) u_fc1 (
        .clk(clk), .rst_n(rst_n), .layer_start(fc1_start),
        .x_valid(fc1_x_valid), .x_s16(fc1_x_s16),
        .w_valid(wbuf_rd_valid), .w_data(wbuf_rd_data), .w_ready(fc_wready[0]),
        .b_valid(fb1), .bias_s32(wl_bias), .m_valid(fm1), .m_s32(wl_m),
        .s_valid(fs1), .shift(wl_shift),
        .y_valid(fc1_y_valid), .y_u8(fc1_y), .done(fc1_done), .grp_advance(fc_grp_advance[0])
    );

    fc_engine #(.CIN(128), .COUT(8), .ZP_IN(8'd0), .ZP_OUT(8'd57)) u_fc2 (
        .clk(clk), .rst_n(rst_n), .layer_start(fc2_start),
        .x_valid(fc1_y_valid), .x_s16({8'd0, fc1_y}),
        .w_valid(wbuf_rd_valid), .w_data(wbuf_rd_data), .w_ready(fc_wready[1]),
        .b_valid(fb2), .bias_s32(wl_bias), .m_valid(fm2), .m_s32(wl_m),
        .s_valid(fs2), .shift(wl_shift),
        .y_valid(fc2_y_valid), .y_u8(fc2_y), .done(fc2_done), .grp_advance(fc_grp_advance[1])
    );

    // fc2 produces 16 lanes (8 real + 8 padding); softmax consumes 8.
    reg [255:0] logits_bus;
    reg [3:0]   fc2_lane;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            logits_bus <= 256'd0;
            fc2_lane   <= 4'd0;
        end else if (fc2_start) begin
            fc2_lane   <= 4'd0;
        end else if (fc2_y_valid && fc2_lane < 4'd8) begin
            logits_bus[fc2_lane*32 +: 32] <=
                $signed({24'd0, fc2_y}) - 32'sd57;
            fc2_lane <= fc2_lane + 4'd1;
        end
    end

    reg sm_start;
    wire [15:0] sm_q16;
    wire [7:0]  sm_pct;
    wire [3:0]  sm_idx;

    softmax_top u_softmax (
        .clk(clk), .rst_n(rst_n), .start(sm_start),
        .logits(logits_bus),
        .out_valid(probs_valid), .out_q16(sm_q16),
        .out_pct(sm_pct), .out_idx(sm_idx),
        .top1_idx(top1), .done(sm_done)
    );

    assign probs_pct = sm_pct;
    assign probs_idx = sm_idx;

    wire layer_finished =
        (layer == L_CONV1) ? conv1_done :
        (layer == L_POOL1) ? pool1_done :
        (layer == L_CONV2) ? conv2_done :
        (layer == L_POOL2) ? pool2_done :
        (layer == L_CONV3) ? conv3_done :
        (layer == L_POOL3) ? pool3_done :
        (layer == L_CONV4) ? conv4_done :
        (layer == L_POOL4) ? pool4_done :
        (layer == L_GAP)   ? gap_complete  :
        (layer == L_FC1)   ? fc1_done  :
        (layer == L_FC2)   ? fc2_done  :
        (layer == L_SM)    ? sm_done   : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy         <= 1'b0;
            done         <= 1'b0;
            npu_cycles   <= 32'd0;
            timeout_flag <= 1'b0;
            layer        <= L_CONV1;
            settle       <= 2'd0;
            layer_pulse  <= 1'b0;
            sm_start     <= 1'b0;
        end else begin
            layer_pulse <= 1'b0;
            sm_start    <= 1'b0;
            done        <= 1'b0;

            if (timeout_flag == 1'b0 && npu_cycles >= TIMEOUT_CYCLES)
                timeout_flag <= 1'b1;

            if (!busy) begin
                if (start) begin
                    busy       <= 1'b1;
                    layer      <= L_CONV1;
                    npu_cycles <= 32'd0;
                    settle     <= 2'd0;
                    layer_pulse<= 1'b1;
                end
            end else begin
                npu_cycles <= npu_cycles + 32'd1;

                if (settle != 2'd0) begin
                    settle <= settle - 2'd1;
                    if (settle == 2'd1) layer_pulse <= 1'b1;
                end else if (layer_finished) begin
                    if (layer == L_FC2) begin
                        sm_start <= 1'b1;
                        layer    <= L_SM;
                        settle   <= 2'd1;
                    end else if (layer == L_SM) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        layer  <= layer + 4'd1;
                        settle <= 2'd1;
                    end
                end
            end
        end
    end

endmodule
