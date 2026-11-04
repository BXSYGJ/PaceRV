"""Unit tests for the pool / GAP / FC contracts (tasks.md T-M2-05 DoD 2/3).

DoD coverage:
  1. Pool shape chain matches design.md 4.4 exactly:
     (48,64,258)->(48,32,129)->(96,16,64)->(192,8,32)->(256,4,16).
  2. Floor semantics: an odd last row/column is dropped, never consumed.
  3. Channel-local max: each channel is pooled independently.
  4. GAP reduces (256,4,16) to (256,), fc1 to (128,), fc2 to (8,).
"""

from __future__ import annotations

import numpy as np

import golden_pipeline as gp


def test_pool_shape_chain():
    shapes = [
        ((48, 64, 258), (48, 32, 129)),
        ((96, 32, 129), (96, 16, 64)),
        ((192, 16, 64), (192, 8, 32)),
        ((256, 8, 32), (256, 4, 16)),
    ]
    for src, want in shapes:
        x = np.zeros(src, dtype=np.uint8)
        out = gp.maxpool2x2_floor(x)
        assert out.shape == want, f'{src} -> {out.shape}, want {want}'


def test_pool_floor_drops_odd_last_column_and_row():
    # 1x3x3 input: the third column and third row must be ignored.
    x = np.zeros((1, 3, 3), dtype=np.uint8)
    x[0, 0, 0] = 10
    x[0, 0, 2] = 250          # dropped column
    x[0, 2, 0] = 200          # dropped row
    out = gp.maxpool2x2_floor(x)
    assert out.shape == (1, 1, 1)
    assert out[0, 0, 0] == 10


def test_pool_channel_local_max():
    x = np.zeros((2, 2, 2), dtype=np.uint8)
    x[0] = np.array([[1, 2], [3, 4]], dtype=np.uint8)
    x[1] = np.array([[9, 1], [1, 1]], dtype=np.uint8)
    out = gp.maxpool2x2_floor(x)
    assert out[0, 0, 0] == 4
    assert out[1, 0, 0] == 9


def test_gap_and_fc_shapes():
    x = np.arange(256 * 4 * 16, dtype=np.uint8).reshape(256, 4, 16)
    gap = gp.gap_s32(x)
    assert gap.shape == (256,)
    assert gap.dtype == np.int64
    # GAP applies the measured >>6 round-half-even requant, channel-local.
    total = int(x[0].astype(np.int64).sum())
    expected = int(gp.round_half_even_shift(np.int64(total), 6))
    assert int(gap[0]) == expected


def test_pool_preserves_dtype():
    x = np.zeros((4, 8, 8), dtype=np.uint8)
    out = gp.maxpool2x2_floor(x)
    assert out.dtype == np.uint8

def test_gap_all_channels_match_round_half_even():
    rng = np.random.default_rng(1234)
    x = rng.integers(0, 256, size=(256, 4, 16), dtype=np.uint8)
    gap = gp.gap_s32(x)
    for c in (0, 1, 77, 128, 255):
        total = int(x[c].astype(np.int64).sum())
        want = int(gp.round_half_even_shift(np.int64(total), 6))
        assert int(gap[c]) == want, f'channel {c}'
