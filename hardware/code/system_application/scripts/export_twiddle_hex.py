#!/usr/bin/env python3
"""Export the FFT twiddle tables from the golden model to hex files.

Task: tasks.md T-M1-02 (fft2048_sdf RTL companion). The RTL twiddle ROMs
must be loaded with the SAME quantized table the golden pipeline uses
(golden_pipeline.make_twiddle_q15 is the single source of truth, per the
golden module header: "The RTL must implement the identical definition").

Outputs (all under src/mel/):
  * twiddle_q15.hex    : full half-spectrum table, 1024 words x 32 bit,
                         word k = {im_q15[15:0], re_q15[15:0]} (im high),
                         kept for reference / board-export verification.
  * twiddle_s{2..11}.hex : per-stage tables consumed by the RTL. Stage s
                         (golden fft_radix2_scaled, s = 2..11; the RTL
                         stage index k = s - 1) uses 2^(s-1) twiddles:
                         butterfly j (0-based) of stage s reads the full
                         table at index j * (2048 >> s). The per-stage
                         file stores them contiguously so the RTL ROM is
                         addressed directly by j (no runtime shifting):
                             file s, line j = word (j * (2048 >> s)).
                         Stage s = 1 (RTL k = 0) is omitted: its single
                         twiddle is W^0 = 1 and the RTL stage-0 butterfly
                         is a pure add/subtract (p = d exactly, proven in
                         the RTL header).

Format per file: one word per line, 8 lowercase hex digits, no address
column ($readmemh), deterministic across runs.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from golden_pipeline import N_FFT, make_twiddle_q15  # noqa: E402

OUT_DIR = SCRIPT_DIR.parent / "src" / "mel"


def words_from_table() -> np.ndarray:
    tw_re, tw_im = make_twiddle_q15(N_FFT)
    # Pack {im[15:0], re[15:0]}.  Both halves must be masked to 16 bits
    # FIRST: astype(uint32) sign-extends int16, so a negative tw_re would
    # otherwise OR 0xFFFF into the high (im) half and destroy it -- the
    # pre-T32 files had exactly that defect (511/1024 words, i.e. every
    # word with cos(j*w) < 0, carried im = 0xFFFF instead of the real
    # value), which broke every non-trivial butterfly of stages s >= 3.
    re_u = tw_re.astype(np.uint32) & np.uint32(0xFFFF)
    im_u = tw_im.astype(np.uint32) & np.uint32(0xFFFF)
    words = (im_u << np.uint32(16)) | re_u
    assert words.size == N_FFT // 2
    # Bit-identity anchors (must hold for the golden table by construction).
    assert np.int32(tw_re[0]) == 32767 and np.int32(tw_im[0]) == 0
    assert np.int32(tw_re[512]) == 0 and np.int32(tw_im[512]) == -32768
    # Field round-trip: the packed word must decode back to the table.
    assert np.all(words & 0xFFFF == re_u), "re field corrupted"
    assert np.all(words >> 16 == im_u), "im field corrupted"
    return words


def write_hex(path: Path, words: np.ndarray) -> str:
    lines = ["%08x" % int(w) for w in words]
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    words = words_from_table()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    report = []
    report.append((OUT_DIR / "twiddle_q15.hex", words, write_hex(OUT_DIR / "twiddle_q15.hex", words)))

    # Per-stage files: stage s = 2..11 (RTL stage k = s-1 = 1..10).
    n_stages = N_FFT.bit_length() - 1  # 11 for N_FFT = 2048
    for s in range(2, n_stages + 1):
        half = 1 << (s - 1)      # butterflies per stage block
        tw_step = N_FFT >> s     # golden twiddle index stride
        idx = np.arange(half, dtype=np.int64) * tw_step
        stage_words = words[idx]
        path = OUT_DIR / f"twiddle_s{s}.hex"
        report.append((path, stage_words, write_hex(path, stage_words)))

    for path, w, digest in report:
        print(f"wrote {path.name}: {w.size} words, sha256 = {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())