import argparse
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'sim'))
import run_sim as sim
v,_=sim._toolchain()
c=sim.Case(name='npu_m1_owner',tb=str(HERE/'tb_npu_m1_owner.sv'),rtl=[str(HERE/'npu_m1_owner.v')],timeout=120)
r=sim.run_case(c,v,argparse.Namespace(clean=False,trace=False,verbose=True))
print(r.output)
raise SystemExit(0 if r.ok else 1)
