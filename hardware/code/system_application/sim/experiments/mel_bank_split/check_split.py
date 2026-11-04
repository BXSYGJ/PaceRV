"""Compare the production split Mel scratch bank against its frozen predecessor."""
import argparse, hashlib, json, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'sim'))
import run_sim as sim
work=ROOT/'build/sim/mel_bank_split';work.mkdir(parents=True,exist_ok=True)
mel=ROOT/'src/mel/mel_engine.v'
s=mel.read_text(encoding='ascii')
block=s.split('    // Split at the power-of-two boundary',1)[1].split('\n',1)[1].split('    assign feat_rd_data = bank_q[7:0];',1)[0]
ports=(Path(__file__).parent/'ports.vfrag').read_text(encoding='ascii')
candidate=work/'split_bank.v'
candidate.write_text('module split_bank('+ports+');\n'+block+'\nassign result=bank_q;\nendmodule\n',encoding='ascii')
tool,_=sim._toolchain()
r=sim.run_case(sim.Case(name='mel_bank_split',tb=str(Path(__file__).parent/'tb_mel_bank_split.sv'),rtl=[str(candidate),str(Path(__file__).parent/'reference_bank.v')],timeout=120),tool,argparse.Namespace(clean=False,trace=False,verbose=True))
print(r.output)
report={'result':'PASS' if r.ok else 'FAIL','scope':'Actual extracted production bank vs frozen single-array bank; all16576 addresses, three writer roles/priority, same-address read/write, boundary, random and no-reset second epoch','source_sha256':hashlib.sha256(mel.read_bytes()).hexdigest(),'log':str(r.log_path),'log_sha256':hashlib.sha256(Path(r.log_path).read_bytes()).hexdigest()}
(ROOT/'reports/mel_bank_split_validation_20261103.json').write_text(json.dumps(report,indent=2)+'\n',encoding='ascii')
raise SystemExit(0 if r.ok else 1)
