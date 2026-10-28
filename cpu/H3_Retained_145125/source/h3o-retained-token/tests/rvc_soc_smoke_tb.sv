`timescale 1ns/1ps
module rvc_soc_smoke_tb;
    reg clk=1'b0;
    reg rst_n=1'b0;
    reg serial_rx=1'b1;
    reg [7:0] gpio_input=8'b0;
    wire serial_tx;
    wire [7:0] gpio_output;
    wire [31:0] status_code;
    wire maintenance_fault;
    wire trace_valid;
    wire [31:0] trace_pc,trace_instruction,trap_cause;
    wire trap_valid;
    wire [63:0] cycle_count,retired_count;
    integer cycles;

    always #5 clk=~clk;

    rv32_soc #(
        .ENABLE_M(1),.ENABLE_C(1),.CLOCK_HZ(1000),.BAUD(100),
        .MEMORY_ADDRESS_BITS(14),.ENABLE_PREDICTOR(1),.LOAD_USE_BUBBLE(1),
        .FAST_ICACHE_HIT(1),.FAST_DCACHE_READ(1),.FAST_DCACHE_WRITE(1),
        .FETCH_OVERLAP(1),.DATA_OVERLAP(1),.EARLY_D_REQUEST(1),
        .BTB_INDEX_BITS(8),.ICACHE_SET_BITS(9),.CACHE_SET_BITS(6),
        .ENABLE_CACHE(1),.INIT_FILE("rvc_smoke.hex")
    ) soc(
        .clk(clk),.rst_n(rst_n),.serial_rx(serial_rx),.serial_tx(serial_tx),
        .gpio_input(gpio_input),.gpio_output(gpio_output),.status_code(status_code),
        .maintenance_fault(maintenance_fault),.trace_valid(trace_valid),
        .trace_pc(trace_pc),.trace_instruction(trace_instruction),
        .trap_valid(trap_valid),.trap_cause(trap_cause),
        .cycle_count(cycle_count),.retired_count(retired_count)
    );

    initial begin
        repeat(5) @(posedge clk);
        rst_n=1'b1;
        cycles=0;
        while(!trap_valid && cycles<1000) begin
            @(posedge clk);
            cycles=cycles+1;
        end
        if(!trap_valid) begin
            $display("RVC SoC smoke FAILED: no trap within cycle bound");
            $fatal(1,"RVC smoke timeout");
        end
        if(trap_cause!==32'd3 || soc.core.registers[8]!==32'd2 || soc.core.trap_pc!==32'd8) begin
            $display("RVC SoC smoke FAILED: cause=%0d x8=%h trap_pc=%h",trap_cause,soc.core.registers[8],soc.core.trap_pc);
            $fatal(1,"RVC smoke mismatch");
        end
        $display("RVC SoC smoke PASSED cycles=%0d retired=%0d x8=%0d",cycle_count,retired_count,soc.core.registers[8]);
        $finish(0);
    end
endmodule
