// ---------------------------------------------------------------------------
// core_probe.v -- core_clk liveness probe (diagnostic, not production)
//
// Sends 16 'C' (0x43) bytes through the shared byte-level uart_tx after
// reset release, one every ~0.2 s at 125 MHz. If the board receives 'C',
// the DDR3 IP's core_clk exists and the core domain is out of reset; no 'C'
// means the core clock never starts (125 MHz differential ref_clk / GPLL).
// The probe stops after 16 bytes so normal UART status lines are not
// polluted once the design is healthy.
//
// Interface: byte-level handshake (tx_data/tx_valid/tx_ready), the same
// contract uart_debug uses. uart_tx performs the serialization.
// ---------------------------------------------------------------------------

module core_probe (
    input  wire       clk,        // core_clk 125 MHz
    input  wire       rst_n,      // core_clk_rst_n
    output reg        tx_valid,
    output reg  [7:0] tx_data,
    input  wire       tx_ready
);

    localparam [24:0] GAP_CYCLES = 25'd25000000;  // 0.2 s at 125 MHz

    reg [24:0] gap_cnt;
    reg [3:0]  sent;
    reg        pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gap_cnt  <= 25'd0;
            sent     <= 4'd0;
            pending  <= 1'b0;
            tx_valid <= 1'b0;
            tx_data  <= 8'd0;
        end else begin
            tx_valid <= 1'b0;

            if (sent != 4'd15) begin
                if (!pending) begin
                    if (gap_cnt == GAP_CYCLES) begin
                        gap_cnt <= 25'd0;
                        pending <= 1'b1;
                    end else begin
                        gap_cnt <= gap_cnt + 25'd1;
                    end
                end else begin
                    tx_data  <= 8'h43;   // 'C'
                    tx_valid <= 1'b1;
                    if (tx_ready) begin
                        pending <= 1'b0;
                        sent    <= sent + 4'd1;
                    end
                end
            end
        end
    end

endmodule