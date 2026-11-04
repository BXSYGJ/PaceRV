"""Generate deterministic test audio fixtures for the golden pipeline tests.

Task: tasks.md T-GP-04 (three representative audio tracks).
Outputs (idempotent, byte-identical on re-run):

  tests/fixtures/silence_3s.wav        : all-zero PCM (digital silence)
  tests/fixtures/sine_440_full.wav     : full-scale 440 Hz sine
  tests/fixtures/sine_440_twolevel.wav : first half -12 dB, second half -3 dB
                                         (two loudness levels spliced)

All tracks: 44100 Hz, mono, 16-bit PCM, 132096 samples (= 258 x 512, the
hardware window length of design.md 2.2.6 / REQ-FTR-001).
"""

from __future__ import annotations

import wave
from pathlib import Path

import numpy as np

SR = 44100
N_SAMPLES = 132096          # 3 s hardware window (258 frames x 512 hop)
SINE_FREQ = 440.0
FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"

# Amplitude coefficients for the two-level splice track (dBFS -> linear).
LEVEL_LOW_DB = -12.0
LEVEL_HIGH_DB = -3.0
FULL_SCALE = 32767


def _pcm_silence() -> np.ndarray:
    """All-zero window (digital silence, REQ-FTR-005 degenerate path)."""
    return np.zeros(N_SAMPLES, dtype=np.int16)


def _pcm_sine_full() -> np.ndarray:
    """Full-scale 440 Hz sine (saturation-adjacent path, REQ-INF-007 kin)."""
    t = np.arange(N_SAMPLES, dtype=np.float64) / SR
    return np.round(np.sin(2.0 * np.pi * SINE_FREQ * t) * FULL_SCALE).astype(np.int16)


def _pcm_sine_two_level() -> np.ndarray:
    """440 Hz sine with a loudness step: -12 dBFS then -3 dBFS.

    Exercises the per-sample statistics over a window mixing two loudness
    levels (REQ-FTR-005 cross-window statistics acceptance kin).
    """
    t = np.arange(N_SAMPLES, dtype=np.float64) / SR
    amp = np.where(
        t < t[-1] / 2.0,
        10.0 ** (LEVEL_LOW_DB / 20.0),
        10.0 ** (LEVEL_HIGH_DB / 20.0),
    )
    return np.round(np.sin(2.0 * np.pi * SINE_FREQ * t) * amp * FULL_SCALE).astype(
        np.int16
    )


def _write_wav(path: Path, pcm: np.ndarray) -> None:
    """Write mono 16-bit PCM wav (deterministic bytes)."""
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(pcm.tobytes())


def ensure_fixtures() -> dict[str, Path]:
    """Generate the three fixture wavs if missing; return their paths."""
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    tracks = {
        "silence": (FIXTURES_DIR / "silence_3s.wav", _pcm_silence()),
        "sine_full": (FIXTURES_DIR / "sine_440_full.wav", _pcm_sine_full()),
        "sine_two_level": (
            FIXTURES_DIR / "sine_440_twolevel.wav",
            _pcm_sine_two_level(),
        ),
    }
    paths: dict[str, Path] = {}
    for name, (path, pcm) in tracks.items():
        if not path.exists():
            _write_wav(path, pcm)
        paths[name] = path
    return paths


def main() -> int:
    """Regenerate all fixtures unconditionally and report."""
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    for name, path in (
        ("silence", FIXTURES_DIR / "silence_3s.wav"),
        ("sine_full", FIXTURES_DIR / "sine_440_full.wav"),
        ("sine_two_level", FIXTURES_DIR / "sine_440_twolevel.wav"),
    ):
        pcm = {
            "silence": _pcm_silence,
            "sine_full": _pcm_sine_full,
            "sine_two_level": _pcm_sine_two_level,
        }[name]()
        _write_wav(path, pcm)
        print(f"[gen_test_audio] wrote {path} ({pcm.size} samples)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())