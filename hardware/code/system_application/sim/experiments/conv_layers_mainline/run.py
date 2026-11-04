"""Replay conv2..4 through promoted mainline RTL and score every output."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sys
import numpy as np
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'sim'))
sys.path.insert(0, str(ROOT / 'scripts'))
import run_sim as sim
import golden_pipeline as golden

def main():
    work = ROOT / 'build/sim/mainline_conv_layers'
    work.mkdir(parents=True, exist_ok=True)
    contract = golden.load_layer_contract()
    feature = np.frombuffer((ROOT / 'sim/experiments/npu_conv1/feat_u8.bin').read_bytes(), dtype=np.uint8).reshape(64,258)
    result = golden.npu_forward(feature, contract, golden.load_mel_tables()['exp_lut'])
    image = (ROOT / 'scripts/outputs/weights_image.bin').read_bytes()
    tool, _ = sim._toolchain()
    cases = []
    expected = {}
    for layer in (1,2,3):
        rec = contract['layers'][layer]
        cin,h,w = rec['in_shape']
        cout = rec['out_shape'][0]
        data = work / ('L' + str(layer))
        data.mkdir(exist_ok=True)
        base = rec['image_offset']
        payload = image[base:base+rec['weight_bytes']]
        taps = [int.from_bytes(payload[i:i+4], 'little') for i in range(0,len(payload),4)]
        params = rec['bias_int32'] + rec['M'] + rec['shift']
        inputs = result['pool' + str(layer)].transpose(1,2,0).reshape(-1)
        for name,values,width in [('tap',taps,8),('ctr',params,8),('x',inputs,2)]:
            (data / (name+'.hex')).write_text(''.join(format(int(v) & ((1<<(4*width))-1), '0'+str(width)+'x')+'\n' for v in values),encoding='ascii')
        text = (ROOT / 'sim/tb_conv_layer.sv').read_text(encoding='ascii')
        text = text.replace('build/ml_conv/', 'build/sim/mainline_conv_layers/')
        text = text.replace('build/sim_L%0d_y.bin', 'build/sim/mainline_conv_layers/L%0d_y.bin')
        tb = data / 'tb_conv_layer.sv';tb.write_text(text,encoding='ascii')
        cases.append(sim.Case(name='mainline_conv'+str(layer+1),tb=str(tb),rtl=['src/npu/conv_engine.v','src/npu/requant_unit.v'],extra_flags=['-GLAYER='+str(layer),'-GCIN='+str(cin),'-GCOUT='+str(cout),'-GH='+str(h),'-GW='+str(w)],timeout=300))
        expected[layer] = result['conv'+str(layer+1)].reshape(cout//16,16,h,w).transpose(2,0,3,1).reshape(-1)
    args = argparse.Namespace(clean=False,trace=False,verbose=True)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda case: sim.run_case(case,tool,args),cases))
    ok = True
    summary = []
    for layer,r in zip((1,2,3),results):
        output = work / ('L'+str(layer)+'_y.bin')
        observed = np.frombuffer(output.read_bytes(),dtype=np.uint8) if output.exists() else np.array([],dtype=np.uint8)
        exp = expected[layer]
        mismatch = int(np.count_nonzero(observed!=exp)) if observed.size==exp.size else -1
        passed = r.ok and mismatch==0
        summary.append(dict(layer=layer+1,passed=passed,samples=int(observed.size),expected=int(exp.size),mismatches=mismatch,log=str(r.log_path)))
        print(json.dumps(summary[-1]))
        if not passed: print(r.output[-5000:])
        ok = ok and passed
    (work/'summary.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='ascii')
    return 0 if ok else 1
if __name__ == '__main__':
    raise SystemExit(main())
