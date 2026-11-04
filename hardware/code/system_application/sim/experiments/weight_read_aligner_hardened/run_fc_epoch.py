"""Repeated FC input preload and independent delayed parameter regression."""
import argparse
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'sim'))
import run_sim as sim

if __name__ == '__main__':
    verilator, _ = sim._toolchain()
    baseline = '--baseline' in sys.argv
    fc = HERE.parent / 'npu_full_end/fc_engine.v' if baseline else HERE / 'fc_engine_repeat_candidate.v'
    case = sim.Case(name='fc_parameter_epoch_baseline' if baseline else 'fc_parameter_epoch', tb=str(HERE / 'tb_fc_parameter_epoch.sv'),
                    rtl=[str(fc), str(ROOT / 'src/npu/requant_unit.v')], timeout=120)
    result = sim.run_case(case, verilator, argparse.Namespace(clean=False, trace=False, verbose=True))
    print(result.output)
    print(f'ok={result.ok} log={result.log_path}')
    raise SystemExit(0 if result.ok else 1)
