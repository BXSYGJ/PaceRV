"""Generate fixed-point Mel coefficient tables for the InstRec-FPGA engine.

Task: tasks.md T-GP-02 (Mel feature coefficient table generator).
Reference: design.md sections 3.3 (log2 LUT), 3.4 (Mel filterbank COO storage),
           4.5 (fixed-point softmax exp LUT); spec.md REQ-FTR-001 (parameters).

Generated tables (all quantized with round-half-up, deterministic bit-exact):

1. hann_q15    : 2048 entries, int16 Q1.15 periodic Hann window.
                 Source: librosa.filters.get_window("hann", 2048, fftbins=True)
                 (equivalent to np.hanning(2049)[:-1]).
                 The exact peak w[1024] == 1.0 quantizes to 32768 which overflows
                 int16, so it saturates to 32767 (1 LSB, within the +/-1 LSB
                 acceptance of DoD item 3).

2. mel_coo     : sparse COO form of the 64x1025 slaney-normalized mel
                 filterbank (librosa.filters.mel, htk=False, norm="slaney").
                 Entries whose Q1.15 weight survives quantization
                 (weight >= 1/65536) are kept; the design.md 3.4 threshold
                 of 1/8192 was widened after real-audio regression showed a
                 dropped 0.0001-weight entry carrying 65% of its channel
                 power (small weight does not imply small contribution).
                 Each entry: {mel_ch s6, bin_idx s11, weight int16 Q1.15}.
                 Stored channel-major (channel, bin ascending), delimited
                 by a 65-entry offset header (offsets[64] == entry count).
                 ROM capacity is 4096 entries x 27 bit (design.md 3.4).

3. log2_lut    : 256 entries, uint8 Q0.8 mantissa table covering [1, 2).
                 Entry i = round(log2(1 + i/256) * 256). Consumed by the RTL
                 log2 composition log2(x) = e + lut[man_hi8(x)] (design.md 3.3).

4. exp_lut     : 512 entries, uint16 Q0.16 softmax exponential table
                 (design.md 4.5). Input domain: Q6.9 difference d = logit - max
                 with d in [-16, 0] (logit dynamics +/-2^20 shifted right by 5).
                 Index i covers d = -i/32 (uniform step 1/32 = 16 Q6.9 LSBs).
                 Entry value = min(round(exp(-i/32) * 2^16), 65535); entry 0
                 (d == 0, exp == 1.0) saturates 1 LSB below full scale, which
                 shifts softmax probabilities by ~1.5e-5 (far below the
                 REQ-ACC-003 tolerance of 0.02).

Outputs (idempotent, no timestamps -> byte-identical on re-run):
  scripts/outputs/mel_tables.coe   RTL-readable $readmemh image (per-table
                                   sections with comment headers).
  scripts/outputs/mel_tables.json  Structured snapshot (params + table data +
                                   per-table sha256 over canonical bytes).

Usage:
  python scripts/gen_mel_tables.py [--params <feature_params.json>]
                                   [--outdir <dir>]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import librosa
import numpy as np

# ---------------------------------------------------------------------------
# Constants (REQ-FTR-001 expected values, cross-checked against
# InstRec/deploy/feature_params.json on every run).
# ---------------------------------------------------------------------------
EXPECTED_PARAMS = {
    "sr": 44100,
    "n_fft": 2048,
    "hop_length": 512,
    "win_length": 2048,
    "window": "hann",
    "n_mels": 64,
    "n_frames": 258,
    "f_min": 0.0,
    "f_max": 22050.0,
    "power": 2.0,
    "top_db": 80.0,
    "normalization": "per_sample",
}

# Fixed-point formats.
Q15_SCALE = 32768          # Q1.15 (signed 16-bit) scale factor
INT16_MIN = -32768
INT16_MAX = 32767
UINT16_MAX = 65535

# Mel COO sparsification (design.md 3.4; threshold deviation recorded in
# the module docstring and the delivery report: the design.md 1/8192 cut
# drops small-weight entries that can still carry large-power bins -- on
# real instrument audio a 0.0001-weight bin held 65% of its channel power
# and broke REQ-ACC-001. Keeping every entry whose Q1.15 weight survives
# quantization (w >= 1/65536) makes the sparsification itself lossless;
# entry count stays far below the 4096-entry ROM capacity).
COO_WEIGHT_THRESHOLD = 1.0 / 65536.0    # keep entries with weight >= 1/2^16
COO_TABLE_CAPACITY = 4096             # ROM depth x 27 bit per design.md 3.4
COO_OFFSET_HEADER_LEN = 65            # 64 channels + 1 terminator

# LUT sizes.
LOG2_LUT_N = 256                      # design.md 3.3 (mantissa [1,2), Q0.8)
EXP_LUT_N = 512                       # design.md 4.5 (Q6.9 diff domain)
EXP_LUT_DOMAIN_SPAN = 16.0            # Q6.9 input domain [-16, 0]
EXP_LUT_STEP = EXP_LUT_DOMAIN_SPAN / EXP_LUT_N   # 1/32 per entry

# Default IO locations (repo layout: <pango>/ZGTC_RISC_CPU/instrec_fpga/scripts).
DEFAULT_PARAMS_PATH = (
    Path(__file__).resolve().parents[3] / "InstRec" / "deploy" / "feature_params.json"
)
DEFAULT_OUT_DIR = Path(__file__).resolve().parent / "outputs"

GENERATOR_NAME = "gen_mel_tables.py"
SPEC_REFS = "tasks.md T-GP-02; design.md 3.3/3.4/4.5; spec.md REQ-FTR-001"


# ---------------------------------------------------------------------------
# Parameter loading and REQ-FTR-001 assertion.
# ---------------------------------------------------------------------------
def load_feature_params(params_path: Path) -> dict:
    """Load the feature parameter snapshot (single source of truth)."""
    with open(params_path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def assert_params_match_req(params: dict) -> None:
    """Assert every REQ-FTR-001 item against the parameter snapshot.

    Covers the ten T-GP-02 items (sr, n_fft, hop_length, n_mels, n_frames,
    f_min, f_max, power, top_db, normalization) plus win_length and window,
    which REQ-FTR-001 also pins (win=2048, Hann window).
    """
    for key, expected in EXPECTED_PARAMS.items():
        actual = params.get(key)
        if actual != expected or type(actual) is not type(expected):
            raise AssertionError(
                f"REQ-FTR-001 param mismatch for '{key}': "
                f"feature_params.json has {actual!r}, expected {expected!r}"
            )


# ---------------------------------------------------------------------------
# Quantization helpers.
# ---------------------------------------------------------------------------
def quantize_round_half_up(values: np.ndarray, lo: int, hi: int) -> np.ndarray:
    """Quantize floats to integers with round-half-up, then saturate.

    Round-half-up is implemented as floor(x + 0.5) so ties resolve towards
    +infinity, matching the RTL semantics used throughout design.md 3.1.
    """
    scaled = np.floor(values.astype(np.float64) + 0.5).astype(np.int64)
    scaled = np.clip(scaled, lo, hi)
    return scaled


def _sha256_hex(data: bytes) -> str:
    """Return the lowercase sha256 hex digest of a byte string."""
    return hashlib.sha256(data).hexdigest()


def _int16_le_bytes(values: np.ndarray) -> bytes:
    """Pack a signed 16-bit array into little-endian canonical bytes."""
    return np.asarray(values, dtype=np.int16).tobytes()


def _uint16_le_bytes(values: np.ndarray) -> bytes:
    """Pack an unsigned 16-bit array into little-endian canonical bytes."""
    return np.asarray(values, dtype=np.uint16).tobytes()


def _uint8_bytes(values: np.ndarray) -> bytes:
    """Pack an unsigned 8-bit array into canonical bytes."""
    return np.asarray(values, dtype=np.uint8).tobytes()


# ---------------------------------------------------------------------------
# Table generators.
# ---------------------------------------------------------------------------
def generate_hann_table(n_fft: int) -> np.ndarray:
    """Generate the periodic Hann window table as int16 Q1.15.

    librosa get_window(..., fftbins=True) yields the periodic Hann (identical
    to np.hanning(n_fft + 1)[:-1]), matching the training-side STFT.
    """
    window = librosa.filters.get_window("hann", n_fft, fftbins=True)
    quantized = quantize_round_half_up(
        window.astype(np.float64) * Q15_SCALE, INT16_MIN, INT16_MAX
    )
    return quantized.astype(np.int16)


def generate_mel_dense(params: dict) -> np.ndarray:
    """Generate the dense 64x1025 slaney mel filterbank (float64)."""
    dense = librosa.filters.mel(
        sr=int(params["sr"]),
        n_fft=int(params["n_fft"]),
        n_mels=int(params["n_mels"]),
        fmin=float(params["f_min"]),
        fmax=float(params["f_max"]),
        htk=False,
        norm="slaney",
    )
    return dense.astype(np.float64)


def sparsify_mel_coo(dense: np.ndarray) -> dict:
    """Extract the COO sparse form of the dense mel filterbank.

    Keeps entries whose quantized weight is non-zero (weight >= 1/65536;
    see COO_WEIGHT_THRESHOLD for why the design.md 3.4 1/8192 cut was
    widened) and quantizes each weight to int16 Q1.15. Entries are emitted
    channel-major (channel index ascending, then bin index ascending) so
    the 65-entry offset header fully delimits each channel segment.
    """
    n_mels, n_bins = dense.shape
    keep_mask = dense >= COO_WEIGHT_THRESHOLD
    channels, bins = np.nonzero(keep_mask)  # C order: channel asc, bin asc

    weights_q15 = quantize_round_half_up(
        dense[channels, bins] * Q15_SCALE, INT16_MIN, INT16_MAX
    ).astype(np.int16)

    counts = np.bincount(channels, minlength=n_mels)
    offsets = np.concatenate(([0], np.cumsum(counts))).astype(np.int64)

    n_entries = int(offsets[-1])
    if n_entries > COO_TABLE_CAPACITY:
        raise AssertionError(
            f"COO entry count {n_entries} exceeds ROM capacity {COO_TABLE_CAPACITY}"
        )
    bin_limit = 1 << 11  # bin_idx is an 11-bit field
    if bins.size and int(bins.max()) >= bin_limit:
        raise AssertionError(
            f"bin_idx {int(bins.max())} exceeds the 11-bit field range"
        )

    return {
        "n_mels": n_mels,
        "n_bins": n_bins,
        "offsets": offsets,
        "channels": channels.astype(np.int16),
        "bin_idx": bins.astype(np.int16),
        "weight_q15": weights_q15,
    }


def rebuild_dense_from_coo(coo: dict) -> np.ndarray:
    """Rebuild the dense float64 filterbank from quantized COO entries.

    Used for the sparsification fidelity check: dropped entries contribute
    zero and kept entries contribute their dequantized Q1.15 value, so the
    per-element error is bounded by max(threshold, 0.5 LSB) = 1/65536
    (stronger than the 1/8192 requirement of the T-GP-02 DoD item 2).
    """
    dense = np.zeros((coo["n_mels"], coo["n_bins"]), dtype=np.float64)
    offsets = coo["offsets"]
    bins = coo["bin_idx"]
    weights = coo["weight_q15"].astype(np.float64) / Q15_SCALE
    for ch in range(coo["n_mels"]):
        lo = int(offsets[ch])
        hi = int(offsets[ch + 1])
        dense[ch, bins[lo:hi]] += weights[lo:hi]
    return dense


def generate_log2_lut() -> np.ndarray:
    """Generate the 256-entry Q0.8 log2 mantissa table (design.md 3.3).

    Entry i = round(log2(1 + i/256) * 256) for the mantissa interval
    [1, 2); the RTL composes log2(x) = (e - 56) + lut[man_hi8(x)] / 256.
    """
    idx = np.arange(LOG2_LUT_N, dtype=np.float64)
    vals = np.log2(1.0 + idx / 256.0) * 256.0
    return quantize_round_half_up(vals, 0, 255).astype(np.uint8)


def generate_exp_lut() -> np.ndarray:
    """Generate the 512-entry Q0.16 softmax exp table (design.md 4.5).

    Input domain: Q6.9 difference d = logit - max_logit, d in [-16, 0]
    (logit dynamic range +/-2^20 scaled down by 2^5). The 512 entries sample
    the domain uniformly: index i covers d = -i/32. Entry value is
    round(exp(d) * 2^16) in an unsigned Q0.16 container; entry 0 saturates
    to 65535 because exp(0) * 2^16 == 2^16 overflows the 16-bit container.
    """
    idx = np.arange(EXP_LUT_N, dtype=np.float64)
    vals = np.exp(-idx * EXP_LUT_STEP) * 65536.0
    quantized = quantize_round_half_up(vals, 0, UINT16_MAX)
    return quantized.astype(np.uint16)


# ---------------------------------------------------------------------------
# Table bundle assembly and self-checks.
# ---------------------------------------------------------------------------
def build_tables(params: dict) -> dict:
    """Build all tables and run generation-time self-checks.

    Self-checks:
      * COO rebuild error vs the librosa dense matrix is <= 1/8192
        (sparsification must be lossless at the 1/8192 level).
      * COO entry count fits the 4096-entry ROM capacity.
    """
    hann = generate_hann_table(int(params["n_fft"]))
    dense_mel = generate_mel_dense(params)
    coo = sparsify_mel_coo(dense_mel)
    log2_lut = generate_log2_lut()
    exp_lut = generate_exp_lut()

    rebuilt = rebuild_dense_from_coo(coo)
    rebuild_err = float(np.max(np.abs(rebuilt - dense_mel)))
    if rebuild_err > COO_WEIGHT_THRESHOLD:
        raise AssertionError(
            f"COO rebuild error {rebuild_err:.3e} exceeds 1/8192 "
            f"({COO_WEIGHT_THRESHOLD:.3e})"
        )

    # COO canonical bytes: (bin_idx, weight) interleaved as int16 LE pairs.
    n_entries = int(coo["offsets"][-1])

    packed = np.empty(2 * n_entries, dtype=np.int16)
    packed[0::2] = coo["bin_idx"]
    packed[1::2] = coo["weight_q15"]
    coo_bytes = _int16_le_bytes(packed)

    tables = {
        "hann_q15": {
            "n": int(hann.size),
            "format": "int16 Q1.15 (round-half-up, saturated)",
            "source": 'librosa.filters.get_window("hann", 2048, fftbins=True)',
            "canonical_bytes": "int16 little-endian x n",
            "data": [int(v) for v in hann],
            "sha256": _sha256_hex(_int16_le_bytes(hann)),
        },
        "mel_coo": {
            "n_entries": n_entries,
            "capacity": COO_TABLE_CAPACITY,
            "entry_format": "{mel_ch s6, bin_idx s11, weight int16 Q1.15}",
            "offset_header": f"{COO_OFFSET_HEADER_LEN} entries (channel starts)",
            "drop_threshold": COO_WEIGHT_THRESHOLD,
            "source": (
                "librosa.filters.mel(sr=44100, n_fft=2048, n_mels=64, "
                "fmin=0, fmax=22050, htk=False, norm='slaney')"
            ),
            "canonical_bytes": "(bin_idx, weight) int16 LE pairs x n_entries",
            "offsets": [int(v) for v in coo["offsets"]],
            "channels": [int(v) for v in coo["channels"]],
            "bin_idx": [int(v) for v in coo["bin_idx"]],
            "weight_q15": [int(v) for v in coo["weight_q15"]],
            "sha256": _sha256_hex(coo_bytes),
            "stats": {
                "n_dense_nonzero": int(np.count_nonzero(dense_mel)),
                "n_kept": n_entries,
                "n_dropped": int(np.count_nonzero(dense_mel)) - n_entries,
                "per_channel_min": int(np.bincount(
                    coo["channels"], minlength=int(params["n_mels"])
                ).min()),
                "per_channel_max": int(np.bincount(
                    coo["channels"], minlength=int(params["n_mels"])
                ).max()),
                "dense_max": round(float(dense_mel.max()), 12),
                "max_rebuild_error": round(rebuild_err, 15),
            },
        },
        "log2_lut": {
            "n": LOG2_LUT_N,
            "format": "uint8 Q0.8 (unsigned semantics, values 0..255)",
            "domain": "log2 mantissa [1, 2); entry i = round(log2(1+i/256)*256)",
            "canonical_bytes": "uint8 x n",
            "data": [int(v) for v in log2_lut],
            "sha256": _sha256_hex(_uint8_bytes(log2_lut)),
        },
        "exp_lut": {
            "n": EXP_LUT_N,
            "format": "uint16 Q0.16 (unsigned container; entry 0 saturates 65535)",
            "domain": (
                "Q6.9 softmax difference d in [-16, 0]; index i covers "
                "d = -i/32 (step 1/32 = 16 Q6.9 LSBs)"
            ),
            "entry_formula": "value_i = min(round(exp(-i/32) * 2^16), 65535)",
            "canonical_bytes": "uint16 little-endian x n",
            "data": [int(v) for v in exp_lut],
            "sha256": _sha256_hex(_uint16_le_bytes(exp_lut)),
        },
    }
    return tables


# ---------------------------------------------------------------------------
# Output writers.
# ---------------------------------------------------------------------------
def _hex_word(value: int, bit_width: int) -> str:
    """Format an integer as a fixed-width hex word for $readmemh."""
    mask = (1 << bit_width) - 1
    return f"{value & mask:0{bit_width // 4}X}"


def write_coe(path: Path, tables: dict, params: dict) -> None:
    """Write the RTL-readable .coe image with per-table sections.

    Section order: hann_q15, mel_coo_offsets, mel_coo_entries (padded to the
    4096-entry ROM capacity), log2_lut, exp_lut. All words are hex with fixed
    width so $readmemh can load them into matching ROM declarations.
    """
    lines: list[str] = []
    lines.append("// ===================================================================")
    lines.append("// InstRec-FPGA Mel coefficient tables (auto-generated, do not edit)")
    lines.append(f"// generator : {GENERATOR_NAME}")
    lines.append(f"// spec refs : {SPEC_REFS}")
    lines.append("// source    : InstRec/deploy/feature_params.json")
    lines.append(f"//   sr={params['sr']} n_fft={params['n_fft']} hop={params['hop_length']}"
                 f" n_mels={params['n_mels']} n_frames={params['n_frames']}")
    lines.append(f"//   f_min={params['f_min']} f_max={params['f_max']}"
                 f" power={params['power']} top_db={params['top_db']}"
                 f" norm={params['normalization']}")
    lines.append("// determinism: byte-identical on re-run (no timestamps)")
    lines.append("// table sha256 (canonical bytes):")
    for name in ("hann_q15", "mel_coo", "log2_lut", "exp_lut"):
        lines.append(f"//   {name:<10}: {tables[name]['sha256']}")
    lines.append("// ===================================================================")
    lines.append("")

    # --- hann_q15 -------------------------------------------------------
    hann = tables["hann_q15"]
    lines.append(f"// ---- table hann_q15 : {hann['n']} entries, 16-bit signed Q1.15 ----")
    lines.append("// periodic Hann (librosa get_window('hann', 2048, fftbins=True)),")
    lines.append("// round-half-up quantized; peak saturates to 0x7FFF (1 LSB)")
    for value in hann["data"]:
        lines.append(_hex_word(value, 16))
    lines.append("")

    # --- mel_coo_offsets ------------------------------------------------
    coo = tables["mel_coo"]
    lines.append(f"// ---- table mel_coo_offsets : {COO_OFFSET_HEADER_LEN} entries,")
    lines.append("//      16-bit container (13-bit effective), channel start offsets ----")
    lines.append(f"//      offsets[64] = {coo['n_entries']} = total COO entry count")
    for value in coo["offsets"]:
        lines.append(_hex_word(value, 16))
    lines.append("")

    # --- mel_coo_entries ------------------------------------------------
    lines.append(f"// ---- table mel_coo_entries : {coo['n_entries']} entries used of")
    lines.append(f"//      {coo['capacity']}-entry capacity, 27-bit word")
    lines.append("//      {bin_idx[26:16] (11 bit), weight[15:0] (signed Q1.15)} ----")
    lines.append(f"//      keep threshold: weight > {COO_WEIGHT_THRESHOLD:.10f} (1/8192)")
    pad_count = coo["capacity"] - coo["n_entries"]
    for bin_idx, weight in zip(coo["bin_idx"], coo["weight_q15"]):
        word = (int(bin_idx) << 16) | (int(weight) & 0xFFFF)
        lines.append(_hex_word(word, 27))
    for _ in range(pad_count):
        lines.append(_hex_word(0, 27))
    lines.append("")

    # --- log2_lut -------------------------------------------------------
    log2_lut = tables["log2_lut"]
    lines.append(f"// ---- table log2_lut : {log2_lut['n']} entries, 8-bit unsigned Q0.8 ----")
    lines.append("//      entry i = round(log2(1 + i/256) * 256); mantissa domain [1,2)")
    for value in log2_lut["data"]:
        lines.append(_hex_word(value, 8))
    lines.append("")

    # --- exp_lut --------------------------------------------------------
    exp_lut = tables["exp_lut"]
    lines.append(f"// ---- table exp_lut : {exp_lut['n']} entries, 16-bit Q0.16 ----")
    lines.append("//      softmax exp table; Q6.9 diff domain [-16, 0],")
    lines.append("//      index i covers d = -i/32; entry 0 saturates to 65535")
    for value in exp_lut["data"]:
        lines.append(_hex_word(value, 16))
    lines.append("")

    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write("\n".join(lines))


def write_json(path: Path, tables: dict, params: dict) -> None:
    """Write the structured JSON snapshot (params + tables + sha256)."""
    payload = {
        "generator": GENERATOR_NAME,
        "spec_refs": SPEC_REFS,
        "params": params,
        "param_assertions": {
            "expected": EXPECTED_PARAMS,
            "checked_items": len(EXPECTED_PARAMS),
            "status": "pass",
        },
        "tables": tables,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=True)
        fh.write("\n")


# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    """Generate all tables and write the .coe/.json outputs."""
    parser = argparse.ArgumentParser(
        description="Generate InstRec-FPGA Mel coefficient tables."
    )
    parser.add_argument(
        "--params",
        type=Path,
        default=DEFAULT_PARAMS_PATH,
        help="path to InstRec/deploy/feature_params.json",
    )
    parser.add_argument(
        "--outdir",
        type=Path,
        default=DEFAULT_OUT_DIR,
        help="output directory (default: scripts/outputs)",
    )
    args = parser.parse_args(argv)

    params = load_feature_params(args.params)
    assert_params_match_req(params)

    tables = build_tables(params)

    coe_path = args.outdir / "mel_tables.coe"
    json_path = args.outdir / "mel_tables.json"
    write_coe(coe_path, tables, params)
    write_json(json_path, tables, params)

    coo = tables["mel_coo"]
    print(f"[gen_mel_tables] params OK ({len(EXPECTED_PARAMS)} REQ-FTR-001 items)")
    print(f"[gen_mel_tables] hann_q15   : {tables['hann_q15']['n']} entries")
    print(
        f"[gen_mel_tables] mel_coo    : {coo['n_entries']} entries "
        f"(dense nonzero {coo['stats']['n_dense_nonzero']}, "
        f"dropped {coo['stats']['n_dropped']}, capacity {coo['capacity']})"
    )
    print(f"[gen_mel_tables] log2_lut   : {tables['log2_lut']['n']} entries")
    print(f"[gen_mel_tables] exp_lut    : {tables['exp_lut']['n']} entries")
    for name in ("hann_q15", "mel_coo", "log2_lut", "exp_lut"):
        print(f"[gen_mel_tables] sha256 {name:<10}: {tables[name]['sha256']}")
    print(f"[gen_mel_tables] wrote {coe_path}")
    print(f"[gen_mel_tables] wrote {json_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())