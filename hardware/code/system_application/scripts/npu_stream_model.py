"""Behaviour-level end-to-end model of the InstRec INT8 NPU datapath.

This model does NOT reuse the arithmetic in ``golden_pipeline``: it is an
independent re-implementation written from the RTL, so a bit-exact match
against ``reports/golden_ref/<stem>/`` is meaningful evidence that the RTL
scan order and storage contract reproduce the golden datapath.

What is mirrored from the RTL (file:line in parentheses):

  * wdma group walk (src/npu/wdma.v): one 32-byte beat stream per weight
    region, cut into taps of ``tap_bytes`` (16 B conv/fc1, 8 B fc2).  The
    region base is 32-byte aligned except for conv1's 144-byte group
    stride: group 1 starts 16 bytes into a beat (``grp_off``), so its
    first beat only contributes the HIGH half (``sub == 1``).  Group
    ``grp_mod`` is re-read for every output row (h_times amplification),
    which is what this model replays per ``(out_row, grp)``.
  * wbuf replay (src/npu/wbuf.v): the group is cached on chip and replayed
    once per output pixel in tap order, i.e. the same (tap_num, lanes)
    matrix is reused for every out_col of that (row, group).
  * conv_engine scan (src/npu/conv_engine.v): out_row -> grp -> out_col ->
    tap, with tap order cin outer, dy*3+dx inner, pad-1 stride-1, 16 lanes
    per group, live ``x - zp_in`` in the signed MAC domain and pad cells
    reading 0.  The 16 lane results are the 16 output channels of the
    group: ``acc = bias; acc += x_tap * w_tap`` then requant.
  * pool_engine (src/npu/pool_engine.v): 2x2 stride-2 floor, odd last
    row/column dropped, max is channel-local.
  * gap_unit (src/npu/gap_unit.v): s32 sum of the raw u8 container over
    the 4x16 map, round-half-even ``>> 6``.
  * fc_engine (src/npu/fc_engine.v): 16 output lanes per group, bias seeds
    the accumulator on the first tap, ``(x - zp_in)`` MAC, bias/M/shift
    contract streams.  fc2 has 8 real channels; lanes 8..15 are padded with
    zero weights and zero contract values, so their result is ``zp_out``
    (logit 0) and is dropped.
  * softmax_top (src/npu/softmax_top.v): S_Q15 = 9197, Q16.15 pre-scale,
    >>6 to Q6.9 with -16384 saturation, 512-entry Q0.16 exp LUT, index
    step 16 Q6.9 LSBs per entry, round-half-up Q0.16 division, saturate to
    65535, percent via round-half-up.

Vectorisation: the per-tap MAC is expressed as one integer matmul per
``(out_row, grp)`` instead of a Python triple loop.  Integer addition and
multiplication are associative, so the vectorised sum is bit-identical to
the RTL's serial tap scan (see test_vectorised_scan_equals_tap_loop).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_IMAGE = ROOT / "scripts" / "outputs" / "weights_image.bin"
DEFAULT_CONTRACT = ROOT / "scripts" / "outputs" / "layer_contract.json"
DEFAULT_TABLES = ROOT / "scripts" / "outputs" / "mel_tables.json"
DEFAULT_GOLDEN_ROOT = ROOT / "reports" / "golden_ref"
DEFAULT_STEMS = ("sine_440_full", "sine_440_twolevel", "silence_3s")

GROUP_CHANNELS = 16
BEAT_BYTES = 32
TAP_PHASE_BYTES = 16          # wdma grp_off is a 16-byte in-beat phase

SOFTMAX_S_Q15 = 9197          # round(s_out * 2^15), fc2 contract
SOFTMAX_Q69_SHIFT = 6
SOFTMAX_Q69_SAT = 1 << 14     # -16384, s15 lower saturation
SOFTMAX_LUT_STEP = 4          # 16 Q6.9 LSBs per LUT entry
SOFTMAX_LUT_DEPTH = 512
Q16_SAT = 65535

# wdma.v layer_id geometry: (wb, cout, h_times, grp_num, taps_per_grp, tap_bytes).
# The model derives the same numbers from the contract and asserts these.
WDMA_GEOMETRY = {
    0: ("conv1", 512, 48, 64, 3, 9, 16),
    1: ("conv2", 1376, 96, 32, 6, 432, 16),
    2: ("conv3", 43712, 192, 16, 12, 864, 16),
    3: ("conv4", 211328, 256, 8, 16, 1728, 16),
    4: ("fc1", 656000, 128, 1, 8, 256, 16),
    5: ("fc2", 689920, 8, 1, 1, 128, 8),
}


# ---------------------------------------------------------------------------
# Integer arithmetic (independent re-implementation of the golden / RTL core)
# ---------------------------------------------------------------------------
def rhe_shift(x: np.ndarray, k) -> np.ndarray:
    """Round-half-to-even arithmetic shift, two's-complement direct form.

    Identical to golden_pipeline.round_half_even_shift and to the RTL
    requant_unit S3 carry logic: floor shift, then round up when the low
    bits exceed half, or on an exact tie when the truncated quotient is odd.
    ``k`` may be a per-channel array (broadcast over the trailing axes).
    """
    x = np.asarray(x, dtype=np.int64)
    k = np.asarray(k, dtype=np.int64)
    q = np.right_shift(x, k)
    rem = np.bitwise_and(x, (np.int64(1) << k) - np.int64(1))
    half = np.int64(1) << (k - np.int64(1))
    inc = (rem > half) | ((rem == half) & ((q & np.int64(1)) != 0))
    return q + inc.astype(np.int64)


def requant_u8(acc: np.ndarray, m: np.ndarray, shift: np.ndarray,
               zp_out: int) -> np.ndarray:
    """y = sat_u8(rhe_shift(acc * M[c], shift[c]) + zp_out)."""
    chan = (len(m),) + (1,) * (acc.ndim - 1)
    prod = acc.astype(np.int64) * m.reshape(chan).astype(np.int64)
    y = rhe_shift(prod, np.asarray(shift).reshape(chan)) + np.int64(zp_out)
    return np.clip(y, 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# Weight image parsing (wdma groups + contract streams)
# ---------------------------------------------------------------------------
def load_contract(path: Path = DEFAULT_CONTRACT) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def load_exp_lut(path: Path = DEFAULT_TABLES) -> np.ndarray:
    """512-entry Q0.16 exp LUT from mel_tables.json (RTL exp_lut.hex)."""
    payload = json.loads(Path(path).read_text(encoding="ascii"))
    lut = np.asarray(payload["tables"]["exp_lut"]["data"], dtype=np.int64)
    assert lut.shape == (SOFTMAX_LUT_DEPTH,)
    return lut


class LayerWeights:
    """One layer's wdma weight groups plus its bias/M/shift contract."""

    def __init__(self, rec: dict, image: np.ndarray):
        self.rec = rec
        self.name = rec["name"]
        self.is_conv = rec["layer_type"] == "conv"
        self.cout = int(rec["num_channels"])
        self.k = int(rec["weight_k"])
        self.zp_in = int(rec["zp_in"])
        self.zp_out = int(rec["zp_out"])
        self.base = int(rec["image_offset"])
        self.tap_bytes = 8 if self.name == "fc2" else 16
        self.group_bytes = self.k * self.tap_bytes
        self.grp_num = (self.cout + GROUP_CHANNELS - 1) // GROUP_CHANNELS
        self.h_times = int(rec["in_shape"][-2]) if self.is_conv else 1
        self.grp_total = self.h_times * self.grp_num
        self._image = image

        seg = image[self.base:self.base + rec["segment_bytes"]]
        self.bias = np.frombuffer(
            seg[rec["bias_off"]:rec["bias_off"] + rec["bias_bytes"]].tobytes(),
            dtype="<i4").astype(np.int64)
        self.m = np.frombuffer(
            seg[rec["m_off"]:rec["m_off"] + rec["m_bytes"]].tobytes(),
            dtype="<i4").astype(np.int64)
        self.shift = np.frombuffer(
            seg[rec["shift_off"]:rec["shift_off"] + rec["shift_bytes"]].tobytes(),
            dtype=np.uint8).astype(np.int64)
        assert self.bias.tolist() == [int(v) for v in rec["bias_int32"]]
        assert self.m.tolist() == [int(v) for v in rec["M"]]
        assert self.shift.tolist() == [int(v) for v in rec["shift"]]

    # -- wdma geometry -----------------------------------------------------
    def group_base(self, grp: int) -> int:
        """Byte offset of group ``grp`` inside the weight region."""
        return self.base + grp * self.group_bytes

    def group_phase(self, grp: int) -> int:
        """In-beat phase of the group start: 0 or 16 bytes (wdma grp_off)."""
        return TAP_PHASE_BYTES if (self.group_base(grp) & TAP_PHASE_BYTES) else 0

    def group_beats(self, grp: int) -> int:
        span = self.group_phase(grp) + self.group_bytes
        return (span + BEAT_BYTES - 1) // BEAT_BYTES

    def raw_taps(self, grp: int) -> np.ndarray:
        """(tap_num, lanes) int8 taps produced by the wdma beat fetch.

        The address is aligned down to 32 B and the first ``grp_off`` bytes
        are skipped, exactly like wdma S_TFIL/S_TEMIT.  The beat stream is
        read contiguously; taps never cross a discarded beat because the
        alignment is a whole 16-byte half.
        """
        base = self.group_base(grp)
        phase = self.group_phase(grp)
        aligned = base - phase
        beats = self.group_beats(grp)
        stream = b"".join(
            self._image[aligned + b * BEAT_BYTES:
                        aligned + (b + 1) * BEAT_BYTES].tobytes()
            for b in range(beats))
        n_bytes = self.k * self.tap_bytes
        buf = stream[phase:phase + n_bytes]
        assert len(buf) == n_bytes, f"{self.name} group {grp} truncated"
        return np.frombuffer(buf, dtype=np.int8).reshape(self.k, self.tap_bytes)

    def group_weight(self, grp: int) -> np.ndarray:
        """(16, K) int8 weights; fc2 lanes 8..15 are zero padded."""
        taps = self.raw_taps(grp)
        w = np.zeros((GROUP_CHANNELS, self.k), dtype=np.int8)
        w[:taps.shape[1], :] = taps.T
        return w

    def group_weight_natural(self) -> np.ndarray:
        """(cout, K) natural-order weights rebuilt from the group replay."""
        out = np.zeros((self.cout, self.k), dtype=np.int8)
        for grp in range(self.grp_num):
            w = self.group_weight(grp)
            lo = grp * GROUP_CHANNELS
            hi = min(lo + GROUP_CHANNELS, self.cout)
            out[lo:hi, :] = w[:hi - lo, :]
        return out

    # -- 48-beat (conv) / 3*Cout-beat (fc) contract streams -----------------
    def group_contract(self, grp: int) -> dict:
        """Contract beats for one group, padded to 16 lanes with zeros."""
        lanes = np.arange(grp * GROUP_CHANNELS,
                          grp * GROUP_CHANNELS + GROUP_CHANNELS)
        valid = lanes < self.cout
        safe = np.minimum(lanes, self.cout - 1)
        out = {
            "bias": np.where(valid, self.bias[safe], 0).astype(np.int64),
            "m": np.where(valid, self.m[safe], 0).astype(np.int64),
            "shift": np.where(valid, self.shift[safe], 0).astype(np.int64),
        }
        return out

    def fc_contract(self) -> dict:
        """fc_engine loads COUT beats of bias/M/shift before the first group."""
        return {"bias": self.bias.copy(), "m": self.m.copy(),
                "shift": self.shift.copy()}


class NpuWeights:
    def __init__(self, image_path: Path = DEFAULT_IMAGE,
                 contract_path: Path = DEFAULT_CONTRACT):
        self.contract = load_contract(contract_path)
        image = np.fromfile(str(image_path), dtype=np.uint8)
        assert image.size == self.contract["image_total_bytes"]
        self.layers = {}
        for rec in self.contract["layers"]:
            layer = LayerWeights(rec, image)
            self.layers[layer.name] = layer
        self._check_wdma_geometry()

    def _check_wdma_geometry(self) -> None:
        for lid, (name, wb, cout, h_times, grp_num, taps, tap_b) in \
                WDMA_GEOMETRY.items():
            lay = self.layers[name]
            assert lay.base == wb, name
            assert lay.cout == cout, name
            assert lay.h_times == h_times, name
            assert lay.grp_num == grp_num, name
            assert lay.k == taps, name
            assert lay.tap_bytes == tap_b, name
            assert self.contract["layers"][lid]["name"] == name, name

    def __getitem__(self, name: str) -> LayerWeights:
        return self.layers[name]


# ---------------------------------------------------------------------------
# Convolution: out_row -> grp -> out_col -> tap, vectorised per (row, group)
# ---------------------------------------------------------------------------
def _conv_row_taps(x_signed: np.ndarray, out_row: int) -> np.ndarray:
    """(Cin*9, W) signed window matrix for one output row.

    Order is cin outer, dy*3+dx inner (matches the weight tap order and
    golden's (Cin, H, W, 3, 3) flatten).  Out-of-range rows/cols stay 0,
    which is the signed-domain neutral pad value (conv_engine reads 0).
    """
    cin, h, w = x_signed.shape
    win = np.zeros((cin, 3, 3, w), dtype=np.int64)
    for dy in range(3):
        ry = out_row + dy - 1
        if ry < 0 or ry >= h:
            continue
        win[:, dy, 1, :] = x_signed[:, ry, :]
        win[:, dy, 0, 1:] = x_signed[:, ry, :w - 1]
        win[:, dy, 2, :w - 1] = x_signed[:, ry, 1:]
    return win.reshape(cin * 9, w)


def conv_layer_stream(x_u8: np.ndarray, layer: LayerWeights) -> np.ndarray:
    """3x3 pad-1 stride-1 INT8 conv in the RTL scan order."""
    cin, h, w = x_u8.shape
    assert cin == layer.k // 9 and layer.k % 9 == 0
    x_signed = x_u8.astype(np.int64) - np.int64(layer.zp_in)
    out = np.empty((layer.cout, h, w), dtype=np.uint8)
    for out_row in range(h):
        taps = _conv_row_taps(x_signed, out_row)          # (Cin*9, W)
        for grp in range(layer.grp_num):
            # wdma re-reads the group for every (row, group); wbuf then
            # replays it for all out_col of this row (one matmul).
            wg = layer.group_weight(grp).astype(np.int64)  # (16, Cin*9)
            ct = layer.group_contract(grp)
            acc = wg @ taps + ct["bias"].reshape(-1, 1)
            lo = grp * GROUP_CHANNELS
            hi = lo + GROUP_CHANNELS
            out[lo:hi, out_row, :] = requant_u8(acc, ct["m"], ct["shift"],
                                                layer.zp_out)
    return out


def conv_reference_loop(x_u8: np.ndarray, weight: np.ndarray,
                        bias: np.ndarray, m: np.ndarray, shift: np.ndarray,
                        zp_in: int, zp_out: int) -> np.ndarray:
    """Slow per-pixel / per-tap reference used only to prove order equality."""
    cout, k = weight.shape
    cin = k // 9
    h, w = x_u8.shape[1], x_u8.shape[2]
    out = np.empty((cout, h, w), dtype=np.uint8)
    for out_row in range(h):
        for grp in range((cout + 15) // 16):
            for col in range(w):
                acc = bias[grp * 16:grp * 16 + 16].astype(np.int64).copy()
                for tap in range(k):
                    c, dy, dx = tap // 9, (tap % 9) // 3, tap % 3
                    ry, cx = out_row + dy - 1, col + dx - 1
                    xv = 0
                    if 0 <= ry < h and 0 <= cx < w:
                        xv = int(x_u8[c, ry, cx]) - zp_in
                    acc += xv * weight[grp * 16:grp * 16 + 16, tap].astype(
                        np.int64)
                out[grp * 16:grp * 16 + 16, out_row, col] = requant_u8(
                    acc.reshape(-1, 1), m[grp * 16:grp * 16 + 16].reshape(-1),
                    shift[grp * 16:grp * 16 + 16].reshape(-1),
                    zp_out).reshape(-1)
    return out


# ---------------------------------------------------------------------------
# Pool / GAP / FC / softmax (RTL stream semantics)
# ---------------------------------------------------------------------------
def pool_layer_stream(x_u8: np.ndarray) -> np.ndarray:
    """2x2 stride-2 floor max pool; odd last row/col dropped (R-10)."""
    c, h, w = x_u8.shape
    oh, ow = h // 2, w // 2
    view = x_u8[:, :oh * 2, :ow * 2].reshape(c, oh, 2, ow, 2)
    return view.max(axis=(2, 4))


def gap_layer_stream(x_u8: np.ndarray) -> np.ndarray:
    """s32 sum of the raw u8 container, round-half-even >>6."""
    total = x_u8.astype(np.int64).sum(axis=(1, 2))
    return rhe_shift(total, 6)


def fc_layer_stream(x_vec: np.ndarray, layer: LayerWeights) -> np.ndarray:
    """INT8 fully connected layer, 16 lanes per group, bias-seeded MAC."""
    cin = x_vec.size
    assert cin == layer.k
    x_eff = x_vec.astype(np.int64) - np.int64(layer.zp_in)
    out = np.empty(layer.cout, dtype=np.uint8)
    for grp in range(layer.grp_num):
        wg = layer.group_weight(grp).astype(np.int64)
        ct = layer.group_contract(grp)
        acc = wg @ x_eff + ct["bias"]
        y = requant_u8(acc.reshape(-1, 1), ct["m"], ct["shift"],
                       layer.zp_out).reshape(-1)
        lo = grp * GROUP_CHANNELS
        hi = min(lo + GROUP_CHANNELS, layer.cout)
        out[lo:hi] = y[:hi - lo]
    return out


def softmax_stream(logits: np.ndarray, exp_lut: np.ndarray,
                   s_q15: int = SOFTMAX_S_Q15) -> dict:
    """Fixed-point 8-class softmax, bit-exact to softmax_top.v."""
    l_int = np.asarray(logits, dtype=np.int64)
    l_q = l_int * np.int64(s_q15)
    d = l_q - np.int64(l_q.max())
    d69 = np.right_shift(d, SOFTMAX_Q69_SHIFT)
    d69 = np.maximum(d69, -np.int64(SOFTMAX_Q69_SAT))
    idx = np.minimum(np.right_shift(-d69, SOFTMAX_LUT_STEP),
                     SOFTMAX_LUT_DEPTH - 1).astype(np.int64)
    exp_v = exp_lut[idx]
    total = int(exp_v.sum())
    if total == 0:
        p_q16 = np.zeros_like(exp_v)
    else:
        p_q16 = ((exp_v << 16) + (total >> 1)) // total
        p_q16 = np.minimum(p_q16, Q16_SAT)
    pct = (p_q16 * 100 + 32768) >> 16
    return {
        "logits": l_int,
        "logits_q16": l_q,
        "softmax_idx": idx,
        "exp_q16": exp_v,
        "probs_q16": p_q16.astype(np.int64),
        "percent": pct.astype(np.int64),
        "top1": int(np.argmax(p_q16)) if total else 0,
    }


# ---------------------------------------------------------------------------
# Full forward
# ---------------------------------------------------------------------------
def npu_stream_forward(feat_u8: np.ndarray, weights: NpuWeights,
                       exp_lut: np.ndarray) -> dict:
    """Run conv1 -> pool -> conv2 -> ... -> gap -> fc1 -> fc2 -> softmax."""
    assert feat_u8.shape == (64, 258)
    x = feat_u8[np.newaxis, :, :]
    out = {}
    for idx, (conv_name, pool_name) in enumerate(
            (("conv1", "pool1"), ("conv2", "pool2"),
             ("conv3", "pool3"), ("conv4", "pool4"))):
        x = conv_layer_stream(x, weights[conv_name])
        out[conv_name] = x
        x = pool_layer_stream(x)
        out[pool_name] = x
    gap = gap_layer_stream(x)
    out["gap"] = gap
    fc1 = fc_layer_stream(gap, weights["fc1"])
    out["fc1"] = fc1
    fc2 = fc_layer_stream(fc1, weights["fc2"])
    out["fc2"] = fc2
    # fc2 lanes 8..15 are contract-padded: weights 0, contract 0 -> zp_out.
    assert np.all(fc2[8:] == weights["fc2"].zp_out)
    logits = fc2[:8].astype(np.int64) - np.int64(weights["fc2"].zp_out)
    out["fc2_logits"] = logits
    sm = softmax_stream(logits, exp_lut)
    out["probs_q16"] = sm["probs_q16"]
    out["percent"] = sm["percent"]
    out["top1"] = sm["top1"]
    out["_softmax"] = sm
    return out


# ---------------------------------------------------------------------------
# Golden comparison helper
# ---------------------------------------------------------------------------
STAGE_FILES = (
    "feat", "conv1", "pool1", "conv2", "pool2", "conv3", "pool3",
    "conv4", "pool4", "gap", "fc1", "fc2_logits", "probs",
)


def compare_stem(stem: str, weights: NpuWeights | None = None,
                 exp_lut: np.ndarray | None = None,
                 golden_root: Path = DEFAULT_GOLDEN_ROOT) -> dict:
    """Return {stage: {exact, max_abs_delta, hits, total}} for one stem."""
    if weights is None:
        weights = NpuWeights()
    if exp_lut is None:
        exp_lut = load_exp_lut()
    root = Path(golden_root) / stem
    feat = np.load(root / "feat.npy")
    got = npu_stream_forward(feat, weights, exp_lut)
    got["feat"] = feat
    got["probs"] = got["probs_q16"]
    result = {}
    refs = {stage: np.load(root / f"{stage}.npy") for stage in STAGE_FILES}
    refs["percent"] = np.load(root / "probs_u8_percent.npy")
    for stage, ref in refs.items():
        a = np.asarray(got[stage])
        eq = bool(np.array_equal(a, ref))
        delta = np.abs(a.astype(np.int64) - ref.astype(np.int64))
        result[stage] = {
            "exact": eq,
            "max_abs_delta": int(delta.max()) if delta.size else 0,
            "hits": int((delta == 0).sum()),
            "total": int(delta.size),
        }
    return result


def _main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--stem", action="append", default=None)
    ap.add_argument("--golden-root", type=Path, default=DEFAULT_GOLDEN_ROOT)
    args = ap.parse_args()
    stems = args.stem or list(DEFAULT_STEMS)
    weights = NpuWeights()
    exp_lut = load_exp_lut()
    for stem in stems:
        report = compare_stem(stem, weights, exp_lut, args.golden_root)
        bad = [s for s, r in report.items() if not r["exact"]]
        print(f"{stem}: {len(report)} stages, "
              f"{'EXACT' if not bad else 'MISMATCH ' + ','.join(bad)}")
        for stage, r in report.items():
            if not r["exact"]:
                print(f"  {stage}: max|d|={r['max_abs_delta']} "
                      f"hits={r['hits']}/{r['total']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())