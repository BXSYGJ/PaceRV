#!/usr/bin/env python3
"""Per-layer comparison between UART layer exports and the golden NPU model.

Task: tasks.md T-M2-07 (PC side), design.md 9.2.

Input is the directory produced by

    python scripts/uart_capture.py --port COM5 --frames --out-dir reports/f

which holds one ``layer_XX.npy`` per exported layer (``XX`` is the raw
layer_id, so a sampled export lands in ``layer_81.npy`` for CONV1).  Every
captured tensor is re-wrapped into a synthetic design.md 9.2 frame and fed
back through ``uart_frames.compare`` -- the frame reassembly, NaN masking
and shape checks are therefore the SAME code the live path uses, not a
re-implementation.

References come from ``golden_pipeline.npu_forward`` (bit-level truth,
scripts/outputs/golden/<stem>_feat.npy as the uint8 input) unless a per
layer ``--ref <id>=<path.npy>`` override is given.

Layer map (uart_frames.LAYER_SHAPES / LAYER_DTYPES):

    0x00 MEL_Q8_8      int16 (64, 258)   golden feat, containers widened
    0x01 CONV1         uint8 (48, 64, 258)
    0x02 CONV2         uint8 (96, 32, 129)
    0x03 CONV3         uint8 (192, 16, 64)
    0x04 CONV4         uint8 (256, 8, 32)
    0x05 FC1           uint8 (128,)
    0x06 FC2_LOGITS    int32 (8,)         container ints (out_u8 - zp_out)
    0x07 PROBS         uint8 (8,)         encoding selected by --probs-encoding:
                        percent (default): golden percent (0..100, rounded)
                        q0.8:              Q0.16 probabilities >> 8
    0x08 STATS         int32 (8,)         timestamps/counters, no reference
                        -> reported as skipped

Sampled exports (layer_id | 0x80, every 16th element) are reassembled by
uart_frames into a float64 tensor whose unsampled slots are NaN; the mask
is re-created from the non-NaN slots, so coverage is reported as the
sampled fraction (1/16 for a complete capture) and the hit rates only see
the exported elements.

Exit codes: 0 = table printed, 1 = some layer could not be compared,
2 = bad arguments / reference generation failed.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

import golden_pipeline as gp
import uart_frames as uf

SCRIPTS_DIR = Path(__file__).resolve().parent
DEFAULT_GOLDEN_DIR = SCRIPTS_DIR / 'outputs' / 'golden'
DEFAULT_TABLES_PATH = gp.DEFAULT_TABLES_PATH
DEFAULT_CONTRACT_PATH = gp.DEFAULT_CONTRACT_PATH
DEFAULT_WEIGHT_IMAGE_PATH = gp.DEFAULT_WEIGHT_IMAGE_PATH

# layer_id (without the 0x80 sampled flag) -> (npu_forward key, uart dtype)
LAYER_STAGE = {
    0: ('feat', np.int16),
    1: ('conv1', np.uint8),
    2: ('conv2', np.uint8),
    3: ('conv3', np.uint8),
    4: ('conv4', np.uint8),
    5: ('fc1', np.uint8),
    6: ('logits', np.int32),
    7: ('probs', np.uint8),
}

# Layers that exist on the wire but have no golden counterpart.
SKIPPED_LAYERS = {
    8: 'STATS (timestamps / wait counters), no golden reference',
}

PROBS_ENCODINGS = ('percent', 'q0.8')

# design.md 9.2 caps the length field at 16 bits, so a full CONV1 export
# (792,576 B) always spans many seq frames.  The chunk size only affects
# framing overhead, never the reassembled tensor.
FRAME_CHUNK_BYTES = 4096


# ---------------------------------------------------------------------------
# Reference construction.
# ---------------------------------------------------------------------------
def load_feat_npy(path) -> np.ndarray:
    """Load a golden feature .npy and normalise it to the uint8 contract.

    The golden run_mel_pipeline emits uint8; older archived fixtures were
    saved as int8 (all-zero silence), which still round-trips numerically.
    Values outside [0, 255] mean the file is not a quantized feature.
    """
    arr = np.asarray(np.load(path))
    if arr.shape != uf.LAYER_SHAPES[0]:
        raise ValueError(
            f'feat {path} shape {arr.shape} != {uf.LAYER_SHAPES[0]}')
    if arr.dtype.kind == 'f':
        raise ValueError(f'feat {path} is {arr.dtype}, expected an integer '
                         f'quint8 container')
    lo, hi = int(arr.min()), int(arr.max())
    if lo < 0 or hi > 255:
        raise ValueError(f'feat {path} range [{lo}, {hi}] outside quint8 '
                         f'[0, 255]')
    return arr.astype(np.uint8)


def find_golden_feat(golden_dir=DEFAULT_GOLDEN_DIR, stem=None) -> Path:
    """Pick the golden feature file to drive npu_forward.

    With --stem the exact <stem>_feat.npy is used; otherwise the directory
    must hold exactly one *_feat.npy (ambiguity is an error, never a silent
    pick, because the reference would then belong to another recording).
    """
    d = Path(golden_dir)
    if stem:
        path = d / f'{stem}_feat.npy'
        if not path.is_file():
            raise FileNotFoundError(f'no such golden feat: {path}')
        return path
    found = sorted(d.glob('*_feat.npy'))
    if not found:
        raise FileNotFoundError(
            f'no *_feat.npy in {d}; pass --golden-feat or --stem')
    if len(found) > 1:
        names = ', '.join(p.name for p in found)
        raise ValueError(
            f'{d} holds several features ({names}); pass --stem or '
            f'--golden-feat')
    return found[0]


def encode_probs(npu: dict, probs_encoding: str) -> np.ndarray:
    """Map the golden Q0.16 probabilities onto the u8 PROBS wire container.

    design.md 9.2 pins PROBS as 8 x u8, which cannot carry Q0.16; the two
    lossless-enough encodings are the integer percent (UI value) and Q0.8
    (Q0.16 >> 8).  Both are selected explicitly to keep the comparison
    well defined instead of guessing in the metric code.
    """
    if probs_encoding == 'percent':
        return np.asarray(npu['percent'], np.int64).clip(0, 255).astype(
            np.uint8)
    if probs_encoding == 'q0.8':
        q16 = np.asarray(npu['probs_q16'], np.int64)
        return np.minimum((q16 + 128) >> 8, 255).astype(np.uint8)
    raise ValueError(f'unknown probs encoding {probs_encoding!r} '
                     f'(choose among {PROBS_ENCODINGS})')


def references_from_npu(feat_u8: np.ndarray, npu: dict,
                        probs_encoding: str = 'percent') -> dict:
    """Build the per-layer reference dict from an npu_forward result."""
    refs = {}
    for layer_id, (key, dtype) in LAYER_STAGE.items():
        if layer_id == 7:
            arr = encode_probs(npu, probs_encoding)
        elif layer_id == 0:
            arr = np.asarray(feat_u8)
        else:
            arr = np.asarray(npu[key])
        shape = uf.LAYER_SHAPES[layer_id]
        if arr.shape != shape:
            raise ValueError(
                f'layer 0x{layer_id:02x} reference shape {arr.shape} != '
                f'uart contract {shape}')
        refs[layer_id] = arr.astype(dtype)
    return refs


def build_references(golden_feat=None, golden_dir=DEFAULT_GOLDEN_DIR,
                     stem=None, contract_path=DEFAULT_CONTRACT_PATH,
                     weights_path=DEFAULT_WEIGHT_IMAGE_PATH,
                     tables_path=DEFAULT_TABLES_PATH,
                     probs_encoding='percent',
                     layer_ids=None) -> tuple[dict, list]:
    """Generate the golden references for the requested layers.

    Returns (refs, notes).  npu_forward is only invoked when a layer other
    than MEL_Q8_8 is requested, so a Mel-only capture needs no weight image.
    """
    if probs_encoding not in PROBS_ENCODINGS:
        raise ValueError(f'unknown probs encoding {probs_encoding!r}')

    feat_path = Path(golden_feat) if golden_feat else find_golden_feat(
        golden_dir, stem)
    feat = load_feat_npy(feat_path)
    notes = [f'golden feat: {feat_path}']

    wanted = set(LAYER_STAGE) if layer_ids is None else {
        int(i) & 0x7F for i in layer_ids}
    wants_npu = any(lid != 0 for lid in wanted)
    if not wants_npu:
        return {0: feat.astype(np.int16)}, notes

    contract = gp.load_layer_contract(Path(contract_path))
    tables = gp.load_mel_tables(Path(tables_path))
    weights = gp.load_weights_from_image(contract, Path(weights_path))
    npu = gp.npu_forward(feat, contract, tables['exp_lut'], weights)
    refs = references_from_npu(feat, npu, probs_encoding)
    notes.append(f'contract: {contract_path}')
    notes.append(f'weights: {weights_path}')
    notes.append(f'probs encoding: {probs_encoding}')
    notes.append(f'golden top1: {npu["top1"]}')
    return {k: v for k, v in refs.items() if k in wanted or k == 0}, notes


# ---------------------------------------------------------------------------
# Captured tensors -> uart_frames.compare.
# ---------------------------------------------------------------------------
def discover_layer_files(frames_dir) -> dict:
    """Map layer_id -> path for a uart_capture --frames --out-dir tree."""
    out = {}
    for path in sorted(Path(frames_dir).glob('layer_*.npy')):
        tag = path.stem[len('layer_'):]
        try:
            lid = int(tag, 16)
        except ValueError:
            continue
        if not 0 <= lid <= 0xFF:
            continue
        out[lid] = path
    return out


def frames_from_array(arr, layer_id) -> list:
    """Rebuild synthetic UART frames carrying an already-reassembled array.

    A full export is the flattened payload split into seq frames of
    FRAME_CHUNK_BYTES (design.md 9.2 caps len at 16 bits).  A sampled export
    (float64 with NaN holes from uart_frames.reassemble) keeps only its
    non-NaN slots: feeding those back through the step-16 reassembly
    reproduces exactly the same mask, so the statistics stay identical.
    """
    base = layer_id & 0x7F
    if base not in uf.LAYER_DTYPES:
        raise ValueError(f'unknown layer id 0x{layer_id:02x}')
    a = np.asarray(arr)
    flat = a.reshape(-1)
    if a.dtype.kind == 'f':
        values = flat[~np.isnan(flat)]
    else:
        values = flat
    dtype = np.dtype(uf.LAYER_DTYPES[base]).newbyteorder('<')
    payload = np.asarray(values).astype(dtype).tobytes()
    return [(layer_id, seq, payload[off:off + FRAME_CHUNK_BYTES])
            for seq, off in enumerate(range(0, max(len(payload), 1),
                                           FRAME_CHUNK_BYTES))]


def compare_array(arr, layer_id, reference) -> dict:
    """Run uart_frames.compare on a saved array and return its stats."""
    frames = frames_from_array(arr, layer_id)
    return uf.compare(frames, layer_id, reference)


def compare_dir(frames_dir, references, layer_ids=None,
                strict=False) -> list:
    """Compare every captured layer against its reference.

    Returns one row per captured layer with keys layer_id, name, sampled,
    coverage, exact, within_1lsb, max_abs_delta, error, skipped, path.
    With strict=True the first per-layer failure raises instead of being
    recorded in the row (tests use both behaviours).
    """
    files = discover_layer_files(frames_dir)
    if not files:
        raise FileNotFoundError(f'no layer_*.npy in {frames_dir}')

    wanted = None if layer_ids is None else {int(i) & 0x7F for i in layer_ids}
    rows = []
    for lid in sorted(files):
        base = lid & 0x7F
        row = {
            'layer_id': lid,
            'name': uf.LAYER_NAMES.get(base, '?'),
            'sampled': bool(lid & 0x80),
            'coverage': 0.0,
            'exact': 0.0,
            'within_1lsb': 0.0,
            'max_abs_delta': None,
            'error': None,
            'skipped': False,
            'path': str(files[lid]),
        }
        if wanted is not None and base not in wanted:
            continue
        if base in SKIPPED_LAYERS:
            row['skipped'] = True
            row['error'] = SKIPPED_LAYERS[base]
            rows.append(row)
            continue
        try:
            if base not in references:
                raise KeyError(
                    f'no golden reference for {row["name"]} (0x{lid:02x})')
            ref = np.asarray(references[base])
            if ref.dtype.kind == 'f':
                raise ValueError(
                    f'reference for {row["name"]} is {ref.dtype}; expected '
                    f'the integer wire container')
            arr = np.load(files[lid])
            stats = compare_array(arr, lid, ref)
        except (ValueError, KeyError, OSError) as exc:
            if strict:
                raise
            row['error'] = str(exc)
            rows.append(row)
            continue
        row.update(stats)
        rows.append(row)
    return rows


def format_table(rows, notes=None) -> str:
    """Render the comparison rows as a fixed-width console table."""
    lines = []
    header = (f'{"layer":<7} {"name":<13} {"mode":<8} {"coverage":>9} '
              f'{"exact":>8} {"within1":>8} {"max|d|":>7}  note')
    lines.append(header)
    lines.append('-' * len(header))
    for row in rows:
        lid = row['layer_id']
        mode = 'sampled' if row['sampled'] else 'full'
        if row['skipped']:
            note = f'skipped: {row["error"]}'
            cov = exact = within = '     -  '
            mx = '  -'
        elif row['error']:
            note = f'ERROR: {row["error"]}'
            cov = exact = within = '     -  '
            mx = '  -'
        else:
            note = ''
            cov = f'{100.0 * row["coverage"]:8.2f}%'
            exact = f'{100.0 * row["exact"]:7.2f}%'
            within = f'{100.0 * row["within_1lsb"]:7.2f}%'
            mx = f'{row["max_abs_delta"]:4d}'
        lines.append(f'0x{lid:02x}    {row["name"]:<13} {mode:<8} {cov} '
                     f'{exact} {within} {mx}  {note}')

    compared = [r for r in rows if not r['error'] and not r['skipped']]
    failed = [r for r in rows if r['error'] and not r['skipped']]
    lines.append('-' * len(header))
    if compared:
        worst = max(compared, key=lambda r: r['max_abs_delta'])
        lines.append(f'{len(compared)} layer(s) compared, '
                     f'{len(failed)} failed; worst max|d| = '
                     f'{worst["max_abs_delta"]} LSB on '
                     f'{worst["name"]} (0x{worst["layer_id"]:02x})')
    else:
        lines.append(f'no layer compared ({len(failed)} failed)')
    if notes:
        for note in notes:
            lines.append(f'[ref] {note}')
    return '\n'.join(line.rstrip() for line in lines)


# ---------------------------------------------------------------------------
# CLI.
# ---------------------------------------------------------------------------
def _parse_layer_list(values) -> list:
    out = []
    for value in values:
        for part in str(value).split(','):
            part = part.strip()
            if part:
                out.append(int(part, 0))
    return out


def _parse_ref_overrides(values) -> dict:
    out = {}
    for value in values:
        key, _, path = value.partition('=')
        if not _:
            raise ValueError(f'--ref expects LAYER=PATH, got {value!r}')
        lid = int(key, 0) & 0x7F
        if lid not in LAYER_STAGE:
            raise ValueError(f'--ref layer 0x{lid:02x} has no reference shape')
        out[lid] = Path(path)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description='Compare UART layer exports against the golden NPU model.')
    ap.add_argument('frames_dir', type=Path,
                    help='directory produced by uart_capture.py --frames '
                         '--out-dir (layer_XX.npy files)')
    ap.add_argument('--golden-feat', type=Path,
                    help='golden uint8 feature .npy driving npu_forward')
    ap.add_argument('--golden-dir', type=Path, default=DEFAULT_GOLDEN_DIR,
                    help='directory searched for <stem>_feat.npy '
                         '(default: scripts/outputs/golden)')
    ap.add_argument('--stem', help='golden run stem, e.g. sine_440_full')
    ap.add_argument('--layer', action='append', default=None,
                    help='base layer id (e.g. 0x01 or 1), repeatable/comma '
                         'separated; default = every captured layer')
    ap.add_argument('--probs-encoding', choices=PROBS_ENCODINGS,
                    default='percent',
                    help='u8 encoding of the PROBS layer (default: percent)')
    ap.add_argument('--ref', action='append', default=[],
                    help='override one layer reference: LAYER=PATH.npy')
    ap.add_argument('--contract', type=Path, default=DEFAULT_CONTRACT_PATH)
    ap.add_argument('--weights', type=Path, default=DEFAULT_WEIGHT_IMAGE_PATH)
    ap.add_argument('--tables', type=Path, default=DEFAULT_TABLES_PATH)
    ap.add_argument('--strict', action='store_true',
                    help='abort on the first per-layer comparison failure')
    args = ap.parse_args(argv)

    try:
        layer_ids = _parse_layer_list(args.layer) if args.layer else None
        overrides = _parse_ref_overrides(args.ref)
    except ValueError as exc:
        print(f'[compare] {exc}', file=sys.stderr)
        return 2

    notes = []
    refs = {}
    try:
        for lid, path in overrides.items():
            refs[lid] = np.load(path)
            notes.append(f'override 0x{lid:02x}: {path}')
        need = {lid & 0x7F for lid in discover_layer_files(args.frames_dir)}
        if layer_ids:
            need &= {lid & 0x7F for lid in layer_ids}
        need &= set(LAYER_STAGE)
        need -= set(refs)
        if need:
            built, built_notes = build_references(
                golden_feat=args.golden_feat,
                golden_dir=args.golden_dir,
                stem=args.stem,
                contract_path=args.contract,
                weights_path=args.weights,
                tables_path=args.tables,
                probs_encoding=args.probs_encoding,
                layer_ids=need,
            )
            refs.update(built)
            notes.extend(built_notes)
    except (OSError, ValueError, KeyError) as exc:
        print(f'[compare] reference generation failed: {exc}',
              file=sys.stderr)
        return 2

    try:
        rows = compare_dir(args.frames_dir, refs, layer_ids,
                           strict=args.strict)
    except FileNotFoundError as exc:
        print(f'[compare] {exc}', file=sys.stderr)
        return 1
    except (ValueError, KeyError) as exc:
        print(f'[compare] {exc}', file=sys.stderr)
        return 1

    missing = []
    if layer_ids:
        present = {int(r['layer_id']) & 0x7F for r in rows}
        missing = sorted({int(i) & 0x7F for i in layer_ids} - present)
        for lid in missing:
            notes.append(f'requested but not captured: 0x{lid:02x}')
    print(format_table(rows, notes))
    failed = [r for r in rows if r['error'] and not r['skipped']]
    return 1 if failed or missing else 0


if __name__ == '__main__':
    sys.exit(main())