"""Build explicit top1/last-class reporting firmware without changing source ROM."""
import importlib.util
from pathlib import Path
import shutil
import sys
ROOT=Path(__file__).resolve().parents[3]
work=ROOT/'build/sim/cpu_native_joint_top1/firmware'
work.mkdir(parents=True,exist_ok=True)
for name in ('start.S','link.ld'):
    shutil.copyfile(ROOT/'sw/rv32'/name,work/name)
s=(ROOT/'sw/rv32/main.c').read_text(encoding='ascii')
old='            puts_("NPU t=");\n            putdec(pr & 0x0fu);\n            puts_(" p=");'
new='            puts_("NPU top1=");\n            putdec((status >> 8) & 0x0fu);\n            puts_(" last_class=");\n            putdec(pr & 0x0fu);\n            puts_(" last_p=");'
if s.count(old)==1:
    s=s.replace(old,new)
elif s.count(new)!=1:
    raise RuntimeError('Review firmware result formatting patch')
(work/'main.c').write_text(s,encoding='ascii')
spec=importlib.util.spec_from_file_location('firmware_builder',ROOT/'scripts/build_rv32_sw.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.SW=work;m.OUT=work;m.HEX=work/'prog.hex'
sys.argv=['build_rv32_sw.py','--no-m']
raise SystemExit(m.main())
