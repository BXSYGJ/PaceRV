`timescale 1ns/1ps
module tb_npu_m1_owner;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,loader_allowed=1,l_valid=0,n_valid=0,l_rd_ready=1,n_rd_ready=1;
reg[36:0]l_cmd=0,n_cmd=0;reg[255:0]l_wdata=1,n_wdata=2;
reg m_wready=0,m_rvalid=0,m_done=0,m_abort=0;
wire l_wready,l_rvalid,l_done,n_wready,n_rvalid,n_done,n_abort,m_valid,m_rd_ready,idle,protocol_error;
wire[36:0]m_cmd;wire[255:0]m_wdata;
npu_m1_owner dut(.*);
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task reset;begin rst_n=0;l_valid=0;n_valid=0;m_done=0;m_abort=0;m_rvalid=0;tick;rst_n=1;tick;end endtask
integer i;
initial begin
reset;
// Both request: permitted loader wins, owner survives policy change.
l_valid=1;n_valid=1;l_cmd={1'b1,28'h100000,8'd0};n_cmd={1'b0,28'h110000,8'd3};tick;
if(!m_valid || m_cmd!==l_cmd)$fatal(1,"simultaneous arbitration");
loader_allowed=0;l_cmd=0;tick;
if(m_cmd!=={1'b1,28'h100000,8'd0})$fatal(1,"command not latched");
m_wready=1;#1;if(!l_wready || n_wready)$fatal(1,"write owner changed");tick;m_wready=0;
m_done=1;#1;if(l_done || n_done)$fatal(1,"loader done was not delayed");tick;m_done=0;
#1;if(!l_done || n_done)$fatal(1,"done owner changed");tick;
if(idle)$fatal(1,"valid drop gap missing");l_valid=0;tick;tick;
if(!m_valid || m_cmd!==n_cmd)$fatal(1,"NPU request not retained");
// Native done may precede draining all four FIFO beats.
n_rd_ready=0;m_done=1;tick;m_done=0;n_valid=0;l_valid=1;loader_allowed=1;
m_rvalid=1;repeat(4)begin tick;if(idle || l_rvalid || !n_rvalid)$fatal(1,"owner stolen under backpressure");end
n_rd_ready=1;for(i=0;i<4;i=i+1)tick;m_rvalid=0;tick;
if(!m_valid || m_cmd!==l_cmd)$fatal(1,"next loader not granted after drain");
// Abort is fail-closed until reset.
m_abort=1;tick;m_abort=0;repeat(3)tick;
if(m_valid || idle || !protocol_error)$fatal(1,"abort not fail closed");
reset;loader_allowed=0;n_valid=1;n_cmd={1'b0,28'h100000,8'd15};tick;
if(!m_valid)$fatal(1,"16-beat boundary rejected");
m_abort=1;#1;if(!n_abort)$fatal(1,"abort not routed");tick;m_abort=0;
if(m_valid || !protocol_error)$fatal(1,"NPU abort state");
reset;n_valid=1;n_cmd={1'b0,28'h100000,8'd16};tick;
if(m_valid || !protocol_error || !n_abort)$fatal(1,"17-beat request accepted");
reset;if(!idle || protocol_error)$fatal(1,"reset recovery");
// Real loader drops ready/valid as soon as done is sampled. Therefore its
// completion must be delayed until the final accepted FIFO beat.
loader_allowed=1;l_valid=1;l_rd_ready=0;l_cmd={1'b0,28'h100000,8'd3};tick;
m_done=1;m_rvalid=1;#1;if(l_done)$fatal(1,"loader done before delivery");tick;m_done=0;
repeat(4)begin tick;if(l_done || idle)$fatal(1,"loader done under stall");end
l_rd_ready=1;
for(i=0;i<4;i=i+1)begin
 #1;if(l_done !== (i==3))$fatal(1,"loader done beat %0d",i);
 tick;
end
// Emulate S_RD_BEAT leaving after its final handshake.
l_valid=0;l_rd_ready=0;m_rvalid=0;#1;
if(l_done)$fatal(1,"loader completion repeated");tick;
if(!idle)$fatal(1,"loader retained after completed drain");
// Data must not escape on abort or in the fail-closed state.
l_valid=1;l_rd_ready=1;l_cmd={1'b0,28'h100000,8'd1};tick;
m_abort=1;m_rvalid=1;#1;if(l_rvalid || l_done)$fatal(1,"loader data/done escaped during abort");tick;
m_abort=0;repeat(3)begin tick;if(l_rvalid || n_rvalid || m_valid || l_done)$fatal(1,"data escaped after abort");end
reset;loader_allowed=1;l_valid=1;l_cmd={1'b1,28'h100000,8'd16};tick;
if(l_done || m_valid || !protocol_error)$fatal(1,"invalid loader command falsely completed");
$display("RESULT: PASS M1 owner simultaneous/policy/early-done/4-beat-stall/drain/abort/reset/16-beat-limit/loader-completion/no-abort-leak");$finish;
end
initial begin repeat(1000)tick;$fatal(1,"watchdog");end
endmodule
