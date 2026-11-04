"""CPU MMIO regression using the isolated top1-reporting firmware candidate."""
import argparse
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'sim'))
import run_sim as sim
work=ROOT/'build/sim/cpu_top1_firmware';work.mkdir(parents=True,exist_ok=True)
rom=ROOT/'build/sim/cpu_native_joint_top1/firmware/prog.hex'
if not rom.is_file():raise RuntimeError('Run build_firmware.py first')
text=(ROOT/'sim/tb_rv_cpu.sv').read_text(encoding='ascii')
text=text.replace('src/cpu/prog.hex',rom.as_posix())
text=text.replace('.npu_top1        (npu_probs_idx)',".npu_top1        (4'd5)")
text=text.replace('NPU t=3 p=87','NPU top1=5 last_class=3 last_p=87')
tb=work/'tb_rv_cpu.sv';tb.write_text(text,encoding='ascii')
rtl=sim.CASES['rv_cpu'].rtl
tool,_=sim._toolchain()
r=sim.run_case(sim.Case(name=work.name,tb=str(tb),rtl=rtl,timeout=180),tool,argparse.Namespace(clean=False,trace=False,verbose=True))
print(r.output);print('ok='+str(r.ok)+' log='+str(r.log_path))
raise SystemExit(0 if r.ok else 1)
