"""Native m1 weight/activation transaction bridge unit regression."""
import argparse
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'sim'))
import run_sim as sim
if __name__=='__main__':
    verilator,_=sim._toolchain()
    case=sim.Case(name='npu_m1_bridge_experiment',tb=str(HERE/'tb_npu_m1_bridge.sv'),rtl=[str(HERE/'npu_m1_bridge.v')],timeout=120)
    result=sim.run_case(case,verilator,argparse.Namespace(clean=False,trace=False,verbose=True))
    print(result.output)
    print(f'ok={result.ok} log={result.log_path}')
    raise SystemExit(0 if result.ok else 1)
