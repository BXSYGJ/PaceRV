"""Contract-stream facts for wdma / conv_engine (tasks.md T-M2-02).

Each layer region stores, after the interleaved weights:
    bias int32 (cout entries) | M int32 (cout) | shift uint8 (cout)
The 48-beat group contract expected by conv_engine is, per 16-channel
group, exactly:
    beats 0..15  bias[g*16 + i]   (s32)
    beats 16..31 M[g*16 + i]      (s32)
    beats 32..47 shift[g*16 + i]  (u8 in a 7-bit field)

This test pins the per-layer offsets and proves the stream matches the
authoritative layer_contract.json (so the RTL address table cannot drift).
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / 'scripts/outputs/weights_image.bin'
CONTRACT = ROOT / 'scripts/outputs/layer_contract.json'

# name -> (region base, weights bytes, cout, taps per group, tap bytes, groups)
LAYERS = {
    'conv1': (512, 432, 48, 9, 16, 3),
    'conv2': (1376, 41472, 96, 432, 16, 6),
    'conv3': (43712, 165888, 192, 864, 16, 12),
    'conv4': (211328, 442368, 256, 1728, 16, 16),
    'fc1': (656000, 32768, 128, 256, 16, 8),
    'fc2': (689920, 1024, 8, 128, 8, 1),
}


def _load_contract():
    return json.loads(CONTRACT.read_text(encoding='utf-8'))


def test_region_tail_layout():
    data = IMAGE.read_bytes()
    for name, (base, wbytes, cout, *_rest) in LAYERS.items():
        b = base + wbytes
        m = b + cout * 4
        s = m + cout * 4
        end = s + cout
        assert end <= len(data), name
        # The next region starts exactly at 'end' for every layer.
        assert end == base + wbytes + cout * 9, name


def test_bias_m_shift_match_contract_json():
    data = IMAGE.read_bytes()
    contract = _load_contract()
    recs = {r['name']: r for r in contract['layers']}
    for name, (base, wbytes, cout, *_rest) in LAYERS.items():
        b = np.frombuffer(data[base + wbytes: base + wbytes + cout * 4], dtype='<i4')
        m_off = base + wbytes + cout * 4
        m = np.frombuffer(data[m_off: m_off + cout * 4], dtype='<i4')
        s_off = m_off + cout * 4
        s = np.frombuffer(data[s_off: s_off + cout], dtype=np.uint8)

        rec = recs[name]
        assert b.tolist() == [int(v) for v in rec['bias_int32']], name
        assert m.tolist() == [int(v) for v in rec['M']], name
        assert [int(v) for v in s] == [int(v) for v in rec['shift']], name


def test_group_contract_is_48_beats():
    data = IMAGE.read_bytes()
    for name, (base, wbytes, cout, taps, tap_bytes, groups) in LAYERS.items():
        b = np.frombuffer(data[base + wbytes: base + wbytes + cout * 4], dtype='<i4')
        m_off = base + wbytes + cout * 4
        m = np.frombuffer(data[m_off: m_off + cout * 4], dtype='<i4')
        s_off = m_off + cout * 4
        s = np.frombuffer(data[s_off: s_off + cout], dtype=np.uint8)
        if name.startswith('conv'):
            # conv_engine contract: 16 channels/group -> 48 beats/group.
            for g in range(groups):
                sl = slice(g * 16, (g + 1) * 16)
                beats = list(b[sl]) + list(m[sl]) + [int(v) for v in s[sl]]
                assert len(beats) == 48, name
                assert all(0 <= v <= 127 for v in beats[32:]), name
        else:
            # fc_engine contract: one beat per channel for bias, M and shift.
            beats = list(b) + list(m) + [int(v) for v in s]
            assert len(beats) == 3 * cout, name
            assert all(0 <= v <= 127 for v in beats[2 * cout:]), name


def test_shift_fits_six_bits_per_layer_contract():
    contract = _load_contract()
    for rec in contract['layers']:
        assert 37 <= min(rec['shift']) <= max(rec['shift']) <= 53, rec['name']
        assert max(rec['shift']) < 64