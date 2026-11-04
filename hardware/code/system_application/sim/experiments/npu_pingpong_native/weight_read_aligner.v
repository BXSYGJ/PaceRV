// Experimental adapter: byte-offset WDMA reads to aligned native bursts.
module weight_read_aligner(
 input wire clk,rst_n,input wire up_valid,input wire[36:0]up_cmd,
 output wire[255:0]up_data,output wire up_rd_valid,up_done,
 output wire dn_valid,output wire[36:0]dn_cmd,
 input wire[255:0]dn_data,input wire dn_rd_valid,dn_done
);
 localparam IDLE=0,ISSUE=1,GAP=2,EMIT=3,WAIT_LOW=4;
 reg[2:0]state;reg[4:0]offset,wanted,total,received,emitted,chunk,chunk_received;
 reg[27:0]addr;reg[255:0]beats[0:16];
 wire[511:0]pair={beats[emitted+1],beats[emitted]};
 assign up_data=pair>>(offset*8);
 assign up_rd_valid=state==EMIT;
 assign up_done=state==EMIT && emitted==wanted-1;
 assign dn_valid=state==ISSUE;
 assign dn_cmd={1'b0,addr,3'd0,(chunk-5'd1)};
 always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;offset<=0;wanted<=0;total<=0;received<=0;emitted<=0;chunk<=0;chunk_received<=0;addr<=0;end
 else case(state)
 IDLE:if(up_valid)begin
 offset<=up_cmd[12:8];wanted<={1'b0,up_cmd[3:0]}+1;
 total<={1'b0,up_cmd[3:0]}+1+(up_cmd[12:8]!=0);
 chunk<=({1'b0,up_cmd[3:0]}+1+(up_cmd[12:8]!=0)>16)?16:({1'b0,up_cmd[3:0]}+1+(up_cmd[12:8]!=0));
 received<=0;emitted<=0;chunk_received<=0;addr<={up_cmd[35:13],5'd0}+28'h100000;state<=ISSUE;
 end
 ISSUE:begin
 if(dn_rd_valid)begin beats[received]<=dn_data;received<=received+1;chunk_received<=chunk_received+1;end
 if(dn_done)begin
 if(chunk_received+(dn_rd_valid?1:0)!=chunk)$fatal(1,"aligner truncated native burst");
 state<=GAP;addr<=addr+chunk*32;
 end
 end
 GAP:begin
 if(received==total)state<=EMIT;
 else begin chunk<=total-received;chunk_received<=0;state<=ISSUE;end
 end
 EMIT:if(emitted==wanted-1)state<=WAIT_LOW;else emitted<=emitted+1;
 WAIT_LOW:if(!up_valid)state<=IDLE;
 default:state<=IDLE;
 endcase
 end
endmodule
