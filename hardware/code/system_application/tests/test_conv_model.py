"""Streaming conv model (tasks.md T-M2-03 DoD 2).

The hardware scan order is (out_row, group, out_col, tap) with a 3x3
pad-1 window, 16 output channels per group and the tap order
(cin outer, dy*3+dx inner). This test re-implements that loop nest in
Python and asserts it is bit-identical to the vectorised golden math
(same padding contract, same requant), so an indexing error in the
hardware order would show up here.
"""

from __future__ import annotations

import numpy as np

import golden_pipeline as gp


def _vec_conv(x, w, bias, m, shift, zp_in, zp_out):
    cin, h, wd = x.shape
    cout = w.shape[0]
    padded = np.zeros((cin, h + 2, wd + 2), dtype=np.int64)
    padded[:, 1:-1, 1:-1] = x.astype(np.int64) - np.int64(zp_in)
    windows = np.lib.stride_tricks.sliding_window_view(padded, (1, 3, 3))[:, :, :, 0]
    win = windows.reshape(cin, h * wd, 9)
    wk = w.reshape(cout, cin, 9)
    acc = np.tensordot(win, wk, axes=([0, 2], [1, 2])).T.reshape(cout, h, wd)
    acc = acc + bias.reshape(cout, 1, 1)
    return gp.requant_u8(acc, m, shift, zp_out)


def _stream_conv(x, w, bias, m, shift, zp_in, zp_out, group=16):
    """Loop nest mirroring conv_engine (row, group, col, cin, tap)."""
    cin, h, wd = x.shape
    cout = w.shape[0]
    padded = np.zeros((cin, h + 2, wd + 2), dtype=np.int64)
    padded[:, 1:-1, 1:-1] = x.astype(np.int64) - np.int64(zp_in)

    out = np.zeros((cout, h, wd), dtype=np.uint8)
    for r in range(h):
        for g in range(cout // group):
            lanes = slice(g * group, (g + 1) * group)
            for c in range(wd):
                acc = bias[lanes].astype(np.int64).copy()
                for ci in range(cin):
                    for dy in range(3):
                        for dx in range(3):
                            xv = int(padded[ci, r + dy, c + dx])
                            acc += xv * w[lanes, ci, dy, dx].astype(np.int64)
                q = gp.requant_u8(acc, m[lanes], shift[lanes], zp_out)
                out[lanes, r, c] = q.reshape(-1)
    return out


def _make_layer(cin, cout, seed=7):
    rng = np.random.default_rng(seed)
    x = rng.integers(0, 256, size=(cin, 5, 7), dtype=np.uint8)
    w = rng.integers(-128, 128, size=(cout, cin, 3, 3), dtype=np.int8)
    bias = rng.integers(-1000, 1000, size=(cout,), dtype=np.int32)
    m = rng.integers(2**30, 2**31, size=(cout,), dtype=np.int64)
    shift = rng.integers(37, 44, size=(cout,), dtype=np.int64)
    return x, w, bias, m, shift


def test_stream_order_matches_vectorised_math():
    x, w, bias, m, shift = _make_layer(cin=3, cout=32)
    vec = _vec_conv(x, w, bias, m, shift, zp_in=49, zp_out=0)
    stream = _stream_conv(x, w, bias, m, shift, zp_in=49, zp_out=0)
    assert np.array_equal(stream, vec)


def test_zero_point_padding_is_neutral():
    # A fully zp_in-filled input must produce all-zero signed cells, so the
    # output is exactly the requantised bias.
    cin, cout = 2, 16
    x = np.full((cin, 4, 5), 49, dtype=np.uint8)
    w = np.ones((cout, cin, 3, 3), dtype=np.int8)
    bias = np.arange(cout, dtype=np.int32) * 100
    m = np.full(cout, 2**30, dtype=np.int64)
    shift = np.full(cout, 40, dtype=np.int64)
    out = _stream_conv(x, w, bias, m, shift, zp_in=49, zp_out=0)
    expect = gp.requant_u8(bias.reshape(cout, 1, 1), m, shift, 0)
    assert np.array_equal(out, np.broadcast_to(expect, out.shape))