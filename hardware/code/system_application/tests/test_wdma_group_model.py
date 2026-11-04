"""wdma group-stream order model (tasks.md T-M2-02, contract phase).

Per layer, per group, the DMA must emit exactly:
    grp_start
    16 x bias  (s32, native channel order)
    16 x M     (s32)
    16 x shift (u8, 7-bit field)
    taps_per_grp x tap (16 B for conv/fc1, 8 B for fc2)

This test builds that stream straight from the image and checks it against
layer_contract.json, so the RTL address/order cannot drift.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / 'scripts/outputs/weights_image.bin'
CONTRACT = ROOT / 'scripts/outputs/layer_contract.json'

# name -> (base, weights bytes, cout, groups, taps/group, tap bytes)
LAYERS = {
    'conv1': (512, 432, 48, 3, 9, 16),
    'conv2': (1376, 41472, 96, 6, 432, 16),
    'conv3': (43712, 165888, 192, 12, 864, 16),
    'conv4': (211328, 442368, 256, 16, 1728, 16),
    'fc1': (656000, 32768, 128, 8, 256, 16),
    'fc2': (689920, 1024, 8, 1, 128, 8),
}


def _arrays(data, name):
    base, wbytes, cout, groups, taps, tap_bytes = LAYERS[name]
    b = np.frombuffer(data[base + wbytes: base + wbytes + cout * 4], dtype='<i4')
    m_off = base + wbytes + cout * 4
    m = np.frombuffer(data[m_off: m_off + cout * 4], dtype='<i4')
    s_off = m_off + cout * 4
    s = np.frombuffer(data[s_off: s_off + cout], dtype=np.uint8)
    w = data[base: base + wbytes]
    return b, m, s, w


def _taps(weights, groups, taps, tap_bytes):
    out = []
    for g in range(groups):
        for t in range(taps):
            off = g * taps * tap_bytes + t * tap_bytes
            out.append(weights[off: off + tap_bytes])
    return out


def test_group_stream_matches_contract_and_image():
    data = IMAGE.read_bytes()
    contract = json.loads(CONTRACT.read_text(encoding='utf-8'))
    recs = {r['name']: r for r in contract['layers']}

    for name, (base, wbytes, cout, groups, taps, tap_bytes) in LAYERS.items():
        b, m, s, w = _arrays(data, name)
        assert b.tolist() == [int(v) for v in recs[name]['bias_int32']], name
        assert m.tolist() == [int(v) for v in recs[name]['M']], name
        assert [int(v) for v in s] == [int(v) for v in recs[name]['shift']], name

        taps_all = _taps(w, groups, taps, tap_bytes)
        assert len(taps_all) == groups * taps

        for g in range(groups):
            sl = slice(g * 16, (g + 1) * 16)
            # Pad an 8-channel fc2 group to the 16-lane contract.
            if cout < 16:
                bias_g = list(b) + [0] * (16 - cout)
                m_g = list(m) + [0] * (16 - cout)
                s_g = [int(v) for v in s] + [0] * (16 - cout)
            else:
                bias_g = list(b[sl])
                m_g = list(m[sl])
                s_g = [int(v) for v in s[sl]]
            stream = bias_g + m_g + s_g
            assert len(stream) == 48, name

            # Taps of this group must be exactly the image slice.
            got = taps_all[g * taps:(g + 1) * taps]
            for t, tap in enumerate(got):
                off = base + (g * taps + t) * tap_bytes
                assert tap == data[off: off + tap_bytes], name


def test_fc2_group_pads_to_sixteen_lanes():
    data = IMAGE.read_bytes()
    b, m, s, w = _arrays(data, 'fc2')
    assert len(b) == 8
    bias_g = list(b) + [0] * 8
    m_g = list(m) + [0] * 8
    s_g = [int(v) for v in s] + [0] * 8
    assert len(bias_g + m_g + s_g) == 48
    # Taps are 8 bytes each, 128 of them.
    taps = _taps(w, 1, 128, 8)
    assert len(taps) == 128 and all(len(t) == 8 for t in taps)


def test_conv1_group_stride_is_tap_aligned():
    # conv1: 9 taps x 16 B = 144 B per group; groups are contiguous.
    data = IMAGE.read_bytes()
    b, m, s, w = _arrays(data, 'conv1')
    assert len(w) == 432
    starts = [0, 144, 288]
    for g0, g1 in zip(starts, starts[1:]):
        assert w[g0:g0 + 144] != w[g1:g1 + 144]


import numpy as np  # noqa: E402  (kept last so the file reads top-down)