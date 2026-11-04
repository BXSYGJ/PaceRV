#!/usr/bin/env python3
"""test_conv1_debug_vectors.py -- offline regression vectors for T24.

These tests freeze the EVIDENCE gathered while root-causing the conv1
board mismatch (T22 bitstream, reports/conv1_compare.json).  They do not
touch the board, DDR3, PDS or any product RTL: everything is recomputed
from the three $readmemh tables in hex_conv1/, the golden .npy files and
an archived copy of the board capture.

Board capture archive
---------------------
build/uart_last.bin is shared with other board tasks and was overwritten
by a later DDR3 run, so the two group-0 windows of the 2026-10-31 conv1
capture are embedded below (32 pixels x 16 channels each):

    win 0  ->  row  0, group 0, columns  0..31   (top + left pad)
    win 4  ->  row 63, group 0, columns  0..31   (bottom + left pad)

Value facts they encode
-----------------------
* every channel is CONSTANT from column 4 (row 0) / 2 (row 63) on, and
  the golden conv1 is constant there too: the Mel feature map is flat in
  the pad border, so column invariance is a property of the DATA, not a
  datapath bug (this test pins that down so it is not misread later);
* the value set over the two windows is {0, 1, 2, 8, 255} and 99.5% of
  the samples are 0/1/255, i.e. the egress is crushed by a requant that
  sees the WRONG (M, shift) pair;
* the observed values are not a permutation of the golden ones, so the
  lane -> channel mapping is not the culprit.

What the tests assert
---------------------
1. the three hex tables match the layer_contract layout exactly;
2. the contract-bank address mapping in top_npu_conv1_test.v is NOT that
   layout: grp0 loads its M and shift out of the bias block, and a 6-bit
   6'd96 truncates to 32 for grp2;
3. the parameter-model direction: replaying the RTL mapping comes closer
   to the board than the golden does, but still misses > 500 of 1024
   samples -- so the address bug is real but not the whole story;
4. the capture readout pipeline drops one sample per 24-sample frame,
   which is exactly the frame_sum vs RTL-sum delta of 46;
5. round-half-even vs truncation differs by at most 1 LSB and cannot
   produce 0 <-> 255 flips.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
HEX = ROOT / 'hex_conv1'
GOLDEN_DIR = ROOT / 'reports' / 'golden_ref' / 'sine_440_full'
COMPARE_JSON = ROOT / 'reports' / 'conv1_compare.json'

H, W, CH, GRP, LANES = 64, 258, 48, 3, 16

#: Archived board capture (2026-10-31 conv1 run, group 0 of row 0 / row 63).
ARCHIVED_WIN0 = [
    [2, 2, 255, 1, 0, 1, 0, 1, 0, 1, 255, 1, 255, 1, 0, 0],
    [1, 0, 255, 0, 0, 1, 0, 1, 2, 2, 255, 1, 0, 1, 0, 1],
    [0, 1, 255, 1, 255, 1, 0, 0, 1, 0, 255, 0, 0, 1, 0, 1],
    [1, 0, 0, 1, 255, 0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0],
] + [[0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0]] * 28

ARCHIVED_WIN4 = [
    [255, 255, 255, 1, 255, 255, 1, 255, 1, 1, 1, 1, 1, 255, 8, 255],
    [255, 255, 255, 1, 255, 255, 1, 255, 1, 0, 0, 0, 0, 0, 1, 1],
] + [[1, 0, 0, 0, 255, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0]] * 30


# --------------------------------------------------------------------------- #
# tables / golden
# --------------------------------------------------------------------------- #
def _read_hex(path: Path, width: int) -> np.ndarray:
    values = []
    for line in io.open(path, encoding='ascii'):
        line = line.strip()
        if line:
            values.append(int(line, 16) & ((1 << (8 * width)) - 1))
    return np.array(values, dtype=np.uint64)


def _s32(word) -> int:
    value = int(word)
    return value - (1 << 32) if value & 0x80000000 else value


@pytest.fixture(scope='module')
def tables() -> dict:
    return {
        'w32': _read_hex(HEX / 'conv1_w32.hex', 4).astype(np.uint32),
        'ctr': _read_hex(HEX / 'conv1_ctr.hex', 4).astype(np.uint32),
        'feat': _read_hex(HEX / 'conv1_feat.hex', 1).astype(np.uint8),
    }


@pytest.fixture(scope='module')
def contract() -> dict:
    with io.open(SCRIPTS / 'outputs' / 'layer_contract.json',
                 encoding='utf-8') as handle:
        return json.load(handle)


@pytest.fixture(scope='module')
def golden() -> tuple[np.ndarray, np.ndarray]:
    return (np.load(GOLDEN_DIR / 'feat.npy'),
            np.load(GOLDEN_DIR / 'conv1.npy'))


@pytest.fixture(scope='module')
def weights(tables) -> np.ndarray:
    """(48, 9) int8 taps, tap order dy*3+dx, group-major image order."""
    taps = np.asarray(tables['w32'], dtype=np.uint32).reshape(27, 4)
    out = np.zeros((CH, 9), dtype=np.int64)
    for tap in range(27):
        word = 0
        for sub in range(4):
            word |= int(taps[tap][sub]) << (32 * sub)
        for lane in range(LANES):
            byte = (word >> (8 * lane)) & 0xFF
            out[(tap // 9) * LANES + lane, tap % 9] = (
                byte - 256 if byte >= 128 else byte)
    return out


# --------------------------------------------------------------------------- #
# numeric model (mirror of conv_engine.v MAC + requant_unit.v S3/S4)
# --------------------------------------------------------------------------- #
def _x_eff(feat: np.ndarray, zp_in: int = 49) -> np.ndarray:
    """Pad ring is the signed-domain neutral 0 (conv_engine.v:911-912)."""
    pad = np.zeros((H + 2, W + 2), dtype=np.int64)
    pad[1:-1, 1:-1] = feat.astype(np.int64) - zp_in
    return pad


def _rhe(prod, shift) -> np.ndarray:
    """round-half-even >>shift, with the Verilog 64-bit shift saturation."""
    prod = np.asarray(prod, dtype=np.int64)
    shift = np.asarray(shift, dtype=np.int64)
    over = shift >= 64
    q0 = np.where(over, np.where(prod < 0, -1, 0),
                  prod >> np.where(over, 63, shift))
    mask = np.where(over, np.uint64(0xFFFFFFFFFFFFFFFF),
                    (np.uint64(1) << shift.astype(np.uint64)) - np.uint64(1))
    rem = prod.astype(np.uint64) & mask
    half = np.where(over, np.uint64(0),
                    np.uint64(1) << np.maximum(
                        shift.astype(np.uint64) - np.uint64(1), np.uint64(0)))
    inc = (rem > half) | ((rem == half) & ((q0 & 1) == 1))
    return q0 + inc.astype(np.int64)


def _requant(acc, mul, shift, zp_out=0) -> np.ndarray:
    return np.clip(_rhe(acc * mul, shift) + zp_out, 0, 255).astype(np.uint8)


def contract_layout(ctr: np.ndarray) -> dict:
    """The grouping the layer_contract LAYOUT intends (16 consecutive)."""
    bias = [_s32(ctr[i]) for i in range(48)]
    mul = [_s32(ctr[48 + i]) for i in range(48)]
    shft = [int(ctr[96 + i]) & 0x7F for i in range(48)]
    return {g: {'bias': np.array(bias[g * 16:(g + 1) * 16], dtype=np.int64),
                'm': np.array(mul[g * 16:(g + 1) * 16], dtype=np.int64),
                'shift': np.array(shft[g * 16:(g + 1) * 16], dtype=np.int64)}
            for g in range(GRP)}


def rtl_layout(ctr: np.ndarray) -> dict:
    """The grouping top_npu_conv1_test.v actually drives (lines 230-231).

        ctr_base = (job_grp==0) ? 6'd0 : (job_grp==1) ? 6'd48 : 6'd96;

    ctr_base is SIX bits, so 6'd96 is 32.  Each job then walks 48
    CONSECUTIVE words (c_step 0..47) instead of the three 16-word blocks.
    """
    bases = {0: 0, 1: 48, 2: 96 % 64}
    return {g: {'bias': np.array([_s32(ctr[bases[g] + i]) for i in range(16)],
                                 dtype=np.int64),
                'm': np.array([_s32(ctr[bases[g] + 16 + i]) for i in range(16)],
                              dtype=np.int64),
                'shift': np.array([int(ctr[bases[g] + 32 + i]) & 0x7F
                                   for i in range(16)], dtype=np.int64)}
            for g in range(GRP)}


def _conv_window(feat: np.ndarray, weight: np.ndarray, mapping: dict,
                 pixels: list[tuple[int, int]]) -> np.ndarray:
    """(pixels, 16) egress values of one group for the given mapping."""
    pad = _x_eff(feat)
    acc = np.zeros((len(pixels), 16), dtype=np.int64)
    for index, (row, col) in enumerate(pixels):
        for dy in range(3):
            for dx in range(3):
                pr, pc = row + dy - 1, col + dx - 1
                x = 0 if not (0 <= pr < H and 0 <= pc < W) else int(pad[pr + 1, pc + 1])
                acc[index] += x * weight[0:16, dy * 3 + dx]
    acc = acc + mapping[0]['bias'].reshape(1, 16)
    return _requant(acc, mapping[0]['m'].reshape(1, 16),
                    mapping[0]['shift'].reshape(1, 16))


def _board_stable() -> tuple[np.ndarray, list[tuple[int, int]]]:
    """Board samples that are column-invariant, plus their pixel identity."""
    win0 = np.array(ARCHIVED_WIN0, dtype=np.int64)
    win4 = np.array(ARCHIVED_WIN4, dtype=np.int64)
    pixels = [(0, col) for col in range(4, 32)] + [(63, col) for col in range(2, 32)]
    board = np.vstack([win0[4:32], win4[2:32]])
    return board, pixels


# --------------------------------------------------------------------------- #
# 1. the hex tables are exactly the contract layout
# --------------------------------------------------------------------------- #
def test_hex_contract_table_layout(tables, contract):
    rec = contract['layers'][0]
    ctr = tables['ctr']
    assert len(ctr) == 144
    assert [_s32(ctr[i]) for i in range(48)] == rec['bias_int32']
    assert [_s32(ctr[48 + i]) for i in range(48)] == rec['M']
    assert [int(ctr[96 + i]) & 0x7F for i in range(48)] == rec['shift']
    muls = [_s32(ctr[48 + i]) for i in range(48)]
    assert all((1 << 30) <= m < (1 << 31) for m in muls), \
        'M must be a Q0.31 multiplier in [2^30, 2^31)'
    assert all(37 <= int(ctr[96 + i]) & 0x7F <= 41 for i in range(48)), \
        'measured conv1 shift range is 37..41'


def test_feat_hex_is_the_golden_map(tables, golden):
    feat, _ = golden
    assert tables['feat'].shape == (H * W,)
    assert np.array_equal(tables['feat'], feat.reshape(-1).astype(np.uint8))


def test_weight_rom_is_group_major_taps(tables, weights):
    assert weights.shape == (CH, 9)
    assert weights.min() >= -128 and weights.max() <= 127
    # group-major image order: the 27 taps are 3 groups x 9 taps
    assert not np.all(weights[0:16] == weights[16:32])


# --------------------------------------------------------------------------- #
# 2. the RTL contract-bank address mapping is NOT that layout  (root cause)
# --------------------------------------------------------------------------- #
def test_rtl_ctr_base_truncates_96_to_32(tables):
    """Verilog: 6'd96 is a 6-bit literal -> 32, so grp2 reads 32..79."""
    assert 96 % 64 == 32
    mapping = rtl_layout(tables['ctr'])
    assert np.array_equal(mapping[2]['bias'],
                          np.array([_s32(tables['ctr'][32 + i]) for i in range(16)]))
    assert np.array_equal(mapping[2]['m'],
                          np.array([_s32(tables['ctr'][48 + i]) for i in range(16)]))


def test_rtl_group0_m_and_shift_come_from_the_bias_block(tables):
    """grp0 bias is right by accident; its M/shift land in bias[16..47]."""
    lay = contract_layout(tables['ctr'])
    rtl = rtl_layout(tables['ctr'])
    assert np.array_equal(rtl[0]['bias'], lay[0]['bias'])
    assert not np.array_equal(rtl[0]['m'], lay[0]['m'])
    assert not np.array_equal(rtl[0]['shift'], lay[0]['shift'])
    # M[0..15] of grp0 == ctr_rom[16..31] == bias[16..31]
    assert np.array_equal(
        rtl[0]['m'], np.array([_s32(tables['ctr'][16 + i]) for i in range(16)]))
    # shift[0..15] of grp0 == low 7 bits of bias[32..47]
    assert np.array_equal(
        rtl[0]['shift'],
        np.array([int(tables['ctr'][32 + i]) & 0x7F for i in range(16)]))
    # the loaded "shift" values are far outside the measured 37..41 range
    assert rtl[0]['shift'].min() < 37
    assert rtl[0]['shift'].max() > 41


def test_rtl_group1_bias_is_the_M_block(tables):
    lay = contract_layout(tables['ctr'])
    rtl = rtl_layout(tables['ctr'])
    assert not np.array_equal(rtl[1]['bias'], lay[1]['bias'])
    assert np.array_equal(rtl[1]['bias'], lay[0]['m'])
    assert np.array_equal(rtl[1]['m'], lay[1]['m'])
    assert not np.array_equal(rtl[1]['shift'], lay[1]['shift'])


def test_every_group_is_misloaded(tables):
    lay = contract_layout(tables['ctr'])
    rtl = rtl_layout(tables['ctr'])
    for group in range(GRP):
        wrong = sum(not np.array_equal(rtl[group][key], lay[group][key])
                    for key in ('bias', 'm', 'shift'))
        assert wrong >= 2, f'group {group} should be misloaded, got {wrong}/3 wrong'


# --------------------------------------------------------------------------- #
# 3. board archive facts (value domain, column invariance, no permutation)
# --------------------------------------------------------------------------- #
def test_archived_board_value_domain():
    win0 = np.array(ARCHIVED_WIN0, dtype=np.int64)
    win4 = np.array(ARCHIVED_WIN4, dtype=np.int64)
    values = set(win0.reshape(-1).tolist()) | set(win4.reshape(-1).tolist())
    assert values == {0, 1, 2, 8, 255}
    dominant = (np.isin(win0, (0, 1, 255)).sum()
                + np.isin(win4, (0, 1, 255)).sum())
    assert dominant / (win0.size + win4.size) > 0.99


def test_board_columns_are_invariant_and_so_is_the_golden(golden):
    """Column invariance is a property of the Mel data, not of the datapath."""
    win0 = np.array(ARCHIVED_WIN0, dtype=np.int64)
    win4 = np.array(ARCHIVED_WIN4, dtype=np.int64)
    assert all(len(set(win0[4:, ch].tolist())) == 1 for ch in range(16))
    assert all(len(set(win4[2:, ch].tolist())) == 1 for ch in range(16))
    _, conv1 = golden
    assert all(int(conv1[ch, 0, 4:32].std()) == 0 for ch in range(16))
    assert all(int(conv1[ch, 63, 2:32].std()) == 0 for ch in range(16))


def test_observed_is_not_a_permutation_of_the_golden(golden):
    """Rules out the 16-lane TDM lane -> channel mapping hypothesis."""
    _, conv1 = golden
    win0 = np.array(ARCHIVED_WIN0, dtype=np.int64)
    equal = 0
    for col in range(32):
        expected = sorted(int(conv1[ch, 0, col]) for ch in range(16))
        observed = sorted(int(v) for v in win0[col])
        equal += expected == observed
    assert equal == 0


# --------------------------------------------------------------------------- #
# 4. the parameter hypothesis: right direction, still incomplete
# --------------------------------------------------------------------------- #
def test_rtl_parameter_mapping_beats_the_golden_but_does_not_close(tables):
    feat_g, conv1 = np.load(GOLDEN_DIR / 'feat.npy'), np.load(GOLDEN_DIR / 'conv1.npy')
    weight = _weights(tables)
    board, pixels = _board_stable()
    golden_pred = np.array([[int(conv1[ch, row, col]) for ch in range(16)]
                            for row, col in pixels], dtype=np.int64)
    rtl_pred = _conv_window(feat_g, weight, rtl_layout(tables['ctr']), pixels)
    golden_miss = int((golden_pred != board).sum())
    rtl_miss = int((rtl_pred != board).sum())
    assert rtl_miss < golden_miss, 'parameter mapping must explain the shift'
    assert rtl_miss > 500, (
        'the address bug alone does NOT reproduce the board: %d/%d still '
        'differ, so a second defect remains' % (rtl_miss, board.size))


def test_contract_mapping_is_bit_exact_against_the_golden(tables, golden):
    feat, conv1 = golden
    weight = _weights(tables)
    mapping = contract_layout(tables['ctr'])
    pad = _x_eff(feat)
    win = np.empty((H, W, 9), dtype=np.int64)
    for dy in range(3):
        for dx in range(3):
            win[:, :, dy * 3 + dx] = pad[dy:dy + H, dx:dx + W]
    acc = np.tensordot(win, weight[0:16].T, axes=([2], [0]))
    acc = acc + mapping[0]['bias'].reshape(1, 1, 16)
    acc = np.transpose(acc, (2, 0, 1))
    pred = _requant(acc, mapping[0]['m'].reshape(16, 1, 1),
                    mapping[0]['shift'].reshape(16, 1, 1))
    assert np.array_equal(pred, conv1[0:16]), \
        'the contract layout, replayed in Python, IS the golden'


def _weights(tables) -> np.ndarray:
    taps = np.asarray(tables['w32'], dtype=np.uint32).reshape(27, 4)
    out = np.zeros((CH, 9), dtype=np.int64)
    for tap in range(27):
        word = sum(int(taps[tap][sub]) << (32 * sub) for sub in range(4))
        for lane in range(LANES):
            byte = (word >> (8 * lane)) & 0xFF
            out[(tap // 9) * LANES + lane, tap % 9] = (
                byte - 256 if byte >= 128 else byte)
    return out


# --------------------------------------------------------------------------- #
# 5. capture readout off-by-one explains the 46-count sum delta
# --------------------------------------------------------------------------- #
def test_readout_pipeline_drops_one_sample_per_frame():
    """top_npu_conv1_test.v:651-657 reads cap_ram one beat late.

    ro_i=0 sets cap_rd_addr<-base, but cap_dout is the registered output of
    the PREVIOUS address, so dsb[0] receives cap[base-1] while dsb[1..23]
    receive cap[base..base+22].  Every 24-sample frame therefore loses its
    last sample and repeats the previous frame's last sample.
    """
    frame = 24
    n = 3072
    assert n % frame == 0
    # observed_sum = cap_sum - cap[n-1] + cap[0]  (cap[0] is the reset
    # residue of the first frame's dsb[0], which also lands in obs[1])
    observed_sum = 184223
    rtl_sum = 184269
    delta = rtl_sum - observed_sum
    assert delta == 46
    first_sample = ARCHIVED_WIN0[0][1]          # obs[1] == cap[0]
    implied_tail = first_sample + delta          # cap[3071]
    assert 0 <= implied_tail <= 255
    assert implied_tail == 48


def test_compare_json_is_consistent_with_the_archive():
    if not COMPARE_JSON.is_file():
        pytest.skip('reports/conv1_compare.json not present')
    with io.open(COMPARE_JSON, encoding='utf-8') as handle:
        record = json.load(handle)
    assert record['expected_sum'] == 26685
    assert record['observed_sum'] == 184223
    assert record['status_frame']['sample_sum'] == 184269
    assert record['status_frame']['stream_samples'] == 792576
    assert record['status_frame']['sample_count'] == 3072
    assert record['frames']['missing_data_indices'] == []
    # the first 16 mismatch rows are exactly the win-0 column-0 vector
    first = {row['channel']: (row['expected'], row['observed'])
             for row in record['first_mismatch'] if row['sample'] < 16}
    arch = ARCHIVED_WIN0[0]
    for channel, (_, observed) in first.items():
        assert observed == arch[channel], f'channel {channel} archive drift'


# --------------------------------------------------------------------------- #
# 6. requant rounding cannot explain 0 <-> 255 flips
# --------------------------------------------------------------------------- #
def test_round_half_even_vs_truncation_is_at_most_one_lsb():
    prod = np.arange(-4096, 4096, 7, dtype=np.int64)
    for shift in (1, 7, 12, 41):
        rhe = _rhe(prod, np.full(prod.shape, shift, dtype=np.int64))
        trunc = prod >> shift
        assert np.abs(rhe - trunc).max() <= 1
        # ties resolve to the even neighbour, sign-symmetric
        assert _rhe(np.array([-3]), np.array([1]))[0] == -2
        assert _rhe(np.array([3]), np.array([1]))[0] == 2


def test_large_shift_collapses_the_output_to_zero_or_one():
    prod = np.array([-10 ** 6, -1, 0, 1, 10 ** 6], dtype=np.int64)
    y = _rhe(prod, np.full(prod.shape, 87, dtype=np.int64))
    assert y.tolist() == [0, 0, 0, 1, 1]
    clipped = np.clip(y, 0, 255)
    assert clipped.tolist() == [0, 0, 0, 1, 1]
    assert set(clipped.tolist()) <= {0, 1}


def test_saturated_output_reaches_255_only_with_a_small_shift():
    acc = np.array([10 ** 6], dtype=np.int64)
    mul = np.array([1 << 30], dtype=np.int64)
    assert np.clip(_rhe(acc * mul, np.array([2], dtype=np.int64)), 0, 255)[0] == 255
    assert np.clip(_rhe(acc * mul, np.array([60], dtype=np.int64)), 0, 255)[0] == 0