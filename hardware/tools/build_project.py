"""Portable 100Pro+ PDS project preparation and background execution."""
from pathlib import Path
import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def local(base, relative):
    path = (base / relative).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError('Path escapes the package: ' + str(relative))
    return path


def tcl_path(path):
    text = Path(path).resolve().as_posix()
    if any(c in text for c in '{}\r\n'):
        raise ValueError('Unsupported Tcl path characters')
    return '{' + text + '}'


def expand(base, patterns):
    result = []
    for pattern in patterns:
        matches = sorted(glob.glob(str(local(base, pattern))))
        if not matches and not glob.has_magic(pattern):
            raise FileNotFoundError(pattern)
        for name in matches:
            p = Path(name).resolve()
            if not p.is_file():
                raise FileNotFoundError(p)
            if p not in result:
                result.append(p)
    return result


def prepare(name, output, stop):
    config = json.loads((ROOT / 'projects.json').read_text(encoding='utf-8-sig'))
    project = config['projects'][name]
    base = local(ROOT, project['root'])
    sources = expand(base, project['sources'])
    ips = expand(base, project['ip_cores'])
    constraints = expand(base, project['constraints'])
    if not sources:
        raise ValueError('Empty source list')
    output.mkdir(parents=True, exist_ok=True)
    for entry in project['copies']:
        src = local(base, entry['source'])
        target = (output / entry['destination']).resolve()
        if not src.is_file() or not target.is_relative_to(output):
            raise ValueError('Invalid initialization dependency: ' + str(entry))
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, target)
    commands = [f'add_design {tcl_path(p)}' for p in sources + ips]
    commands += [f'add_constraint {tcl_path(p)}' for p in constraints]
    commands += ['set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676',
                 'compile -system_verilog -top_module ' + project['top']]
    stages = ['compile', 'synthesize', 'dev_map', 'pnr', 'report_timing', 'gen_bit_stream']
    flow = ['synthesize -ads -selected_syn_tool_opt 2', 'dev_map',
            'pnr ' + project['pnr_options'], 'report_timing', 'gen_bit_stream']
    commands += flow[:stages.index(stop)]
    # PDS batch files use top-level flow commands. Verify their own stage
    # completion records rather than assuming generic Tcl control support.
    text = '\n'.join(commands) + '\n'
    (output / 'build.tcl').write_text(text, encoding='utf-8')
    inputs = sources + ips + constraints + [local(base, x['source']) for x in project['copies']]
    identity = {'project': name, 'board': config['board'], 'device': config['device'],
                'package': config['package'], 'top': project['top'], 'stop_after': stop,
                'files': [{'path': p.relative_to(ROOT).as_posix(),
                           'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in inputs]}
    (output / 'inputs.json').write_text(json.dumps(identity, indent=2), encoding='utf-8')
    return identity


def main():
    names = json.loads((ROOT / 'projects.json').read_text(encoding='utf-8-sig'))['projects']
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project', choices=names)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--stop-after', choices=['compile', 'synthesize', 'dev_map', 'pnr', 'report_timing', 'gen_bit_stream'], default='gen_bit_stream')
    parser.add_argument('--pds-root', type=Path, default=os.environ.get('PDS_ROOT'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = (args.output or ROOT / 'build' / args.project).resolve()
    if output == ROOT or ROOT.is_relative_to(output):
        raise ValueError('Output must be a dedicated build directory')
    identity = prepare(args.project, output, args.stop_after)
    if args.prepare_only:
        print(f'PREPARED {args.project}: {len(identity["files"])} inputs; PG2L100H / FBG676')
        return 0
    if not args.pds_root:
        raise ValueError('Set PDS_ROOT or pass --pds-root')
    shell = args.pds_root.resolve() / 'bin/pds_shell.exe'
    if not shell.is_file():
        raise FileNotFoundError(shell)
    kwargs = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
    cmd = [str(shell), '-file', str(output / 'build.tcl'), '-work_dir', str(output), '-project_name', args.project]
    with (output / 'pds-console.log').open('wb') as log:
        process = subprocess.run(cmd, cwd=output, stdout=log, stderr=subprocess.STDOUT, **kwargs)
    data = (output / 'pds-console.log').read_bytes()
    stage = args.stop_after.encode()
    completed = re.search(rb'Executing\s*:\s*' + stage + rb'[^\r\n]*successfully', data, re.I)
    errors = [line for line in data.splitlines() if re.match(rb'^E:', line) and b'SCBV' not in line]
    successful = process.returncode == 0 and bool(completed) and not errors
    summary = {k: identity[k] for k in ['project', 'board', 'device', 'package', 'stop_after']}
    summary.update({'exit_status': process.returncode, 'tool_stage_completed': successful})
    (output / 'result.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps(summary))
    if not successful:
        print('Inspect ' + str(output / 'pds-console.log'), file=sys.stderr)
        return 1
    # Completion of the bitstream flow is distinct from timing acceptance.
    if args.stop_after == 'gen_bit_stream':
        reports = list((output / 'report_timing').glob('*.rtr'))
        if not reports:
            raise RuntimeError('Timing report missing')
        if not list((output / 'generate_bitstream').glob('*.sbit')):
            raise RuntimeError('Bitstream missing')
        print('Check every timing requirement in report_timing before promoting this image.')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
