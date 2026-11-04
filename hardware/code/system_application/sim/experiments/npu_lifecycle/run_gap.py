import sys,argparse
from pathlib import Path
sys.path.insert(0,str(Path('sim').resolve()))
import run_sim as r
c=r.Case(name='gap_lifecycle',tb=str(Path('sim/experiments/npu_lifecycle/tb_gap_lifecycle.sv').resolve()),rtl=['sim/experiments/npu_lifecycle/gap_unit.v','sim/experiments/npu_lifecycle/gap_unit_original.v'],timeout=180)
v,_=r._toolchain();x=r.run_case(c,v,argparse.Namespace(clean=False,trace=False,verbose=True))
print(x.output);sys.exit(0 if x.ok else 1)
