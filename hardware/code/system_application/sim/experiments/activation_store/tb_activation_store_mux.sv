module tb_activation_store_mux;
reg clk=0;always #5 clk=~clk;
reg rst_n=0;
reg[1:0]cv=0,cw=0,wv=0;reg[31:0]ca[0:1];reg[255:0]wd[0:1];
wire[1:0]cr,wr,rv;wire[255:0]rd[0:1];
wire act_cmd_valid,act_cmd_write,act_wr_valid,protocol_error;
wire[31:0]act_cmd_addr;wire[255:0]act_wr_data;
reg act_cmd_ready=0,act_wr_ready=0,delayed_valid=0;
reg[255:0]delayed_data=0;
wire immediate=act_cmd_valid&&act_cmd_ready&&!act_cmd_write&&act_cmd_addr[5];
wire act_rd_valid=delayed_valid||immediate;
wire[255:0]act_rd_data=immediate ? {8{act_cmd_addr}} : delayed_data;
activation_store_mux dut(.clk(clk),.rst_n(rst_n),
 .s0_cmd_valid(cv[0]),.s0_cmd_write(cw[0]),.s0_cmd_addr(ca[0]),.s0_cmd_ready(cr[0]),
 .s0_wr_valid(wv[0]),.s0_wr_data(wd[0]),.s0_wr_ready(wr[0]),.s0_rd_valid(rv[0]),.s0_rd_data(rd[0]),
 .s1_cmd_valid(cv[1]),.s1_cmd_write(cw[1]),.s1_cmd_addr(ca[1]),.s1_cmd_ready(cr[1]),
 .s1_wr_valid(wv[1]),.s1_wr_data(wd[1]),.s1_wr_ready(wr[1]),.s1_rd_valid(rv[1]),.s1_rd_data(rd[1]),
 .act_cmd_valid(act_cmd_valid),.act_cmd_write(act_cmd_write),.act_cmd_addr(act_cmd_addr),.act_cmd_ready(act_cmd_ready),
 .act_wr_valid(act_wr_valid),.act_wr_data(act_wr_data),.act_wr_ready(act_wr_ready),
 .act_rd_valid(act_rd_valid),.act_rd_data(act_rd_data),.protocol_error(protocol_error));
integer cyc=0,delay_r=-1;reg[31:0]pending_addr;reg pending_write=0;
integer commands=0,read_results=0,write_results=0,completed=0;
reg stalled=0;reg[32:0]held_cmd;
always @(negedge clk)begin
 cyc=cyc+1;act_cmd_ready=cyc%7==0;act_wr_ready=cyc%11==0;
 delayed_valid=0;
 if(delay_r==0)begin delayed_valid=1;delayed_data={8{pending_addr}};delay_r=-1;end
 else if(delay_r>0)delay_r=delay_r-1;
 if(cyc>20000)$fatal(1,"mux timeout");
end
always @(posedge clk)begin
 if(stalled && (!act_cmd_valid||{act_cmd_write,act_cmd_addr}!==held_cmd))$fatal(1,"command unstable");
 stalled<=act_cmd_valid&&!act_cmd_ready;held_cmd<={act_cmd_write,act_cmd_addr};
 if(protocol_error)$fatal(1,"protocol routing");
 if(act_cmd_valid&&act_cmd_ready)begin
  if(pending_write||delay_r>=0)$fatal(1,"overlapping command");
  commands=commands+1;pending_addr=act_cmd_addr;
  if(act_cmd_write)pending_write=1;
  else if(!immediate)delay_r=4;
 end
 if(act_wr_valid&&act_wr_ready)begin
  if(!pending_write||act_wr_data!=={8{pending_addr}})$fatal(1,"write owner/data");
  pending_write=0;write_results=write_results+1;
 end
 if(act_rd_valid)read_results=read_results+1;
 if(rv==3 || wr==3)$fatal(1,"response broadcast to both clients");
end
task automatic client(input integer id);
 integer k;reg[31:0]addr;reg is_write;
 begin
 for(k=0;k<12;k=k+1)begin
  @(negedge clk);addr=id*4096+k*32;is_write=(k+id)%2==0;
  ca[id]=addr;cw[id]=is_write;cv[id]=1;
  @(posedge clk);while(!cr[id])@(posedge clk);
  // A zero-latency R is sampled on this command handshake.
  if(!is_write&&rv[id])begin
   if(rd[id]!=={8{addr}})$fatal(1,"immediate read owner");
   @(negedge clk);cv[id]=0;
  end else begin
   @(negedge clk);cv[id]=0;
   if(is_write)begin
    repeat(id+1)@(negedge clk);
    wv[id]=1;wd[id]={8{addr}};
    @(posedge clk);while(!wr[id])@(posedge clk);
    @(negedge clk);wv[id]=0;
   end else begin
    @(posedge clk);while(!rv[id])@(posedge clk);
    if(rd[id]!=={8{addr}})$fatal(1,"delayed read owner");
   end
  end
 end
 completed=completed+1;
 end
endtask
initial begin
 #21;rst_n=1;
 fork client(0);client(1);join
 repeat(3)@(negedge clk);
 if(completed!=2||commands!=24||write_results!=12||read_results!=12)$fatal(1,"mux counts");
 $display("RESULT: PASS activation store mux: 24 transactions, mixed immediate/delayed R");$finish;
end
endmodule
