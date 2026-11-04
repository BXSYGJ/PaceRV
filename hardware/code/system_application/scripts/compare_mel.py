#!/usr/bin/env python3
"""Compare the top_mel_test feature hex stream against the golden feature map.

Task: T23 (stand-alone Mel-engine validation bitstream).

The bitstream ``build/top_mel_test-latest.sbit`` emits, after one reset:

  1. one 91-byte diagnostic frame (G = 0x01, STATUS before the stream),
  2. the full 16512-byte Mel feature as uppercase hex, two digits per byte,
     one newline after every 64 bytes (one Mel frame, frame-major order),
  3. one 91-byte diagnostic frame (G = 0x02, DONE with checksums).

Expected reference: ``reports/golden_ref/sine_440_full/feat.npy``
(uint8, shape (64, 258), zp_in = 49).  NOTE: the file under
``scripts/outputs/golden/sine_440_full_feat.npy`` is an all-zero int8
silence map and is NOT a valid reference for this test.

Element order (the only easy mistake in this comparison)
---------------------------------------------------------
  * golden .npy  : C-order over shape (64, 258) -> index = mel * 258 + frame
  * RTL stream   : frame-major, index = frame * 64 + mel
                   (mel_engine spectrum bank address = frame*64 + mel)
so the RTL byte stream reshaped to (258, 64) must be TRANSPOSED before it
lines up with ``golden.flatten()``.  Both orders are reported, so a layout
error is visible instead of being attributed to arithmetic.

Usage
-----
  # reference self-check (no board needed, prints the expected values)
  python scripts/compare_mel.py --golden-only
  python scripts/compare_mel.py --golden-only --rows 4

  # compare a raw UART capture (bytes as received from the port)
  python scripts/compare_mel.py --capture reports/mel_test/uart.bin
  python scripts/compare_mel.py --capture reports/mel_test/uart.bin \\
      --json reports/mel_test/compare.json

  # compare an already-decoded text capture (hex lines only)
  python scripts/compare_mel.py --hex-file reports/mel_test/uart.txt

Exit codes: 0 = byte-exact match AND clean diagnostic frames,
            1 = mismatch or a diagnostic-frame problem,
            2 = bad arguments/input.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REF = ROOT / 'reports' / 'golden_ref' / 'sine_440_full' / 'feat.npy'

#: Feature geometry, frozen by golden_pipeline.py (N_MELS x N_FRAMES).
FEAT_SHAPE = (64, 258)
FEAT_BYTES = FEAT_SHAPE[0] * FEAT_SHAPE[1]
#: Elements per emitted text line (one Mel frame).
LINE_BYTES = 64
#: Character set accepted as payload.
HEX_CHARS = set('0123456789ABCDEFabcdef')

#: Snapshot of the staged audio input, for the report only.
GOLDEN_CONDITIONS = {
    'source_wav': 'tests/fixtures/sine_440_full.wav',
    'sample_rate_hz': 44100,
    'channels': 1,
    'pcm_dtype': 'int16',
    'pcm_formula': 'round(sin(2*pi*440.0*n/44100.0) * 32767)',
    'window_samples': 132096,
    'hop': 512,
    'n_fft': 2048,
    'n_frames': 258,
    'feat_dtype': 'uint8',
    'feat_shape': list(FEAT_SHAPE),
    'zp_in': 49,
    'feat_order_on_wire': 'frame-major (frame*64 + mel)',
}

#: Diagnostic byte offsets of the two frames this bitstream emits.
STATUS_FRAME_G = 0x01
DONE_FRAME_G = 0x02

#: Field slices of the H status byte of top_mel_test (see the RTL header).
STATUS_H_BITS = {
    'design_marker': (0, 0),
    'mel_busy': (1, 1),
    'win_miss': (2, 2),
    'addr_err': (3, 3),
    'run_timeout': (4, 4),
    'mel_timeout': (5, 5),
    'mel_done_seen': (6, 6),
    'hex_done': (7, 7),
}

#: Expected command counts of the mel_engine window (mel_engine.v header).
EXPECT_RD_CMDS = 516     # PCM reads, 516 x 256 samples = 132096
EXPECT_WR_CMDS = 1032    # dB export, 1032 x 16 elements = 16512


# ---------------------------------------------------------------------------
# Golden side
# ---------------------------------------------------------------------------
def load_golden(path: Path) -> np.ndarray:
    """Load and validate the golden feature map (uint8, shape (64, 258))."""
    feat = np.load(str(path))
    if feat.dtype != np.uint8:
        raise ValueError(f'{path}: expected uint8, got {feat.dtype}')
    if feat.shape != FEAT_SHAPE:
        raise ValueError(f'{path}: expected shape {FEAT_SHAPE}, got {feat.shape}')
    return feat


def rtl_order(feat: np.ndarray) -> np.ndarray:
    """Golden map -> the byte order the RTL streams (frame-major)."""
    return feat.T.reshape(-1)          # (258, 64) -> frame*64 + mel


def golden_checksums(feat: np.ndarray) -> dict[str, int]:
    """Reproduce top_mel_test's side-32 checksums over the wire byte order."""
    wire = rtl_order(feat).astype(np.uint32)
    xor_acc = 0
    sum_acc = 0
    for value in wire.tolist():
        xor_acc ^= value
        sum_acc = (sum_acc + value) & 0xFFFFFFFF
    return {'xor': xor_acc, 'sum': sum_acc}


# ---------------------------------------------------------------------------
# Capture side
# ---------------------------------------------------------------------------
def split_capture(blob: bytes) -> tuple[list[str], bytes, int]:
    """Split a raw UART capture into frames, hex payload and junk bytes.

    The RTL emits exactly two kinds of lines: 91-byte ``DIAG ...`` frames and
    pure hex lines of 128 characters (one newline per 64 feature bytes).
    Anything else (boot banner, partial first line after opening the port)
    is counted as junk and dropped.
    """
    frames: list[str] = []
    payload: list[bytes] = []
    junk = 0
    for raw_line in blob.split(b'\n'):
        line = raw_line.rstrip(b'\r')
        if not line:
            continue
        if line.startswith(b'DIAG '):
            frames.append(line.decode('ascii', 'replace'))
            continue
        if all(chr(byte) in HEX_CHARS for byte in line) and len(line) >= 2:
            payload.append(line)
            continue
        junk += 1
    return frames, b''.join(payload), junk


def decode_payload(payload: bytes) -> bytes:
    """Turn the hex payload (even length) into feature bytes."""
    if len(payload) % 2 != 0:
        raise ValueError(f'hex payload has an odd character count '
                         f'({len(payload)})')
    try:
        return bytes.fromhex(payload.decode('ascii'))
    except ValueError as exc:              # pragma: no cover - defensive
        raise ValueError(f'hex payload is not decodable: {exc}') from exc


def decode_status(field_h: int) -> dict[str, int]:
    """Split the H byte of a top_mel_test diagnostic frame."""
    return {
        name: (field_h >> lsb) & ((1 << (msb - lsb + 1)) - 1)
        for name, (msb, lsb) in STATUS_H_BITS.items()
    }


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------
def compare(wire_bytes: bytes, feat: np.ndarray) -> dict:
    """Byte-exact comparison of the captured stream against the golden map."""
    if len(wire_bytes) != FEAT_BYTES:
        return {
            'ok': False,
            'reason': f'payload length {len(wire_bytes)} != expected {FEAT_BYTES}',
            'wire_bytes': len(wire_bytes),
        }

    wire = np.frombuffer(wire_bytes, dtype=np.uint8)
    # Wire order is frame-major: element = frame*64 + mel.
    wire_map = wire.reshape(FEAT_SHAPE[1], FEAT_SHAPE[0])      # (258, 64)
    wire_as_golden = wire_map.T.reshape(-1)                    # (64, 258)

    golden_flat = feat.reshape(-1)
    exact = np.array_equal(wire_as_golden, golden_flat)
    different = int(np.count_nonzero(wire_as_golden != golden_flat))
    wrong_order = int(np.count_nonzero(wire != golden_flat))

    first = None
    if different:
        index = int(np.argmax(wire_as_golden != golden_flat))
        first = {
            'flat_index': index,
            'mel': index // FEAT_SHAPE[1],
            'frame': index % FEAT_SHAPE[1],
            'got': int(wire_as_golden[index]),
            'expected': int(golden_flat[index]),
        }

    xor_acc = 0
    sum_acc = 0
    for value in wire.tolist():
        xor_acc ^= value
        sum_acc = (sum_acc + value) & 0xFFFFFFFF

    return {
        'ok': exact,
        'reason': 'byte-exact' if exact else f'{different} byte(s) differ',
        'wire_bytes': len(wire_bytes),
        'different_bytes': different,
        'different_bytes_without_transpose': wrong_order,
        'first_difference': first,
        'wire_checksums': {'xor': xor_acc, 'sum': sum_acc},
        'golden_checksums': golden_checksums(feat),
        'sha256_wire': hashlib.sha256(wire_bytes).hexdigest(),
        'sha256_golden': hashlib.sha256(feat.tobytes()).hexdigest(),
    }


def check_frames(frames: list[str]) -> dict:
    """Decode both diagnostic frames and assert the fixed expectations."""
    sys.path.insert(0, str(ROOT / 'scripts'))
    import diag_frames                                   # noqa: PLC0415

    status: dict = {'frames_decoded': 0, 'frames': []}
    for line in frames:
        record = diag_frames.parse_frame(line)
        if record is None:
            status.setdefault('undecoded', []).append(line[:40])
            continue
        status['frames_decoded'] += 1
        record['status_bits'] = decode_status(record['h'])
        status['frames'].append(record)

    problems: list[str] = []
    status_frame = next((f for f in status['frames'] if f['g'] == STATUS_FRAME_G), None)
    done_frame = next((f for f in status['frames'] if f['g'] == DONE_FRAME_G), None)
    if status_frame is None:
        problems.append('STATUS frame (G=0x01) missing')
    if done_frame is None:
        problems.append('DONE frame (G=0x02) missing')

    if done_frame is not None:
        if done_frame['d'] != EXPECT_WR_CMDS:
            problems.append(
                f"dB export command count {done_frame['d']} != {EXPECT_WR_CMDS}")
        bits = done_frame['status_bits']
        if not bits['hex_done']:
            problems.append('DONE frame has hex_done = 0')
        if not bits['mel_done_seen']:
            problems.append('DONE frame has mel_done_seen = 0')
        if bits['mel_timeout']:
            problems.append('mel_engine watchdog fired (mel_timeout = 1)')
        if bits['run_timeout']:
            problems.append('top-level run timeout fired')
        if bits['addr_err']:
            problems.append('fake PCM source saw an address mismatch')

    if status_frame is not None:
        if status_frame['c'] != EXPECT_RD_CMDS:
            problems.append(
                f"PCM read command count {status_frame['c']} != {EXPECT_RD_CMDS}")
        if status_frame['b'] == 0:
            problems.append('STATUS frame reports mel_cycles = 0')

    status['problems'] = problems
    return status


# ---------------------------------------------------------------------------
# Reference self-check (--golden-only)
# ---------------------------------------------------------------------------
def golden_report(feat: np.ndarray, rows: int) -> str:
    """Human-readable reference dump used before the build."""
    wire = rtl_order(feat)
    sums = golden_checksums(feat)
    lines = [
        'golden reference: reports/golden_ref/sine_440_full/feat.npy',
        f'  dtype        : {feat.dtype}',
        f'  shape        : {feat.shape}',
        f'  min / max    : {int(feat.min())} / {int(feat.max())}',
        f'  unique values: {np.unique(feat).tolist()}',
        f'  sha256       : {hashlib.sha256(feat.tobytes()).hexdigest()}',
        '',
        'generation conditions (must match top_mel_test.v):',
    ]
    for key, value in GOLDEN_CONDITIONS.items():
        lines.append(f'  {key:22s}: {value}')
    lines += [
        '',
        f'first {rows} values, golden C-order (index = mel*258 + frame):',
        '  ' + ' '.join(f'{v:3d}' for v in feat.reshape(-1)[:rows].tolist()),
        '',
        f'first {rows} values, RTL wire order (index = frame*64 + mel):',
        '  ' + ' '.join(f'{v:3d}' for v in wire[:rows].tolist()),
        '',
        f'first {min(rows, FEAT_SHAPE[0])} values of frame 0 (mel 0..N):',
        '  ' + ' '.join(f'{v:3d}' for v in wire[:rows].tolist()),
        '',
        'expected side-32 checksums of the hex stream:',
        f'  xor8  (xor of all 8-bit values) : 0x{sums["xor"]:08X} ({sums["xor"]})',
        f"  sum8  (sum mod 2^32)            : 0x{sums['sum']:08X} ({sums['sum']})",
        f'  payload bytes                    : {FEAT_BYTES}',
        '  DONE frame B field must equal the xor8 value above.',
    ]
    return '\n'.join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description='Compare the top_mel_test feature hex stream with '
                    'reports/golden_ref/sine_440_full/feat.npy (T23).')
    ap.add_argument('--golden-only', action='store_true',
                    help='print the expected feature values and checksums '
                         'only (no capture needed)')
    ap.add_argument('--ref', default=str(DEFAULT_REF),
                    help='golden feature .npy (default: %(default)s)')
    ap.add_argument('--capture', help='raw UART capture file (bytes)')
    ap.add_argument('--hex-file',
                    help='text capture holding only the hex payload lines')
    ap.add_argument('--json', help='write the comparison evidence to this path')
    ap.add_argument('--rows', type=int, default=16,
                    help='values per dump line in --golden-only (default: 16)')
    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    ref_path = Path(args.ref)
    try:
        feat = load_golden(ref_path)
    except (OSError, ValueError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 2

    if args.golden_only:
        print(golden_report(feat, max(1, args.rows)))
        return 0

    if not args.capture and not args.hex_file:
        print('error: give --capture / --hex-file, or --golden-only',
              file=sys.stderr)
        return 2

    try:
        if args.capture:
            blob = Path(args.capture).read_bytes()
            frames, payload, junk = split_capture(blob)
        else:
            text = Path(args.hex_file).read_text(encoding='ascii',
                                                 errors='replace')
            frames, payload, junk = split_capture(text.encode('ascii',
                                                              'replace'))
        wire_bytes = decode_payload(payload)
    except (OSError, ValueError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 2

    result = compare(wire_bytes, feat)
    frames_report = check_frames(frames)
    result['frames'] = frames_report
    result['junk_lines'] = junk
    result['capture'] = args.capture or args.hex_file
    result['reference'] = str(ref_path)

    print(f'capture        : {result["capture"]}')
    print(f'reference      : {ref_path}')
    print(f'hex payload    : {len(wire_bytes)} byte(s), '
          f'{len(payload)} hex char(s), {junk} junk line(s)')
    print(f'frames decoded : {frames_report["frames_decoded"]}')
    for problem in frames_report['problems']:
        print(f'  frame issue  : {problem}')

    if 'reason' in result and result['wire_bytes'] != FEAT_BYTES:
        print(f'RESULT         : FAIL - {result["reason"]}')
        _maybe_write_json(args.json, result)
        return 1

    status = 'PASS' if result['ok'] else 'FAIL'
    print(f'bytes differ   : {result["different_bytes"]} '
          f'(frame-major order, without transpose: '
          f'{result["different_bytes_without_transpose"]})')
    if result['first_difference']:
        diff = result['first_difference']
        print(f'first mismatch : flat {diff["flat_index"]} '
              f'(mel {diff["mel"]}, frame {diff["frame"]}) '
              f'got {diff["got"]} expected {diff["expected"]}')
    print(f'wire  checksums: xor=0x{result["wire_checksums"]["xor"]:08X} '
          f'sum=0x{result["wire_checksums"]["sum"]:08X}')
    print(f'golden checksums: xor=0x{result["golden_checksums"]["xor"]:08X} '
          f'sum=0x{result["golden_checksums"]["sum"]:08X}')
    print(f'sha256 wire    : {result["sha256_wire"]}')
    print(f'sha256 golden  : {result["sha256_golden"]}')
    print(f'bytes status   : {status}')

    _maybe_write_json(args.json, result)
    # A product-level PASS needs BOTH the byte-exact feature stream and a
    # clean pair of diagnostic frames (command counts, sticky flags): the
    # frames are the only evidence that the stream came from a complete
    # mel_engine run rather than from a truncated or restarted one.
    if not result['ok']:
        print('RESULT         : FAIL - feature bytes differ')
        return 1
    if frames_report['problems']:
        print('RESULT         : FAIL - feature bytes match but diagnostic '
              'frames report a problem (see the frame issues above)')
        return 1
    print('RESULT         : PASS')
    return 0


def _maybe_write_json(path: str | None, payload: dict) -> None:
    """Write the evidence file as BOM-less UTF-8 JSON when requested."""
    if not path:
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    data = dict(payload)
    data['golden_conditions'] = GOLDEN_CONDITIONS
    target.write_text(json.dumps(data, indent=2, sort_keys=True),
                      encoding='utf-8', newline='\n')
    print(f'evidence       : {target}')


if __name__ == '__main__':
    sys.exit(main())