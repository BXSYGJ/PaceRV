"""Freeze current production with exactly one reviewed narrow RAM override."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def normalized(text):
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*|/\*.*?\*/', '', text, flags=re.S))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--name', default='narrow-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    args = ap.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.name):
        raise SystemExit('Invalid snapshot name')
    out = ROOT / 'build/npu_production_candidate' / args.name
    if out.exists():
        raise SystemExit('Refuse overwrite: ' + str(out))
    reference = HERE / 'activation_row_store_dynamic.v'
    production = ROOT / 'src/npu/activation_row_store_dynamic.v'
    candidate = HERE / 'activation_row_store_narrow.v'
    if normalized(reference.read_text()) != normalized(production.read_text()):
        raise SystemExit('Miter reference differs from production logic')
    text = candidate.read_text(encoding='ascii')
    old = 'module activation_row_store_narrow ('
    if text.count(old) != 1:
        raise SystemExit('Candidate module declaration changed')
    text = '// activation_row_store_dynamic -- Isolated narrow equivalent candidate.\n' + text.replace(old, 'module activation_row_store_dynamic (')
    out.mkdir(parents=True)
    for folder in ('src', 'constraints', 'ipcore', 'sw/rv32'):
        shutil.copytree(ROOT / folder, out / folder)
    shutil.copytree(ROOT.parent / 'cpu/rtl', out / 'cpu_rtl')
    (out / 'scripts').mkdir()
    for name in ('build_sets.json', 'build_full.tcl', 'build_rv32_sw.py'):
        shutil.copyfile(ROOT / 'scripts' / name, out / 'scripts' / name)
    (out / 'verification').mkdir()
    shutil.copyfile(ROOT / 'sim/experiments/npu_pingpong_native/ddr3_axi_model_full.sv', out / 'verification/ddr3_axi_model_full.sv')
    target = out / 'src/npu/activation_row_store_dynamic.v'
    target.write_text(text, encoding='ascii')
    copied = []
    for source in sorted((ROOT / 'src').rglob('*')):
        if source.is_file():
            rel = source.relative_to(ROOT)
            frozen = out / rel
            equal = source.read_bytes() == frozen.read_bytes()
            if not equal and rel.as_posix() != 'src/npu/activation_row_store_dynamic.v':
                raise RuntimeError('Unexpected production override: ' + str(rel))
            copied.append({'path': rel.as_posix(), 'production_sha256': digest(source), 'snapshot_sha256': digest(frozen), 'byte_identical': equal})
    files = [{'path': p.relative_to(out).as_posix(), 'sha256': digest(p)} for p in sorted(out.rglob('*')) if p.is_file()]
    meta = {'kind': 'current production plus one isolated narrow RAM equivalent; no PDS run',
            'sources': files, 'production_comparison': copied,
            'override': {'path': 'src/npu/activation_row_store_dynamic.v', 'candidate_path': candidate.relative_to(ROOT).as_posix(), 'candidate_sha256': digest(candidate), 'miter_reference_sha256': digest(reference), 'production_reference_logic_equal': True, 'change_after_candidate': 'module name and ASCII header only'},
            'limitations': ['Native A/B and structural checks must refer to this manifest.', 'No PDS or board result is implied.', 'No old experiment source is promoted except the explicit narrow candidate.']}
    (out / 'snapshot.json').write_text(json.dumps(meta, indent=2) + '\n', encoding='ascii')
    print('SNAPSHOT=' + str(out))
    print('MANIFEST_SHA256=' + digest(out / 'snapshot.json'))

if __name__ == '__main__':
    main()
