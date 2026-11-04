import sys,argparse
from pathlib import Path
sys.path.insert(0,str(Path('sim').resolve()))
import run_sim as r
c=r.Case(name='activation_row_store_dynamic',tb=str(Path('sim/experiments/activation_store/tb_activation_row_store_dynamic.sv').resolve()),rtl=['sim/experiments/activation_store/activation_row_store_dynamic.v'],timeout=180)
v,_=r._toolchain()
x=r.run_case(c,v,argparse.Namespace(clean=False,trace=False,verbose=True))
print(x.output); print(x)
sys.exit(0 if x.ok else 1)
