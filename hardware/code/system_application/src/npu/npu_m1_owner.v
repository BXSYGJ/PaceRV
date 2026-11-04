module npu_m1_owner(
 input wire clk,rst_n,loader_allowed,
 input wire l_valid,input wire[36:0]l_cmd,input wire[255:0]l_wdata,input wire l_rd_ready,
 output wire l_wready,l_rvalid,l_done,
 input wire n_valid,input wire[36:0]n_cmd,input wire[255:0]n_wdata,input wire n_rd_ready,
 output wire n_wready,n_rvalid,n_done,n_abort,
 output wire m_valid,output wire[36:0]m_cmd,output wire[255:0]m_wdata,output wire m_rd_ready,
 input wire m_wready,m_rvalid,m_done,m_abort,
 output wire idle,output reg protocol_error
);
 reg active,owner,done_seen,fault,reject_pulse,loader_done_seen;
 reg[36:0]cmd_q;
 reg[8:0]reads_left;
 wire selected_valid=owner?l_valid:n_valid;
 wire delivered=m_rvalid && m_rd_ready;
 wire complete=(done_seen || m_done) && (reads_left==0 || (reads_left==1 && delivered));
 wire choose_l=l_valid && loader_allowed;
 wire request=choose_l || n_valid;
 wire[36:0]request_cmd=choose_l?l_cmd:n_cmd;
 assign idle=!active && !fault;
 assign m_valid=active && !fault && !done_seen;
 assign m_cmd=cmd_q;
 assign m_wdata=owner?l_wdata:n_wdata;
 assign m_rd_ready=active && !fault && (owner?l_rd_ready:n_rd_ready);
 assign l_wready=active && !fault && owner && m_wready;
 assign l_rvalid=active && !fault && owner && m_rvalid && !m_abort;

 assign l_done=active && !fault && owner && done_seen && complete && !loader_done_seen && !m_abort;
 assign n_wready=active && !fault && !owner && m_wready;
 assign n_rvalid=active && !fault && !owner && m_rvalid && !m_abort;
 assign n_done=active && !owner && m_done || reject_pulse && !owner;
 assign n_abort=(active && !owner && m_abort) || (reject_pulse && !owner);
 always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin active<=0;owner<=0;done_seen<=0;reads_left<=0;protocol_error<=0;fault<=0;reject_pulse<=0;loader_done_seen<=0;cmd_q<=0;end
 else begin
 reject_pulse<=0;
 if(!active && !fault)begin
  if(request)begin
   owner<=choose_l;cmd_q<=request_cmd;done_seen<=0;loader_done_seen<=0;
   if(request_cmd[7:0]>15)begin fault<=1;protocol_error<=1;reject_pulse<=1;end
   else begin active<=1;reads_left<=request_cmd[36]?0:{1'b0,request_cmd[7:0]}+1;end
  end
 end else if(active)begin
  if(l_done)loader_done_seen<=1;
  if(m_done)done_seen<=1;
  if(delivered && reads_left!=0)reads_left<=reads_left-1;
  if(m_abort)begin active<=0;fault<=1;protocol_error<=1;end
  else if(complete && !selected_valid)active<=0;
 end
 end
 end
endmodule
