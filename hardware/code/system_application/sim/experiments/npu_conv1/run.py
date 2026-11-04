"""Run complete conv1 through real NPU control, weight DDR and feature ROM."""
import argparse
import sys
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(ROOT / 'sim'), str(ROOT / 'scripts')]
import run_sim as sim
import golden_pipeline as golden


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wide', action='store_true', help='use synchronous wide parameter RAM candidate')
    args = parser.parse_args()
    assets = ROOT / 'build/sim/npu_conv1_assets'
    assets.mkdir(parents=True, exist_ok=True)
    image = (ROOT / 'scripts/outputs/weights_image.bin').read_bytes()
    feat = np.frombuffer((HERE / 'feat_u8.bin').read_bytes(), dtype=np.uint8).reshape(1, 64, 258)
    weights = golden.load_weights_from_image(golden.load_layer_contract())
    conv = golden.conv2d_int8(feat, weights['conv1'])
    scan = conv.reshape(3, 16, 64, 258).transpose(2, 0, 3, 1).reshape(-1)
    for name, values in [('weights', image), ('feat', feat.reshape(-1)), ('conv1', scan)]:
        (assets / (name + '.hex')).write_text(''.join(f'{int(v):02x}\n' for v in values), encoding='ascii')
    rtl = [HERE / 'conv_engine_candidate.v', HERE / 'npu_top_candidate.v', HERE / 'wbuf_candidate.v',
           HERE.parent / ('wdma_parameter_ram/wdma_wide_fixed.v' if args.wide else 'wdma_handshake/wdma_fixed.v')]
    rtl += [ROOT / ('src/npu/' + name + '.v') for name in
            ['fc_engine', 'gap_unit', 'pool_engine', 'requant_unit', 'softmax_top']]
    case = sim.Case(name='npu_conv1_wide' if args.wide else 'npu_conv1', tb=str(HERE / 'tb_npu_conv1.sv'),
                    rtl=[str(p) for p in rtl], timeout=180)
    verilator, _ = sim._toolchain()
    result = sim.run_case(case, verilator, argparse.Namespace(clean=False, trace=False, verbose=True))
    print(result.output)
    print(f'ok={result.ok} log={result.log_path}')
    return 0 if result.ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
