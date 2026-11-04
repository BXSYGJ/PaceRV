"""Boot the frozen candidate CPU/ROM and check software MMIO control.

This reuses the established CPU TB with an injected accelerator response;
it does not claim full top/audio/NPU co-simulation or board functionality.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'sim'))
import run_sim as sim

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('snapshot', type=Path)
    args = ap.parse_args()
    snapshot = args.snapshot.resolve()
    manifest = json.loads((snapshot / 'snapshot.json').read_text())
    for row in manifest['sources']:
        p = snapshot / row['path']
        if hashlib.sha256(p.read_bytes()).hexdigest() != row['sha256']:
            raise RuntimeError('Frozen source mismatch: ' + str(p))
    work = ROOT / 'build/sim' / ('snapshot_cpu_' + snapshot.name)
    work.mkdir(parents=True, exist_ok=True)
    text = (ROOT / 'sim/tb_rv_cpu.sv').read_text(encoding='ascii')
    text = text.replace('src/cpu/prog.hex', (snapshot / 'src/cpu/prog.hex').as_posix())
    tb = work / 'tb_rv_cpu.sv'
    tb.write_text(text, encoding='ascii')
    rtl = [snapshot / 'src/cpu/rv32_cpu_subsys.sv']
    rtl += [snapshot / ('cpu_rtl/' + n + '.sv') for n in
            ('rv32_core', 'rv32_decode', 'rv32_alu', 'rv32_muldiv', 'rv32_btb', 'rv32_machine')]
    tool, _ = sim._toolchain()
    case = sim.Case(name=work.name, tb=str(tb), rtl=[str(p) for p in rtl], timeout=180)
    result = sim.run_case(case, tool, argparse.Namespace(clean=False, trace=False, verbose=True))
    print(result.output)
    print('ok=' + str(result.ok) + ' log=' + str(result.log_path))
    return 0 if result.ok else 1

if __name__ == '__main__':
    raise SystemExit(main())
