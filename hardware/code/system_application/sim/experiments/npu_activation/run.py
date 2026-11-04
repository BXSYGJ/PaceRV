"""Full conv1 -> pool1 -> abstract DDR -> conv2 golden verification."""
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
    assets = ROOT / 'build/sim/npu_activation_assets'
    assets.mkdir(parents=True, exist_ok=True)
    feat = np.frombuffer((HERE.parent / 'npu_conv1/feat_u8.bin').read_bytes(), dtype=np.uint8).reshape(1, 64, 258)
    weights = golden.load_weights_from_image(golden.load_layer_contract())
    c1 = golden.conv2d_int8(feat, weights['conv1'])
    p1 = golden.maxpool2x2_floor(c1)
    c2 = golden.conv2d_int8(p1, weights['conv2'])
    p2 = golden.maxpool2x2_floor(c2)
    vectors = {'feat': feat.reshape(-1), 'weights': (ROOT / 'scripts/outputs/weights_image.bin').read_bytes()}
    for name, array in [('conv1', c1), ('pool1', p1), ('conv2', c2), ('pool2', p2)]:
        channels, height, width = array.shape
        vectors[name] = array.reshape(channels // 16, 16, height, width).transpose(2, 0, 3, 1).reshape(-1)
    for name, values in vectors.items():
        (assets / (name + '.hex')).write_text(''.join(f'{int(v):02x}\n' for v in values), encoding='ascii')
    rtl = [HERE / 'conv_engine_candidate.v', HERE / 'pool_engine_candidate.v', HERE / 'npu_top_candidate.v',
           HERE.parent / 'npu_conv1/wbuf_candidate.v', HERE.parent / 'wdma_parameter_ram/wdma_wide_fixed.v',
           HERE.parent / 'activation_store/activation_row_store_dynamic.v']
    rtl += [ROOT / ('src/npu/' + name + '.v') for name in ['fc_engine', 'gap_unit', 'requant_unit', 'softmax_top']]
    case = sim.Case(name='npu_activation', tb=str(HERE / 'tb_npu_activation.sv'), rtl=[str(p) for p in rtl], timeout=240)
    verilator, _ = sim._toolchain()
    result = sim.run_case(case, verilator, argparse.Namespace(clean=False, trace=False, verbose=True))
    print(result.output)
    print(f'ok={result.ok} log={result.log_path}')
    return 0 if result.ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
