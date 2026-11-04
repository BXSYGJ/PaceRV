"""Extract real replay and Mel bank RTL; reproduce layout bug and verify fix."""
import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'sim'))
import run_sim as sim
work=ROOT/'build/sim/mel_feature_handoff';work.mkdir(parents=True,exist_ok=True)
npu=(ROOT/'src/npu/npu_top.v').read_text(encoding='ascii')
mel=(ROOT/'src/mel/mel_engine.v').read_text(encoding='ascii')
replay=npu.split('    reg [14:0] feat_addr;',1)[1].split('    // -----------------------------------------------------------------------',1)[0]
replay='    reg [14:0] feat_addr;'+replay
replay=replay.replace('    wire [15:0] conv1_ingress_max_row;','')
wrapper='''module feature_replay_slice #(parameter FEATURE_FRAME_MAJOR=0)(
 input wire clk,rst_n,conv1_start,input wire[15:0]conv1_ingress_max_row,
 output wire[14:0]feat_rd_addr,output wire feat_rd_en,output wire dv);
'''+replay+'\nassign dv=feat_dv;\nendmodule\n'
replay_path=work/'feature_replay_slice.sv';replay_path.write_text(wrapper,encoding='ascii')
bank='    reg [15:0] spec_bank'+mel.split('    reg [15:0] spec_bank',1)[1].split('    assign feat_rd_data = bank_q[7:0];',1)[0]+'    assign feat_rd_data = bank_q[7:0];'
wrapper='''module mel_bank_slice(input wire clk,input wire[14:0]feat_rd_addr,output wire[7:0]feat_rd_data);
wire db_active=0,std_active=0,ex_active=0,run_active=0,mel_valid=0,db_wr_en=0,std_feat_wr_en=0;
wire[14:0]db_spec_rd_addr=0,std_db_rd_addr=0,ex_rd_addr=0,db_wr_addr=0,std_feat_wr_addr=0;
wire[8:0]frm_out=0;wire[5:0]mel_ch=0;wire[15:0]mel_q88=0,db_wr_data=0;wire[7:0]std_feat_wr_data=0;
'''+bank+'\nendmodule\n'
bank_path=work/'mel_bank_slice.sv';bank_path.write_text(wrapper,encoding='ascii')
tb=work/'tb_mel_handoff.sv'
tb.write_text('''module tb_mel_handoff;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,conv1_start=0;reg[15:0]credit=65535;
wire[14:0]old_addr,new_addr;wire old_en,new_en,old_dv,new_dv;
wire[7:0]old_data,new_data;
feature_replay_slice #(.FEATURE_FRAME_MAJOR(0)) old_replay(clk,rst_n,conv1_start,credit,old_addr,old_en,old_dv);
feature_replay_slice #(.FEATURE_FRAME_MAJOR(1)) new_replay(clk,rst_n,conv1_start,credit,new_addr,new_en,new_dv);
mel_bank_slice old_bank(clk,old_addr,old_data);
mel_bank_slice new_bank(clk,new_addr,new_data);
integer m,t,count=0,mismatches=0,above127=0;
reg[7:0]expected;
initial begin
 for(t=0;t<258;t=t+1)for(m=0;m<64;m=m+1)begin
  if(64+t*64+m<16384)begin
   old_bank.spec_bank_lo[64+t*64+m]=(m*13+t*7)%256;
   new_bank.spec_bank_lo[64+t*64+m]=(m*13+t*7)%256;
  end else begin
   old_bank.spec_bank_hi[64+t*64+m-16384]=(m*13+t*7)%256;
   new_bank.spec_bank_hi[64+t*64+m-16384]=(m*13+t*7)%256;
  end
 end
 repeat(3)@(negedge clk);rst_n=1;conv1_start=1;
 @(negedge clk);conv1_start=0;
 wait(count==16512);@(negedge clk);
 if(mismatches==0 || above127==0)$fatal(1,"counterexample or uint8 coverage absent");
 if(old_en || new_en || old_dv || new_dv)$fatal(1,"feature stream did not stop");
 $display("RESULT: PASS real Mel bank/replay slices all 16512 bytes; legacy mismatches=%0d uint8_high=%0d",mismatches,above127);$finish;
end
always @(posedge clk)if(rst_n)begin
 if(old_dv!==new_dv || old_en!==new_en)$fatal(1,"mapping altered cadence");
 if(new_dv)begin
  expected=((count/258)*13+(count%258)*7)%256;
  if(new_data!==expected)$fatal(1,"mapped Mel data mismatch index=%0d got=%0d expected=%0d",count,new_data,expected);
  if(count==1 && (old_data!==8'd13 || new_data!==8'd7))$fatal(1,"minimal layout counterexample changed");
  if(old_data!==expected)mismatches=mismatches+1;
  if(new_data>127)above127=above127+1;
  count=count+1;
 end
end
initial begin repeat(20000)@(negedge clk);$fatal(1,"handoff timeout");end
endmodule
''',encoding='ascii')
addresses=[(i%258)*64+i//258 for i in range(16512)]
assert len(set(addresses))==16512 and min(addresses)==0 and max(addresses)==16511
tool,_=sim._toolchain()
result=sim.run_case(sim.Case(name='mel_feature_handoff',tb=str(tb),rtl=[str(replay_path),str(bank_path)],timeout=90),tool,argparse.Namespace(clean=False,trace=False,verbose=True))
print(result.output)
report={'result':'PASS' if result.ok else 'FAIL','scope':'Actual extracted NPU replay and Mel bank mux/synchronous read RTL; other Mel phases tied idle',
 'mapping':'time*64+mel = {feat_col,feat_row[5:0]}; Mel applies +64 internally',
 'addresses':16512,'bijection':True,'minimal_counterexample':{'npu_linear_index':1,'expected_mel':0,'expected_time':1,'legacy_logical_address':1,'correct_logical_address':64,'legacy_byte':13,'correct_byte':7},
 'sources':[{'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}for p in [ROOT/'src/npu/npu_top.v',ROOT/'src/mel/mel_engine.v',replay_path,bank_path,tb]],
 'log':str(result.log_path),'log_sha256':hashlib.sha256(Path(result.log_path).read_bytes()).hexdigest()}
(ROOT/'reports/mel_feature_handoff_validation_20261103.json').write_text(json.dumps(report,indent=2)+'\n',encoding='ascii')
raise SystemExit(0 if result.ok else 1)
