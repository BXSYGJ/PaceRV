"""Run the complete golden-checked native-controller NPU candidate."""
import argparse
import sys
import numpy as np
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'sim'))
sys.path.insert(0, str(ROOT / 'scripts'))
import run_sim as sim
import golden_pipeline as golden


def main():
    assets = ROOT / 'build/sim/npu_full_native_assets'
    assets.mkdir(parents=True, exist_ok=True)
    feat = np.frombuffer((HERE.parent / 'npu_conv1/feat_u8.bin').read_bytes(), dtype=np.uint8).reshape(64,258)
    contract = golden.load_layer_contract()
    tables = golden.load_mel_tables()
    results = golden.npu_forward(feat, contract, tables['exp_lut'])
    values = {'weights': (ROOT / 'scripts/outputs/weights_image.bin').read_bytes(), 'feat': feat.reshape(-1),
              'gap': results['gap'], 'fc1': results['fc1'], 'fc2_logits': results['fc2'], 'probs': results['probs_q16']}
    for name in ('conv1','conv2','conv3','conv4','pool1','pool2','pool3','pool4'):
        a = results[name]
        channels, height, width = a.shape
        values[name] = a.reshape(channels//16,16,height,width).transpose(2,0,3,1).reshape(-1)
    for name, data in values.items():
        (assets / (name+'.hex')).write_text(''.join(f'{int(v):08x}\n' for v in data),encoding='ascii')
    tb = assets / 'tb_npu_full_native.sv'
    text = (HERE / 'tb_npu_full_native.sv').read_text(encoding='ascii')
    text = text.replace('build/npu_full/', 'build/sim/npu_full_native_assets/')
    tb.write_text(text, encoding='ascii')
    rtl = [HERE.parent / 'npu_full_end/conv_engine_candidate.v', HERE.parent / 'npu_full_end/pool_engine_candidate.v',
           HERE.parent / 'npu_full_end/npu_top_candidate.v', HERE.parent / 'npu_full_end/fc_engine.v', HERE.parent / 'npu_full_end/wbuf.v',
           ROOT / 'sim/experiments/wdma_parameter_ram/wdma_wide_fixed.v',
           ROOT / 'sim/experiments/activation_store/activation_row_store_dynamic.v',
           ROOT / 'sim/experiments/activation_store/activation_store_mux.v',
           ROOT / 'sim/experiments/npu_lifecycle/npu_stage_lifecycle.v']
    rtl += [ROOT / ('src/npu/' + name + '.v') for name in
            ('gap_unit', 'requant_unit', 'softmax_top')]
    rtl += [HERE.parent / 'npu_pingpong_native/weight_read_aligner.v', HERE.parent / 'npu_pingpong_native/ddr3_axi_model_full.sv', ROOT / 'src/ddr3/ddr3_ctrl_axi.v', ROOT / 'sim/experiments/npu_lifecycle/ddr3_arbiter.v', ROOT / 'sim/experiments/npu_m1_bridge/npu_m1_bridge.v']
    case = sim.Case(name='npu_full_native', tb=str(tb), rtl=[str(p) for p in rtl], timeout=360)
    verilator, _ = sim._toolchain()
    result = sim.run_case(case, verilator, argparse.Namespace(clean=False, trace=False, verbose=True))
    print(result.output)
    print(f'ok={result.ok} log={result.log_path}')
    return 0 if result.ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
