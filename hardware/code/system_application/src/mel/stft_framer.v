module stft_framer #(
    parameter integer N_FFT          = 2048,
    parameter integer HOP            = 512,
    parameter integer REFLECT_PAD    = 1024,
    parameter integer WINDOW_SAMPLES = 132096,
    parameter integer FRAME_COUNT    = 259,
    parameter integer RING_DEPTH     = 2560,

    parameter integer TAIL_FIRST     = WINDOW_SAMPLES - REFLECT_PAD - 1,
    parameter integer TAIL_LAST      = WINDOW_SAMPLES - 2,

    parameter         HAN_HEX_FILE   = "hann_q15.hex"
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        win_start,
    output wire        busy,
    output wire        all_done,
    input  wire        out_ready,

    input  wire [31:0] pcm_rd_data,
    input  wire        pcm_rd_valid,
    output wire        pcm_rd_ready,

    output reg  [16:0] win_s17,
    output reg         win_valid,
    output reg         frame_start,
    output reg         frame_done,
    output wire        frame_last,
    output reg  [8:0]  frame_idx
);

    localparam [10:0] PAD_W          = REFLECT_PAD;
    localparam [9:0]  TAIL_FIRST_LOW = TAIL_FIRST;
    localparam [8:0]  LAST_FRAME     = FRAME_COUNT - 1;
    localparam [11:0] RING_LAST      = RING_DEPTH - 1;
    localparam [11:0] BASE_WRAP      = RING_DEPTH - HOP;

    reg [15:0] win_ring [0:RING_DEPTH-1];
    reg [15:0] head_ram [0:1023];
    reg [15:0] head_extra;
    reg [15:0] tail_ram [0:1023];
    reg [15:0] ring_q;
    wire [15:0] han_q;

    wire [10:0] han_addr;

    hann_rom #(
        .HAN_HEX_FILE (HAN_HEX_FILE)
    ) u_hann_rom (
        .clk  (clk),
        .addr (han_addr),
        .q    (han_q)
    );

    localparam [2:0] PH_IDLE   = 3'd0;
    localparam [2:0] PH_FILL   = 3'd1;
    localparam [2:0] PH_VLEFT  = 3'd2;
    localparam [2:0] PH_REPLAY = 3'd3;
    localparam [2:0] PH_STREAM = 3'd4;
    localparam [2:0] PH_VRIGHT = 3'd5;
    localparam [2:0] PH_DONE   = 3'd6;

    reg [2:0]  phase;
    reg        started;
    reg [17:0] push_cnt;
    reg [11:0] push_slot;
    reg [17:0] samp_cnt;
    reg [10:0] replay_cnt;
    reg [10:0] vright_cnt;

    reg        out_run;
    reg        all_done_reg;

    wire [17:0] frame_th = 18'd2048 + {frame_idx, 9'd0};

    wire [17:0] push_limit = frame_th + 18'd512;

    wire        push_open  = (push_cnt < push_limit) && out_ready;
    wire        frame_go   = started && !out_run && (push_cnt == frame_th)
                             && out_ready;

    assign pcm_rd_ready = (phase == PH_FILL) ||
                          ((phase == PH_STREAM) && push_open);

    wire push_fire = started && push_open && (
        (phase == PH_VLEFT)  || (phase == PH_REPLAY) ||
        (phase == PH_VRIGHT) ||
        ((phase == PH_STREAM) && pcm_rd_valid));

    wire [11:0] next_push_slot = (push_slot == RING_LAST)
                               ? 12'd0 : (push_slot + 12'd1);

    wire [10:0] vleft_full     = PAD_W - push_cnt[10:0];
    wire [9:0]  vleft_ram_idx  = vleft_full[9:0];

    wire [9:0]  vright_ram_idx = 10'd1023 - vright_cnt[9:0];

    wire [9:0] head_read_idx = (phase == PH_REPLAY)
                               ? replay_cnt[9:0] : vleft_ram_idx;
    reg [15:0] head_q;
    reg [15:0] tail_q;
    reg push_pending;
    reg [11:0] push_slot_d;
    reg use_head_d;
    reg use_tail_d;
    reg [15:0] direct_data_d;
    wire use_head = ((phase == PH_VLEFT) && (push_cnt[10:0] != 11'd0)) ||
                    ((phase == PH_REPLAY) && (replay_cnt != PAD_W));
    wire [15:0] push_data = use_tail_d ? tail_q :
                            use_head_d ? head_q : direct_data_d;
    always @(posedge clk) begin
        head_q <= head_ram[head_read_idx];
        tail_q <= tail_ram[vright_ram_idx];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            push_pending <= 1'b0;
            push_slot_d <= 12'd0;
            use_head_d <= 1'b0;
            use_tail_d <= 1'b0;
            direct_data_d <= 16'd0;
        end else begin
            push_pending <= push_fire;
            push_slot_d <= push_slot;
            use_head_d <= use_head;
            use_tail_d <= (phase == PH_VRIGHT);
            direct_data_d <= (phase == PH_STREAM) ? pcm_rd_data[15:0] : head_extra;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase      <= PH_IDLE;
            started    <= 1'b0;
            push_cnt   <= 18'd0;
            push_slot  <= 12'd0;
            samp_cnt   <= 18'd0;
            replay_cnt <= 11'd0;
            vright_cnt <= 11'd0;
            head_extra <= 16'd0;
        end else begin
            case (phase)
                PH_IDLE: begin
                    if (win_start) begin
                        phase     <= PH_FILL;
                        started   <= 1'b1;
                        push_cnt  <= 18'd0;
                        push_slot <= 12'd0;
                        samp_cnt  <= 18'd0;
                    end
                end

                PH_FILL: begin

                    if (pcm_rd_valid && pcm_rd_ready) begin
                        if (samp_cnt <= 17'd1023) begin
                            head_ram[samp_cnt[9:0]] <= pcm_rd_data[15:0];
                        end else begin
                            head_extra <= pcm_rd_data[15:0];
                        end
                        samp_cnt <= samp_cnt + 18'd1;
                        if (samp_cnt == 17'd1024) begin

                            phase <= PH_VLEFT;
                        end
                    end
                end

                PH_VLEFT: begin

                    if (push_fire) begin
                        push_cnt  <= push_cnt + 18'd1;
                        push_slot <= next_push_slot;
                        if (push_cnt == 18'd1023) begin
                            replay_cnt <= 11'd0;
                            phase      <= PH_REPLAY;
                        end
                    end
                end

                PH_REPLAY: begin

                    if (push_fire) begin
                        push_cnt   <= push_cnt + 18'd1;
                        push_slot  <= next_push_slot;
                        replay_cnt <= replay_cnt + 11'd1;
                        if (replay_cnt == PAD_W) begin

                            phase <= PH_STREAM;
                        end
                    end
                end

                PH_STREAM: begin

                    if (pcm_rd_valid && pcm_rd_ready) begin

                        if ((samp_cnt >= TAIL_FIRST) &&
                            (samp_cnt <= TAIL_LAST)) begin
                            tail_ram[samp_cnt[9:0] - TAIL_FIRST_LOW]
                                <= pcm_rd_data[15:0];
                        end
                        push_cnt  <= push_cnt + 18'd1;
                        push_slot <= next_push_slot;
                        samp_cnt  <= samp_cnt + 18'd1;
                        if (samp_cnt == 18'd132095) begin

                            vright_cnt <= 11'd0;
                            phase      <= PH_VRIGHT;
                        end
                    end
                end

                PH_VRIGHT: begin

                    if (push_fire) begin
                        push_cnt   <= push_cnt + 18'd1;
                        push_slot  <= next_push_slot;
                        vright_cnt <= vright_cnt + 11'd1;
                        if (vright_cnt == 11'd1023) begin
                            phase <= PH_DONE;
                        end
                    end
                end

                PH_DONE: begin

                    if (all_done_reg) begin
                        phase   <= PH_IDLE;
                        started <= 1'b0;
                    end
                end

                default: begin
                    phase <= PH_IDLE;
                end
            endcase
        end
    end

    reg  [11:0] rd_addr;

    always @(posedge clk) begin
        if (push_pending) begin
            win_ring[push_slot_d] <= push_data;
        end
        ring_q <= win_ring[rd_addr];
    end

    reg        addr_done;
    reg [10:0] out_k;
    reg [11:0] frame_base;
    reg [10:0] out_beat;
    reg        v_data;
    reg        v_mult;
    reg signed [31:0] stage_mult;

    wire signed [15:0] pcm_s = ring_q;
    wire signed [15:0] han_s = han_q;
    wire signed [31:0] mult_w = pcm_s * han_s;
    wire signed [31:0] rhu_w  = stage_mult + 32'sd16384;
    wire signed [16:0] win_n  = rhu_w[31:15];

    always @(posedge clk) begin
        if (out_run && v_data)
            stage_mult <= mult_w;
    end

    assign han_addr = out_k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_run      <= 1'b0;
            addr_done    <= 1'b0;
            out_k        <= 11'd0;
            rd_addr      <= 12'd0;
            frame_base   <= 12'd0;
            out_beat     <= 11'd0;
            v_data       <= 1'b0;
            v_mult       <= 1'b0;
            win_s17      <= 17'd0;
            win_valid    <= 1'b0;
            frame_start  <= 1'b0;
            frame_done   <= 1'b0;
            all_done_reg <= 1'b0;
            frame_idx    <= 9'd0;
        end else begin

            win_valid <= 1'b0;
            v_data <= 1'b0;
            v_mult <= 1'b0;

            frame_start  <= 1'b0;
            frame_done   <= 1'b0;
            all_done_reg <= 1'b0;

            if (!out_run) begin

                if (win_start && !started)
                    frame_base <= 12'd0;
                if (frame_go) begin
                    out_run   <= 1'b1;
                    addr_done <= 1'b0;
                    out_k     <= 11'd0;
                    out_beat  <= 11'd0;
                    rd_addr   <= frame_base;
                end
            end else begin

                if (!addr_done) begin
                    if (rd_addr == RING_LAST) begin
                        rd_addr <= 12'd0;
                    end else begin
                        rd_addr <= rd_addr + 12'd1;
                    end
                    if (out_k == 11'd2047) begin
                        addr_done <= 1'b1;
                    end else begin
                        out_k <= out_k + 11'd1;
                    end
                end

                v_data    <= !addr_done;
                v_mult    <= v_data;
                win_valid <= v_mult;

                if (v_mult) begin
                    win_s17  <= win_n;
                    out_beat <= out_beat + 11'd1;
                    if (out_beat == 11'd0) begin
                        frame_start <= 1'b1;
                    end
                    if (out_beat == 11'd2047) begin

                        frame_done <= 1'b1;
                        out_run    <= 1'b0;
                        addr_done  <= 1'b0;

                        if (frame_base == BASE_WRAP) begin
                            frame_base <= 12'd0;
                        end else begin
                            frame_base <= frame_base + 12'd512;
                        end
                        if (frame_idx == LAST_FRAME) begin
                            frame_idx    <= 9'd0;
                            all_done_reg <= 1'b1;
                        end else begin
                            frame_idx <= frame_idx + 9'd1;
                        end
                    end
                end
            end
        end
    end

    assign busy       = started;
    assign all_done   = all_done_reg;
    assign frame_last = out_run && (frame_idx == LAST_FRAME);

endmodule
