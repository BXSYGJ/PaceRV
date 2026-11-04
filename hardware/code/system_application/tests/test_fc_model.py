"""Streaming FC model (tasks.md T-M2-05 DoD 3 support).

Mirrors fc_engine: 16 output channels per group, CIN beats per group,
requant per channel. fc1 uses zp_out=0 (quint8 ReLU rail); fc2 uses
zp_out=57 and the int32 logits container is (y_u8 - 57).
"""

from __future__ import annotations

import numpy as np

import golden_pipeline as gp


def _vec(x, w, bias, m, shift, zp_in, zp_out):
    acc = (x.astype(np.int64) - np.int64(zp_in)) @ w.astype(np.int64).T + bias
    return gp.requant_u8(acc, m, shift, zp_out)


def _stream(x, w, bias, m, shift, zp_in, zp_out):
    cout = w.shape[0]
    out = np.zeros(cout, dtype=np.uint8)
    for g in range(cout // 16):
        lanes = slice(g * 16, (g + 1) * 16)
        acc = bias[lanes].astype(np.int64).copy()
        for k in range(len(x)):
            acc += (int(x[k]) - zp_in) * w[lanes, k].astype(np.int64)
        out[lanes] = gp.requant_u8(acc, m[lanes], shift[lanes], zp_out).reshape(-1)
    return out


def _layer(cin, cout, seed=11):
    rng = np.random.default_rng(seed)
    x = rng.integers(0, 200, size=(cin,), dtype=np.uint8)
    w = rng.integers(-128, 128, size=(cout, cin), dtype=np.int8)
    bias = rng.integers(-5000, 5000, size=(cout,), dtype=np.int32)
    m = rng.integers(2**30, 2**31, size=(cout,), dtype=np.int64)
    shift = rng.integers(38, 44, size=(cout,), dtype=np.int64)
    return x, w, bias, m, shift


def test_stream_fc1_relu_matches():
    x, w, bias, m, shift = _layer(256, 128)
    vec = _vec(x, w, bias, m, shift, zp_in=0, zp_out=0)
    got = _stream(x, w, bias, m, shift, zp_in=0, zp_out=0)
    assert np.array_equal(got, vec)
    # zp_out == 0 is the ReLU rail: nothing can be negative in quint8.
    assert got.min() >= 0


def test_stream_fc2_logits_container():
    # fc2 has 8 real outputs, padded to one 16-lane group in hardware.
    x, w, bias, m, shift = _layer(128, 16)
    got = _stream(x, w, bias, m, shift, zp_in=0, zp_out=57)
    vec = _vec(x, w, bias, m, shift, zp_in=0, zp_out=57)
    assert np.array_equal(got, vec)
    logits = got[:8].astype(np.int64) - 57
    assert logits.shape == (8,)


def test_all_zero_input_equals_bias_only():
    cin, cout = 64, 32
    x = np.zeros(cin, dtype=np.uint8)
    w = np.ones((cout, cin), dtype=np.int8)
    bias = np.arange(cout, dtype=np.int32) * 3
    m = np.full(cout, 2**30, dtype=np.int64)
    shift = np.full(cout, 40, dtype=np.int64)
    got = _stream(x, w, bias, m, shift, zp_in=0, zp_out=0)
    want = gp.requant_u8(bias.astype(np.int64), m, shift, 0)
    assert np.array_equal(got, want)