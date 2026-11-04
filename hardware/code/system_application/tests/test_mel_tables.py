"""Unit tests for gen_mel_tables.py (tasks.md T-GP-02 DoD, five items).

DoD coverage:
  1. test_feature_params_match_req_ftr_001
     All ten T-GP-02 parameter items (plus win_length/window pinned by
     REQ-FTR-001) match InstRec/deploy/feature_params.json.
  2. test_coo_rebuild_matches_librosa_dense
     The dense mel filterbank rebuilt from the quantized COO entries agrees
     with the direct librosa matrix element-wise within 1/8192 (i.e. the
     sparsification itself is lossless at the 1/8192 level).
  3. test_hann_table_first_mid_last_matches_librosa
     Hann table first/middle/last values match librosa within +/-1 LSB of
     the Q1.15 grid (the exact peak 1.0 saturates to 32767).
  4. test_repeat_run_sha256_deterministic
     Two full generator runs produce byte-identical outputs (file-level
     sha256 equality for both mel_tables.coe and mel_tables.json).
  5. test_lut_sizes_and_log2_boundaries
     LUT sizes are 256/512 and the log2 LUT boundaries are correct
     (entry 0 -> 0, entry 255 -> 255, i.e. log2(2) * 256 - 1).
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import librosa
import numpy as np

import gen_mel_tables as gmt

# Absolute location of the single source of truth for feature parameters.
FEATURE_PARAMS_PATH = gmt.DEFAULT_PARAMS_PATH

# The ten T-GP-02 items (REQ-FTR-001 also pins win_length/window, covered by
# the full EXPECTED_PARAMS comparison in the generator module).
REQ_FTR_001_TEN_ITEMS = (
    "sr", "n_fft", "hop_length", "n_mels", "n_frames",
    "f_min", "f_max", "power", "top_db", "normalization",
)


# ---------------------------------------------------------------------------
# DoD 1: parameter assertions against feature_params.json.
# ---------------------------------------------------------------------------
def test_feature_params_match_req_ftr_001():
    params = gmt.load_feature_params(FEATURE_PARAMS_PATH)
    gmt.assert_params_match_req(params)  # raises on any mismatch

    # Item-by-item check of the ten T-GP-02 fields against the JSON snapshot.
    with open(FEATURE_PARAMS_PATH, "r", encoding="utf-8") as fh:
        raw = json.load(fh)
    for key in REQ_FTR_001_TEN_ITEMS:
        assert raw[key] == gmt.EXPECTED_PARAMS[key], (
            f"feature_params.json '{key}' = {raw[key]!r}, "
            f"REQ-FTR-001 expects {gmt.EXPECTED_PARAMS[key]!r}"
        )
        assert params[key] == raw[key]

    # Extra REQ-FTR-001 items beyond the ten: window shape/type.
    assert raw["win_length"] == 2048
    assert raw["window"] == "hann"


# ---------------------------------------------------------------------------
# DoD 2: COO rebuild fidelity vs direct librosa computation.
# ---------------------------------------------------------------------------
def test_coo_rebuild_matches_librosa_dense():
    params = gmt.load_feature_params(FEATURE_PARAMS_PATH)
    dense = gmt.generate_mel_dense(params)
    coo = gmt.sparsify_mel_coo(dense)
    rebuilt = gmt.rebuild_dense_from_coo(coo)

    assert rebuilt.shape == dense.shape == (64, 1025)
    max_err = float(np.max(np.abs(rebuilt - dense)))
    assert max_err <= gmt.COO_WEIGHT_THRESHOLD, (
        f"max rebuild error {max_err:.3e} exceeds 1/8192 "
        f"({gmt.COO_WEIGHT_THRESHOLD:.3e})"
    )

    # Structural sanity of the offset header (channel-major segmentation).
    offsets = coo["offsets"]
    assert len(offsets) == gmt.COO_OFFSET_HEADER_LEN
    assert int(offsets[0]) == 0
    assert int(offsets[-1]) == coo["bin_idx"].size
    assert np.all(np.diff(offsets) >= 0)
    assert coo["bin_idx"].size <= gmt.COO_TABLE_CAPACITY
    assert int(coo["bin_idx"].max()) <= 1024  # 11-bit field headroom

    # Kept weights must survive quantization within 0.5 LSB (1/65536).
    channels, bins = coo["channels"], coo["bin_idx"]
    kept_float = dense[channels, bins]
    dequant = coo["weight_q15"].astype(np.float64) / gmt.Q15_SCALE
    assert np.max(np.abs(dequant - kept_float)) <= 1.0 / 65536.0


# ---------------------------------------------------------------------------
# DoD 3: Hann table first/middle/last values vs librosa.
# ---------------------------------------------------------------------------
def test_hann_table_first_mid_last_matches_librosa():
    n_fft = 2048
    table = gmt.generate_hann_table(n_fft)
    reference = librosa.filters.get_window("hann", n_fft, fftbins=True)

    assert table.shape == (n_fft,)
    assert table.dtype == np.int16

    # First / middle / last samples within +/-1 LSB of the Q1.15 grid.
    # The middle sample w[1024] == 1.0 exactly, quantizing to 32768 which
    # saturates to 32767, hence the 1-LSB tolerance.
    for idx in (0, n_fft // 2, n_fft - 1):
        ideal = float(reference[idx]) * gmt.Q15_SCALE
        assert abs(int(table[idx]) - ideal) <= 1.0, (
            f"hann[{idx}]: quantized {int(table[idx])} vs ideal {ideal}"
        )

    # Full-table quantization fidelity (every sample within 1 LSB).
    ideal_all = reference.astype(np.float64) * gmt.Q15_SCALE
    assert np.max(np.abs(table.astype(np.float64) - ideal_all)) <= 1.0


# ---------------------------------------------------------------------------
# DoD 4: deterministic re-run (sha256 bit-exact).
# ---------------------------------------------------------------------------
def test_repeat_run_sha256_deterministic(tmp_path):
    out_dir_1 = tmp_path / "run1"
    out_dir_2 = tmp_path / "run2"
    gmt.main(["--outdir", str(out_dir_1)])
    gmt.main(["--outdir", str(out_dir_2)])

    for name in ("mel_tables.coe", "mel_tables.json"):
        bytes_1 = (out_dir_1 / name).read_bytes()
        bytes_2 = (out_dir_2 / name).read_bytes()
        assert bytes_1 == bytes_2, f"{name} differs between repeated runs"
        digest_1 = hashlib.sha256(bytes_1).hexdigest()
        digest_2 = hashlib.sha256(bytes_2).hexdigest()
        assert digest_1 == digest_2

    # Per-table canonical sha256 must also match between the two runs.
    with open(out_dir_1 / "mel_tables.json", "r", encoding="ascii") as fh:
        tables_1 = json.load(fh)["tables"]
    with open(out_dir_2 / "mel_tables.json", "r", encoding="ascii") as fh:
        tables_2 = json.load(fh)["tables"]
    for table_name in ("hann_q15", "mel_coo", "log2_lut", "exp_lut"):
        assert tables_1[table_name]["sha256"] == tables_2[table_name]["sha256"]


# ---------------------------------------------------------------------------
# DoD 5: LUT sizes and log2 LUT boundary values.
# ---------------------------------------------------------------------------
def test_lut_sizes_and_log2_boundaries():
    log2_lut = gmt.generate_log2_lut()
    exp_lut = gmt.generate_exp_lut()

    assert log2_lut.size == 256
    assert exp_lut.size == 512

    # log2 LUT boundaries: entry 0 -> log2(1) == 0; entry 255 -> round of
    # log2(2 - 1/256) * 256 = 255.28 -> 255, i.e. log2(2) * 256 - 1.
    assert int(log2_lut[0]) == 0
    assert abs(int(log2_lut[255]) - 256) <= 1
    assert int(log2_lut[255]) == 255

    # Monotonicity and range of both LUTs.
    assert np.all(np.diff(log2_lut.astype(np.int64)) >= 0)
    assert int(log2_lut.max()) <= 255
    assert np.all(np.diff(exp_lut.astype(np.int64)) <= 0)  # exp decays
    assert 0 <= int(exp_lut.min()) and int(exp_lut.max()) <= gmt.UINT16_MAX
    # Entry 0 is the saturated full-scale value (exp(0) * 2^16 -> 65535).
    assert int(exp_lut[0]) == gmt.UINT16_MAX