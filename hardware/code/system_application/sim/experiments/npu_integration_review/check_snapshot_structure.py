"""Structure-only top expansion using explicit wrapper-level vendor stubs."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'sim'))
import run_sim

def stub_header(source):
    s=source.read_text();s=re.sub(r'//[^\n]*|/\*.*?\*/','',s,flags=re.S)
    start=re.search(r'\bmodule\s+\w+',s).start()
    end=s.index(');',start)+2
    return '// STRUCTURAL STUB ONLY. No clock/PHY/functional behavior.\n'+s[start:end]+'\nendmodule\n'

def main():
    ap=argparse.ArgumentParser();ap.add_argument('snapshot',type=Path);ap.add_argument('--top',choices=['top_rv_core','instrec_top','top_core_only'],default='top_rv_core');args=ap.parse_args()
    snapshot=args.snapshot.resolve()
    manifest=json.loads((snapshot/'snapshot.json').read_text())
    import hashlib
    for row in manifest['sources']:
        p=snapshot/row['path']
        if hashlib.sha256(p.read_bytes()).hexdigest()!=row['sha256']:raise SystemExit('Frozen source mismatch '+str(p))
    work=ROOT/'build/sim/npu_snapshot_structure'/snapshot.name/args.top;work.mkdir(parents=True,exist_ok=True)
    config=json.loads((snapshot/'scripts/build_sets.json').read_text())['sets'][{'top_rv_core':'rv_core','instrec_top':'full','top_core_only':'core_only'}[args.top]]
    sources=[]
    for pattern in config['sources']:
        if pattern.startswith('../cpu/rtl/'):
            paths=[snapshot/'cpu_rtl'/Path(pattern).name]
        else:paths=list(snapshot.glob(pattern))
        sources.extend(paths)
    sources=list(dict.fromkeys(sources))
    # Replacing only these wrapper boundaries preserves all CPU/NPU/control RTL.
    stubbed=[]
    for i,p in enumerate(sources):
        if p.name in ('audio_pll.v','ddr3_wrapper.v','hdmi_tx_if.v'):
            q=work/p.name;q.write_text(stub_header(p),encoding='ascii');sources[i]=q;stubbed.append(p.name)
    tool,_=run_sim._toolchain()
    cmd=[str(tool),'--lint-only','--timing','-Wno-fatal','--top-module',args.top,'--Mdir',str(work/'obj')]
    for d in [snapshot/'src/mel',snapshot/'src/cpu',snapshot/'cpu_rtl',snapshot/'src/ddr3']:
        cmd+=['-I'+str(d)]
    # Windows .bat launch has an 8191-character command limit. Keep the exact
    # frozen source list in a Verilator response file for the complete top.
    filelist=work/'sources.f'
    filelist.write_text('\n'.join('"'+p.as_posix()+'"' for p in sources)+'\n',encoding='ascii')
    cmd += ['-f',str(filelist)]
    r=subprocess.run(cmd,cwd=ROOT,env=run_sim._build_env(),text=True,capture_output=True)
    (work/'elaboration.log').write_text(r.stdout+r.stderr,encoding='utf-8')
    (work/'inputs.json').write_text(json.dumps({'top':args.top,'stubbed':stubbed,'sources':[str(p) for p in sources]},indent=2),encoding='ascii')
    print((r.stdout+r.stderr)[-6000:])
    print('STRUCTURE_RESULT='+('PASS' if r.returncode==0 else 'FAIL')+' log='+str(work/'elaboration.log'))
    return r.returncode
if __name__=='__main__':raise SystemExit(main())
