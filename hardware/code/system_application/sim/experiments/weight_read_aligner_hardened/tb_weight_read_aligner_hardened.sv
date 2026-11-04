`timescale 1ns/1ps
module tb_weight_read_aligner_hardened;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,up_valid=0,up_rd_ready=1,dn_rd_valid=0,dn_done=0,dn_abort=0;
reg [36:0] up_cmd=0;
reg [255:0] dn_data=0;
wire [255:0] up_data;
wire up_rd_valid,up_done,dn_valid,protocol_error,transaction_failed;
wire [36:0] dn_cmd;
weight_read_aligner_hardened dut(.*);
integer model_state=0,beat=0,count=0,transactions=0,outputs=0,done_count=0;
integer tick=0,expected_offset=0,expected_beats=0,early_mode=0;
reg [27:0] command_addr=0,first_addr=0,second_addr=0;
reg [7:0] first_len=0,second_len=0;
reg stalled=0;reg [255:0] held_data=0;
function [255:0] pattern(input integer a);
 integer j;begin
 for(j=0;j<32;j=j+1)pattern[j*8+:8]=(a+j)^((a+j)>>8)^8'hc3;
 end
endfunction
always @(negedge clk) begin
 dn_rd_valid=0;dn_done=0;
 if(!rst_n || dn_abort)model_state=0;
 else case(model_state)
 0:if(dn_valid)begin
  if(dn_cmd[36] || dn_cmd[12:8]!=0 || dn_cmd[7:0]>15 ||
     dn_cmd[35:8]<28'h100000 || {1'b0,dn_cmd[35:8]}+((dn_cmd[7:0]+1)*32)>29'h1b8000)
   $fatal(1,"illegal native command %h",dn_cmd);
  command_addr=dn_cmd[35:8];count=dn_cmd[7:0]+1;beat=0;
  if(transactions==0)begin first_addr=command_addr;first_len=dn_cmd[7:0];end
  if(transactions==1)begin second_addr=command_addr;second_len=dn_cmd[7:0];end
  transactions=transactions+1;model_state=1;
 end
 1:begin
  if(early_mode!=0 && beat==0)begin dn_done=1;model_state=2;end
  else begin
   dn_rd_valid=1;dn_data=pattern(command_addr+beat*32);beat=beat+1;
   if(beat==count)begin dn_done=1;model_state=3;end
  end
 end
 2:begin
  dn_rd_valid=1;dn_data=pattern(command_addr+beat*32);beat=beat+1;
  if(beat==count)model_state=3;
 end
 3:if(!dn_valid)model_state=0;
 endcase
 if(rst_n)begin tick=tick+1;up_rd_ready=(tick%4!=0 && tick%4!=1);end
end
always @(posedge clk)if(rst_n)begin
 if(stalled && !dn_abort && (!up_rd_valid || up_data!==held_data))$fatal(1,"output changed under stall");
 stalled=up_rd_valid && !up_rd_ready;held_data=up_data;
 if(up_rd_valid && up_rd_ready)begin
  if(up_data!==pattern(32'h100000+expected_offset+outputs*32))$fatal(1,"read data mismatch offset=%h beat=%0d",expected_offset,outputs);
  outputs=outputs+1;
 end
 if(up_done)begin
  done_count=done_count+1;
  if(outputs!=expected_beats)$fatal(1,"early success");
 end
end
task reset_case;
 begin
 @(negedge clk);rst_n=0;up_valid=0;dn_abort=0;stalled=0;
 repeat(3)@(negedge clk);
 transactions=0;outputs=0;done_count=0;first_addr=0;second_addr=0;early_mode=0;
 rst_n=1;
 end
endtask
task good(input integer offset_arg,input integer len_arg,input integer chunks,input integer early_arg);
 begin
 reset_case;expected_offset=offset_arg;expected_beats=len_arg+1;early_mode=early_arg;
 @(negedge clk);up_cmd={1'b0,offset_arg[27:0],len_arg[7:0]};up_valid=1;
 wait(up_done);@(posedge clk);#1;
 @(negedge clk);up_valid=0;repeat(4)@(negedge clk);
 if(protocol_error || transaction_failed || outputs!=expected_beats || done_count!=1 || transactions!=chunks)
  $fatal(1,"good case failed offset=%h tx=%0d outputs=%0d done=%0d",offset_arg,transactions,outputs,done_count);
 if(first_addr!=(28'h100000+(offset_arg & 28'hfffffe0)))$fatal(1,"first alignment wrong");
 if(chunks==2 && (first_len!=15 || second_len!=0 || second_addr!=first_addr+512))$fatal(1,"17 beat split wrong");
 $display("ALIGN PASS offset=%h len=%0d chunks=%0d early_done=%0d",offset_arg,len_arg,chunks,early_arg);
 end
endtask
task bad(input reg [36:0] command);
 begin
 reset_case;@(negedge clk);up_cmd=command;up_valid=1;
 @(posedge clk);#1;
 if(!transaction_failed || !protocol_error || dn_valid || up_done)$fatal(1,"invalid command not rejected %h",command);
 repeat(4)@(negedge clk);
 if(transactions!=0 || !protocol_error || transaction_failed || dn_valid || up_rd_valid)$fatal(1,"invalid command emitted traffic");
 end
endtask
task abort_case(input integer after_buffer);
 begin
 reset_case;expected_offset=16;expected_beats=16;
 @(negedge clk);up_cmd={1'b0,28'd16,8'd15};up_valid=1;
 if(after_buffer!=0)wait(up_rd_valid);else wait(dn_valid);
 @(negedge clk);dn_abort=1;
 @(posedge clk);#1;
 if(!transaction_failed || !protocol_error || dn_valid || up_done || up_rd_valid)$fatal(1,"abort not isolated");
 @(negedge clk);dn_abort=0;stalled=0;
 repeat(4)@(negedge clk);
 if(!protocol_error || transaction_failed || up_done || dn_valid || up_rd_valid)$fatal(1,"abort not sticky/quiescent");
 $display("ABORT PASS buffered=%0d accepted_output_beats=%0d",after_buffer,outputs);
 end
endtask
initial begin
 good(0,0,1,0);good(16,0,1,0);good(16,15,2,0);good(32'hb7fe0,0,1,0);
 good(0,15,1,1);good(16,15,2,1);
 bad({1'b1,28'd0,8'd0});bad({1'b0,28'd0,8'h10});
 bad({1'b0,28'hb8000,8'd0});bad({1'b0,28'hb7ff0,8'd0});bad({1'b0,28'hfffffff,8'd15});
 abort_case(0);abort_case(1);
 $display("RESULT: PASS hardened aligner alignment, 16+1 split, boundary, reserved/write rejection, stalls, early done and abort");$finish;
end
initial begin repeat(10000)@(negedge clk);$fatal(1,"watchdog");end
endmodule
