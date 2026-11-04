#!/usr/bin/env python3
"""One-command board bring-up for InstRec-FPGA.

Chains the steps that used to be typed by hand, in the only order that makes
sense, and stops at the first stage that fails so a partial result is never
mistaken for a working system:

  1. ``board_check.py``   program the bitstream, read the status register,
                          capture the boot banner, verify the expected lines;
  2. ``weight_upload.py`` push the weight image over the same UART and wait
                          for the ``WOK`` acknowledgement;
  3. ``uart_capture.py``  capture per-layer frames into a directory;
  4. ``compare_layers.py``compare each layer against the golden model.

Stages 3 and 4 need real audio at the I2S input (the NPU only produces a
frame when a window completes), so they can be selected explicitly:

    python scripts/board_e2e.py --sbit build/instrec-latest.sbit
    python scripts/board_e2e.py --stage boot
    python scripts/board_e2e.py --stage layers --seconds 20 --stem sine_440_full

Every stage runs as a subprocess of the same interpreter, so the existing,
already-tested scripts stay the single source of truth.  No JTAG process is
ever started or killed here -- board_check owns that policy (single
jtagserver, reused, never terminated).
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'

BOOT_EXPECT = ['INSTREC BOOT', 'DDR3 SELFTEST', 'DDROK']


def run(stage, argv, env=None):
    """Run one stage, echo its output, return (ok, text)."""
    print(f'\n=== {stage} ===')
    print('$ ' + ' '.join(argv))
    proc = subprocess.run(argv, cwd=str(ROOT), capture_output=True, text=True,
                          env=env)
    text = (proc.stdout or '') + (proc.stderr or '')
    print(text.rstrip())
    ok = proc.returncode == 0
    print(f'--- {stage}: {"PASS" if ok else "FAIL"} (rc={proc.returncode})')
    return ok, text


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--sbit', default='build/instrec-latest.sbit')
    ap.add_argument('--port', default='COM5')
    ap.add_argument('--stage', choices=('all', 'boot', 'weights', 'layers'),
                    default='all')
    ap.add_argument('--seconds', type=float, default=12.0,
                    help='UART capture window for stage 3')
    ap.add_argument('--stem', default='sine_440_full',
                    help='golden run stem for stage 4')
    ap.add_argument('--frames-dir', default='build/board_frames')
    ap.add_argument('--image', default='scripts/outputs/weights_image.bin')
    ap.add_argument('--skip-boot-upload', action='store_true',
                    help='skip stages 1-2 and only capture/compare')
    args = ap.parse_args(argv)

    py = sys.executable
    stages = []

    if args.stage in ('all', 'boot'):
        stages.append(('boot', [
            py, str(SCRIPTS / 'board_check.py'),
            '--sbit', args.sbit, '--port', args.port,
            '--seconds', '8', '--expect', *BOOT_EXPECT,
        ]))

    if args.stage in ('all', 'weights'):
        stages.append(('weights', [
            py, str(SCRIPTS / 'weight_upload.py'),
            '--port', args.port, '--image', args.image,
        ]))

    if args.stage in ('all', 'layers'):
        frames = Path(args.frames_dir)
        stages.append(('capture', [
            py, str(SCRIPTS / 'uart_capture.py'),
            '--port', args.port, '--seconds', str(args.seconds),
            '--frames', '--out-dir', str(frames),
        ]))
        stages.append(('compare', [
            py, str(SCRIPTS / 'compare_layers.py'), str(frames),
            '--stem', args.stem,
        ]))

    if args.skip_boot_upload and args.stage == 'all':
        stages = [s for s in stages if s[0] in ('capture', 'compare')]

    results = []
    for name, cmd in stages:
        ok, _ = run(name, cmd)
        results.append((name, ok))
        if not ok:
            print(f'\nstopping after failed stage: {name}')
            break

    print('\n=== summary ===')
    for name, ok in results:
        print(f'{name:9s}: {"PASS" if ok else "FAIL"}')
    ran = {name for name, _ in results}
    for name, _ in stages:
        if name not in ran:
            print(f'{name:9s}: not run')

    all_ok = all(ok for _, ok in results) and len(results) == len(stages)
    if not all_ok and results and results[-1][0] == 'boot':
        print('\nBOOT failed: check the bitstream contains the UART handshake fix '
              '(uart_debug level handshake, 2026-10-29).')
    if not all_ok and results and results[-1][0] == 'weights':
        print('\nweight upload failed: the board must be idle in ST_WEIGHT; '
              'check the image sha256 and the m1 write path.')
    return 0 if all_ok else 1


if __name__ == '__main__':
    sys.exit(main())