"""Run isolated narrow-RAM interruption/reset regression; no production edits."""
import argparse
from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
sys.path.insert(0,str(ROOT/'sim'))
import run_sim as sim
tool,_=sim._toolchain()
case=sim.Case(name='activation_narrow_reset',tb=str(HERE/'tb_activation_narrow_reset.sv'),
              rtl=[str(HERE/'activation_row_store_narrow.v')],timeout=180)
r=sim.run_case(case,tool,argparse.Namespace(clean=False,trace=False,verbose=True))
print(r.output);print('ok='+str(r.ok)+' log='+str(r.log_path))
raise SystemExit(0 if r.ok else 1)
