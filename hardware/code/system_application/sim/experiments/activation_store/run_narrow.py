"""Cycle-by-cycle miter: original versus bounded canonical-RAM candidate."""
import argparse
import sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / 'sim'))
import run_sim as sim

text = (HERE / 'tb_activation_row_store_dynamic.sv').read_text(encoding='ascii')
text = text.replace('module tb_activation_row_store_dynamic;', 'module tb_activation_row_store_narrow;')
ports = ['replay_row','in_ready','cmd_valid','cmd_write','cmd_addr','wr_valid','wr_data','out_valid','out_data','row_done','done','protocol_error']
widths = {'replay_row':16,'cmd_addr':32,'wr_data':256,'out_data':8}
block = '\n'.join('wire '+('['+str(widths[p]-1)+':0] ' if p in widths else '')+'ref_'+p+';' for p in ports)
all_ports = ['clk','rst_n','start','read_mode','row_credit','cfg_layer','cfg_base','in_valid','in_data','cmd_ready','wr_ready','rd_valid','rd_data','out_ready'] + ports
block += '\nactivation_row_store_dynamic reference('+','.join('.'+p+'('+('ref_' if p in ports else '')+p+')' for p in all_ports)+');\n'
block += 'always @(negedge clk)if(rst_n)begin\n'
for p in ports:
    # Uninitialized read data is only meaningful when its associated valid fires.
    guard = 'out_valid && ' if p=='out_data' else ('wr_valid && ' if p=='wr_data' else '')
    block += 'if('+guard+p+' !== ref_'+p+')$fatal(1,"cycle miter '+p+'");\n'
block += 'end\n'
text = text.replace('activation_row_store_dynamic dut(.*);', 'activation_row_store_narrow dut(.*);\n'+block)
text = text.replace('RESULT: PASS activation dynamic true geometries', 'RESULT: PASS bounded canonical-RAM cycle miter all true geometries')
assets=ROOT/'build/sim/activation_row_store_narrow_assets'
assets.mkdir(parents=True,exist_ok=True)
tb=assets/'tb_activation_row_store_narrow.sv';tb.write_text(text,encoding='ascii')
v,_=sim._toolchain()
c=sim.Case(name='activation_row_store_narrow',tb=str(tb),rtl=[str(HERE/'activation_row_store_dynamic.v'),str(HERE/'activation_row_store_narrow.v')],timeout=180)
r=sim.run_case(c,v,argparse.Namespace(clean=False,trace=False,verbose=True))
print(r.output);print('ok='+str(r.ok)+' log='+str(r.log_path)+' detail='+r.detail)
raise SystemExit(0 if r.ok else 1)
