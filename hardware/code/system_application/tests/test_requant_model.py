"""Requant bit-exactness (tasks.md T-M2-04 DoD).

The RTL `requant_unit` must match golden_pipeline.requant_u8() exactly:
    y = sat_u8( round_half_even(acc * M >>> shift) + zp_out )

This test exercises the properties that a truncating shift would break:
exact halves go to the even neighbour (both signs), negative accumulators
round symmetrically, and the u8 rails saturate.
"""

from __future__ import annotations

import numpy as np

import golden_pipeline as gp


def _ref(acc, m, shift, zp_out=0):
    return gp.requant_u8(np.asarray(acc, dtype=np.int64),
                         np.asarray(m, dtype=np.int64),
                         np.asarray(shift, dtype=np.int64),
                         zp_out)


def test_positive_and_negative_halves_go_to_even():
    # With M = 2^31 and shift = 31 the product is acc << 31, so the result is
    # round-half-even(acc / 1) == acc; use shift to expose exact halves:
    # acc * 2^30 >> 31 = acc/2, so odd acc values are exact .5 cases.
    acc = np.array([1, 3, 5, 7], dtype=np.int64)
    m = np.array([2**30] * 4, dtype=np.int64)
    shift = np.array([31] * 4, dtype=np.int64)
    # 1/2 -> 0 (even), 3/2 -> 2, 5/2 -> 2, 7/2 -> 4
    assert _ref(acc, m, shift).tolist() == [0, 2, 2, 4]


def test_negative_halves_round_symmetrically():
    # Test the rounding core directly: the u8 rail would clamp negatives.
    vals = np.array([-1, -3, -5, -7], dtype=np.int64)
    # divide by 2: -0.5 -> 0, -1.5 -> -2, -2.5 -> -2, -3.5 -> -4
    assert gp.round_half_even_shift(vals, 1).tolist() == [0, -2, -2, -4]


def test_truncation_would_differ_on_these_cases():
    # Guard the intent: a truncating shift (floor) gives a different answer
    # for positive exact halves, which is exactly why half-even is required.
    acc = np.array([3], dtype=np.int64)
    m = np.array([2**30], dtype=np.int64)
    shift = np.array([31], dtype=np.int64)
    half_even = int(_ref(acc, m, shift)[0])
    truncated = int((acc[0] * m[0]) >> shift[0])
    assert half_even == 2 and truncated == 1


def test_saturation_rails_with_zp_out():
    acc = np.array([10**9, -10**9, 0], dtype=np.int64)
    m = np.array([2**31 - 1] * 3, dtype=np.int64)
    shift = np.array([40] * 3, dtype=np.int64)
    out = _ref(acc, m, shift, zp_out=0)
    assert out.tolist() == [255, 0, 0]

    out57 = _ref(acc, m, shift, zp_out=57)
    assert out57[0] == 255
    assert out57[1] == 0
    assert out57[2] == 57


def test_random_vectors_match_vectorised_golden():
    rng = np.random.default_rng(99)
    acc = rng.integers(-2**31, 2**31, size=512, dtype=np.int64)
    m = rng.integers(2**30, 2**31, size=512, dtype=np.int64)
    shift = rng.integers(37, 54, size=512, dtype=np.int64)
    out = _ref(acc, m, shift, zp_out=0)
    # Independent scalar re-implementation of the golden formula.
    for a, mm, s, y in zip(acc, m, shift, out):
        prod = int(a) * int(mm)
        sign = prod < 0
        av = -prod if sign else prod
        q = av >> int(s)
        rem = av & ((1 << int(s)) - 1)
        half = 1 << (int(s) - 1)
        if rem > half or (rem == half and (q & 1)):
            q += 1
        q = -q if sign else q
        want = min(255, max(0, q))
        assert int(y) == want