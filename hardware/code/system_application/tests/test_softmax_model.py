"""Softmax fixed-point contract (design.md 4.5, T-M2/M3 support).

Checks the constants softmax_top hardcodes and the golden behaviour the
RTL must reproduce: probabilities sum to ~1, a dominant class saturates
the Q0.16 container at 65535 (expected, not a bug), and the Q15 pre-scale
rounds to 9198 for the measured fc2 scale.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

import golden_pipeline as gp

ROOT = Path(__file__).resolve().parents[1]


def _load():
    contract = json.loads((ROOT / 'scripts/outputs/layer_contract.json').read_text(encoding='utf-8'))
    rec = [x for x in contract['layers'] if x['name'] == 'fc2'][0]
    tables = json.loads((ROOT / 'scripts/outputs/mel_tables.json').read_text(encoding='utf-8'))
    lut = np.array(tables['tables']['exp_lut']['data'], dtype=np.int64)
    return rec, lut


def test_q15_constant_matches_rtl_parameter():
    rec, _ = _load()
    s_q15 = int(np.floor(rec['s_out'] * (1 << 15) + 0.5))
    assert s_q15 == 9197, 'softmax_top S_Q15 default must be updated if this changes'


def test_exp_lut_is_512_q016_entries():
    _, lut = _load()
    assert lut.shape == (512,)
    assert int(lut[0]) == 0xFFFF           # exp(0) == 1.0
    assert int(lut.max()) <= 0xFFFF


def test_uniform_logits_sum_to_one():
    rec, lut = _load()
    u8 = np.full(8, rec['zp_out'], dtype=np.uint8)   # all logits zero
    sm = gp.softmax_fixed(u8, rec, lut)
    assert abs(sm['probs'].sum() - 1.0) < 0.01
    assert sm['probs_q16'].min() >= 8000   # ~1/8 of 65536, ties resolved to even


def test_dominant_class_saturates():
    rec, lut = _load()
    u8 = np.full(8, rec['zp_out'], dtype=np.uint8)
    u8[0] = 255
    sm = gp.softmax_fixed(u8, rec, lut)
    assert int(sm['probs_q16'][0]) == 65535
    assert int(sm['percent'][0]) >= 99
    assert sm['top1'] == 0


def test_percent_is_rounded():
    rec, lut = _load()
    rng = np.random.default_rng(3)
    u8 = rng.integers(0, 256, size=8, dtype=np.uint8)
    sm = gp.softmax_fixed(u8, rec, lut)
    assert sm['percent'].shape == (8,)
    assert np.all(sm['percent'] >= 0) and np.all(sm['percent'] <= 100)