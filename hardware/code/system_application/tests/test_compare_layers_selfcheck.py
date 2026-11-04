"""Self-check of the board-vs-golden per-layer comparison tool (T-M2-07).

``compare_layers.py`` is what the board run depends on: it reassembles the
UART layer frames, masks sampled holes and reports exact / within-1-LSB hit
rates.  If that tool silently compared the wrong thing, a failing board would
look like a pass (or vice versa).  These tests drive it end to end with the
archived golden references as both "captured" and "reference" tensors:

  * feeding a reference back in must report 100 % exact for every layer;
  * flipping one element must drop the hit rate and be attributed to that
    layer only;
  * a shape mismatch must raise instead of being swallowed.

No board, no UART and no PDS are involved.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

import compare_layers as cl          # noqa: E402
import uart_frames as uf             # noqa: E402

GOLDEN = ROOT / 'reports/golden_ref/sine_440_full'

# layer_id -> file stem in reports/golden_ref/<stem>/
REF_FILES = {
    0: 'feat',
    1: 'conv1',
    2: 'conv2',
    3: 'conv3',
    4: 'conv4',
    5: 'fc1',
    6: 'fc2_logits',
}


def _refs():
    out = {}
    for lid, stem in REF_FILES.items():
        path = GOLDEN / f'{stem}.npy'
        if not path.is_file():
            pytest.skip(f'missing golden reference {path}')
        arr = np.load(path)
        dtype = cl.LAYER_STAGE[lid][1]
        out[lid] = arr.astype(dtype)
    return out


def _write_frames_dir(tmp, refs, mutate_layer=None):
    for lid, arr in refs.items():
        data = arr.copy()
        if lid == mutate_layer:
            flat = data.reshape(-1)
            flat[0] = (int(flat[0]) + 7) & 0xFF if data.dtype == np.uint8 else int(flat[0]) + 7
        np.save(Path(tmp) / f'layer_{lid:02x}.npy', data)


def test_reference_roundtrip_is_exact(tmp_path):
    refs = _refs()
    _write_frames_dir(tmp_path, refs)
    rows = cl.compare_dir(tmp_path, refs)
    assert rows, 'no layers compared'
    for row in rows:
        assert row['error'] is None, (row['name'], row['error'])
        assert row['coverage'] == pytest.approx(1.0), row['name']
        assert row['exact'] == pytest.approx(1.0), (row['name'], row['exact'])
        assert row['max_abs_delta'] == 0, row['name']


def test_single_element_flip_is_attributed(tmp_path):
    refs = _refs()
    _write_frames_dir(tmp_path, refs, mutate_layer=1)
    rows = cl.compare_dir(tmp_path, refs)
    by_id = {row['layer_id'] & 0x7F: row for row in rows}
    conv1 = by_id[1]
    assert conv1['exact'] < 1.0, conv1
    assert conv1['max_abs_delta'] >= 7
    for lid, row in by_id.items():
        if lid == 1:
            continue
        assert row['exact'] == pytest.approx(1.0), (row['name'], row['exact'])


def test_shape_mismatch_raises():
    refs = _refs()
    arr = refs[2]
    wrong = arr.reshape(-1)[:-1].copy()
    frames = cl.frames_from_array(wrong, 2)
    with pytest.raises(ValueError):
        uf.compare(frames, 2, arr)


def test_all_golden_layers_are_covered():
    """Every non-skipped wire layer must have a reference path."""
    assert set(REF_FILES) | {7, 8} == {0, 1, 2, 3, 4, 5, 6, 7, 8}
    assert 7 in cl.LAYER_STAGE          # PROBS has its own golden encoding
    assert 8 in cl.SKIPPED_LAYERS       # STATS is reported as skipped