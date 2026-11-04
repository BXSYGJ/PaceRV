`timescale 1ns / 1ps

module rv32_cpu_subsys #(
    parameter integer ENABLE_M         = 1,
    parameter integer ENABLE_PREDICTOR = 0,
    parameter [31:0]  RESET_VECTOR     = 32'h0000_0000,
    parameter integer IMEM_WORDS       = 2048,
    parameter integer DMEM_WORDS       = 2048,
    parameter PROG_HEX                 = "src/cpu/prog.hex"
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        npu_busy,
    input  wire        npu_done,
    input  wire        npu_timeout,
    input  wire        npu_probs_valid,
    input  wire [7:0]  npu_probs_pct,
    input  wire [3:0]  npu_probs_idx,
    input  wire [3:0]  npu_top1,
    input  wire [31:0] npu_cycles,
    input  wire        ddr_ok,
    input  wire        ddr_err,
    input  wire [31:0] ddr_sts,

    output wire        uart_valid,
    output wire [7:0]  uart_data,
    input  wire        uart_ready,

    output reg  [7:0]  cpu_led,
    output reg         cpu_alive,
    output wire        cpu_trap,
    output wire [31:0] cpu_trap_cause,
    output reg         npu_soft_start
);

    localparam integer IAW = $clog2(IMEM_WORDS);
    localparam integer DAW = $clog2(DMEM_WORDS);
    localparam [31:13] DMEM_BASE_HI = 19'h10000;
    localparam [DAW-1:0] DMEM_LAST = DMEM_WORDS - 1;

    localparam [31:0] CPU_ID = 32'h5256_4331;

    wire        i_req_valid, i_req_ready;
    wire [31:0] i_req_address;
    wire        i_rsp_valid, i_rsp_ready;
    wire [31:0] i_rsp_data;
    wire        i_rsp_error;
    wire        d_req_valid, d_req_ready;
    wire [31:0] d_req_address;
    wire [31:0] d_req_data;
    wire [3:0]  d_req_strobe;
    wire        d_req_write;
    wire        d_rsp_valid, d_rsp_ready;
    wire [31:0] d_rsp_data;
    wire        d_rsp_error;
    wire        maintenance_valid;
    wire [63:0] cycle_count, retired_count;

    wire        trace_valid_u, trace_write_u;
    wire [31:0] trace_pc_u, trace_instruction_u, trace_data_u;
    wire [4:0]  trace_rd_u;
    wire [31:0] trap_pc_u, trap_value_u;
    wire [4:0]  pipeline_valid_u;

    rv32_core #(
        .RESET_VECTOR     (RESET_VECTOR),
        .ENABLE_PREDICTOR (ENABLE_PREDICTOR),
        .ENABLE_M         (ENABLE_M)
    ) u_core (
        .clk              (clk),
        .rst_n            (rst_n),
        .i_req_valid      (i_req_valid),
        .i_req_ready      (i_req_ready),
        .i_req_address    (i_req_address),
        .i_rsp_valid      (i_rsp_valid),
        .i_rsp_ready      (i_rsp_ready),
        .i_rsp_data       (i_rsp_data),
        .i_rsp_error      (i_rsp_error),
        .d_req_valid      (d_req_valid),
        .d_req_ready      (d_req_ready),
        .d_req_address    (d_req_address),
        .d_req_data       (d_req_data),
        .d_req_strobe     (d_req_strobe),
        .d_req_write      (d_req_write),
        .d_rsp_valid      (d_rsp_valid),
        .d_rsp_ready      (d_rsp_ready),
        .d_rsp_data       (d_rsp_data),
        .d_rsp_error      (d_rsp_error),
        .maintenance_valid(maintenance_valid),
        .maintenance_ready(1'b1),
        .timer_value      (64'd0),
        .irq_external     (1'b0),
        .irq_software     (1'b0),
        .irq_timer        (1'b0),
        .trace_valid      (trace_valid_u),
        .trace_pc         (trace_pc_u),
        .trace_instruction(trace_instruction_u),
        .trace_write      (trace_write_u),
        .trace_rd         (trace_rd_u),
        .trace_data       (trace_data_u),
        .trap_valid       (cpu_trap),
        .trap_pc          (trap_pc_u),
        .trap_cause       (cpu_trap_cause),
        .trap_value       (trap_value_u),
        .pipeline_valid   (pipeline_valid_u),
        .cycle_count      (cycle_count),
        .retired_count    (retired_count)
    );

    reg [31:0] imem [0:IMEM_WORDS-1];

    reg [31:0] rom_d [0:IMEM_WORDS-1];

    initial begin
        $readmemh(PROG_HEX, imem);
        $readmemh(PROG_HEX, rom_d);
    end

    reg [7:0] dmem0 [0:DMEM_WORDS-1];
    reg [7:0] dmem1 [0:DMEM_WORDS-1];
    reg [7:0] dmem2 [0:DMEM_WORDS-1];
    reg [7:0] dmem3 [0:DMEM_WORDS-1];

    reg        npu_done_st, npu_probs_st, npu_timeout_st;
    reg [7:0]  probs_pct_q;
    reg [3:0]  probs_idx_q;
    reg [31:0] result_cycles_q;

    wire ctrl_write = d_req_valid && d_req_ready && d_req_write &&
                      (d_req_address == 32'h8000_0024);
    wire ctrl_start = ctrl_write && d_req_data[0];
    wire ctrl_clear = ctrl_write && d_req_data[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_done_st    <= 1'b0;
            npu_probs_st   <= 1'b0;
            npu_timeout_st <= 1'b0;
            probs_pct_q    <= 8'd0;
            probs_idx_q    <= 4'd0;
            result_cycles_q <= 32'd0;
            npu_soft_start <= 1'b0;
        end else begin
            npu_soft_start <= ctrl_start;
            if (ctrl_clear) begin
                npu_done_st    <= 1'b0;
                npu_probs_st   <= 1'b0;
                npu_timeout_st <= 1'b0;
            end

            if (npu_done)          npu_done_st    <= 1'b1;
            if (npu_timeout)       npu_timeout_st <= 1'b1;
            if (npu_probs_valid) begin
                npu_probs_st <= 1'b1;
                probs_pct_q  <= npu_probs_pct;
                probs_idx_q  <= npu_probs_idx;
                result_cycles_q <= npu_cycles;
            end
        end
    end

    wire led_write = d_req_valid && d_req_ready && d_req_write &&
                     (d_req_address == 32'h8000_0014);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_led   <= 8'd0;
            cpu_alive <= 1'b0;
        end else if (led_write) begin
            cpu_led   <= d_req_data[7:0];
            cpu_alive <= 1'b1;
        end
    end

    reg [7:0]  txq [0:15];
    reg [4:0]  tx_wr, tx_rd;

    wire [4:0] tx_count  = tx_wr - tx_rd;
    wire       tx_push   = d_req_valid && d_req_ready && d_req_write &&
                           (d_req_address == 32'h8000_000C) && (tx_count != 5'd16);
    wire       tx_ready  = (tx_count != 5'd16);

    assign uart_valid = (tx_count != 5'd0);
    assign uart_data  = txq[tx_rd[3:0]];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_wr <= 5'd0;
            tx_rd <= 5'd0;
        end else begin
            if (tx_push) begin
                txq[tx_wr[3:0]] <= d_req_data[7:0];
                tx_wr <= tx_wr + 5'd1;
            end
            if (uart_valid && uart_ready) begin
                tx_rd <= tx_rd + 5'd1;
            end
        end
    end

    reg [31:0] mmio_rdata;

    always @(*) begin
        case (d_req_address)
            32'h8000_0000: mmio_rdata = CPU_ID;
            32'h8000_0004: mmio_rdata = {8'h00, probs_pct_q, probs_idx_q,
                                         npu_top1, 1'b0, ddr_err, ddr_ok,
                                         1'b0, npu_probs_st, npu_timeout_st,
                                         npu_done_st, npu_busy};
            32'h8000_0008: mmio_rdata = {8'h00, 8'h00, probs_pct_q, 4'h0, probs_idx_q};
            32'h8000_0010: mmio_rdata = {26'h0, tx_count, tx_ready};
            32'h8000_0018: mmio_rdata = cycle_count[31:0];
            32'h8000_001C: mmio_rdata = retired_count[31:0];
            32'h8000_0020: mmio_rdata = ddr_sts;
            32'h8000_0028: mmio_rdata = result_cycles_q;
            default:       mmio_rdata = 32'h0000_0000;
        endcase
    end

    reg        i_pend;
    reg [31:0] i_rsp_q;
    reg        i_err_q;
    reg [9:0]  i_wait;

    assign i_req_ready = !i_pend;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_pend  <= 1'b0;
            i_rsp_q <= 32'd0;
            i_err_q <= 1'b0;
            i_wait  <= 10'd0;
        end else if (i_req_valid && i_req_ready) begin
            i_pend <= 1'b1;
            i_wait <= 10'd0;
            if (i_req_address[31:IAW+2] == {(32-IAW-2){1'b0}}) begin
                i_rsp_q <= imem[i_req_address[IAW+1:2]];
                i_err_q <= 1'b0;
            end else begin
                i_rsp_q <= 32'd0;
                i_err_q <= 1'b1;
            end
        end else if (i_rsp_valid && i_rsp_ready) begin
            i_pend <= 1'b0;
            i_wait <= 10'd0;
        end else if (i_rsp_valid) begin

            if (i_wait == 10'h3ff) begin
                i_pend <= 1'b0;
                i_wait <= 10'd0;
            end else begin
                i_wait <= i_wait + 10'd1;
            end
        end
    end

    assign i_rsp_valid = i_pend;
    assign i_rsp_data  = i_rsp_q;
    assign i_rsp_error = i_err_q;

    reg        d_pend;
    reg [31:0] d_rsp_q;
    reg        d_err_q;
    reg [9:0]  d_wait;

    wire d_acc      = d_req_valid && d_req_ready;
    wire d_is_mmio  = d_req_address[31];
    wire d_is_ram   = (d_req_address[31:13] == DMEM_BASE_HI) &&
                      (d_req_address[DAW+1:2] <= DMEM_LAST);
    wire d_is_rom   = (d_req_address[31:IAW+2] == {(32-IAW-2){1'b0}});
    wire [DAW-1:0] d_word = d_req_address[DAW+1:2];
    wire [IAW-1:0] d_rom_word = d_req_address[IAW+1:2];

    assign d_req_ready = !d_pend &&
                         !(d_req_write && d_req_address == 32'h8000_000C && !tx_ready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_pend  <= 1'b0;
            d_rsp_q <= 32'd0;
            d_err_q <= 1'b0;
            d_wait  <= 10'd0;
        end else if (d_acc) begin
            d_pend <= 1'b1;
            d_wait <= 10'd0;
            if (d_is_mmio) begin
                d_rsp_q <= mmio_rdata;
                d_err_q <= 1'b0;
            end else if (d_is_ram) begin
                d_rsp_q <= {dmem3[d_word], dmem2[d_word],
                            dmem1[d_word], dmem0[d_word]};
                d_err_q <= 1'b0;
            end else if (d_is_rom) begin
                d_rsp_q <= rom_d[d_rom_word];
                d_err_q <= 1'b0;
            end else begin
                d_rsp_q <= 32'd0;
                d_err_q <= 1'b1;
            end
        end else if (d_rsp_valid && d_rsp_ready) begin
            d_pend <= 1'b0;
            d_wait <= 10'd0;
        end else if (d_rsp_valid) begin
            if (d_wait == 10'h3ff) begin
                d_pend <= 1'b0;
                d_wait <= 10'd0;
            end else begin
                d_wait <= d_wait + 10'd1;
            end
        end
    end

    assign d_rsp_valid = d_pend;
    assign d_rsp_data  = d_rsp_q;
    assign d_rsp_error = d_err_q;

    always @(posedge clk) begin
        if (d_acc && d_is_ram && d_req_write) begin
            if (d_req_strobe[0]) dmem0[d_word] <= d_req_data[7:0];
            if (d_req_strobe[1]) dmem1[d_word] <= d_req_data[15:8];
            if (d_req_strobe[2]) dmem2[d_word] <= d_req_data[23:16];
            if (d_req_strobe[3]) dmem3[d_word] <= d_req_data[31:24];
        end
    end

endmodule
