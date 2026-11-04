"""Check all portable projects without requiring a PDS license."""
from pathlib import Path
import importlib.util
import json
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
hardware = root / 'hardware'
spec = importlib.util.spec_from_file_location('portable_build', hardware / 'tools/build_project.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
config = json.loads((hardware / 'projects.json').read_text(encoding='utf-8-sig'))
if config['device'] != 'PG2L100H' or config['package'] != 'FBG676':
    raise ValueError('Unexpected competition device')
with tempfile.TemporaryDirectory(prefix='pacerv-100proplus-') as temp:
    for name in config['projects']:
        result = build.prepare(name, (Path(temp) / name).resolve(), 'compile')
        print(f"PREPARED {name}: {len(result['files'])} inputs; PG2L100H / FBG676")
print(f"PASS: {len(config['projects'])} project configurations")
