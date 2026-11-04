#!/usr/bin/env python3
"""Capture UART bytes from the board and optionally parse layer-export frames.

Usage:
  python scripts/uart_capture.py --port COM5 --seconds 20 --out build/uart.log
  python scripts/uart_capture.py --port COM5 --seconds 20 --hex
  python scripts/uart_capture.py --port COM5 --seconds 30 --frames --out-dir reports/m2_frames
  python scripts/uart_capture.py --port COM5 --seconds 30 --frames --layer 0x06
  python scripts/uart_capture.py --port COM5 --seconds 60 --frames \
      --out-dir reports/m2_frames --compare \
      --golden-feat scripts/outputs/golden/sine_440_full_feat.npy

Default output is a UTF-8 text dump with non-printable bytes escaped.
With --frames the raw stream is parsed as design.md 9.2 frames
(AA | layer_id | seq | len | payload | crc16); each observed layer is
reassembled and saved as .npy when --out-dir is given.
With --compare (implies --frames) the saved tensors are compared against
golden_pipeline.npu_forward via compare_layers (same code the standalone
CLI uses), printing the per-layer coverage / exact / +/-1 LSB table.
Exit code 0 if the port opened and no compared layer failed, 1 if a
layer could not be compared, 2 if the port could not be opened or the
references could not be generated.
"""
import argparse
import sys
import time
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='COM5')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--seconds', type=float, default=10.0)
    ap.add_argument('--out')
    ap.add_argument('--hex', action='store_true')
    ap.add_argument('--frames', action='store_true')
    ap.add_argument('--out-dir')
    ap.add_argument('--layer')
    ap.add_argument('--compare', action='store_true',
                    help='compare the saved layers against the golden NPU '
                         '(implies --frames, needs --out-dir)')
    ap.add_argument('--golden-feat', help='golden uint8 feature .npy')
    ap.add_argument('--golden-dir',
                    help='directory searched for <stem>_feat.npy')
    ap.add_argument('--stem', help='golden run stem, e.g. sine_440_full')
    ap.add_argument('--probs-encoding', choices=('percent', 'q0.8'),
                    default='percent',
                    help='u8 encoding of the PROBS export (default percent)')
    args = ap.parse_args()

    if args.compare:
        args.frames = True
        if not args.out_dir:
            print('--compare needs --out-dir to store the reassembled layers',
                  file=sys.stderr)
            return 2

    try:
        import serial
    except ImportError:
        print('pyserial not installed: pip install pyserial', file=sys.stderr)
        return 2

    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.2)
    except Exception as exc:
        print(f'cannot open {args.port}: {exc}', file=sys.stderr)
        return 2

    chunks = []
    deadline = time.time() + args.seconds
    try:
        while time.time() < deadline:
            data = ser.read(4096)
            if data:
                chunks.append(data)
    finally:
        ser.close()

    raw = b''.join(chunks)

    if args.frames:
        import uart_frames as uf

        frames = uf.parse_frames(raw)
        counts = {}
        for lid, _seq, payload in frames:
            counts[lid] = counts.get(lid, 0) + len(payload)
        print(f'[frames {len(frames)}, bytes {len(raw)}]', file=sys.stderr)
        for lid in sorted(counts):
            name = uf.LAYER_NAMES.get(lid & 0x7F, '?')
            flag = ' (sampled)' if lid & 0x80 else ''
            print(f'  layer 0x{lid:02x} {name}{flag}: {counts[lid]} bytes')

        wanted = None
        if args.layer:
            wanted = int(args.layer, 0)
        if args.out_dir:
            import numpy as np

            out_dir = Path(args.out_dir)
            out_dir.mkdir(parents=True, exist_ok=True)
            for lid in sorted(counts):
                if wanted is not None and lid != wanted:
                    continue
                try:
                    arr = uf.reassemble(frames, lid)
                except ValueError as exc:
                    print(f'  layer 0x{lid:02x}: {exc}', file=sys.stderr)
                    continue
                path = out_dir / f'layer_{lid:02x}.npy'
                np.save(path, arr)
                print(f'  saved {path} {arr.shape} {arr.dtype}')
        if args.compare:
            import compare_layers as cl

            wanted = None if wanted is None else [wanted]
            try:
                kwargs = {'probs_encoding': args.probs_encoding,
                          'layer_ids': wanted}
                if args.golden_feat:
                    kwargs['golden_feat'] = args.golden_feat
                if args.golden_dir:
                    kwargs['golden_dir'] = args.golden_dir
                if args.stem:
                    kwargs['stem'] = args.stem
                refs, notes = cl.build_references(**kwargs)
                rows = cl.compare_dir(out_dir, refs, wanted)
            except (OSError, ValueError, KeyError) as exc:
                print(f'[compare] {exc}', file=sys.stderr)
                return 2
            print(cl.format_table(rows, notes))
            failed = any(r['error'] and not r['skipped'] for r in rows)
            print(f'[captured {len(raw)} byte(s)]', file=sys.stderr)
            return 1 if failed else 0
        print(f'[captured {len(raw)} byte(s)]', file=sys.stderr)
        return 0

    if args.hex:
        text = raw.hex()
        text = ' '.join(text[i:i + 2] for i in range(0, len(text), 2))
    else:
        text = ''.join(chr(b) if 32 <= b < 127 or b in (10, 13, 9) else f'\\x{b:02x}'
                       for b in raw)

    if args.out:
        with open(args.out, 'w', encoding='utf-8', newline='') as fh:
            fh.write(text)
    print(text)
    print(f'[captured {len(raw)} byte(s)]', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())