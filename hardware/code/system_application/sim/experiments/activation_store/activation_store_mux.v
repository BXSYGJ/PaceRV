// Experimental two-client, one-outstanding abstract DDR mux.
module activation_store_mux (
 input wire clk,rst_n,
 input wire s0_cmd_valid,s0_cmd_write,input wire[31:0]s0_cmd_addr,
 output wire s0_cmd_ready,input wire s0_wr_valid,input wire[255:0]s0_wr_data,
 output wire s0_wr_ready,output wire s0_rd_valid,output wire[255:0]s0_rd_data,
 input wire s1_cmd_valid,s1_cmd_write,input wire[31:0]s1_cmd_addr,
 output wire s1_cmd_ready,input wire s1_wr_valid,input wire[255:0]s1_wr_data,
 output wire s1_wr_ready,output wire s1_rd_valid,output wire[255:0]s1_rd_data,
 output wire act_cmd_valid,act_cmd_write,output wire[31:0]act_cmd_addr,input wire act_cmd_ready,
 output wire act_wr_valid,output wire[255:0]act_wr_data,input wire act_wr_ready,
 input wire act_rd_valid,input wire[255:0]act_rd_data,
 output reg protocol_error
);
 localparam IDLE=0,OFFER=1,WRITE=2,READ=3;
 reg[1:0]state;
 reg owner,prefer,held_write;
 reg[31:0]held_addr;
 wire selected=s1_cmd_valid && (!s0_cmd_valid || prefer);
 wire pending=s0_cmd_valid || s1_cmd_valid;
 wire choose_write=selected ? s1_cmd_write : s0_cmd_write;
 wire command_fire=act_cmd_valid && act_cmd_ready;
 wire route_owner=(state==IDLE) ? selected : owner;
 wire read_route=(state==READ) || (command_fire && !act_cmd_write);
 assign act_cmd_valid=((state==IDLE) && pending) || state==OFFER;
 assign act_cmd_write=state==OFFER ? held_write : choose_write;
 assign act_cmd_addr=state==OFFER ? held_addr : selected ? s1_cmd_addr : s0_cmd_addr;
 assign s0_cmd_ready=((state==IDLE) || state==OFFER) && !route_owner && act_cmd_ready;
 assign s1_cmd_ready=((state==IDLE) || state==OFFER) && route_owner && act_cmd_ready;
 assign act_wr_valid=(state==WRITE) && (owner ? s1_wr_valid : s0_wr_valid);
 assign act_wr_data=owner ? s1_wr_data : s0_wr_data;
 assign s0_wr_ready=(state==WRITE) && !owner && act_wr_ready;
 assign s1_wr_ready=(state==WRITE) && owner && act_wr_ready;
 assign s0_rd_valid=act_rd_valid && read_route && !route_owner;
 assign s1_rd_valid=act_rd_valid && read_route && route_owner;
 assign s0_rd_data=act_rd_data;
 assign s1_rd_data=act_rd_data;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin state<=IDLE;owner<=0;prefer<=0;held_write<=0;held_addr<=0;protocol_error<=0;end
  else begin
   if(act_rd_valid && !read_route)protocol_error<=1;
   case(state)
    IDLE:if(pending)begin
     owner<=selected;held_write<=choose_write;held_addr<=act_cmd_addr;
     if(!act_cmd_ready)state<=OFFER;
     else if(choose_write)state<=WRITE;
     else if(act_rd_valid)begin prefer<=!selected;state<=IDLE;end
     else state<=READ;
    end
    OFFER:if(command_fire)begin
     if(held_write)state<=WRITE;
     else if(act_rd_valid)begin prefer<=!owner;state<=IDLE;end
     else state<=READ;
    end
    WRITE:if(act_wr_valid && act_wr_ready)begin prefer<=!owner;state<=IDLE;end
    READ:if(act_rd_valid)begin prefer<=!owner;state<=IDLE;end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
