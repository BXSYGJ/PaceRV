"""Unit tests for uart_frames.py (tasks.md T-M2-07, PC side).

DoD coverage: frame layout, CRC, resynchronisation on garbage, per-seq
reassembly, sampled (0x80) export masking and the comparison metrics.
"""

from __future__ import annotations

import numpy as np

import uart_frames as uf


def test_crc_check_vector():
    assert uf.crc16_ccitt_false(b'123456789') == 0x29B1


def test_roundtrip_single_frame():
    payload = np.arange(10, dtype='<u1').tobytes()
    frame = uf.build_frame(6, 0, payload)
    frames = uf.parse_frames(frame)
    assert frames == [(6, 0, payload)]


def test_garbage_and_bad_crc_are_dropped():
    good = uf.build_frame(1, 0, b'\x01\x02\x03')
    bad = bytearray(uf.build_frame(1, 1, b'\x04\x05'))
    bad[-1] ^= 0xFF
    stream = b'\x00\x11\x22' + bytes(bad) + b'\x33' + good
    frames = uf.parse_frames(stream)
    assert [(lid, seq) for lid, seq, _ in frames] == [(1, 0)]


def test_reassemble_multi_seq():
    total = int(np.prod(uf.LAYER_SHAPES[6]))          # 8 int32
    values = np.arange(total, dtype='<i4')
    raw = values.tobytes()
    frames = []
    chunk = 8
    for i in range(0, len(raw), chunk):
        frames.extend(uf.parse_frames(uf.build_frame(6, i // chunk, raw[i:i + chunk])))
    out = uf.reassemble(frames, 6)
    assert out.shape == (8,)
    assert np.array_equal(out, values)


def test_sampled_export_masks_missing_slots():
    base = 1
    total = int(np.prod(uf.LAYER_SHAPES[base]))
    step = 16
    count = (total + step - 1) // step
    values = np.arange(count, dtype='<u1')
    frames = uf.parse_frames(uf.build_frame(0x80 | base, 0, values.tobytes()))
    out = uf.reassemble(frames, 0x80 | base)
    assert out.size == total
    flat = out.reshape(-1)
    assert np.isnan(flat[1])
    assert int(flat[0]) == 0
    assert int(flat[step]) == 1


def test_compare_metrics_exact_and_off_by_one():
    ref = np.array([1, 2, 3, 4, 5, 6, 7, 8], dtype='<i4')
    payload = ref.astype('<i4').tobytes()
    frames = uf.parse_frames(uf.build_frame(6, 0, payload))
    stats = uf.compare(frames, 6, ref)
    assert stats['exact'] == 1.0
    assert stats['max_abs_delta'] == 0

    off = ref.copy()
    off[0] = 2
    stats = uf.compare(frames, 6, off)
    assert stats['within_1lsb'] == 1.0
    assert stats['exact'] < 1.0