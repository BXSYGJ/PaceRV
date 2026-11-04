// demo_confidence_player: scripted demonstration only. Probabilities are not model predictions.
module demo_confidence_player #(
    parameter TICK_CYCLES = 12500000,
    parameter DEBOUNCE_CYCLES = 2500000,
    parameter SAMPLE_COUNT = 581,
    parameter TABLE_FILE = "src/ui/demo_confidence.hex"
) (
    input wire clk, rst_n, key_n,
    output reg probs_valid,
    output reg [7:0] probs_pct,
    output reg [3:0] probs_idx, top1
);
    reg [63:0] samples [0:4095];
    initial $readmemh(TABLE_FILE, samples);
    reg [1:0] key_sync;
    reg key_stable;
    reg [31:0] debounce_count, tick_count;
    reg playing, replay_pending;
    reg [11:0] sample_index;
    reg [63:0] row;
    reg [2:0] phase;
    reg [3:0] scan_index, best_index;
    reg [7:0] best_value;
    wire [7:0] scan_value = row[scan_index * 8 +: 8];
    wire key_press = key_stable && !key_sync[1] &&
                     debounce_count == DEBOUNCE_CYCLES - 1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_sync <= 2'b11;
            key_stable <= 1'b1;
            debounce_count <= 0;
            tick_count <= 0;
            playing <= 0;
            replay_pending <= 0;
            sample_index <= 0;
            row <= 0;
            phase <= 0;
            scan_index <= 0;
            best_index <= 8;
            best_value <= 0;
            probs_valid <= 0;
            probs_pct <= 0;
            probs_idx <= 0;
            top1 <= 8;
        end else begin
            key_sync <= {key_sync[0], key_n};
            if (key_sync[1] == key_stable) debounce_count <= 0;
            else if (debounce_count == DEBOUNCE_CYCLES - 1) begin
                key_stable <= key_sync[1];
                debounce_count <= 0;
            end else debounce_count <= debounce_count + 1'b1;
            probs_valid <= 0;
            if (key_press) replay_pending <= 1;
            if (tick_count == TICK_CYCLES - 1) tick_count <= 0;
            else tick_count <= tick_count + 1'b1;
            case (phase)
                0: if (replay_pending || tick_count == TICK_CYCLES - 1) begin
                    if (replay_pending) begin
                        row <= samples[0];
                        sample_index <= 0;
                        playing <= 1;
                        replay_pending <= key_press;
                        tick_count <= 0;
                    end else if (playing) row <= samples[sample_index];
                    else row <= 0;
                    scan_index <= 0;
                    best_index <= 8;
                    best_value <= 0;
                    phase <= 1;
                end
                1: begin
                    if (scan_value > best_value) begin
                        best_value <= scan_value;
                        best_index <= scan_index;
                    end
                    if (scan_index == 7) phase <= 2;
                    else scan_index <= scan_index + 1'b1;
                end
                2: begin
                    top1 <= best_index;
                    scan_index <= 0;
                    phase <= 3;
                end
                3: begin
                    probs_valid <= 1;
                    probs_idx <= scan_index;
                    probs_pct <= scan_value;
                    if (scan_index == 7) begin
                        phase <= 0;
                        if (!key_press && !replay_pending && playing && sample_index < SAMPLE_COUNT - 1)
                            sample_index <= sample_index + 1'b1;
                    end else scan_index <= scan_index + 1'b1;
                end
                default: phase <= 0;
            endcase
        end
    end
endmodule
