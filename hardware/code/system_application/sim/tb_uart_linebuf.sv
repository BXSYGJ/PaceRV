`timescale 1ns/1ps
module tb_uart_linebuf;
 reg clk=0, rst_n=0; always #5 clk=~clk;
 reg [7:0] wdata=0; reg wvalid=0; wire wready;
 wire [7:0] txdata; wire txvalid; reg txready=0;
 wire busy; wire [15:0] rxcount;
 reg [7:0] got [0:511]; integer n=0, i;
 uart_debug dut(.clk(clk),.rst_n(rst_n),.tx_byte_data(txdata),.tx_byte_valid(txvalid),.tx_byte_ready(txready),.rx_byte_data(8'd0),.rx_byte_valid(1'b0),.dbg_line_wdata(wdata),.dbg_line_wvalid(wvalid),.dbg_line_wready(wready),.dbg_line_id(3'd0),.dbg_line_arg(32'd0),.dbg_line_fire(1'b0),.dbg_busy(busy),.rx_byte_cnt(rxcount));
 always @(posedge clk) if(rst_n && txvalid) begin
   if(!txready) $fatal(1,"Unexpected TX strobe while receiver blocked");
   if(n>=512) $fatal(1,"Unexpected extra bytes");
   got[n] <= txdata; n <= n+1;
 end
 task send_byte(input [7:0] b);
 begin
   @(negedge clk); while(!wready) @(negedge clk);
   wdata=b; wvalid=1;
   @(negedge clk); wvalid=0;
 end endtask
 task check_idle;
 begin
   repeat(3) @(negedge clk);
   if(busy || !wready) $fatal(1,"Line did not release busy/ready");
 end endtask
 initial begin
   repeat(4) @(negedge clk); rst_n=1;
   check_idle();
   // No newline in the full line: automatic capacity commit is required.
   for(i=0;i<128;i=i+1) send_byte(8'h80+i[7:0]);
   repeat(5) @(negedge clk);
   if(!busy || wready || n!=0) $fatal(1,"Full pending line/backpressure contract");
   // Writes while not ready must be dropped, and must not corrupt the line.
   wvalid=1; wdata=8'h55;
   repeat(8) @(negedge clk);
   wvalid=0;
   if(!busy || wready || n!=0) $fatal(1,"Blocked TX did not preserve pending line");
   txready=1;
   wait(n>=16); @(negedge clk); txready=0;
   repeat(32) @(negedge clk);
   if(n!=16 || !busy || wready) $fatal(1,"Mid-line receiver backpressure");
   txready=1;
   wait(n>=128); check_idle();
   for(i=0;i<128;i=i+1)
     if(got[i] !== (8'h80+i[7:0])) $fatal(1,"Full-line byte %0d mismatch",i);
   // Partial input is busy but remains writable until newline commits.
   send_byte("A");
   if(!busy || !wready) $fatal(1,"Partial-line busy/ready contract");
   send_byte("B"); send_byte("C"); send_byte(8'h0a);
   wait(n>=132); check_idle();
   if(got[128]!="A" || got[129]!="B" || got[130]!="C" || got[131]!=8'h0a)
     $fatal(1,"Short newline line mismatch");
   send_byte(8'h0a); wait(n>=133); check_idle();
   if(got[132]!=8'h0a) $fatal(1,"Empty newline mismatch");
   repeat(12010) @(negedge clk);
   if(n!=133) $fatal(1,"Extra output after drain");
   $display("RESULT: PASS uart_linebuf: full128/no-newline, short/empty newline, blocked-write discard, TX backpressure, busy/ready recovery");
   $finish;
 end
 initial begin #30000000; $fatal(1,"TIMEOUT n=%0d",n); end
endmodule
