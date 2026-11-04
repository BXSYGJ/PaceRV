"""Run the isolated WDMA handshake experiment; baseline is expected to fail."""
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
    assets = ROOT / 'build/sim/wdma_handshake_assets'
    assets.mkdir(parents=True, exist_ok=True)
    image = (ROOT / 'scripts/outputs/weights_image.bin').read_bytes()
    if len(image) != 691040:
        raise ValueError('unexpected weight image length')
    (assets / 'weights.hex').write_text(''.join(f'{byte:02x}\n' for byte in image), encoding='ascii')
    case = sim.Case(
        name='wdma_handshake_experiment_' + args.variant,
        tb=str(HERE / 'tb_wdma_handshake.sv'),
        rtl=[str(HERE / ('wdma_step6_baseline.v' if args.variant == 'baseline' else 'wdma_fixed.v'))],
        timeout=120,
    )
    verilator, _ = sim._toolchain()
    result = sim.run_case(case, verilator, argparse.Namespace(clean=False, trace=False, verbose=True))
    print(result.output)
    print(f'ok={result.ok} log={result.log_path}')
    return 0 if result.ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
