"""Unit tests for golden_pipeline.py Mel section (tasks.md T-GP-04 DoD).

DoD coverage:
  1. test_dod1_*  golden vs librosa per-sample normalized spectrum:
     max|delta| <= 0.05 AND Pearson r >= 0.999 (REQ-ACC-001 closed in the
     Python domain) on the three synthetic stress tracks (silence /
     full-scale sine / two-level loudness splice) plus every real
     instrument sample found under InstRec/data/demo/irmas_test/.
  2. test_dod2_silence_*  all-silent window: no NaN, no overflow wrap,
     amin/eps degenerate path produces the all-zero feature.
  3. test_dod3_first_last_frame_*  reflect-padded boundary frames agree
     with the reference (first / last spectrum columns separately,
     same tolerance as DoD item 1).
  4. test_dod4_stage_output_shapes  every --stage .npy output has the
     correct shape/dtype (log2spec/dbspec 64x258 int16, feat 64x258 int8,
     pcm 132096 int16, windowed 259x2048, fft 259x1025x2, power 259x1025).

The int8 quantization stage uses the REAL QuantStub contract from
scripts/outputs/layer_contract.json (T-GP-03/T-GP-05): quint8 uint8
domain [0, 255] with zp_in == 49, so the silent-window feature is
all-49 (the quantized-domain zero point).
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

import golden_pipeline as gp
from gen_test_audio import ensure_fixtures

# Real instrument samples (REQ-ACC-001 evidence set; skipped if absent).
REAL_AUDIO_DIR = (
    Path(__file__).resolve().parents[3] / "InstRec" / "data" / "demo" / "irmas_test"
)

ACC_MAX_ABS_DELTA = 0.05      # REQ-ACC-001 tolerance (normalized z domain)
ACC_PEARSON_R = 0.999         # REQ-ACC-001 correlation floor

SYNTHETIC_NAMES = ("silence_3s", "sine_440_full", "sine_440_twolevel")


@pytest.fixture(scope="module")
def mel_tables():
    """Coefficient tables (same mel_tables.json the RTL consumes)."""
    return gp.load_mel_tables()


@pytest.fixture(scope="module")
def synth_fixtures():
    """The three deterministic synthetic wav fixtures."""
    return ensure_fixtures()


def _run_pair(tables, wav_path: Path) -> dict:
    """Run golden + librosa on one wav; cache-friendly helper."""
    pcm = gp.load_pcm_s16(wav_path)
    result = gp.run_mel_pipeline(pcm, tables)
    ref = gp.librosa_reference(pcm)
    metrics = gp.compare_to_reference(result["z"], ref)
    return {"pcm": pcm, "result": result, "ref": ref, "metrics": metrics}


@pytest.fixture(scope="module")
def synth_results(mel_tables, synth_fixtures):
    """Golden + reference results for the three synthetic tracks."""
    return {p.stem: _run_pair(mel_tables, p) for p in synth_fixtures.values()}


def _real_wavs() -> list[Path]:
    if not REAL_AUDIO_DIR.is_dir():
        return []
    return sorted(REAL_AUDIO_DIR.glob("*.wav"))


@pytest.fixture(scope="module")
def real_results(mel_tables):
    """Golden + reference results for the real instrument samples."""
    return {p.stem: _run_pair(mel_tables, p) for p in _real_wavs()}


# ---------------------------------------------------------------------------
# DoD 1: REQ-ACC-001 metrics versus librosa (Python-domain closure).
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("name", SYNTHETIC_NAMES)
def test_dod1_acc_metrics_synthetic(synth_results, name):
    m = synth_results[name]["metrics"]
    assert m["max_abs_delta"] <= ACC_MAX_ABS_DELTA, (
        f"{name}: max|delta| {m['max_abs_delta']:.4f} > {ACC_MAX_ABS_DELTA}"
    )
    assert m["pearson_r"] >= ACC_PEARSON_R, (
        f"{name}: pearson r {m['pearson_r']:.6f} < {ACC_PEARSON_R}"
    )


@pytest.mark.parametrize("stem", [p.stem for p in _real_wavs()])
def test_dod1_acc_metrics_real(real_results, stem):
    m = real_results[stem]["metrics"]
    assert m["max_abs_delta"] <= ACC_MAX_ABS_DELTA, (
        f"{stem}: max|delta| {m['max_abs_delta']:.4f} > {ACC_MAX_ABS_DELTA}"
    )
    assert m["pearson_r"] >= ACC_PEARSON_R, (
        f"{stem}: pearson r {m['pearson_r']:.6f} < {ACC_PEARSON_R}"
    )


# ---------------------------------------------------------------------------
# DoD 2: all-silent window robustness (amin/eps degenerate path).
# ---------------------------------------------------------------------------
def test_dod2_silence_no_nan_no_overflow(synth_results):
    res = synth_results["silence_3s"]["result"]

    # All-silent windows degenerate to identical log2(0) values everywhere,
    # so the dB stage collapses to all-zero (max == the same value) and the
    # standardized z / int8 feature are exactly the quantized-domain zero.
    # Since T-GP-05 the feat stage uses the REAL QuantStub contract
    # (layer_contract.json: quint8, zp_in == 49), so the silent feature is
    # all-49, not all-0 (placeholder-era assertion updated accordingly).
    assert np.all(res["dbspec"] == 0), "silent window dB must be all zero"
    assert np.all(res["z"] == 0), "silent window z must be all zero"
    assert np.all(res["feat"] == 49), (
        "silent window uint8 feature must equal the quint8 zero point 49"
    )

    # Integer pipelines cannot produce NaN, but assert finiteness and the
    # in-range property of every intermediate stage anyway (overflow watch).
    assert np.all(np.abs(res["log2spec"].astype(np.int64)) <= 32767)
    assert res["z"].dtype == np.int16 and np.all(np.abs(res["z"]) <= 32767)
    assert res["feat"].dtype == np.uint8
    assert np.all(res["feat"] >= 0) and np.all(res["feat"] <= 255)
    # Reference side must also be finite (eps path, sigma == 0 -> 0/eps).
    ref = synth_results["silence_3s"]["ref"]
    assert np.all(np.isfinite(ref)), "librosa reference must be finite"
    assert np.allclose(ref, 0.0, atol=1e-6), (
        "librosa silent-window reference must be all zero (eps path)"
    )


# ---------------------------------------------------------------------------
# DoD 3: first / last frame boundary agreement (reflect padding).
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("name", SYNTHETIC_NAMES[1:])  # silence has no content
def test_dod3_first_last_frame_boundary_synthetic(synth_results, name):
    res = synth_results[name]
    golden = res["result"]["z"].astype(np.float64) / 4096.0
    ref = res["ref"].astype(np.float64)
    for col, tag in ((0, "first"), (-1, "last")):
        delta = float(np.max(np.abs(golden[:, col] - ref[:, col])))
        assert delta <= ACC_MAX_ABS_DELTA, (
            f"{name} {tag} frame: max|delta| {delta:.4f} > {ACC_MAX_ABS_DELTA}"
        )


@pytest.mark.parametrize("stem", [p.stem for p in _real_wavs()])
def test_dod3_first_last_frame_boundary_real(real_results, stem):
    res = real_results[stem]
    golden = res["result"]["z"].astype(np.float64) / 4096.0
    ref = res["ref"].astype(np.float64)
    for col, tag in ((0, "first"), (-1, "last")):
        delta = float(np.max(np.abs(golden[:, col] - ref[:, col])))
        assert delta <= ACC_MAX_ABS_DELTA, (
            f"{stem} {tag} frame: max|delta| {delta:.4f} > {ACC_MAX_ABS_DELTA}"
        )


# ---------------------------------------------------------------------------
# DoD 4: --stage .npy output shapes and dtypes (CLI end-to-end).
# ---------------------------------------------------------------------------
def test_dod4_stage_output_shapes(tmp_path, synth_fixtures):
    wav = synth_fixtures["sine_full"]
    outdir = tmp_path / "golden"
    cmd = [
        sys.executable,
        str(Path(__file__).resolve().parents[1] / "scripts" / "golden_pipeline.py"),
        "--wav", str(wav),
        "--stage", ",".join(gp.ALL_STAGES),
        "--outdir", str(outdir),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    assert proc.returncode == 0, f"CLI failed:\n{proc.stderr[-2000:]}"

    stem = wav.stem
    expected = {
        "pcm": ((132096,), np.int16),
        "windowed": ((259, 2048), np.int32),
        "fft": ((259, 1025, 2), np.int32),
        "power": ((259, 1025), np.int64),
        "log2spec": ((64, 258), np.int16),
        "dbspec": ((64, 258), np.int16),
        # feat carries the REAL QuantStub contract since T-GP-05: uint8
        # quint8 domain in [0, 255] (zp_in == 49), not the placeholder
        # signed-int8 domain.
        "feat": ((64, 258), np.uint8),
    }
    for stage, (shape, dtype) in expected.items():
        path = outdir / f"{stem}_{stage}.npy"
        assert path.exists(), f"missing stage output {path.name}"
        arr = np.load(path)
        assert arr.shape == shape, f"{stage}: shape {arr.shape} != {shape}"
        assert arr.dtype == dtype, f"{stage}: dtype {arr.dtype} != {dtype}"

    # Value-range sanity: feat is a saturated uint8 quint8 quantization
    # (real layer-contract parameters; value range only, per task).
    feat = np.load(outdir / f"{stem}_feat.npy")
    assert feat.min() >= 0 and feat.max() <= 255
    # dB spectrum respects the top_db floor and the zero ceiling (Q8.8).
    db = np.load(outdir / f"{stem}_dbspec.npy").astype(np.int64)
    assert db.min() >= -20480 and db.max() <= 0