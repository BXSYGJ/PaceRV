"""Check portable manifests, all project dependencies and ROM references."""
from pathlib import Path
import ast
import hashlib
import json
import re
import sys
from build_project import ROOT, expand, local


def main():
    doc = json.loads((ROOT / 'projects.json').read_text(encoding='utf-8-sig'))
    assert doc['device'] == 'PG2L100H' and doc['package'] == 'FBG676'
    results = []
    for name, project in doc['projects'].items():
        base = local(ROOT, project['root'])
        sources = expand(base, project['sources'])
        ips = expand(base, project['ip_cores'])
        constraints = expand(base, project['constraints'])
        if not sources or not constraints:
            raise ValueError('Incomplete source/constraint set: ' + name)
        for entry in project['copies']:
            if not local(base, entry['source']).is_file():
                raise FileNotFoundError(entry['source'])
        results.append({'project': name, 'sources': len(sources), 'ips': len(ips),
                        'constraints': len(constraints), 'initializers': len(project['copies'])})
    app = ROOT / 'code/system_application'
    missing = []
    for p in (app / 'src').rglob('*'):
        if p.suffix not in ['.v', '.sv']:
            continue
        for path in re.findall(rb'"(src/[^"\r\n]+\.(?:hex|mem))"', p.read_bytes()):
            reference = path.decode('ascii')
            if not (app / reference).is_file():
                missing.append(reference)
    if missing:
        raise FileNotFoundError(str(sorted(set(missing))))
    for p in (ROOT / 'tools').glob('*.py'):
        ast.parse(p.read_text(encoding='utf-8-sig'), filename=str(p))
    board_names = re.compile(rb'(?i)PG2L' + rb'200\w*|MES2L676[-_]200\w*|200\s*Pro\+?')
    board_hits = []
    for p in ROOT.rglob('*'):
        if not p.is_file() or any(x in p.relative_to(ROOT).parts for x in ['build', '__pycache__', '.pytest_cache']):
            continue
        if p.suffix.lower() in ['.v', '.sv', '.vp', '.idf', '.md', '.json', '.tcl', '.ps1', '.py', '.fdc', '.sdc']:
            if board_names.search(p.read_bytes()):
                board_hits.append(p.relative_to(ROOT).as_posix())
    if board_hits:
        raise ValueError('Other-board references: ' + str(board_hits))
    hashes = ROOT / 'SHA256SUMS'
    checked = 0
    if hashes.exists():
        for line in hashes.read_text(encoding='utf-8').splitlines():
            digest, path = line.split('  ', 1)
            actual = hashlib.sha256(local(ROOT, path).read_bytes()).hexdigest()
            if actual != digest:
                raise ValueError('Hash mismatch: ' + path)
            checked += 1
    print(json.dumps({'status': 'PASS', 'board': doc['board'], 'device': doc['device'],
                      'projects': results, 'checked_hashes': checked,
                      'missing_literal_rom_paths': missing, 'other_board_references': board_hits},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, AssertionError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
