"""Prepare, never launch, compile/synthesize/dev_map from exact snapshot RTL."""
import argparse
import hashlib
import json
import re
import shutil
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('snapshot', type=Path)
    ap.add_argument('--set', choices=('rv_core', 'full'), default='rv_core')
    args = ap.parse_args()
    snapshot = args.snapshot.resolve()
    meta = json.loads((snapshot / 'snapshot.json').read_text())
    for row in meta['sources']:
        if digest(snapshot / row['path']) != row['sha256']:
            raise SystemExit('Snapshot hash mismatch: ' + row['path'])
    config = json.loads((snapshot / 'scripts/build_sets.json').read_text())['sets'][args.set]
    out = ROOT / 'build/resource_gate' / ('native-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    out.mkdir(parents=True)
    ip_root = snapshot / 'ipcore'
    if not ip_root.is_dir():
        raise SystemExit('Snapshot must include frozen ipcore inputs')
    shutil.copytree(ip_root, out / 'ipcore')
    sources = []
    for pattern in config['sources']:
        if pattern.startswith('../cpu/rtl/'):
            paths = [snapshot / 'cpu_rtl' / Path(pattern).name]
        else:
            paths = sorted(snapshot.glob(pattern))
        if not paths or any(not path.is_file() for path in paths):
            raise SystemExit('Source pattern matched no files: ' + pattern)
        sources.extend(paths)
    sources = list(dict.fromkeys(sources))
    ips = [out / item for item in config['ip_cores']]
    constraints = [snapshot / item for item in config['constraints']]
    for path in sources + ips + constraints:
        if not path.is_file():
            raise SystemExit('Missing gate input: ' + str(path))
    def lines(verb, paths):
        return '\n'.join(verb + ' "' + p.as_posix() + '"' for p in paths)
    copies = []
    hexes = []
    for folder in config['hex_dirs']:
        for src in sorted((snapshot / folder).glob('*.hex')):
            dest = out / folder / src.name
            copies += ['file mkdir "' + dest.parent.as_posix() + '"',
                       'file copy -force "' + src.as_posix() + '" "' + dest.as_posix() + '"']
            hexes.append(src)
    template = (snapshot / 'scripts/build_full.tcl').read_text(encoding='utf-8-sig')
    values = {'DESIGN_FILES': lines('add_design', sources), 'IP_FILES': lines('add_design', ips),
              'CONSTRAINT_FILES': lines('add_constraint', constraints),
              'HEX_COPY_BLOCK': '\n'.join(copies), 'PROJECT_ROOT': snapshot.as_posix(),
              'BUILD_ROOT': out.as_posix(), 'PROJECT_NAME': config['top_module'] + '_pds',
              'TOP_MODULE': config['top_module']}
    for key, value in values.items():
        template = template.replace('__' + key + '__', value)
    template = re.split(r'(?m)^pnr(?:\s|$)', template, maxsplit=1)[0] + '\nexit\n'
    if re.search(r'__[A-Z_]+__|(?m:^\s*(?:pnr|report_timing|gen_bit_stream)\b)', template):
        raise SystemExit('Unexpanded token or implementation stage in gate')
    (out / 'build.tcl').write_text(template, encoding='utf-8')
    inputs = list(dict.fromkeys(sources + constraints + hexes + list((out / 'ipcore').rglob('*')) +
                               [out / 'build.tcl', snapshot / 'scripts/build_sets.json',
                                snapshot / 'scripts/build_full.tcl', snapshot / 'snapshot.json']))
    rows = [{'path': str(p), 'sha256': digest(p)} for p in inputs if p.is_file()]
    manifest = {'Snapshot': str(snapshot), 'SnapshotManifestSha256': digest(snapshot / 'snapshot.json'),
                'BuildSet': args.set, 'TopModule': config['top_module'], 'StopAfter': 'dev_map',
                'NoBitstream': True, 'Files': rows,
                'Limitations': 'Preparation only; functional/owner regression must pass before launch.'}
    (out / 'gate-manifest.json').write_text(json.dumps(manifest, indent=2), encoding='ascii')
    launch = '''# Prepared only. Parent coordinates the single PDS slot.
if (Get-Process pds_shell -ErrorAction SilentlyContinue) { throw "PDS already running" }
$pdsRoot = [Environment]::GetEnvironmentVariable("PDS_ROOT", "User")
if (-not $pdsRoot) { $pdsRoot = $env:PDS_ROOT }
$gateDir = $PSScriptRoot
$gateManifest = Get-Content -Raw -LiteralPath (Join-Path $gateDir "gate-manifest.json") | ConvertFrom-Json
foreach ($gateInput in $gateManifest.Files) {
    $gateActual = (Get-FileHash -Algorithm SHA256 -LiteralPath $gateInput.path).Hash
    if ($gateActual -ne $gateInput.sha256) { throw "Frozen gate input changed: $($gateInput.path)" }
}
& (Join-Path $pdsRoot "bin/pds_shell.exe") -file (Join-Path $gateDir "build.tcl") -work_dir $gateDir -project_name __NAME__
if ($LASTEXITCODE -ne 0) { throw "Resource gate failed: $LASTEXITCODE" }
'''.replace('__NAME__', config['top_module'] + '_pds')
    (out / 'launch.ps1').write_text(launch, encoding='utf-8')
    print('PREPARED_ONLY=' + str(out))
    print('Exact frozen RTL=%d; constraints=%d; copied IP files=%d; StopAfter=dev_map; NOT LAUNCHED' %
          (len(sources), len(constraints), len(list((out / 'ipcore').rglob('*')))))


if __name__ == '__main__':
    main()
