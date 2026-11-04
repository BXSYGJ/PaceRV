"""Create frozen production-named candidates under build; never edits src."""
import argparse
import hashlib
import json
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent

def replace_once(s,old,new):
    if s.count(old)!=1:raise ValueError('Expected one replacement: '+old[:100]+' count='+str(s.count(old)))
    return s.replace(old,new)

def patch_top(s):
    if re.search(r'\bnpu_m1_owner\s+u_npu_m1_owner\s*\(',s):
        # Promotion may already have installed the complete frozen block.
        # Reject partial/stale integration instead of adding duplicate logic.
        flat=re.sub(r'\s+','',s)
        required=[
            'weight_read_aligner_hardenedu_weight_read_aligner(',
            'npu_m1_bridgeu_npu_m1_bridge(',
            "weight_loader#(.BASE_ADDR(28'h100000))u_weight_loader(",
            '.rd_ready({st_rd_ready,mel_m2_rd_ready,native_m1_rd_ready,1\'b0})',
            'assignm1_cmd=native_m1_cmd;', 'assignm1_wdata=native_m1_wdata;',
            "assignnpu_rd_ready_u=1'b1;",
            '.m_abort(ddr_cmd_to_err[1]||ddr_addr_err[1])',
            '.n_abort(bridge_abort)', '.m1_abort(bridge_abort)',
            '.rd_data(npu_weight_data)', '.rd_valid(npu_weight_valid)',
            '.rd_done(npu_weight_done)', '.wready_beat(loader_m1_wready)',
            '.done(loader_m1_done)', '.rd_valid(loader_m1_rvalid)',
            '.rx_valid(rx_byte_valid&&!npu_busy_u&&!npu_start&&!native_fault)',
            '.act_cmd_valid(act_cmd_valid)', '.act_rd_data(act_rd_data)',
            '.done(npu_done_raw)', '.timeout_flag(npu_timeout_raw)',
            '.probs_valid(npu_probs_valid_raw)',
            '&&native_owner_idle&&!native_fault;',
        ]
        missing=[key for key in required if key not in flat]
        if missing:raise ValueError('Existing native top failed integration audit: '+str(missing))
        return s
    a=s.index('    // Master 1 arbitration:');b=s.index('    assign m2_cmd',a)
    s=s[:a]+(HERE/'snapshot_m1_block.vh').read_text()+s[b:]
    s=replace_once(s,".rd_ready       ({st_rd_ready, mel_m2_rd_ready, wl_rd_ready, 1'b0})", ".rd_ready       ({st_rd_ready, mel_m2_rd_ready, native_m1_rd_ready, 1'b0})")
    s=replace_once(s,'weight_loader u_weight_loader (',"weight_loader #(.BASE_ADDR(28'h100000)) u_weight_loader (")
    a=s.index('weight_loader #');b=s.index('    );',a)
    block=s[a:b]
    block=block.replace('.rx_valid    (rx_byte_valid)', '.rx_valid    (rx_byte_valid && !npu_busy_u && !npu_start && !native_fault)')
    block=block.replace('.wready_beat (ddr_wready_beat[1])','.wready_beat (loader_m1_wready)').replace('.done        (ddr_done[1])','.done        (loader_m1_done)').replace('.rd_valid    (ddr_rd_valid[1])','.rd_valid    (loader_m1_rvalid)')
    s=s[:a]+block+s[b:]
    a=s.index('npu_top u_npu');b=s.index('    );',a)
    block=s[a:b]
    block=block.replace(".rd_ready     (wl_busy ? 1'b0 : npu_rd_ready_u)",'.rd_ready     (npu_rd_ready_u)').replace('.rd_data      (rd_data_1)','.rd_data      (npu_weight_data)').replace(".rd_valid     (wl_busy ? 1'b0 : ddr_rd_valid[1])",'.rd_valid     (npu_weight_valid)').replace(".rd_done      (wl_busy ? 1'b0 : ddr_done[1])",'.rd_done      (npu_weight_done)')
    block=block.replace('.done         (npu_done_u)', '.done         (npu_done_raw)').replace('.timeout_flag (npu_timeout_u)', '.timeout_flag (npu_timeout_raw)')
    block=block.replace('.probs_valid  (npu_probs_valid_u)', '.act_cmd_valid(act_cmd_valid), .act_cmd_write(act_cmd_write), .act_cmd_addr(act_cmd_addr),\n        .act_cmd_ready(act_cmd_ready), .act_wr_valid(act_wr_valid), .act_wr_data(act_wr_data),\n        .act_wr_ready(act_wr_ready), .act_rd_valid(act_rd_valid), .act_rd_data(act_rd_data),\n        .probs_valid  (npu_probs_valid_raw)')
    s=s[:a]+block+s[b:]
    if 'wire npu_start = mel_npu_start &&' in s:
        s=s.replace('!wl_busy && !npu_busy_u;', '!wl_busy && !npu_busy_u && native_owner_idle && !native_fault;')
    else:
        s=replace_once(s,"wire        npu_start = NPU_ENABLE ? mel_npu_start : 1'b0;", "wire npu_start = NPU_ENABLE && mel_npu_start && ddr_init_done && weight_ok && !weight_err && !wl_busy && !npu_busy_u && native_owner_idle && !native_fault;")
    if not re.search(r'wire\s+dbg_tx_ready\s*;',s):s=s.replace('    wire wl_busy;', '    wire dbg_tx_ready;\n    wire wl_busy;')
    # Fail the NPU instead of publishing a successful CPU/MMIO result.
    s=s.replace('.npu_done       (npu_done_u)', '.npu_done       (npu_done_u && !native_fault)')
    s=s.replace('.npu_timeout    (npu_timeout_u)', '.npu_timeout    (npu_timeout_u || native_fault)')
    s=s.replace('.npu_probs_valid(npu_probs_valid_u)', '.npu_probs_valid(npu_probs_valid_u && !native_fault)')
    return s

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--name');args=parser.parse_args()
    name=args.name or datetime.now().strftime('%Y%m%d-%H%M%S')
    if not re.fullmatch('[a-zA-Z0-9_-]+',name):raise SystemExit('invalid snapshot name')
    out=ROOT/'build/npu_production_candidate'/name
    if out.exists():raise SystemExit('Refuse overwrite frozen snapshot: '+str(out))
    out.mkdir(parents=True)
    shutil.copytree(ROOT/'src',out/'src')
    shutil.copytree(ROOT.parent/'cpu/rtl',out/'cpu_rtl')
    shutil.copytree(ROOT/'constraints',out/'constraints')
    (out/'scripts').mkdir()
    shutil.copyfile(ROOT/'scripts/build_sets.json',out/'scripts/build_sets.json')
    (out/'verification').mkdir()
    shutil.copyfile(ROOT/'sim/experiments/npu_pingpong_native/ddr3_axi_model_full.sv',out/'verification/ddr3_axi_model_full.sv')
    # Resolve the exact full_native manifest before promoting module/file names.
    sys.path.insert(0,str(HERE));import inspect_manifest
    inspect_manifest.main()
    manifest=json.loads((ROOT/'build/sim/npu_integration_review/manifest.json').read_text())
    for row in manifest:
        mod=row['module']
        if mod in ('ddr3_axi_model_full','weight_read_aligner'):continue
        source=ROOT/row['validated_source']
        dest=out/row['production_source'] if row['production_source'] else out/'src/npu'/ (mod+'.v')
        dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,dest)
    shutil.copyfile(ROOT/'sim/experiments/weight_read_aligner_hardened/weight_read_aligner_hardened.v',out/'src/npu/weight_read_aligner_hardened.v')
    shutil.copyfile(HERE/'npu_m1_owner.v',out/'src/npu/npu_m1_owner.v')
    shutil.copyfile(ROOT/'sim/experiments/weight_read_aligner_hardened/npu_top_repeat_candidate.v',out/'src/npu/npu_top.v')
    shutil.copyfile(ROOT/'sim/experiments/weight_read_aligner_hardened/fc_engine_repeat_candidate.v',out/'src/npu/fc_engine.v')
    for top in ('top_rv_core','instrec_top','top_core_only'):
        p=out/('src/ctrl/'+top+'.v');p.write_text(patch_top(p.read_text()),encoding='ascii')
    # Production lint requires a module-named ASCII header in each file.
    for p in (out/'src/npu').rglob('*.v'):
        text=p.read_text()
        if not re.search(r'(?m)^\s*//[^\n]*\b'+re.escape(p.stem)+r'\b', '\n'.join(text.splitlines()[:30])):
            p.write_text('// '+p.stem+' -- Frozen candidate; PDS and board validation pending.\n'+text,encoding='ascii')
    overrides=[]
    for source,dest in [('weight_read_aligner_hardened.v','weight_read_aligner_hardened.v'),('npu_top_repeat_candidate.v','npu_top.v'),('fc_engine_repeat_candidate.v','fc_engine.v')]:
        source=ROOT/'sim/experiments/weight_read_aligner_hardened'/source
        overrides.append({'candidate':source.relative_to(ROOT).as_posix(),'snapshot':'src/npu/'+dest,'sha256':hashlib.sha256(source.read_bytes()).hexdigest()})
    overrides.append({'candidate':(HERE/'npu_m1_owner.v').relative_to(ROOT).as_posix(),'snapshot':'src/npu/npu_m1_owner.v','sha256':hashlib.sha256((HERE/'npu_m1_owner.v').read_bytes()).hexdigest()})
    files=[]
    for p in sorted(out.rglob('*')):
        if p.is_file():files.append({'path':p.relative_to(out).as_posix(),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
    (out/'snapshot.json').write_text(json.dumps({'kind':'frozen production candidate; validation evidence is external; no PDS/board result','limitations':['Functional status must be established against this exact snapshot hash; consult external validation.json.','Real loader upload/contention and native abort through complete top remain unverified.','Vendor wrapper boundaries are stubbed in structural checks.'],'candidate_overrides':overrides,'sources':files},indent=2)+'\n',encoding='ascii')
    print('SNAPSHOT='+str(out))
if __name__=='__main__':main()
