module tb_wdma_diff;
reg clk=0, rst_n=0,start=0;
reg [3:0] layer_id=0;
reg rd_ready=1,rd_valid=0,rd_done=0,w_ready=0,grp_advance=0;
reg [255:0] rd_data=0;
integer cycle_no=0, layer_no, k, model_state=0,beat_idx=0,beat_count=0,commands=0,weights=0,contracts=0,groups=0;
reg [27:0] addr;
reg [31:0] rng=32'h1abc9327;
wire [0:0] rd_cmd_valid_a;
wire [0:0] rd_cmd_valid_b;
wire [36:0] rd_cmd_a;
wire [36:0] rd_cmd_b;
wire [0:0] w_valid_a;
wire [0:0] w_valid_b;
wire [127:0] w_data_a;
wire [127:0] w_data_b;
wire [0:0] grp_start_a;
wire [0:0] grp_start_b;
wire [0:0] b_valid_a;
wire [0:0] b_valid_b;
wire [31:0] bias_s32_a;
wire [31:0] bias_s32_b;
wire [0:0] m_valid_a;
wire [0:0] m_valid_b;
wire [31:0] m_s32_a;
wire [31:0] m_s32_b;
wire [0:0] s_valid_a;
wire [0:0] s_valid_b;
wire [6:0] shift_a;
wire [6:0] shift_b;
wire [0:0] busy_a;
wire [0:0] busy_b;
wire [0:0] done_a;
wire [0:0] done_b;
wdma_corrected original(.clk(clk),.rst_n(rst_n),.start(start),.layer_id(layer_id),.rd_ready(rd_ready),.rd_data(rd_data),.rd_valid(rd_valid),.rd_done(rd_done),.w_ready(w_ready),.grp_advance(grp_advance),.rd_cmd_valid(rd_cmd_valid_a),.rd_cmd(rd_cmd_a),.w_valid(w_valid_a),.w_data(w_data_a),.grp_start(grp_start_a),.b_valid(b_valid_a),.bias_s32(bias_s32_a),.m_valid(m_valid_a),.m_s32(m_s32_a),.s_valid(s_valid_a),.shift(shift_a),.busy(busy_a),.done(done_a));
wdma candidate(.clk(clk),.rst_n(rst_n),.start(start),.layer_id(layer_id),.rd_ready(rd_ready),.rd_data(rd_data),.rd_valid(rd_valid),.rd_done(rd_done),.w_ready(w_ready),.grp_advance(grp_advance),.rd_cmd_valid(rd_cmd_valid_b),.rd_cmd(rd_cmd_b),.w_valid(w_valid_b),.w_data(w_data_b),.grp_start(grp_start_b),.b_valid(b_valid_b),.bias_s32(bias_s32_b),.m_valid(m_valid_b),.m_s32(m_s32_b),.s_valid(s_valid_b),.shift(shift_b),.busy(busy_b),.done(done_b));

task tick;
begin
 rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
 w_ready=rng[0]|rng[2]; grp_advance=rng[5];
 rd_valid=0;rd_done=0;
 if (!rst_n) model_state=0;
 else case(model_state)
 0: if(rd_cmd_valid_a) begin
     addr=rd_cmd_a[35:8];beat_count=rd_cmd_a[7:0]+1;beat_idx=0;model_state=1;commands=commands+1;
    end
 1: if(rng[3]|rng[6]) begin
     rd_valid=1;
     for(k=0;k<32;k=k+1)rd_data[k*8+:8]=((addr+beat_idx*32+k) ^ ((addr+beat_idx*32+k)>>8) ^ 8'h63);
     beat_idx=beat_idx+1;
     if(beat_idx==beat_count)model_state=2;
    end
 2: begin rd_done=1;model_state=3;end
 3: if(!rd_cmd_valid_a)model_state=0;
 endcase
 #5;clk=1;#1;cycle_no=cycle_no+1;
 if(rd_cmd_valid_a !== rd_cmd_valid_b) $fatal(1,"DIFF layer=%0d cycle=%0d rd_cmd_valid a=%h b=%h",layer_no,cycle_no,rd_cmd_valid_a,rd_cmd_valid_b);
 if(w_valid_a !== w_valid_b) $fatal(1,"DIFF layer=%0d cycle=%0d w_valid a=%h b=%h",layer_no,cycle_no,w_valid_a,w_valid_b);
 if(grp_start_a !== grp_start_b) $fatal(1,"DIFF layer=%0d cycle=%0d grp_start a=%h b=%h",layer_no,cycle_no,grp_start_a,grp_start_b);
 if(b_valid_a !== b_valid_b) $fatal(1,"DIFF layer=%0d cycle=%0d b_valid a=%h b=%h",layer_no,cycle_no,b_valid_a,b_valid_b);
 if(m_valid_a !== m_valid_b) $fatal(1,"DIFF layer=%0d cycle=%0d m_valid a=%h b=%h",layer_no,cycle_no,m_valid_a,m_valid_b);
 if(s_valid_a !== s_valid_b) $fatal(1,"DIFF layer=%0d cycle=%0d s_valid a=%h b=%h",layer_no,cycle_no,s_valid_a,s_valid_b);
 if(busy_a !== busy_b) $fatal(1,"DIFF layer=%0d cycle=%0d busy a=%h b=%h",layer_no,cycle_no,busy_a,busy_b);
 if(done_a !== done_b) $fatal(1,"DIFF layer=%0d cycle=%0d done a=%h b=%h",layer_no,cycle_no,done_a,done_b);
 if(rd_cmd_valid_a && (rd_cmd_a !== rd_cmd_b)) $fatal(1,"DIFF layer=%0d cycle=%0d rd_cmd a=%h b=%h",layer_no,cycle_no,rd_cmd_a,rd_cmd_b);
 if(w_valid_a && (w_data_a !== w_data_b)) $fatal(1,"DIFF layer=%0d cycle=%0d w_data a=%h b=%h",layer_no,cycle_no,w_data_a,w_data_b);
 if(b_valid_a && (bias_s32_a !== bias_s32_b)) $fatal(1,"DIFF layer=%0d cycle=%0d bias_s32 a=%h b=%h",layer_no,cycle_no,bias_s32_a,bias_s32_b);
 if(m_valid_a && (m_s32_a !== m_s32_b)) $fatal(1,"DIFF layer=%0d cycle=%0d m_s32 a=%h b=%h",layer_no,cycle_no,m_s32_a,m_s32_b);
 if(s_valid_a && (shift_a !== shift_b)) $fatal(1,"DIFF layer=%0d cycle=%0d shift a=%h b=%h",layer_no,cycle_no,shift_a,shift_b);
 if(w_valid_a&&w_ready)weights=weights+1;
 if(b_valid_a||m_valid_a||s_valid_a)contracts=contracts+1;
 if(grp_start_a)groups=groups+1;
 #4;clk=0;
end
endtask
initial begin
 for(layer_no=0;layer_no<6;layer_no=layer_no+1)begin
  rst_n=0;start=0;layer_id=layer_no;commands=0;weights=0;contracts=0;groups=0;
  repeat(4)tick;
  rst_n=1;tick;start=1;tick;start=0;
  repeat(350000)tick;
  $display("EQUIVALENT layer=%0d cycles=350000 commands=%0d weights=%0d contracts=%0d groups=%0d done=%0d busy=%0d state=%0d",layer_no,commands,weights,contracts,groups,done_a,busy_a,original.state);
 end
 $display("RESULT: PASS (6 layers bounded cycle equivalence; not functional correctness)");$finish;
end
endmodule
