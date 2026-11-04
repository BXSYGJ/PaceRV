"""Verify the regenerated per-layer golden references (reports/golden_ref).

Task: guard against the stale/typed-wrong archive in
``scripts/outputs/golden/`` (int8 all-zero feat, missing conv2..conv4 /
pool, u8 fc2 instead of int32 container logits) that made
``compare_layers.py`` report false differences.

For every stem written by ``scripts/gen_golden_refs.py`` the test
re-runs the golden pipeline (``run_mel_pipeline`` + ``npu_forward``)
and checks that the on-disk ``.npy`` files reproduce the numpy result
element by element.  The only dtype widening allowed is int64 -> int32
for the GAP vector (values are bounded by 255, so the conversion is
lossless by construction).

Run order: ``python scripts/gen_golden_refs.py`` then
``python -m pytest tests/test_golden_refs.py -q``.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

import compare_layers as cl
import gen_golden_refs as ggr
import golden_pipeline as gp

REF_ROOT = ggr.DEFAULT_OUT_ROOT
ARCHIVE_DIR = ggr.DEFAULT_ARCHIVE_DIR


def _discover_stems() -> list:
    root = Path(REF_ROOT)
    if not root.is_dir():
        return []
    return sorted(p.name for p in root.iterdir()
                  if (p / "manifest.json").is_file())


STEMS = _discover_stems()

pytestmark = pytest.mark.skipif(
    not STEMS,
    reason="no generated references; run python scripts/gen_golden_refs.py",
)

# stage -> (dtype, shape)
EXPECTED = {
    "feat": (np.uint8, (64, 258)),
    "conv1": (np.uint8, (48, 64, 258)),
    "conv2": (np.uint8, (96, 32, 129)),
    "conv3": (np.uint8, (192, 16, 64)),
    "conv4": (np.uint8, (256, 8, 32)),
    "pool1": (np.uint8, (48, 32, 129)),
    "pool2": (np.uint8, (96, 16, 64)),
    "pool3": (np.uint8, (192, 8, 32)),
    "pool4": (np.uint8, (256, 4, 16)),
    "gap": (np.int32, (256,)),
    "fc1": (np.uint8, (128,)),
    "fc2_logits": (np.int32, (8,)),
    "probs": (np.uint16, (8,)),
    "probs_float": (np.float64, (8,)),
    "probs_u8_percent": (np.uint8, (8,)),
    "probs_u8_q0_8": (np.uint8, (8,)),
}


@pytest.fixture(scope="module", params=STEMS, ids=STEMS)
def ref(request):
    """Regenerate the golden chain for one stem and load its directory."""
    stem = request.param
    stem_dir = Path(REF_ROOT) / stem
    manifest = json.loads(
        (stem_dir / "manifest.json").read_text(encoding="utf-8"))
    stats = json.loads(
        (stem_dir / "stats.json").read_text(encoding="utf-8"))

    contract = gp.load_layer_contract()
    tables = gp.load_mel_tables()
    weights = gp.load_weights_from_image(contract)
    wav = Path(manifest["source_wav"])
    built = ggr.build_stem_reference(wav, contract, tables, weights)
    return {
        "stem": stem,
        "dir": stem_dir,
        "manifest": manifest,
        "stats": stats,
        "contract": contract,
        "feat": built["feat"],
        "npu": built["npu"],
        "zp_out": int({r["name"]: r for r in contract["layers"]}
                      ["fc2"]["zp_out"]),
    }


def _load(ref: dict, stage: str) -> np.ndarray:
    return np.load(ref["dir"] / f"{stage}.npy")


# ---------------------------------------------------------------------------
# Manifest / file layout.
# ---------------------------------------------------------------------------
def test_manifest_lists_every_stage(ref):
    manifest = ref["manifest"]
    assert manifest["generator"] == "gen_golden_refs.py"
    assert manifest["stem"] == ref["stem"]
    assert set(manifest["files"]) == set(EXPECTED)
    assert len(list(ref["dir"].glob("*.npy"))) == len(EXPECTED)
    assert (ref["dir"] / "stats.json").is_file()


def test_manifest_metadata_matches_disk(ref):
    for stage, entry in ref["manifest"]["files"].items():
        path = ref["dir"] / entry["file"]
        assert path.is_file(), f"{ref['stem']}: missing {entry['file']}"
        arr = np.load(path)
        assert entry["dtype"] == str(arr.dtype), stage
        assert entry["shape"] == list(arr.shape), stage
        wire_id, contract_layer, contract_layer_id = ggr.STAGE_META[stage]
        assert entry["wire_layer_id"] == wire_id, stage
        assert entry["contract_layer"] == contract_layer, stage
        assert entry["contract_layer_id"] == contract_layer_id, stage
        assert entry["source"], stage
        assert ggr._sha256_file(path) == entry["sha256"], stage


def test_all_files_have_manifested_dtype_and_shape(ref):
    for stage, (dtype, shape) in EXPECTED.items():
        arr = _load(ref, stage)
        assert arr.dtype == dtype, f"{ref['stem']}/{stage}: {arr.dtype}"
        assert arr.shape == shape, f"{ref['stem']}/{stage}: {arr.shape}"


# ---------------------------------------------------------------------------
# Element-wise equality with the golden pipeline.
# ---------------------------------------------------------------------------
def test_feat_matches_mel_pipeline(ref):
    feat = _load(ref, "feat")
    assert np.array_equal(feat, ref["feat"])
    assert int(feat.min()) >= 0 and int(feat.max()) <= 255
    # zp_in = 49 is the quantized zero of the Mel feature.
    zp_in = int(ref["contract"]["quant_stub_input_contract"]["zp_in"])
    assert zp_in == 49
    assert int(feat.min()) <= zp_in <= int(feat.max())


def test_conv_and_pool_match_npu_forward(ref):
    npu = ref["npu"]
    for stage in ("conv1", "conv2", "conv3", "conv4",
                  "pool1", "pool2", "pool3", "pool4"):
        arr = _load(ref, stage)
        assert np.array_equal(arr, np.asarray(npu[stage], np.uint8)), (
            f"{ref['stem']}: {stage} differs from npu_forward")
        assert int(arr.min()) >= 0 and int(arr.max()) <= 255


def test_gap_matches_npu_forward_int64_to_int32(ref):
    gap = _load(ref, "gap")
    npu_gap = np.asarray(ref["npu"]["gap"])
    assert npu_gap.dtype == np.int64
    assert gap.dtype == np.int32
    # Lossless narrowing: the golden GAP values are <= 255.
    assert int(npu_gap.min()) >= np.iinfo(np.int32).min
    assert int(npu_gap.max()) <= np.iinfo(np.int32).max
    assert np.array_equal(gap.astype(np.int64), npu_gap)


def test_fc1_matches_npu_forward(ref):
    fc1 = _load(ref, "fc1")
    assert np.array_equal(fc1, np.asarray(ref["npu"]["fc1"], np.uint8))


def test_fc2_logits_equal_fc2_u8_minus_zp_out(ref):
    logits = _load(ref, "fc2_logits")
    npu = ref["npu"]
    assert logits.dtype == np.int32
    assert np.array_equal(logits, np.asarray(npu["logits"], np.int32))
    assert np.array_equal(
        logits.astype(np.int64),
        np.asarray(npu["fc2"], np.int64) - np.int64(ref["zp_out"]))
    assert ref["zp_out"] == 57
    assert int(logits.min()) >= -ref["zp_out"]
    assert int(logits.max()) <= 255 - ref["zp_out"]


# ---------------------------------------------------------------------------
# Probability containers.
# ---------------------------------------------------------------------------
def test_probs_q16_domain_and_normalization(ref):
    q16 = _load(ref, "probs")
    npu_q16 = np.asarray(ref["npu"]["probs_q16"], np.int64)
    assert q16.dtype == np.uint16
    assert np.array_equal(q16.astype(np.int64), npu_q16)
    assert int(q16.min()) >= 0 and int(q16.max()) <= 65535
    total = int(q16.astype(np.int64).sum())
    # Round-half-up in Q0.16 lands on 65536; each class may lose at most
    # 1 LSB, and a single dominant class saturates the winner to 65535
    # (expected Q0.16 semantics), so 8 classes bound the residual at 8.
    assert abs(total - 65536) <= 8, f"{ref['stem']}: probs sum {total}"


def test_probs_float_is_q16_over_65536(ref):
    q16 = _load(ref, "probs").astype(np.float64)
    p = _load(ref, "probs_float")
    assert np.array_equal(p, q16 / 65536.0)
    assert np.allclose(p.sum(), 1.0, atol=2.0 / 65536.0)
    assert int(np.argmax(p)) == ref["npu"]["top1"]


def test_probs_u8_encodings_match_compare_layers(ref):
    npu = ref["npu"]
    percent = _load(ref, "probs_u8_percent")
    q0_8 = _load(ref, "probs_u8_q0_8")
    assert np.array_equal(percent, cl.encode_probs(npu, "percent"))
    assert np.array_equal(q0_8, cl.encode_probs(npu, "q0.8"))
    assert np.array_equal(percent, np.asarray(npu["percent"], np.uint8))
    assert int(percent.max()) <= 100


# ---------------------------------------------------------------------------
# stats.json and compare_layers usability.
# ---------------------------------------------------------------------------
def test_stats_json_matches_recomputed_values(ref):
    stats = ref["stats"]
    assert stats["stem"] == ref["stem"]
    for stage in EXPECTED:
        arr = _load(ref, stage)
        entry = stats["files"][stage]
        assert entry["dtype"] == str(arr.dtype), stage
        assert entry["shape"] == list(arr.shape), stage
        assert entry["min"] == (float(arr.min())
                                if arr.dtype.kind == "f" else int(arr.min()))
        assert entry["max"] == (float(arr.max())
                                if arr.dtype.kind == "f" else int(arr.max()))
        assert entry["n_unique"] == int(np.unique(arr).size), stage
    assert stats["golden_top1"] == int(ref["npu"]["top1"])
    assert stats["probs_q16_sum"] == int(
        _load(ref, "probs").astype(np.int64).sum())


def test_disk_refs_compare_exactly_through_compare_layers(ref):
    """Every integer file is a valid ``--ref`` for its wire layer id."""
    npu = ref["npu"]
    expected = {
        "feat": ref["feat"],
        "conv1": npu["conv1"], "conv2": npu["conv2"],
        "conv3": npu["conv3"], "conv4": npu["conv4"],
        "fc1": npu["fc1"], "fc2_logits": npu["logits"],
        "probs_u8_percent": cl.encode_probs(npu, "percent"),
        "probs_u8_q0_8": cl.encode_probs(npu, "q0.8"),
    }
    for stage, want in expected.items():
        layer_id = ggr.STAGE_META[stage][0]
        stats = cl.compare_array(_load(ref, stage), layer_id, want)
        assert stats["max_abs_delta"] == 0, (ref["stem"], stage, stats)
        assert stats["exact"] == 1.0, (ref["stem"], stage, stats)


def test_generated_root_is_outside_the_archive():
    with pytest.raises(ValueError):
        ggr._check_out_root(ARCHIVE_DIR)
    with pytest.raises(ValueError):
        ggr._check_out_root(Path(ARCHIVE_DIR) / "sub")
    assert Path(REF_ROOT).resolve() != Path(ARCHIVE_DIR).resolve()
    # The frozen archive still exists untouched as evidence.
    assert (Path(ARCHIVE_DIR) / "sine_440_full_feat.npy").is_file()