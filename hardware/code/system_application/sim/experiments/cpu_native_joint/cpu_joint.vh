// Real CPU executes the checked-in ROM. Accelerator signals are never forced.
localparam NPU_ENABLE=0;
wire core_clk=clk,core_clk_rst_n=rst_n;
wire sys_run=1'b1,st_done=1'b1,st_fail=1'b0,safe_err=1'b0;
wire ddr_init_done=1'b1,weight_ok=1'b1,weight_err=1'b0,wl_busy=1'b0;
wire npu_busy_u=busy,native_owner_idle=owner_idle;
wire native_fault=owner_error || n_protocol_error || aligner_error || timeout_flag;
reg mel_npu_start=0;
wire cpu_npu_start;
wire cpu_uart_valid,cpu_alive,cpu_trap;
wire [7:0] cpu_uart_data,cpu_led;
wire [31:0] cpu_trap_cause;
reg cpu_uart_ready=1;
integer uart_gap=0,launches=0,cpu_requests=0,cpu_acks=0;
wire cpu_clear=u_cpu.ctrl_clear;
rv32_cpu_subsys #(.ENABLE_M(0),.ENABLE_PREDICTOR(0),.PROG_HEX("src/cpu/prog.hex")) u_cpu(
 .clk(clk),.rst_n(rst_n),.npu_busy(busy),.npu_done(done),.npu_timeout(native_fault),
 .npu_probs_valid(probs_valid && !native_fault),.npu_probs_pct(pct),.npu_probs_idx(idx),
 .npu_top1(top1),.npu_cycles(cycles),.ddr_ok(1'b1),.ddr_err(1'b0),.ddr_sts(32'd1),
 .uart_valid(cpu_uart_valid),.uart_data(cpu_uart_data),.uart_ready(cpu_uart_ready),
 .cpu_led(cpu_led),.cpu_alive(cpu_alive),.cpu_trap(cpu_trap),.cpu_trap_cause(cpu_trap_cause),
 .npu_soft_start(cpu_npu_start));
always @(posedge clk) if(rst_n) begin
 if(cpu_trap) $fatal(1,"real CPU trapped cause=%h",cpu_trap_cause);
 if(start) launches=launches+1;
 if(cpu_npu_start) cpu_requests=cpu_requests+1;
 if(cpu_clear) cpu_acks=cpu_acks+1;
 if(cpu_uart_valid && cpu_uart_ready) uart_gap<=20;
 else if(uart_gap>0) uart_gap<=uart_gap-1;
 cpu_uart_ready<=(uart_gap==0);
end
string uart_line="",uart_log="",expected_report="";
reg report_seen=0;
reg [7:0] last_pct=0;
reg [3:0] last_idx=0;
reg [31:0] last_cycles=0;
always @(posedge clk) if(rst_n) begin
 if(probs_valid) begin last_pct<=pct;last_idx<=idx;last_cycles<=cycles;end
 if(cpu_uart_valid && cpu_uart_ready) begin
  if(cpu_uart_data==8'h0a) begin
   $display("CPU UART %s",uart_line);
   uart_log={uart_log,uart_line,"\n"};
   if(uart_line==expected_report && expected_report!="") report_seen=1;
   uart_line="";
  end else if(cpu_uart_data!=8'h0d) uart_line={uart_line,$sformatf("%c",cpu_uart_data)};
 end
end
function automatic bit log_has(string needle);
 integer j;
 begin
 log_has=0;
 for(j=0;j+needle.len()<=uart_log.len();j=j+1)
  if(uart_log.substr(j,j+needle.len()-1)==needle) log_has=1;
 end
endfunction
