"""Corrected WDMA scalar/wide parameter RAM cycle equivalence."""
import argparse
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'sim'))
import run_sim as sim
if __name__=='__main__':
    verilator,_=sim._toolchain()
    case=sim.Case(name='wdma_parameter_ram_experiment',tb=str(HERE/'tb_wdma_diff.sv'),rtl=[str(HERE/'wdma_corrected.v'),str(HERE/'wdma_wide_fixed.v')],timeout=180)
    result=sim.run_case(case,verilator,argparse.Namespace(clean=False,trace=False,verbose=True))
    print(result.output)
    print(f'ok={result.ok} log={result.log_path}')
    raise SystemExit(0 if result.ok else 1)
