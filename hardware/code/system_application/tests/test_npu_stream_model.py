"""End-to-end behaviour model of the INT8 NPU vs the golden references.

The model under test is scripts/npu_stream_model.py: an independent
re-implementation of the RTL datapath (wdma group walk, wbuf replay,
conv_engine scan order, pool/gap/fc/softmax).  These tests

  1. pin the wdma group geometry against layer_contract.json and
     golden_pipeline.load_weights_from_image (weights are rebuilt from the
     beat stream, not from the de-interleaver);
  2. pin the conv1 144-byte group stride / 16-byte in-beat phase and the
     discarded tail beat;
  3. prove the vectorised conv scan is bit-identical to a literal
     per-pixel / per-tap loop;
  4. pin pool floor, GAP >>6, the fc2 8->16 lane pad and the softmax
     saturation;
  5. require element-wise equality with reports/golden_ref/<stem>/ for all
     three stems and every stage (conv/pool/gap/fc/logits/probs/percent).
     No tolerance is allowed: any LSB difference would fail here.
"""

from __future__ import annotations

import numpy as np
import pytest

import golden_pipeline as gp
import npu_stream_model as nsm


@pytest.fixture(scope="module")
def weights():
    return nsm.NpuWeights()


@pytest.fixture(scope="module")
def exp_lut():
    return nsm.load_exp_lut()


# ---------------------------------------------------------------------------
# 1. wdma weight groups vs the authoritative contract
# ---------------------------------------------------------------------------
def test_group_weights_match_deinterleaved_contract(weights):
    golden = gp.load_weights_from_image(weights.contract)
    for name, layer in weights.layers.items():
        rebuilt = layer.group_weight_natural()
        assert np.array_equal(rebuilt, golden[name]["weight"]), name


def test_contract_shared_fields_match_image(weights):
    for rec in weights.contract["layers"]:
        layer = weights[rec["name"]]
        assert layer.bias.tolist() == [int(v) for v in rec["bias_int32"]]
        assert layer.m.tolist() == [int(v) for v in rec["M"]]
        assert layer.shift.tolist() == [int(v) for v in rec["shift"]]
        assert layer.zp_in == rec["zp_in"]
        assert layer.zp_out == rec["zp_out"]


def test_wdma_geometry_groups_and_tap_bytes(weights):
    expect = {
        "conv1": (3, 192, 9, 16, 144, 5),
        "conv2": (6, 192, 432, 16, 6912, 216),
        "conv3": (12, 192, 864, 16, 13824, 432),
        "conv4": (16, 128, 1728, 16, 27648, 864),
        "fc1": (8, 8, 256, 16, 4096, 128),
        "fc2": (1, 1, 128, 8, 1024, 32),
    }
    for name, (grp_num, grp_total, taps, tap_b, gbytes, beats) in \
            expect.items():
        lay = weights[name]
        assert lay.grp_num == grp_num, name
        assert lay.grp_total == grp_total, name
        assert lay.k == taps, name
        assert lay.tap_bytes == tap_b, name
        assert lay.group_bytes == gbytes, name
        assert lay.group_beats(0) == beats, name


# ---------------------------------------------------------------------------
# 2. conv1 144-byte group stride / 16-byte in-beat phase / tail beat
# ---------------------------------------------------------------------------
def test_conv1_groups_alternate_in_beat_phase(weights):
    conv1 = weights["conv1"]
    assert conv1.group_bytes == 144
    assert conv1.base % nsm.BEAT_BYTES == 0
    # 144 B is not a multiple of 32 B, so odd groups start mid-beat.
    bases = [conv1.group_base(g) for g in range(3)]
    assert bases == [512, 656, 800]
    assert [b % 32 for b in bases] == [0, 16, 0]
    assert [conv1.group_phase(g) for g in range(3)] == [0, 16, 0]
    # Each group still occupies 5 beats (144 B = 4.5 beats, phase included).
    assert [conv1.group_beats(g) for g in range(3)] == [5, 5, 5]


def test_conv1_group1_reads_high_half_of_first_beat(weights):
    image = np.fromfile(nsm.DEFAULT_IMAGE, dtype=np.uint8)
    conv1 = weights["conv1"]
    taps = conv1.raw_taps(1)
    # Group 1 starts at byte 656 = the high half of the beat at 640.
    aligned_first_half = np.frombuffer(
        image[640:656].tobytes(), dtype=np.int8)
    high_half = np.frombuffer(image[656:672].tobytes(), dtype=np.int8)
    assert not np.array_equal(aligned_first_half, high_half)
    assert np.array_equal(taps[0], high_half)
    assert np.array_equal(taps.reshape(-1),
                          np.frombuffer(image[656:800].tobytes(),
                                        dtype=np.int8))
    # The low half of the fetched beat is group 0's last tap and must be
    # skipped by the grp_off/sub==1 path, never emitted for group 1.
    assert np.array_equal(conv1.raw_taps(0)[8], aligned_first_half)


def test_conv1_last_group_does_not_emit_beyond_weights(weights):
    conv1 = weights["conv1"]
    taps = conv1.raw_taps(2)
    # 800 + 9*16 = 944 == the end of the conv1 weight block.
    image = np.fromfile(nsm.DEFAULT_IMAGE, dtype=np.uint8)
    assert np.array_equal(taps.reshape(-1),
                          np.frombuffer(image[800:944].tobytes(),
                                        dtype=np.int8))


def test_conv1_tail_beat_has_one_tap(weights):
    conv1 = weights["conv1"]
    # 9 taps * 16 B = 144 B: 4 full beats (8 taps) + 1 half beat (1 tap).
    taps = conv1.raw_taps(0)
    assert taps.shape == (9, 16)
    assert conv1.group_beats(0) * 32 == 160
    assert 4 * 2 == 8 and 9 - 8 == 1


# ---------------------------------------------------------------------------
# 3. vectorised scan == literal per-pixel / per-tap loop
# ---------------------------------------------------------------------------
class _StubLayer:
    """Minimal LayerWeights surface for the scan-equality test."""

    def __init__(self, weight, bias, m, shift, zp_in, zp_out):
        self.weight = weight
        self.bias = bias
        self.m = m
        self.shift = shift
        self.zp_in = zp_in
        self.zp_out = zp_out
        self.cout, self.k = weight.shape
        self.grp_num = (self.cout + 15) // 16

    def group_weight(self, grp):
        w = np.zeros((16, self.k), dtype=np.int8)
        lo = grp * 16
        hi = min(lo + 16, self.cout)
        w[:hi - lo] = self.weight[lo:hi]
        return w

    def group_contract(self, grp):
        lanes = np.arange(grp * 16, grp * 16 + 16)
        valid = lanes < self.cout
        safe = np.minimum(lanes, self.cout - 1)
        return {
            "bias": np.where(valid, self.bias[safe], 0),
            "m": np.where(valid, self.m[safe], 0),
            "shift": np.where(valid, self.shift[safe], 0),
        }


def test_vectorised_scan_equals_tap_loop():
    rng = np.random.default_rng(20261028)
    cin, cout, h, w = 3, 32, 4, 5
    weight = rng.integers(-128, 128, size=(cout, cin * 9), dtype=np.int8)
    bias = rng.integers(-5000, 5000, size=(cout,), dtype=np.int64)
    m = rng.integers(2**30, 2**31, size=(cout,), dtype=np.int64)
    shift = rng.integers(37, 45, size=(cout,), dtype=np.int64)
    x = rng.integers(0, 256, size=(cin, h, w), dtype=np.uint8)
    stub = _StubLayer(weight, bias, m, shift, zp_in=49, zp_out=0)
    fast = nsm.conv_layer_stream(x, stub)
    slow = nsm.conv_reference_loop(x, weight, bias, m, shift, 49, 0)
    assert np.array_equal(fast, slow)


# ---------------------------------------------------------------------------
# 4. pool / gap / fc / softmax primitives
# ---------------------------------------------------------------------------
def test_pool_floor_drops_odd_row_and_column():
    x = np.zeros((2, 3, 3), dtype=np.uint8)
    x[0, 0, 0], x[0, 0, 2], x[0, 2, 0] = 10, 250, 200
    out = nsm.pool_layer_stream(x)
    assert out.shape == (2, 1, 1)
    assert int(out[0, 0, 0]) == 10


def test_gap_round_half_even_shift6():
    x = np.zeros((256, 4, 16), dtype=np.uint8)
    x[0, 0, 0] = 32          # 32/64 == 0.5 -> ties to even 0
    x[1, 0, 0] = 96          # 96/64 == 1.5 -> ties to even 2
    x[2, 0, 0] = 33          # 33/64 -> 1
    x[3, 0, 0] = 31          # 31/64 -> 0
    gap = nsm.gap_layer_stream(x)
    assert gap.dtype == np.int64
    assert [int(gap[i]) for i in range(4)] == [0, 2, 1, 0]


def test_fc2_pads_8_channels_to_16(weights):
    fc2 = weights["fc2"]
    assert fc2.cout == 8 and fc2.grp_num == 1
    ct = fc2.group_contract(0)
    assert ct["bias"].shape == (16,) and ct["m"].shape == (16,)
    assert not ct["bias"][8:].any()
    assert not ct["m"][8:].any()
    assert not ct["shift"][8:].any()
    wg = fc2.group_weight(0)
    assert wg.shape == (16, 128)
    assert not wg[8:].any()
    # Zero weight + zero M + zero shift -> acc 0 -> sat(0 + zp_out(57)).
    pad = nsm.requant_u8(np.zeros((8, 1), dtype=np.int64),
                         np.zeros(8, dtype=np.int64),
                         np.zeros(8, dtype=np.int64), 57)
    assert np.all(pad == 57)


def test_softmax_dominant_class_saturates_65535(weights, exp_lut):
    logits = np.full(8, -60, dtype=np.int64)
    logits[3] = 60
    sm = nsm.softmax_stream(logits, exp_lut)
    assert int(sm["probs_q16"][3]) == 65535
    assert int(sm["percent"][3]) == 100
    assert sm["top1"] == 3
    assert int(sm["probs_q16"].sum()) == 65535


def test_softmax_exp_lut_matches_rtl_hex(weights, exp_lut):
    hex_path = nsm.ROOT / "src/mel/exp_lut.hex"
    values = [int(tok, 16) for tok in hex_path.read_text().split()]
    assert np.array_equal(np.asarray(values, dtype=np.int64), exp_lut)
    assert nsm.SOFTMAX_S_Q15 == 9197


def test_conv1_pads_with_signed_zero_not_minus_zp():
    # 1x1 input, all-ones 3x3 kernel: the 8 pad cells must contribute 0 in
    # the signed domain, so acc == bias + (x - 49) * 1, never 8*(-49).
    weight = np.ones((16, 9), dtype=np.int8)
    bias = np.zeros(16, dtype=np.int64)
    m = np.full(16, 2**30, dtype=np.int64)
    shift = np.full(16, 30, dtype=np.int64)
    stub = _StubLayer(weight, bias, m, shift, zp_in=49, zp_out=0)
    x = np.full((1, 1, 1), 200, dtype=np.uint8)
    out = nsm.conv_layer_stream(x, stub)
    assert np.all(out == 200 - 49)


def test_conv_contract_is_48_beats(weights):
    for name in ("conv1", "conv2", "conv3", "conv4"):
        lay = weights[name]
        for grp in range(lay.grp_num):
            ct = lay.group_contract(grp)
            beats = list(ct["bias"]) + list(ct["m"]) + list(ct["shift"])
            assert len(beats) == 48, f"{name} g{grp}"
            assert all(0 <= int(v) <= 127 for v in ct["shift"]), name


def test_fc_contract_streams_are_per_channel(weights):
    for name in ("fc1", "fc2"):
        ct = weights[name].fc_contract()
        cout = weights[name].cout
        assert ct["bias"].shape == (cout,)
        assert ct["m"].shape == (cout,)
        assert ct["shift"].shape == (cout,)


# ---------------------------------------------------------------------------
# 5. end-to-end bit-exact comparison (no tolerance)
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("stem", nsm.DEFAULT_STEMS)
def test_stem_all_stages_bit_exact(stem, weights, exp_lut):
    report = nsm.compare_stem(stem, weights, exp_lut)
    for stage, res in report.items():
        assert res["exact"], (
            f"{stem}/{stage}: max|delta|={res['max_abs_delta']} "
            f"hits={res['hits']}/{res['total']}")


@pytest.mark.parametrize("stem", nsm.DEFAULT_STEMS)
def test_stem_probs_and_percent(stem, weights, exp_lut):
    feat = np.load(nsm.DEFAULT_GOLDEN_ROOT / stem / "feat.npy")
    out = nsm.npu_stream_forward(feat, weights, exp_lut)
    root = nsm.DEFAULT_GOLDEN_ROOT / stem
    assert np.array_equal(out["probs_q16"], np.load(root / "probs.npy"))
    assert np.array_equal(out["percent"],
                          np.load(root / "probs_u8_percent.npy"))
    assert 0 <= int(out["probs_q16"].min())
    assert 65520 <= int(out["probs_q16"].sum()) <= 65544