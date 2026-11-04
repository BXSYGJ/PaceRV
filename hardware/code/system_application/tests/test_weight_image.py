"""Unit tests for gen_weight_image.py (tasks.md T-GP-03 DoD, five items).

DoD coverage:
  1. test_image_layout_offsets_match_design_5_2
     The binary image is ~690 KB and its region offsets follow the
     design.md 5.2 layout: 32 B header at 0x0000 (magic 'IRW1'),
     384 B layer-contract table at 0x0020, first layer segment at
     0x0200, consecutive 32-byte-aligned segments, and the last segment
     ending exactly at the file size.  The binary contract-table
     entries agree with the JSON records.
  2. test_image_payload_matches_sources (support of item 1)
     Per-segment payload spot check: de-interleaved conv1 weights equal
     the npy source, bias/M/shift arrays equal the JSON contract, and
     every M is inside [2^30, 2^31).
  3. test_layer_contract_json_complete
     layer_contract.json contains all six layers with the complete
     field set (scales, zero points, M/shift, groups, shapes, offsets,
     biases) plus the QuantStub input quantization contract
     (Mel -> int8, REQ-FTR-006) and the eight class names (zh + en).
  4. test_class_order_guard
     The R-06 class-order guard passes: class_names.json ==
     dataset.py INSTRUMENT_NAMES == 0=clarinet .. 7=violin.
  5. test_determinism_sha256
     Two fresh generator runs produce byte-identical outputs (bin
     sha256 and JSON text), matching the committed outputs too.
  6. test_m_shift_and_inv_s_in_q_format_boundaries
     Q-format selection logic: compute_m_shift keeps M in
     [2^30, 2^31) over the full feasible ratio range (including
     extreme small/large values and the exact boundary ratios), and
     choose_inv_s_in escalates Q16.16 -> Q8.24 on 16-bit overflow and
     raises when even the 32-bit container overflows.
"""

from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path

import numpy as np
import pytest

import gen_weight_image as gwi

INSTREC_ROOT = gwi.DEFAULT_INSTREC_ROOT
OUTPUTS_DIR = gwi.DEFAULT_OUT_DIR
BIN_PATH = OUTPUTS_DIR / "weights_image.bin"
JSON_PATH = OUTPUTS_DIR / "layer_contract.json"

# design.md 5.2 pinned layout constants.
HEADER_BYTES = 32
CONTRACT_TABLE_OFFSET = 0x0020
CONTRACT_TABLE_BYTES = 384
FIRST_LAYER_OFFSET = 0x0200
ALIGN_BYTES = 32

# design.md 4.1 grouping table (16-channel groups per layer).
EXPECTED_GROUPS = {"conv1": 3, "conv2": 6, "conv3": 12,
                   "conv4": 16, "fc1": 8, "fc2": 1}
EXPECTED_COUT = {"conv1": 48, "conv2": 96, "conv3": 192,
                 "conv4": 256, "fc1": 128, "fc2": 8}

LAYER_REQUIRED_FIELDS = (
    "name", "layer_id", "layer_type", "s_in", "s_out", "zp_in", "zp_out",
    "activation_dtype", "M", "shift", "M_min", "M_max",
    "shift_min", "shift_max", "num_groups", "num_channels",
    "group_channels", "last_group_channels", "weight_k", "weight_shape",
    "in_shape", "out_shape", "weight_bytes", "bias_bytes", "m_bytes",
    "shift_bytes", "segment_bytes", "image_offset", "ddr3_offset",
    "bias_off", "m_off", "shift_off",
    "bias_int32", "bias_source", "padding_value", "zp_in_correction",
)

# Binary contract-table entry layout (must mirror pack_contract_entry).
ENTRY_STRUCT = struct.Struct("<HBBHHIIIIIIbbBBHHHHIHHIII")


@pytest.fixture(scope="module")
def image_and_contract() -> tuple:
    """Load the committed generator outputs once for the module."""
    assert BIN_PATH.exists(), "weights_image.bin not generated yet"
    assert JSON_PATH.exists(), "layer_contract.json not generated yet"
    image = BIN_PATH.read_bytes()
    with open(JSON_PATH, "r", encoding="utf-8") as fh:
        contract = json.load(fh)
    return image, contract


def _align32(n: int) -> int:
    return (n + ALIGN_BYTES - 1) // ALIGN_BYTES * ALIGN_BYTES


# ---------------------------------------------------------------------------
# DoD 1: image layout vs design.md 5.2.
# ---------------------------------------------------------------------------
def test_image_layout_offsets_match_design_5_2(image_and_contract):
    image, contract = image_and_contract
    total = len(image)

    # ~690 KB total size (design.md 5.2 table).
    assert 680_000 <= total <= 700_000, f"total size {total} not ~690 KB"
    assert total == contract["image_total_bytes"]

    # 32 B image header at 0x0000: magic IRW1, 6 layers, version 1.
    magic, num_layers, version, total_field, payload_len, checksum = \
        struct.unpack("<4sHHII16s", image[:HEADER_BYTES])
    assert magic == b"IRW1"
    assert num_layers == 6
    assert version == 1
    assert total_field == total
    assert payload_len == total - HEADER_BYTES
    assert len(checksum) == 16

    # 384 B contract table at 0x0020 with six 64 B entries.
    table = image[CONTRACT_TABLE_OFFSET:
                  CONTRACT_TABLE_OFFSET + CONTRACT_TABLE_BYTES]
    entries = []
    for i in range(6):
        entry = ENTRY_STRUCT.unpack(
            table[i * 64:(i + 1) * 64])
        assert entry[0] == 0x4C43, f"entry {i} magic != 'LC'"
        entries.append(entry)

    layers = contract["layers"]
    assert len(layers) == 6
    assert [rec["name"] for rec in layers] == [
        "conv1", "conv2", "conv3", "conv4", "fc1", "fc2"]

    # First layer segment at 0x0200 (design.md 5.2).
    assert layers[0]["image_offset"] == FIRST_LAYER_OFFSET
    assert entries[0][5] == FIRST_LAYER_OFFSET

    # Consecutive 32-byte-aligned segments; offsets in the JSON, the
    # binary table and the region list must all agree.
    offset = FIRST_LAYER_OFFSET
    for i, rec in enumerate(layers):
        assert rec["image_offset"] == offset, (
            f"{rec['name']}: offset {rec['image_offset']} != {offset}"
        )
        assert entries[i][5] == rec["image_offset"]
        region = contract["image_layout"]["regions"][i]
        assert region["name"] == rec["name"]
        assert region["offset"] == rec["image_offset"]
        assert region["bytes"] == rec["segment_bytes"]
        # Binary entry fields vs JSON record.
        assert entries[i][1] == rec["layer_id"]
        assert entries[i][2] == (0 if rec["layer_type"] == "conv" else 1)
        assert entries[i][3] == rec["num_groups"]
        assert entries[i][4] == rec["num_channels"]
        assert entries[i][6] == rec["segment_bytes"]
        assert entries[i][7] == rec["weight_bytes"]
        assert entries[i][8] == rec["bias_off"]
        assert entries[i][9] == rec["m_off"]
        assert entries[i][10] == rec["shift_off"]
        assert entries[i][11] == rec["zp_in"]
        assert entries[i][12] == rec["zp_out"]
        offset = _align32(offset + rec["segment_bytes"])

    # The last segment ends exactly at the file size (no trailing data).
    assert offset == total, (
        f"last segment ends at {offset}, file size is {total}"
    )


# ---------------------------------------------------------------------------
# DoD 1 (payload substance): segment contents vs the npy/JSON sources.
# ---------------------------------------------------------------------------
def test_image_payload_matches_sources(image_and_contract):
    image, contract = image_and_contract
    layers = {rec["name"]: rec for rec in contract["layers"]}

    # conv1 segment: de-interleave the weight block back to (48, 9) and
    # compare with the npy source (16-channel group interleave check).
    conv1 = layers["conv1"]
    seg = image[conv1["image_offset"]:
                conv1["image_offset"] + conv1["segment_bytes"]]
    w_bytes = np.frombuffer(
        seg[:conv1["weight_bytes"]], dtype=np.int8).copy()
    cout, k = 48, 9
    restored = np.empty((cout, k), dtype=np.int8)
    pos = 0
    for g in range(0, cout, gwi.GROUP_CHANNELS):
        gc = min(gwi.GROUP_CHANNELS, cout - g)
        block = w_bytes[pos:pos + gc * k]
        # interleave wrote (K, gc) row-major per group.
        restored[g:g + gc, :] = block.reshape(k, gc).T
        pos += gc * k
    npy_w = np.load(INSTREC_ROOT / "deploy" / "weights"
                    / "conv1_weight_int8.npy")
    assert np.array_equal(restored, npy_w.reshape(48, 9))

    # bias / M / shift sub-blocks of every layer match the JSON contract.
    for name, rec in layers.items():
        bias = np.frombuffer(
            seg_bias := image[
                rec["image_offset"] + rec["bias_off"]:
                rec["image_offset"] + rec["bias_off"] + rec["bias_bytes"]],
            dtype=np.int32)
        assert bias.tolist() == rec["bias_int32"]
        m_arr = np.frombuffer(
            image[rec["image_offset"] + rec["m_off"]:
                  rec["image_offset"] + rec["m_off"] + rec["m_bytes"]],
            dtype=np.int32)
        assert m_arr.tolist() == rec["M"]
        assert np.all(m_arr >= gwi.M_MIN) and np.all(m_arr < gwi.M_MAX)
        shift_arr = np.frombuffer(
            image[rec["image_offset"] + rec["shift_off"]:
                  rec["image_offset"] + rec["shift_off"]
                  + rec["shift_bytes"]], dtype=np.uint8)
        assert shift_arr.tolist() == rec["shift"]


# ---------------------------------------------------------------------------
# DoD 2: layer_contract.json completeness + QuantStub input contract.
# ---------------------------------------------------------------------------
def test_layer_contract_json_complete(image_and_contract):
    _, contract = image_and_contract
    layers = contract["layers"]
    assert len(layers) == 6

    for rec in layers:
        for field in LAYER_REQUIRED_FIELDS:
            assert field in rec, f"{rec['name']}: missing field '{field}'"
        # R-12 sanity: scale in (1e-4, 1), zero point in [-128, 127].
        assert 1e-4 < rec["s_in"] < 1.0
        assert 1e-4 < rec["s_out"] < 1.0
        assert -128 <= rec["zp_in"] <= 127
        assert -128 <= rec["zp_out"] <= 127
        # Per-channel array lengths == Cout.
        cout = EXPECTED_COUT[rec["name"]]
        assert rec["num_channels"] == cout
        assert len(rec["M"]) == cout
        assert len(rec["shift"]) == cout
        assert len(rec["bias_int32"]) == cout
        # M/shift Q-format window (design.md 4.3).
        assert rec["M_min"] >= gwi.M_MIN and rec["M_max"] < gwi.M_MAX
        # Grouping table (design.md 4.1).
        assert rec["num_groups"] == EXPECTED_GROUPS[rec["name"]]
        assert rec["group_channels"] == 16
        assert rec["last_group_channels"] == (
            cout - (rec["num_groups"] - 1) * 16)
        # Bias provenance and padding value recorded.
        assert rec["bias_source"] == "pt_packed_params_float_bias"
        assert rec["padding_value"] == rec["zp_in"]

    # QuantStub input quantization contract (Mel -> int8, REQ-FTR-006).
    qs = contract["quant_stub_input_contract"]
    assert qs["dtype"] == "torch.quint8"
    assert qs["s_in"] == pytest.approx(0.062666222, rel=1e-6)
    assert qs["zp_in"] == 49
    # inv_s_in = round(2^24 / s_in) in the Q8.24 escalated format
    # (round(2^16 / s_in) ~ 1.05e6 overflows the 16-bit container).
    assert qs["inv_s_in_format"] == "Q8.24"
    assert qs["inv_s_in_bits"] == 32
    assert qs["inv_s_in"] == int(round(2 ** 24 / qs["s_in"]))

    # Class names (en + zh) present in the contract.
    assert contract["classes"]["num_classes"] == 8


# ---------------------------------------------------------------------------
# DoD 3: class-order guard (R-06).
# ---------------------------------------------------------------------------
def test_class_order_guard(image_and_contract):
    _, contract = image_and_contract

    # Direct invocation of the generator guard (asserts internally).
    classes = gwi.assert_class_order(
        INSTREC_ROOT / "deploy" / "class_names.json",
        INSTREC_ROOT / "src" / "dataset.py")
    assert tuple(classes["names"]) == gwi.EXPECTED_CLASS_NAMES

    # The JSON contract carries the verified order (0..7).
    assert contract["classes"]["names"] == list(gwi.EXPECTED_CLASS_NAMES)
    assert contract["classes"]["names_zh"] == list(
        gwi.EXPECTED_CLASS_NAMES_ZH)


# ---------------------------------------------------------------------------
# DoD 4: determinism (repeated runs are byte-identical).
# ---------------------------------------------------------------------------
def test_determinism_sha256(image_and_contract, tmp_path_factory):
    committed_image, committed_contract = image_and_contract
    committed_sha = hashlib.sha256(committed_image).hexdigest()
    assert committed_sha == committed_contract["image_sha256"]

    out1 = tmp_path_factory.mktemp("run1")
    out2 = tmp_path_factory.mktemp("run2")
    image1, contract1 = gwi.generate(INSTREC_ROOT, out1)
    image2, contract2 = gwi.generate(INSTREC_ROOT, out2)

    sha1 = hashlib.sha256(image1).hexdigest()
    sha2 = hashlib.sha256(image2).hexdigest()
    assert sha1 == sha2, "two fresh runs differ (non-deterministic output)"
    assert sha1 == committed_sha, (
        "fresh run differs from the committed image (non-deterministic "
        f"output): fresh {sha1} vs committed {committed_sha}"
    )
    assert contract1 == contract2
    j1 = (out1 / "layer_contract.json").read_text(encoding="utf-8")
    j2 = (out2 / "layer_contract.json").read_text(encoding="utf-8")
    assert j1 == j2


# ---------------------------------------------------------------------------
# DoD 5: Q-format selection boundaries (M/shift + inv_s_in escalation).
# ---------------------------------------------------------------------------
def test_m_shift_and_inv_s_in_q_format_boundaries(image_and_contract):
    _, contract = image_and_contract

    # --- compute_m_shift boundaries -------------------------------------
    # The shift choice is not unique; the required properties are
    # M == round(ratio * 2^shift) with M in [2^30, 2^31) and shift in
    # [0, 63].  Boundary ratios are checked against those properties.
    for boundary_ratio in (0.5, (2 ** 31 - 1) / 2 ** 31, 1.0):
        m, shift = gwi.compute_m_shift(boundary_ratio)
        assert m == int(round(boundary_ratio * 2.0 ** shift))
        assert gwi.M_MIN <= m < gwi.M_MAX
        assert 0 <= shift <= 63

    # ratio >= 2^31: no non-negative shift keeps M below 2^31 -> the
    # feasibility guard must reject it explicitly (no runaway loop).
    with pytest.raises(ValueError):
        gwi.compute_m_shift(2.0 ** 31)

    # Extremely small ratio (deep fc1 channels reach ~1.4e-7): still a
    # valid (M, shift) pair with M in the window and shift <= 63.
    m, shift = gwi.compute_m_shift(1.4e-7)
    assert gwi.M_MIN <= m < gwi.M_MAX
    assert 0 <= shift <= 63

    # Log-spaced sweep over the whole feasible ratio domain.
    for ratio in np.logspace(-9, np.log10((2 ** 31 - 1) / 2 ** 31), 257):
        m, shift = gwi.compute_m_shift(float(ratio))
        assert gwi.M_MIN <= m < gwi.M_MAX, (
            f"M={m} outside [2^30, 2^31) for ratio={ratio!r}"
        )
        assert 0 <= shift <= 63

    # Real per-layer extremes (fc1 weight scales span four decades ->
    # per-channel shifts span 40..53, exercising both boundaries).
    for rec in contract["layers"]:
        assert rec["shift_min"] >= 0 and rec["shift_max"] <= 63
        assert gwi.M_MIN <= rec["M_min"] and rec["M_max"] < gwi.M_MAX

    # --- choose_inv_s_in Q-format escalation ---------------------------
    # Q16.16 container holds at most 65535, reachable only when
    # round(2^16 / s_in) <= 65535, i.e. s_in > 1.0 (outside the R-12
    # activation-scale domain (1e-4, 1)).  Test the branch logic on a
    # synthetic s_in beyond the domain.
    fmt = gwi.choose_inv_s_in(2.0)      # round(2^16/2) == 32768 fits u16
    assert fmt["format"] == "Q16.16"
    assert fmt["value"] == 32768

    # s_in == 1.0: round(2^16/1) == 65536 overflows by exactly 1 LSB
    # -> escalate to Q8.24.
    fmt = gwi.choose_inv_s_in(1.0)
    assert fmt["format"] == "Q8.24"
    assert fmt["value"] == 2 ** 24

    # s_in == 0.5: 2^17 overflows 16 bits -> Q8.24 s32.
    fmt = gwi.choose_inv_s_in(0.5)
    assert fmt["format"] == "Q8.24"
    assert fmt["bits"] == 32
    assert fmt["value"] == 2 ** 25

    # Every legal activation scale < 1 escalates to Q8.24 (values up to
    # ~2^24 / 1e-4 overflow even the 32-bit container and must raise).
    for s_in in (0.02, 0.06266622245311737, 0.5, 0.999):
        fmt = gwi.choose_inv_s_in(s_in)
        assert fmt["format"] == "Q8.24", f"s_in={s_in} unexpectedly Q16.16"
    with pytest.raises(ValueError):
        gwi.choose_inv_s_in(1e-4)   # 2^24 / 1e-4 ~ 1.7e11 > s32 max

    # Real QuantStub scale (~0.0627): Q8.24 escalation path.
    s_in = contract["quant_stub_input_contract"]["s_in"]
    fmt = gwi.choose_inv_s_in(s_in)
    assert fmt["format"] == "Q8.24"
    assert fmt["value"] == int(round(2 ** 24 / s_in))

    # Tiny s_in overflowing even the 32-bit container -> no third
    # escalation level defined in design.md 3.7 -> must raise.
    with pytest.raises(ValueError):
        gwi.choose_inv_s_in(2.0 ** -9)   # 2^24 / 2^-9 == 2^33 > s32 max