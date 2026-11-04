"""Run actual RTL raster verification and export the dashboard preview artifacts.

Run from any directory: python scripts/render_dashboard.py
Frozen font ROMs suffice; font installation is needed only to regenerate assets.
The PNGs contain deterministic simulation inputs, never board measurements.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def export():
    work = ROOT / 'build/sim/dashboard_ui'
    log = work / 'run.log'
    if 'RESULT: PASS dashboard_ui frames=5 active_pixels=10368000 bar_checks=2000' not in log.read_text(encoding='utf-8'):
        raise RuntimeError('A complete successful dashboard RTL raster run is required')
    artifacts = {}
    for state in ['waiting', 'ready', 'full_scale', 'zero', 'clamped']:
        source = work / (state + '.ppm')
        target = ROOT / 'reports' / ('ui_dashboard_' + state + '_20261102.png')
        with Image.open(source) as image:
            if image.size != (1920, 1080):
                raise RuntimeError('Incorrect active raster size')
            image.save(target)
        artifacts[state] = dict(path=target.relative_to(ROOT).as_posix(), sha256=sha(target), ppm_sha256=sha(source))
    # Saturation must affect both numeric text and graph identically.
    if sha(work / 'full_scale.ppm') != sha(work / 'clamped.ppm'):
        raise RuntimeError('100 percent and overrange inputs render differently')
    sources = [ROOT / p for p in ['src/ui/dashboard_renderer.v', 'src/ui/dashboard_text.v', 'src/ui/bars_data.v',
                                  'src/ctrl/instrec_top.v', 'sim/tb_dashboard_ui.sv', 'sim/tb_dynamic_ui.sv',
                                  'scripts/gen_dashboard_assets.py', 'scripts/render_dashboard.py']]
    sources += sorted((ROOT / 'src/ui').glob('dashboard_*.hex'))
    report = dict(status='RTL_SIMULATION_PASS_NOT_BOARD_TESTED', model='Original eight-class single-label model unchanged',
                  input='Deterministic synthetic waveform, Mel-feature byte fixture and probabilities; not captured audio',
                  active_pixels_per_frame=2073600, frames=5, checked_active_pixels=10368000,
                  bar_interior_checks=2000, video_latency_clocks=4,
                  checks=['RAM bounds', '1920-column waveform window resampled over the 1024-pixel plot',
                          'all 258 feature columns and 64 reversed frequency rows',
                          'DE/HS/VS four-clock alignment', 'card border and plot isolation',
                          'empty/ready/0/100/overrange states', '100/255 byte-identical complete rasters'],
                  pds='NOT_RUN', bitstream='NONE', board='UNAVAILABLE_NOT_PROGRAMMED',
                  sources={p.relative_to(ROOT).as_posix(): sha(p) for p in sources},
                  run_log_sha256=sha(log), artifacts=artifacts)
    path = ROOT / 'reports/ui_dashboard_validation_20261102.json'
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
    print(path)


def main():
    subprocess.run([sys.executable, 'sim/run_sim.py', 'dashboard_ui'], cwd=ROOT, check=True)
    export()


if __name__ == '__main__':
    main()
