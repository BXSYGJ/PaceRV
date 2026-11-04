"""Immediate-R, busy-start and unexpected-R/reset miter, isolated from production."""
import argparse
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / 'sim'))
import run_sim as sim


def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('Review boundary TB transformation: ' + old[:80])
    return text.replace(old, new)


text = (HERE / 'tb_activation_row_store_dynamic.sv').read_text(encoding='ascii')
text = once(text, 'module tb_activation_row_store_dynamic;', 'module tb_activation_store_boundaries;')
text = once(text, 'reg cmd_ready=0,wr_ready=0,rd_valid=0,out_ready=0;\nreg[255:0] rd_data=0;', '''reg cmd_ready=0,wr_ready=0,out_ready=0;
reg inject_r=0,expect_error=0;
wire immediate=cmd_valid && cmd_ready && !cmd_write;
wire rd_valid=immediate || inject_r;
wire[255:0] rd_data=immediate ? ddr[cmd_addr/32] : 256'hbad;
integer immediate_reads=0,busy_starts=0;''')
text = once(text, ' out_ready=(cycle%3!=0); rd_valid=0;\n if(delay_r==0) begin rd_valid=1; rd_data=ddr[pending_addr/32]; delay_r=-1; end\n else if(delay_r>0) delay_r=delay_r-1;', ' out_ready=(cycle%3!=0);')
text = once(text, '  else begin delay_r=2; reads=reads+1; end', '  else begin reads=reads+1;immediate_reads=immediate_reads+1; end')
text = once(text, ' if(protocol_error) $fatal(1,"unexpected R response");', ' if(protocol_error && !expect_error) $fatal(1,"unexpected R response");')
text = once(text, '  repeat(7)@(negedge clk);', '''  // Busy CREDIT ignores start, including invalid live configuration.
  repeat(2)@(negedge clk);start=1;
  @(negedge clk);start=0;busy_starts=busy_starts+1;
  repeat(4)@(negedge clk);''')
text = once(text, '      in_valid=1;in_data=(row*73+col*19+(grp*16+lane)*7)%256;', '''      if(row==0 && grp==0 && col==0 && lane==0)begin start=1;busy_starts=busy_starts+1;end
      in_valid=1;in_data=(row*73+col*19+(grp*16+lane)*7)%256;''')
text = once(text, '      @(negedge clk);in_valid=0;', '      @(negedge clk);in_valid=0;start=0;')
text = once(text, '  row_credit=1;', '''  row_credit=1;
  wait(out_valid);@(negedge clk);start=1;busy_starts=busy_starts+1;
  @(negedge clk);start=0;''')
text = once(text, ' $display("RESULT: PASS activation dynamic true geometries");', ''' if(immediate_reads!=10816 || busy_starts!=9)$fatal(1,"boundary coverage counts");
 // Repeated/unsolicited R in IDLE must latch the protocol error, without output.
 expect_error=1;inject_r=1;@(negedge clk);inject_r=0;
 if(!protocol_error || out_valid || cmd_valid || wr_valid)$fatal(1,"unexpected R not flagged");
 repeat(2)@(negedge clk);
 inject_r=1;@(negedge clk);inject_r=0;
 if(!protocol_error)$fatal(1,"duplicate R lost sticky error");
 // Only reset recovery is asserted here; no automatic transaction retry claim.
 rst_n=0;repeat(2)@(negedge clk);rst_n=1;
 @(negedge clk);expect_error=0;
 if(protocol_error || out_valid || cmd_valid || wr_valid || done)$fatal(1,"reset failed to quiesce store");
 cfg_layer=2;cfg_base=32'h00080000;read_mode=1;row_credit=0;start=1;
 @(negedge clk);start=0;repeat(3)@(negedge clk);
 if(protocol_error || cmd_valid || out_valid || replay_row!=0)$fatal(1,"post-reset CREDIT contract");
 $display("RESULT: PASS immediate R all geometries, narrow cycle miter, 9 busy starts (FILL/CREDIT/EMIT), duplicate R sticky error and reset contract; immediate_reads=%0d",immediate_reads);''')

ports = ['replay_row','in_ready','cmd_valid','cmd_write','cmd_addr','wr_valid','wr_data','out_valid','out_data','row_done','done','protocol_error']
widths = {'replay_row':16,'cmd_addr':32,'wr_data':256,'out_data':8}
block = '\n'.join('wire '+('['+str(widths[p]-1)+':0] ' if p in widths else '')+'ref_'+p+';' for p in ports)
all_ports = ['clk','rst_n','start','read_mode','row_credit','cfg_layer','cfg_base','in_valid','in_data','cmd_ready','wr_ready','rd_valid','rd_data','out_ready'] + ports
block += '\nactivation_row_store_dynamic reference('+','.join('.'+p+'('+('ref_' if p in ports else '')+p+')' for p in all_ports)+');\n'
block += 'always @(negedge clk)if(rst_n)begin\n'
for p in ports:
    guard = 'out_valid && ' if p=='out_data' else ('wr_valid && ' if p=='wr_data' else '')
    block += 'if('+guard+'('+p+' !== ref_'+p+'))$fatal(1,"boundary cycle miter '+p+'");\n'
block += 'end\n'
text = once(text, 'activation_row_store_dynamic dut(.*);', 'activation_row_store_narrow dut(.*);\n'+block)
assets = ROOT / 'build/sim/activation_store_boundaries_assets'
assets.mkdir(parents=True, exist_ok=True)
tb = assets / 'tb_activation_store_boundaries.sv'
tb.write_text(text, encoding='ascii')
rtl = [HERE/'activation_row_store_dynamic.v', HERE/'activation_row_store_narrow.v']
(assets/'inputs.json').write_text(json.dumps([{'path':str(p), 'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in rtl+[tb]], indent=2), encoding='ascii')
tool, _ = sim._toolchain()
result = sim.run_case(sim.Case(name='activation_store_boundaries', tb=str(tb), rtl=[str(p) for p in rtl], timeout=180), tool,
                      argparse.Namespace(clean=False, trace=False, verbose=True))
print(result.output)
print('ok='+str(result.ok)+' log='+str(result.log_path)+' detail='+result.detail)
raise SystemExit(0 if result.ok else 1)
