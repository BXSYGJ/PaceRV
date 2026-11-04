"""Isolated WBUF replay/load-boundary experiment."""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'sim'))
import run_sim as sim


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('variant', choices=['baseline', 'fixed'], nargs='?', default='fixed')
    args = parser.parse_args()
    case = sim.Case(
        name='wbuf_replay_experiment_' + args.variant,
        tb=str(HERE / 'tb_wbuf_replay.sv'),
        rtl=[str(HERE / ('wbuf_step4_baseline.v' if args.variant == 'baseline' else 'wbuf_step8_fixed.v'))],
        timeout=120,
    )
    verilator, _ = sim._toolchain()
    result = sim.run_case(case, verilator, argparse.Namespace(clean=False, trace=False, verbose=True))
    print(result.output)
    print(f'ok={result.ok} log={result.log_path}')
    return 0 if result.ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
