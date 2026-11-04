"""Run the four-convolution abstract DDR pingpong candidate."""
import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'sim'))
import run_sim as sim


def main():
    assets = ROOT / 'build/sim/npu_pingpong_assets'
    source = ROOT / 'build/npu_full'
    assets.mkdir(parents=True, exist_ok=True)
    for name in ('weights.hex', 'feat.hex', 'conv1.hex', 'conv2.hex',
                 'conv3.hex', 'conv4.hex', 'pool1.hex', 'pool2.hex',
                 'pool3.hex', 'pool4.hex', 'gap.hex', 'fc1.hex',
                 'fc2_logits.hex', 'probs.hex'):
        shutil.copyfile(source / name, assets / name)
    tb = assets / 'tb_npu_pingpong.sv'
    text = (HERE / 'tb_npu_pingpong.sv').read_text(encoding='ascii')
    text = text.replace('build/npu_full/', 'build/sim/npu_pingpong_assets/')
    tb.write_text(text, encoding='ascii')
    rtl = [HERE / 'conv_engine_candidate.v', HERE / 'pool_engine_candidate.v',
           HERE / 'npu_top_candidate.v', ROOT / 'build/npu_full/wbuf_step8.v',
           ROOT / 'sim/experiments/wdma_parameter_ram/wdma_wide_fixed.v',
           ROOT / 'sim/experiments/activation_store/activation_row_store_dynamic.v',
           ROOT / 'sim/experiments/activation_store/activation_store_mux.v',
           ROOT / 'sim/experiments/npu_lifecycle/npu_stage_lifecycle.v']
    rtl += [ROOT / ('src/npu/' + name + '.v') for name in
            ('fc_engine', 'gap_unit', 'requant_unit', 'softmax_top')]
    case = sim.Case(name='npu_pingpong', tb=str(tb), rtl=[str(p) for p in rtl], timeout=360)
    verilator, _ = sim._toolchain()
    result = sim.run_case(case, verilator, argparse.Namespace(clean=False, trace=False, verbose=True))
    print(result.output)
    print(f'ok={result.ok} log={result.log_path}')
    return 0 if result.ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
