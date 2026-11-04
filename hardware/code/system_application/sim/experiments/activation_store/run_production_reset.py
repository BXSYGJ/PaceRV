"""Run the eight-state reset TB against actual production activation RTL."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
sys.path.insert(0,str(ROOT/'sim'))
import run_sim as sim
work=ROOT/'build/sim/activation_production_reset'
work.mkdir(parents=True,exist_ok=True)
source=ROOT/'src/npu/activation_row_store_dynamic.v'
text=(HERE/'tb_activation_narrow_reset.sv').read_text(encoding='ascii')
old='activation_row_store_narrow dut(.*);'
if text.count(old)!=1:raise RuntimeError('Review production TB adaptation')
text=text.replace(old,'activation_row_store_dynamic dut(.*);')
text=text.replace('module tb_activation_narrow_reset;','module tb_activation_production_reset;')
text=text.replace('RESULT: PASS narrow reset','RESULT: PASS production reset')
tb=work/'tb_activation_production_reset.sv'
tb.write_text(text,encoding='ascii')
tool,_=sim._toolchain()
case=sim.Case(name=work.name,tb=str(tb),rtl=[str(source)],timeout=180)
r=sim.run_case(case,tool,argparse.Namespace(clean=False,trace=False,verbose=True))
print(r.output);print('ok='+str(r.ok)+' log='+str(r.log_path))
if r.ok:
    report=ROOT/'reports/activation_narrow_reset_validation_20261101.json'
    evidence=json.loads(report.read_text())
    evidence['production_rerun']={
        'result':'PASS', 'source':source.relative_to(ROOT).as_posix(),
        'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
        'testbench':tb.relative_to(ROOT).as_posix(),
        'testbench_sha256':hashlib.sha256(tb.read_bytes()).hexdigest(),
        'log':r.log_path.relative_to(ROOT).as_posix(),
        'log_sha256':hashlib.sha256(r.log_path.read_bytes()).hexdigest(),
        'passed_scenarios':[line for line in r.output.splitlines() if line.startswith('PASS reset phase=')],
        'adaptation':'DUT module name and TB/result names only; all eight-state stimulus/assertions unchanged',
        'boundary':'Same coordinated pending-DDR cancellation as candidate regression; no physical or full-top reset claim'}
    if len(evidence['production_rerun']['passed_scenarios'])!=8:
        raise RuntimeError('Incomplete production reset scenario count')
    report.write_text(json.dumps(evidence,indent=2)+'\n',encoding='ascii')
raise SystemExit(0 if r.ok else 1)
