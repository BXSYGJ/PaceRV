import sys,argparse
from pathlib import Path
sys.path.insert(0,str(Path('sim').resolve()))
import run_sim as r
c=r.Case(name='conv1_backpressure',tb=str(Path('sim/experiments/activation_pipeline/tb_conv_engine.sv').resolve()),rtl=['sim/experiments/activation_pipeline/conv_engine.v','src/npu/requant_unit.v'],prepare='conv1',extra_flags=['--public'],timeout=300)
v,_=r._toolchain()
x=r.run_case(c,v,argparse.Namespace(clean=False,trace=False,verbose=True))
print(x.output); print(x)

sys.exit(0 if x.ok else 1)
