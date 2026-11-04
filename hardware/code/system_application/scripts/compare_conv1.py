#!/usr/bin/env python3
"""compare_conv1.py -- offline golden / on-board UART comparator for the
conv1-only NPU verification bitstream (``top_npu_conv1_test``).

Why this script exists
----------------------
The NPU compute engines (conv/pool/gap/fc/softmax) have only ever been
proven at compile level; the full-model weights live in DDR3 and that
path is still unproven.  ``top_npu_conv1_test`` removes the DDR3
dependency by holding the whole conv1 tensor (432 B of weights, 192 B of
bias, 192 B of M, 48 B of shift) in on-chip ROMs, replaying the golden
Mel feature map from a ROM, running ``conv_engine`` once, and streaming a
sampled copy of the result over UART in C-DIAG-UART@1 frames.  This
script is the reader half of that experiment: it scores the captured
frames against ``reports/golden_ref/sine_440_full/conv1.npy`` byte by
byte.

Sampling contract (must stay bit-identical to the RTL constants)
---------------------------------------------------------------
``conv_engine`` emits the egress stream in scan order

    (out_row, group, col, lane)  ->  16 lanes per pixel

so the flat y-stream index of one u8 sample is

    k = ((row * 3 + grp) * 258 + col) * 16 + lane
    channel = grp * 16 + lane

The whole stream is 64 * 3 * 258 * 16 = 792576 samples (792 KB, ~69 s at
115200), so the RTL captures six disjoint 512-sample windows and the
UART only has to carry 3072 samples (~1 s).  ``WINDOWS`` below is the
SAME six windows hard-coded in ``src/diag/top_npu_conv1_test.v``
(``WIN_BASE_*`` / ``WIN_SPAN``).  The windows are chosen to cover

  * every one of the 48 output channels (groups 0/1/2 all sampled),
  * the top / bottom / left / right padding borders (rows 0 and 63,
    columns 0 and 257),
  * one interior block (row 32, group 1, columns 128..159),
  * all three contract groups at row 0 (channels 0..15, 16..31, 32..47).

Frame contract
--------------
Frames keep the 91-byte C-DIAG-UART@1 template verbatim; no field is
added or removed.  ``diag_uart_report.v`` hard-codes the tag names, so
this bitstream reuses two existing ``frame_tag`` codes:

    frame_tag = 2 ("DDR3SW" field text)  -> CONV1STS status frame
    frame_tag = 3 ("DDR3RS" field text)  -> CONV1DAT data frame

CONV1STS (one frame, sent before the data frames)::

    A = 0x434F4E31  magic "CON1"
    B = done flag   (1 = conv1 finished, layer_done seen)
    C = captured sample count (3072)
    D = 32-bit sum of all captured u8 samples
    E = y-stream sample count seen by the RTL (expected 792576)
    F = 0 (reserved)
    G = number of capture windows (6)
    H = 0xA5  status magic

CONV1DAT (128 frames, 24 samples each, little-endian inside every
32-bit field -- field bit[7:0] is the FIRST sample of that field)::

    A = samples  0.. 3     B =  4.. 7     C =  8..11
    D = samples 12..15     E = 16..19     F = 20..23
    G = frame index (low byte)          H = frame index (high byte)

Usage
-----
    python scripts/compare_conv1.py --golden-only
    python scripts/compare_conv1.py --golden-only --limit 64
    python scripts/compare_conv1.py --emit-hex
    python scripts/compare_conv1.py --uart-file build/uart_last.bin
    python scripts/compare_conv1.py --self-check
    python scripts/compare_conv1.py --uart-file dump.bin --json ev.json

Exit codes: 0 = match, 1 = mismatch or missing evidence, 2 = usage /
input error.
"""

from __future__ import annotations

import argparse
import io
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
CONTRACT_PATH = SCRIPTS / 'outputs' / 'layer_contract.json'
IMAGE_PATH = SCRIPTS / 'outputs' / 'weights_image.bin'
GOLDEN_DIR = ROOT / 'reports' / 'golden_ref' / 'sine_440_full'
FEAT_NPY = GOLDEN_DIR / 'feat.npy'
CONV1_NPY = GOLDEN_DIR / 'conv1.npy'
HEX_DIR = ROOT / 'hex_conv1'

#: conv1 geometry, identical to the conv_engine layer-0 parameters.
CONV1_H = 64
CONV1_W = 258
CONV1_CH = 48
CONV1_GRP = CONV1_CH // 16      # 3

#: Samples in the full conv1 egress stream (64 x 3 x 258 pixels x 16 lanes).
STREAM_SAMPLES = CONV1_H * CONV1_GRP * CONV1_W * 16        # 792576

#: (start, span) of the six capture windows in flat y-stream order.
#: MIRROR of the WIN_BASE_* / WIN_SPAN localparams in top_npu_conv1_test.v.
WINDOWS = (
    (0, 512),            # row 0,  group 0, col 0..31   (top + left pad)
    (4128, 512),         # row 0,  group 1, col 0..31   (ch 16..31)
    (8256, 512),         # row 0,  group 2, col 0..31   (ch 32..47)
    (402464, 512),       # row 32, group 1, col 128..159 (interior)
    (780192, 512),       # row 63, group 0, col 0..31   (bottom + left pad)
    (792064, 512),       # row 63, group 2, col 226..257 (right pad)
)

#: Samples the bitstream captures and the UART carries.
SAMPLE_COUNT = sum(span for _, span in WINDOWS)             # 3072

#: u8 samples per CONV1DAT frame (six 32-bit fields x 4 bytes).
FRAME_SAMPLES = 24

#: Number of CONV1DAT frames.
FRAME_COUNT = SAMPLE_COUNT // FRAME_SAMPLES                 # 128

#: frame_tag codes reused by this bitstream (see module docstring).
STS_TAG = 2
DAT_TAG = 3
STS_MAGIC = 0x434F4E31        # ASCII "CON1"
STS_TAIL = 0xA5

#: Reserved Verilog-relevant words are irrelevant here; this is Python.


# --------------------------------------------------------------------------- #
# golden side
# --------------------------------------------------------------------------- #
def load_contract(path: Path = CONTRACT_PATH) -> dict:
    """Read the layer contract (utf-8, the file carries non-ASCII notes)."""
    with io.open(path, encoding='utf-8') as handle:
        return json.load(handle)


def load_conv1(path: Path = CONV1_NPY) -> np.ndarray:
    """Golden conv1 output, (48, 64, 258) uint8."""
    conv1 = np.load(path)
    if conv1.shape != (CONV1_CH, CONV1_H, CONV1_W):
        raise SystemExit(
            'golden conv1 shape {0} != expected {1}'.format(
                conv1.shape, (CONV1_CH, CONV1_H, CONV1_W)))
    if conv1.dtype != np.uint8:
        raise SystemExit('golden conv1 dtype {0} != uint8'.format(conv1.dtype))
    return conv1


def stream_index(channel: int, row: int, col: int) -> int:
    """Flat y-stream index of one output sample (inverse of decode below)."""
    grp = channel // 16
    lane = channel % 16
    return ((row * CONV1_GRP + grp) * CONV1_W + col) * 16 + lane


def decode_stream_index(index: int) -> tuple[int, int, int, int]:
    """(row, group, col, lane) of a flat y-stream index."""
    pixel, lane = divmod(index, 16)
    col = pixel % CONV1_W
    row, grp = divmod(pixel // CONV1_W, CONV1_GRP)
    return row, grp, col, lane


def expected_samples(conv1: np.ndarray) -> np.ndarray:
    """Golden samples in the exact order the RTL captures them."""
    out = np.empty(SAMPLE_COUNT, dtype=np.uint8)
    pos = 0
    for base, span in WINDOWS:
        for index in range(base, base + span):
            row, grp, col, lane = decode_stream_index(index)
            out[pos] = conv1[grp * 16 + lane, row, col]
            pos += 1
    return out


def verify_sampling_rule(conv1: np.ndarray, feat: np.ndarray,
                         contract: dict) -> dict:
    """Recompute conv1 from the golden feature map and diff the two.

    This proves the golden ``conv1.npy`` still matches the bit-exact
    reference of ``golden_pipeline.conv2d_int8`` (round-half-even requant,
    padding == zp_in in the uint8 container, i.e. 0 in the signed MAC
    domain -- exactly what conv_engine's read-side pad guard does), so a
    board match against ``conv1.npy`` is a match against the golden.
    """
    if str(SCRIPTS) not in sys.path:
        sys.path.insert(0, str(SCRIPTS))
    import golden_pipeline as gp          # noqa: E402  (path set above)

    weights = gp.load_weights_from_image(contract)
    c1 = gp.conv2d_int8(feat[np.newaxis, :, :], weights['conv1'])
    diff = np.abs(c1.astype(np.int16) - conv1.astype(np.int16))
    return {
        'shape': list(c1.shape),
        'max_abs_diff': int(diff.max()),
        'mismatch_count': int((diff != 0).sum()),
        'total': int(diff.size),
    }


# --------------------------------------------------------------------------- #
# weight image -> $readmemh tables
# --------------------------------------------------------------------------- #
def _hex_word(value: int) -> str:
    return '{0:08X}'.format(int(value) & 0xFFFFFFFF)


def build_tables(contract: dict, image: bytes) -> dict:
    """Split the conv1 segment of the weight image into the three ROMs.

    ``weights_image.bin`` conv1 payload starts at ``layers[0].image_offset``
    (512) and is 864 bytes: 432 weight + 192 bias + 192 M + 48 shift, all
    in the exact order the layer contract records (``bias_off`` 432,
    ``m_off`` 624, ``shift_off`` 816).

    The weight block is group-major: 16 output channels per group, and
    inside one group the 9 taps are contiguous, each tap being 16 signed
    bytes (lane 0 first).  That is bit-identical to the 128-bit tap word
    conv_engine consumes, so the ROM needs no re-interleave.
    """
    rec = contract['layers'][0]
    base = int(rec['image_offset'])
    seg = image[base:base + int(rec['segment_bytes'])]
    if len(seg) != int(rec['segment_bytes']):
        raise SystemExit('weight image truncated at the conv1 segment')

    weight = seg[:rec['weight_bytes']]
    bias = np.frombuffer(seg[rec['bias_off']:rec['bias_off'] + rec['bias_bytes']],
                         dtype='<i4')
    muls = np.frombuffer(seg[rec['m_off']:rec['m_off'] + rec['m_bytes']],
                         dtype='<i4')
    shifts = np.frombuffer(seg[rec['shift_off']:rec['shift_off'] + rec['shift_bytes']],
                           dtype=np.uint8)
    if bias.tolist() != rec['bias_int32']:
        raise SystemExit('image conv1 bias block != layer_contract bias_int32')
    if muls.tolist() != rec['M']:
        raise SystemExit('image conv1 M block != layer_contract M')
    if shifts.tolist() != rec['shift']:
        raise SystemExit('image conv1 shift block != layer_contract shift')

    # 128-bit tap words -> 4 little-endian 32-bit ROM words per tap.
    w32 = []
    for tap in range(rec['weight_bytes'] // 16):
        for sub in range(4):
            off = tap * 16 + sub * 4
            w32.append(int.from_bytes(weight[off:off + 4], 'little'))

    # 48 bias + 48 M + 48 shift, shift kept in the low 7 bits.
    ctr = [int(v) for v in bias] + [int(v) for v in muls] \
        + [int(v) & 0x7F for v in shifts]

    return {'w32': w32, 'ctr': ctr}


def _write_hex(path: Path, values, width: int) -> int:
    """One value per line, upper-case zero padded (PDS $readmemh format).

    ``width`` is the ROM word width in bytes (2 for the u8 tables, 4 for the
    signed 32-bit contract table).  Signed entries are written as their
    two's-complement pattern; the formatter must therefore never look at the
    Python value's sign or magnitude to pick the field width.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    digits = width * 2
    text = '\n'.join('{0:0{1}X}'.format(int(v) & ((1 << (8 * width)) - 1), digits)
                     for v in values) + '\n'
    with io.open(path, 'w', encoding='ascii', newline='\n') as handle:
        handle.write(text)
    return len(values)


def emit_hex(out_dir: Path = HEX_DIR) -> dict:
    """Write the three $readmemh tables the conv1 test bitstream needs."""
    contract = load_contract()
    image = IMAGE_PATH.read_bytes()
    if len(image) != int(contract['image_total_bytes']):
        raise SystemExit(
            'weight image size {0} != contract image_total_bytes {1}'.format(
                len(image), contract['image_total_bytes']))
    tables = build_tables(contract, image)
    feat = np.load(FEAT_NPY)
    if feat.shape != (CONV1_H, CONV1_W):
        raise SystemExit('golden feat shape {0} != (64, 258)'.format(feat.shape))

    written = {
        'conv1_w32.hex': _write_hex(out_dir / 'conv1_w32.hex', tables['w32'], 4),
        'conv1_ctr.hex': _write_hex(out_dir / 'conv1_ctr.hex', tables['ctr'], 4),
        'conv1_feat.hex': _write_hex(out_dir / 'conv1_feat.hex',
                                     feat.reshape(-1).tolist(), 1),
    }
    return {'out_dir': str(out_dir), 'lines': written,
            'weight_words': len(tables['w32']),
            'contract_words': len(tables['ctr'])}


# --------------------------------------------------------------------------- #
# board side
# --------------------------------------------------------------------------- #
def _unpack_field(value: int) -> list[int]:
    """Little-endian bytes of one 32-bit frame field (first sample in [7:0])."""
    return [(value >> (8 * i)) & 0xFF for i in range(4)]


def decode_frames(frames: list[dict]) -> dict:
    """Split parsed frames into one CONV1STS record and the data samples."""
    status = None
    data: dict[int, list[int]] = {}
    other = 0
    for record in frames:
        if record['tag'] == 'DDR3SW' and record.get('a') == STS_MAGIC:
            if status is None:
                status = record
        elif record['tag'] == 'DDR3RS':
            index = (record.get('g') or 0) | ((record.get('h') or 0) << 8)
            if index < FRAME_COUNT:
                samples = []
                for field in ('a', 'b', 'c', 'd', 'e', 'f'):
                    samples.extend(_unpack_field(record[field]))
                data[index] = samples
        else:
            other += 1
    return {'status': status, 'data': data, 'ignored_frames': other}


def parse_uart_dump(path: Path) -> str:
    """Decode a raw UART capture into text (ASCII, replacement on damage)."""
    raw = path.read_bytes()
    return raw.decode('ascii', errors='replace')


def report(observed: bytes, expected: np.ndarray, limit: int) -> dict:
    """Byte-compare the captured samples with the golden window samples."""
    total = int(expected.size)
    if len(observed) != total:
        return {'verdict': 'INCOMPLETE',
                'expected': total, 'observed': len(observed)}
    exp = np.frombuffer(bytes(expected), dtype=np.uint8)
    obs = np.frombuffer(observed, dtype=np.uint8)
    bad = np.nonzero(exp != obs)[0]
    detail = []
    for index in bad[:limit]:
        row, grp, col, lane = decode_stream_index(int(index))
        detail.append({
            'sample': int(index),
            'row': row, 'group': grp, 'col': col,
            'channel': grp * 16 + lane,
            'expected': int(exp[index]),
            'observed': int(obs[index]),
        })
    per_window = []
    pos = 0
    for base, span in WINDOWS:
        chunk = slice(pos, pos + span)
        n_bad = int((exp[chunk] != obs[chunk]).sum())
        per_window.append({'start': base, 'span': span, 'mismatch': n_bad})
        pos += span
    return {
        'verdict': 'PASS' if bad.size == 0 else 'FAIL',
        'expected': total,
        'observed': total,
        'mismatch_count': int(bad.size),
        'first_mismatch': detail,
        'per_window': per_window,
        'expected_sum': int(exp.astype(np.int64).sum()),
        'observed_sum': int(obs.astype(np.int64).sum()),
    }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def _print_golden(conv1: np.ndarray, limit: int) -> None:
    samples = expected_samples(conv1)
    print('conv1 golden: {0}  shape={1}  stream_samples={2}'.format(
        CONV1_NPY, tuple(conv1.shape), STREAM_SAMPLES))
    print('capture windows (flat y-stream index, (row, group, col, channel)):')
    pos = 0
    for base, span in WINDOWS:
        row, grp, col, lane = decode_stream_index(base)
        end_row, end_grp, end_col, end_lane = decode_stream_index(base + span - 1)
        print('  {0:>7}..{1:>7}  row{2} grp{3} col{4}..{5}  ch{6}..{7}'.format(
            base, base + span - 1, row, grp, col,
            end_col if end_row == row and end_grp == grp else CONV1_W - 1,
            grp * 16 + lane, end_grp * 16 + end_lane))
        pos += span
    print('first {0} expected samples (decimal):'.format(min(limit, samples.size)))
    print(' '.join(str(int(v)) for v in samples[:limit].tolist()))
    print('golden sample sum = {0}'.format(int(samples.astype(np.int64).sum())))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='Compare the conv1 NPU test bitstream UART capture with '
                    'reports/golden_ref/sine_440_full/conv1.npy.')
    parser.add_argument('--golden-only', action='store_true',
                        help='print the expected samples sampled by the RTL '
                             'and exit (no serial hardware needed)')
    parser.add_argument('--self-check', action='store_true',
                        help='recompute conv1 from the golden feature map and '
                             'diff it against conv1.npy')
    parser.add_argument('--emit-hex', action='store_true',
                        help='write hex_conv1/*.hex ($readmemh tables)')
    parser.add_argument('--out-dir', type=Path, default=HEX_DIR,
                        help='hex output directory for --emit-hex')
    parser.add_argument('--uart-file', type=Path, default=None,
                        help='raw UART capture to score (e.g. build/uart_last.bin)')
    parser.add_argument('--limit', type=int, default=32,
                        help='values printed by --golden-only / mismatch rows')
    parser.add_argument('--json', type=Path, default=None,
                        help='write the evidence record here (no BOM)')
    args = parser.parse_args(argv)

    if args.emit_hex:
        summary = emit_hex(args.out_dir)
        print(json.dumps(summary, indent=2))
        return 0

    conv1 = load_conv1()

    if args.self_check:
        result = verify_sampling_rule(conv1, np.load(FEAT_NPY), load_contract())
        print(json.dumps(result, indent=2))
        return 0 if result['max_abs_diff'] == 0 else 1

    if args.golden_only:
        _print_golden(conv1, max(args.limit, 1))
        return 0

    if args.uart_file is None:
        parser.error('either --uart-file, --golden-only, --self-check or '
                     '--emit-hex is required')
        return 2
    if not args.uart_file.is_file():
        raise SystemExit('UART capture not found: {0}'.format(args.uart_file))

    if str(SCRIPTS) not in sys.path:
        sys.path.insert(0, str(SCRIPTS))
    import diag_frames                     # noqa: E402

    text = parse_uart_dump(args.uart_file)
    frames = diag_frames.parse_all(text)
    decoded = decode_frames(frames)
    status = decoded['status']
    if status is None:
        raise SystemExit(
            'no CONV1STS frame (magic 0x{0:08X}) in {1}; frames parsed: {2}'
            .format(STS_MAGIC, args.uart_file, len(frames)))

    ordered = bytearray()
    missing = []
    for index in range(FRAME_COUNT):
        chunk = decoded['data'].get(index)
        if chunk is None:
            missing.append(index)
        else:
            ordered.extend(chunk)

    result = report(bytes(ordered), expected_samples(conv1), max(args.limit, 1))
    result['frames'] = {
        'parsed': len(frames),
        'status': 1,
        'data': len(decoded['data']),
        'missing_data_indices': missing,
        'ignored': decoded['ignored_frames'],
    }
    result['status_frame'] = {
        'done_flag': status.get('b'),
        'sample_count': status.get('c'),
        'sample_sum': status.get('d'),
        'stream_samples': status.get('e'),
        'window_count': status.get('g'),
        'tail': status.get('h'),
    }

    print(json.dumps(result, indent=2))
    if args.json is not None:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        with io.open(args.json, 'w', encoding='utf-8', newline='\n') as handle:
            json.dump(result, handle, indent=2)
            handle.write('\n')

    ok = (result['verdict'] == 'PASS'
          and status.get('b') == 1
          and status.get('c') == SAMPLE_COUNT
          and status.get('e') == STREAM_SAMPLES
          and status.get('d') == result['expected_sum']
          and not missing)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())