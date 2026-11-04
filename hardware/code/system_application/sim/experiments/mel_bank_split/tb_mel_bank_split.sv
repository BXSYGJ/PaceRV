module tb_mel_bank_split;
reg clk=0;always #5 clk=~clk;
reg db_active=0,std_active=0,ex_active=0,run_active=0,mel_valid=0,db_wr_en=0,std_feat_wr_en=0;
reg[14:0]db_spec_rd_addr=0,std_db_rd_addr=0,ex_rd_addr=0,db_wr_addr=0,std_feat_wr_addr=0;
reg[13:0]feat_rd_addr=0;reg[8:0]frm_out=0;reg[5:0]mel_ch=0;
reg[15:0]mel_q88=0,db_wr_data=0;reg[7:0]std_feat_wr_data=0;
wire[15:0]old_result,new_result;
reference_bank old_bank(clk,db_active,std_active,ex_active,run_active,mel_valid,db_wr_en,std_feat_wr_en,db_spec_rd_addr,std_db_rd_addr,ex_rd_addr,db_wr_addr,std_feat_wr_addr,feat_rd_addr,frm_out,mel_ch,mel_q88,db_wr_data,std_feat_wr_data,old_result);
split_bank new_bank(clk,db_active,std_active,ex_active,run_active,mel_valid,db_wr_en,std_feat_wr_en,db_spec_rd_addr,std_db_rd_addr,ex_rd_addr,db_wr_addr,std_feat_wr_addr,feat_rd_addr,frm_out,mel_ch,mel_q88,db_wr_data,std_feat_wr_data,new_result);
integer i,epoch,addr,checks=0;reg compare_on=0;reg[31:0]random_state=32'hbca25781;
task step;begin @(posedge clk);#1;if(compare_on)begin
 if(old_result!==new_result)$fatal(1,"bank mismatch check=%0d old=%h new=%h",checks,old_result,new_result);
 checks=checks+1;end @(negedge clk);end endtask
initial begin
 @(negedge clk);
 // Initialize every valid physical word through the production first writer.
 run_active=1;mel_valid=1;
 for(i=0;i<16576;i=i+1)begin frm_out=i/64;mel_ch=i%64;mel_q88=i^16'hc35a;step;end
 run_active=0;mel_valid=0;compare_on=1;
 for(epoch=0;epoch<2;epoch=epoch+1)begin
  // Full reads across the 16383/16384 split through both read roles.
  db_active=1;std_active=0;
  for(i=0;i<16576;i=i+1)begin db_spec_rd_addr=i;step;end
  db_active=0;std_active=1;
  for(i=0;i<16576;i=i+1)begin std_db_rd_addr=i;step;end
  std_active=0;ex_active=1;
  for(i=0;i<16576;i=i+1)begin ex_rd_addr=i;step;end
  ex_active=0;
  for(i=0;i<16512;i=i+1)begin feat_rd_addr=i;step;end
  // State/enable combinations also check the legacy priority if overlapped.
  for(i=0;i<40000;i=i+1)begin
   random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
   addr=random_state%16576;
   run_active=random_state[0];mel_valid=random_state[1];db_active=random_state[2];db_wr_en=random_state[3];
   std_active=random_state[4];std_feat_wr_en=random_state[5];ex_active=random_state[6];
   frm_out=addr/64;mel_ch=addr%64;db_wr_addr=addr;std_feat_wr_addr=random_state%16512;
   db_spec_rd_addr=addr;std_db_rd_addr=addr;ex_rd_addr=addr;feat_rd_addr=random_state%16512;
   mel_q88=random_state[31:16];db_wr_data=random_state[15:0];std_feat_wr_data=random_state[23:16];step;
  end
  run_active=0;mel_valid=0;db_active=0;db_wr_en=0;std_active=0;std_feat_wr_en=0;ex_active=0;
 end
 $display("RESULT: PASS split Mel bank %0d cycle comparisons, two no-reset epochs",checks);$finish;
end
initial begin #4000000;$fatal(1,"timeout");end
endmodule
