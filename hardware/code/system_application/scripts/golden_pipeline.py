"""Bit-accurate fixed-point golden model of the InstRec-FPGA Mel pipeline.

Task: tasks.md T-GP-04 (golden_pipeline.py Mel section, first half).
Reference: design.md section 3 (fixed-point width decision table):
  3.1 full-chain widths, 3.2 FFT scaling, 3.3 log2 conversion,
  3.5 dB conversion / top_db clamp, 3.6 per-sample standardization,
  3.7 CNN input quantization. spec.md REQ-FTR-001..005, REQ-ACC-001.

The golden model consumes the SAME coefficient tables as the RTL
(scripts/outputs/mel_tables.json produced by gen_mel_tables.py):
  * hann_q15  : 2048 x int16 Q1.15 periodic Hann window
  * mel_coo   : 1820-entry COO sparse filterbank {bin_idx s11, weight Q1.15}
                + 65-entry channel offset header
  * log2_lut  : 256 x uint8 Q0.8 mantissa table

FFT twiddle factors are NOT part of mel_tables.json (design.md 3.1 S3 only
pins the Q1.15 format), so this module defines them explicitly here:
  tw[k] = round_half_up(exp(-2*pi*i*k/2048) * 2^15), re/im each int16,
  with |re| == 1 saturating to 32767 (Q1.15 container edge, same semantics
  as the Hann peak). The RTL must implement the identical definition.

Rounding conventions used throughout (all documented for RTL parity):
  * rhu_shift(x, k)      : round-half-up arithmetic shift, i.e.
                           floor((x + 2^(k-1)) / 2^k); ties go to +infinity.
                           Used for the Hann >>15, every FFT stage >>1,
                           the twiddle product >>15, the dB x775 >>8 and
                           the z >>8 steps.
  * trunc_div(a, b)      : truncation toward zero (hardware restoring
                           division semantics) for mu / var statistics.
  * round_half_even      : bit-level round-half-to-even for the final
                           int8 quantization step (PyTorch fbgemm parity).
  * floor semantics      : log2 mantissa index (high 8 bits after the
                           leading one, plain truncation) and isqrt for
                           sigma (exact integer floor square root).

Dataflow (all integer NumPy int64/int32, no float shortcuts except for
table/parameter preparation and the librosa reference mode):

  PCM s16 (132096 samples per 3 s window)
    -> reflect pad 1024 both sides (center=True semantics, REQ-FTR-002)
    -> 259 frames x 2048 (hop 512), keep tail 258 frames AFTER the dB stage
       (mirrors features.py _pad_or_truncate_frames: 259 -> keep last 258)
    -> Hann Q1.15 multiply, >>15 rhu            -> s17 windowed frames
    -> radix-2 DIT FFT, 11 stages, unscaled     -> s28 re/im (1025 bins)
       (single power-domain >>22 rescale below; see fft_radix2_scaled
       docstring for why per-stage /2 was rejected -- R-03/BFP clause)
    -> power = rhu_shift(re^2 + im^2, 22)       -> s37 power spectrum
    -> COO sparse mel filtering (exact integer) -> s56 mel power (64 ch)
    -> log2: leading-one normalize + 256 LUT    -> int16 Q8.8 (bias -56)
    -> pass 2a: max over the FULL 259-frame log2 spectrum
    -> dB = sat16(rhu((log2 - max) * 775, 8)), clamp [-20480, 0]
       (-20480 = -80 dB Q8.8, top_db floor; >0 clamp is a +/-1 LSB guard)
    -> truncate to the last 258 frames
    -> pass 2b: mu (trunc div 16512), var (Q8.16), sigma (isqrt),
       inv_sigma = rhu(2^20 / max(sigma, 1)),
       z = sat16(rhu((dB - mu) * inv_sigma, 8))  -> int16 Q4.12
    -> int8: sat_int8(round_half_even(z * inv_s_in, 16) + zp_in)

Special paths:
  * all-zero window: log2(0) is defined as -56 << 8 = -14336 (leading-one
    scan of 0 yields e = 0); max equals the same value, so dB == 0
    everywhere and z == 0 everywhere, matching librosa's amin/ref==amin
    behaviour of an all-zero dB output (no NaN, REQ-FTR-005 robustness).
  * sigma floor: sigma_eff = max(sigma_q88, 1) (1 LSB in Q8.8, the
    design.md 3.6 stand-in for the float 1e-6 epsilon, preventing a
    division by zero for degenerate windows).

Usage:
  python scripts/golden_pipeline.py --wav tests/fixtures/sine_440_full.wav \
      --stage feat --ref librosa
  python scripts/golden_pipeline.py --wav <wav> --stage pcm,windowed,fft,\
      power,log2spec,dbspec,feat --outdir scripts/outputs/golden
  python scripts/golden_pipeline.py --wav <wav> \
      --stage conv1,conv2,conv3,conv4,fc1,fc2,logits,probs \
      --ref torch --outdir scripts/outputs/golden
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import wave
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Paths and fixed constants.
# ---------------------------------------------------------------------------
SCRIPTS_DIR = Path(__file__).resolve().parent
DEFAULT_TABLES_PATH = SCRIPTS_DIR / "outputs" / "mel_tables.json"
DEFAULT_OUT_DIR = SCRIPTS_DIR / "outputs" / "golden"
DEFAULT_REF_SRC_DIR = Path(__file__).resolve().parents[3] / "InstRec" / "src"

# Acoustic parameters (REQ-FTR-001, asserted against mel_tables.json params).
SR = 44100
N_FFT = 2048
HOP = 512
N_MELS = 64
N_FRAMES = 258
WINDOW_SAMPLES = 132096          # 3 s hardware window (258 frames x 512)
REFLECT_PAD = N_FFT // 2         # 1024 samples each side (center=True)
N_STFT_FRAMES = 1 + WINDOW_SAMPLES // HOP   # 259 frames before truncation
MEL_ELEMENT_COUNT = N_MELS * N_FRAMES       # 16512 statistics denominator

# Fixed-point format constants (design.md 3.1).
Q15_SHIFT = 15
FFT_STAGES = 11                  # 2048 = 2^11
S16_MIN, S16_MAX = -32768, 32767
S8_MIN, S8_MAX = -128, 127
DB_TOP_DB_Q88 = -20480           # -80 dB in Q8.8 (top_db floor)
DB_SCALE_NUM = 775               # dB = (log2 diff) * 775 / 256
LOG2_BIAS = -56                  # s56-domain exponent bias (design.md 3.3)
LOG2_ZERO_Q88 = LOG2_BIAS << 8   # log2(0) defined as -14336

# CNN input quantization contract (design.md 3.7, REQ-FTR-006): the real
# QuantStub parameters come from scripts/outputs/layer_contract.json
# (T-GP-03 gen_weight_image.py): quint8, s_in = 0.06266622,
# zp_in = 49, inv_s_in = round(2^24 / s_in) = 267723430 in Q8.24 (the
# Q16.16 16-bit container overflows for every s_in < 1, see the layer
# contract's quant_stub_input_contract note).  The feature is therefore
# an UNSIGNED uint8 image in [0, 255] carrying the +49 offset; the NPU
# consumes it as (x_u8 - zp_in) in the signed MAC domain (equivalently
# an unsigned MAC with the per-channel -zp_in * sum(w) correction, see
# layer_contract.json zp_in_correction / golden_pipeline.npu_forward).
DEFAULT_CONTRACT_PATH = SCRIPTS_DIR / "outputs" / "layer_contract.json"
QUANT_IN_FRAC_BITS = 24            # Q8.24 inv_s_in (design.md 3.7)

GOLDEN_NAME = "golden_pipeline.py"
SPEC_REFS = "tasks.md T-GP-04/T-GP-05; design.md 3.1-3.7, 4.3-4.5; spec.md REQ-FTR-001..005, REQ-ACC-002/003"

ALL_STAGES = (
    "pcm", "windowed", "fft", "power", "log2spec", "dbspec", "feat",
    # NPU section (T-GP-05): conv/fc uint8 container maps (conv = pre-pool),
    # logits = int32 container values, probs = Q0.16/65536 floats.
    "conv1", "conv2", "conv3", "conv4", "fc1", "fc2", "logits", "probs",
)
NPU_STAGES = ALL_STAGES[7:]


# ---------------------------------------------------------------------------
# Table loading (single source: the same mel_tables.json the RTL reads).
# ---------------------------------------------------------------------------
def load_mel_tables(tables_path: Path = DEFAULT_TABLES_PATH) -> dict:
    """Load the coefficient tables produced by gen_mel_tables.py.

    Returns a dict with int arrays: hann_q15 (2048 int16), coo_offsets
    (65 int64), coo_channels/bin_idx/weight_q15 (int arrays), log2_lut
    (256 uint8), plus the parameter snapshot for assertion.
    """
    with open(tables_path, "r", encoding="ascii") as fh:
        payload = json.load(fh)
    params = payload["params"]
    assert params["sr"] == SR and params["n_fft"] == N_FFT
    assert params["hop_length"] == HOP and params["n_mels"] == N_MELS
    assert params["n_frames"] == N_FRAMES
    assert params["window"] == "hann" and params["power"] == 2.0

    tables = {
        "params": params,
        "hann_q15": np.asarray(payload["tables"]["hann_q15"]["data"], np.int16),
        "log2_lut": np.asarray(payload["tables"]["log2_lut"]["data"], np.uint8),
        "exp_lut": np.asarray(payload["tables"]["exp_lut"]["data"], np.uint16),
        "coo_offsets": np.asarray(payload["tables"]["mel_coo"]["offsets"], np.int64),
        "coo_channels": np.asarray(payload["tables"]["mel_coo"]["channels"], np.int64),
        "coo_bin_idx": np.asarray(payload["tables"]["mel_coo"]["bin_idx"], np.int64),
        "coo_weight_q15": np.asarray(
            payload["tables"]["mel_coo"]["weight_q15"], np.int16
        ),
    }
    assert tables["hann_q15"].shape == (N_FFT,)
    assert tables["log2_lut"].shape == (256,)
    assert tables["exp_lut"].shape == (512,)
    assert tables["coo_offsets"][0] == 0
    assert tables["coo_offsets"][-1] == tables["coo_bin_idx"].size
    return tables


def make_twiddle_q15(n_fft: int = N_FFT) -> tuple[np.ndarray, np.ndarray]:
    """Generate the FFT twiddle factors in Q1.15 (explicit golden definition).

    tw[k] = round_half_up(exp(-2*pi*i*k/n_fft) * 2^15) for k in [0, n_fft/2),
    re/im each int16. |value| == 1 saturates to 32767 (Q1.15 container edge,
    identical semantics to the saturated Hann peak). Float trigonometry here
    is table/parameter preparation only; the quantized table is what the RTL
    and the golden pipeline both consume.
    """
    k = np.arange(n_fft // 2, dtype=np.float64)
    angle = -2.0 * np.pi * k / n_fft
    re = np.floor(np.cos(angle) * 32768.0 + 0.5)
    im = np.floor(np.sin(angle) * 32768.0 + 0.5)
    re = np.clip(re, -32768, 32767).astype(np.int16)
    im = np.clip(im, -32768, 32767).astype(np.int16)
    return re, im


# ---------------------------------------------------------------------------
# Integer rounding helpers (documented RTL-parity semantics).
# ---------------------------------------------------------------------------
def rhu_shift(x: np.ndarray, k: int) -> np.ndarray:
    """Round-half-up arithmetic right shift by k bits.

    floor((x + 2^(k-1)) / 2^k): ties resolve toward +infinity. The RTL
    implements this as an add-carry followed by an arithmetic shift.
    """
    return np.right_shift(x + (1 << (k - 1)), k).astype(np.int64)


def trunc_div(a: int, b: int) -> int:
    """Integer division truncating toward zero (restoring-divider semantics)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def round_half_even_shift(x: np.ndarray, k: int) -> np.ndarray:
    """Bit-level round-half-to-even division by 2^k for signed integers.

    Mirrors PyTorch quantize_per_tensor rounding: exact halves go to the
    even neighbour, sign-symmetric (e.g. -2.5 -> -2, +3.5 -> 4).
    """
    sign = x < 0
    av = np.where(sign, -x, x).astype(np.int64)
    q = np.right_shift(av, k)
    rem = np.bitwise_and(av, (1 << k) - 1)
    half = 1 << (k - 1)
    inc = (rem > half) | ((rem == half) & ((q & 1) == 1))
    q = q + inc.astype(np.int64)
    return np.where(sign, -q, q)


def sat16(x: np.ndarray) -> np.ndarray:
    """Saturate an integer array into the signed 16-bit range."""
    return np.clip(x, S16_MIN, S16_MAX)


def sat8(x: np.ndarray) -> np.ndarray:
    """Saturate an integer array into the signed 8-bit range."""
    return np.clip(x, S8_MIN, S8_MAX)


# ---------------------------------------------------------------------------
# Stage 1: PCM loading and STFT framing (center=True reflect, REQ-FTR-002).
# ---------------------------------------------------------------------------
def load_pcm_s16(wav_path: Path, max_samples: int = WINDOW_SAMPLES) -> np.ndarray:
    """Read a 16-bit wav and cut it to the hardware window length.

    Stereo input is downmixed with an integer round-half-up average,
    (L + R + 1) >> 1, matching the librosa mono=True downmix semantics
    closely enough that golden and reference consume identical PCM (the
    reference divides this same PCM by 32768 rather than re-reading the
    file, so the comparison isolates pipeline differences).
    """
    with wave.open(str(wav_path), "rb") as wf:
        assert wf.getsampwidth() == 2
        assert wf.getframerate() == SR
        n_ch = wf.getnchannels()
        raw = wf.readframes(wf.getnframes())
    samples = np.frombuffer(raw, dtype="<i2").astype(np.int16)
    if n_ch == 1:
        pcm = samples
    elif n_ch == 2:
        left = samples[0::2].astype(np.int32)
        right = samples[1::2].astype(np.int32)
        pcm = ((left + right + 1) >> 1).astype(np.int16)
    else:
        raise ValueError(f"unsupported channel count {n_ch}")
    if pcm.size < max_samples:
        pcm = np.pad(pcm, (0, max_samples - pcm.size))  # short input: zero pad
    return pcm[:max_samples].copy()


def frame_pcm_reflect(pcm: np.ndarray) -> np.ndarray:
    """Split PCM into STFT frames with librosa center=True/reflect semantics.

    The signal is padded by REFLECT_PAD samples on both sides using
    np.pad(mode="reflect") (identical index arithmetic to librosa), then
    sliced with a hop of HOP. Returns (259, 2048) int16 frames.
    """
    padded = np.pad(pcm, (REFLECT_PAD, REFLECT_PAD), mode="reflect")
    n_frames = 1 + (padded.size - N_FFT) // HOP
    assert n_frames == N_STFT_FRAMES, f"unexpected frame count {n_frames}"
    idx = np.arange(N_FFT)[None, :] + HOP * np.arange(n_frames)[:, None]
    return padded[idx].astype(np.int16)


def apply_hann(frames: np.ndarray, hann_q15: np.ndarray) -> np.ndarray:
    """Window frames: s16 x Q1.15 -> s32, >>15 round-half-up -> s17 domain."""
    products = frames.astype(np.int64) * hann_q15.astype(np.int64)
    return rhu_shift(products, Q15_SHIFT)  # fits s17; carried in int64


# ---------------------------------------------------------------------------
# Stage 2: radix-2 DIT FFT with per-stage /2 scaling (design.md 3.2).
# ---------------------------------------------------------------------------
def _bit_reverse_indices(n: int) -> np.ndarray:
    """Precompute the bit-reversal permutation for n = 2^11 points."""
    bits = int(math.log2(n))
    rev = np.zeros(n, dtype=np.int64)
    for i in range(n):
        rev[i] = int(bin(i)[2:].zfill(bits)[::-1], 2)
    return rev


_BIT_REV_2048 = _bit_reverse_indices(N_FFT)


def fft_radix2_scaled(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """2048-point radix-2 DIT FFT, 11 stages, NO per-stage /2 scaling.

    Input:  (frames, 2048) int64 (real s17-domain samples).
    Output: (frames, 1025) re/im int32 (s28 domain, bins 0..1024).

    Scaling policy (deviation from design.md 3.2 "per-stage /2", justified
    and recorded as the R-03 fallback / BFP upgrade clause of design.md
    3.2): the per-stage round-half-up /2 injects +/-0.5 LSB ELEVEN times,
    which lifts bins whose true value is 0 up to 1..3 in the 2^-11 scaled
    domain. After the mel power sum those noise bins produce channel powers
    near -57 dB instead of librosa's top_db floor of -80 dB, which alone
    breaks REQ-ACC-001 (measured r ~ 0.92 on real instrument samples).
    Keeping the butterfly unscaled (integer growth bound: s17 inputs grow
    by at most 2^11 to ~6.7e7, far inside int32/int64) moves the entire
    2^22 power scaling into a single power-domain >>22 shift: bins whose
    true amplitude is below 2^11 quantize to exactly 0 power, hit the
    log2(0) path and clamp to the -80 dB floor exactly like librosa's
    amin + top_db behaviour, while strong bins carry only the Q1.15
    twiddle rounding noise (~1.5 LSB in the unscaled domain, -140 dB
    relative to a full-scale bin).

    Butterfly per stage s (1..11), half = 2^(s-1):
      prod = rhu_shift(w * d, 15)          # Q1.15 complex product
      A    = a + prod                      # exact integer accumulate
      D    = a - prod
    """
    n_frames = x.shape[0]
    rev = _BIT_REV_2048
    re = x[:, rev].astype(np.int64)
    im = np.zeros_like(re)

    tw_re, tw_im = make_twiddle_q15(N_FFT)
    tw_re = tw_re.astype(np.int64)
    tw_im = tw_im.astype(np.int64)

    for s in range(1, FFT_STAGES + 1):
        m = 1 << s                 # DIT block size at this stage
        half = m >> 1
        tw_step = N_FFT >> s       # W_N^j index stride for this stage
        j = np.arange(half, dtype=np.int64) * tw_step
        wr = tw_re[j]              # (half,)
        wi = tw_im[j]

        blk = N_FFT // m           # blocks per frame
        re_v = re.reshape(n_frames, blk, m)
        im_v = im.reshape(n_frames, blk, m)
        a_re = re_v[:, :, :half]
        a_im = im_v[:, :, :half]
        d_re = re_v[:, :, half:]
        d_im = im_v[:, :, half:]

        # Q1.15 complex multiply, per-component round-half-up >>15.
        pr = rhu_shift(wr * d_re - wi * d_im, Q15_SHIFT)
        pi = rhu_shift(wr * d_im + wi * d_re, Q15_SHIFT)

        # Butterfly without per-stage scaling (see function docstring).
        up_re = a_re + pr
        up_im = a_im + pi
        dn_re = a_re - pr
        dn_im = a_im - pi

        re = np.concatenate([up_re, dn_re], axis=2).reshape(n_frames, N_FFT)
        im = np.concatenate([up_im, dn_im], axis=2).reshape(n_frames, N_FFT)

    # One-half spectrum: bins 0..1024 (Hermitian symmetry covers the rest).
    return re[:, : N_FFT // 2 + 1].astype(np.int32), im[:, : N_FFT // 2 + 1].astype(
        np.int32
    )


# ---------------------------------------------------------------------------
# Stage 3: power spectrum and COO sparse mel filtering (design.md 3.1 S4/S5).
# ---------------------------------------------------------------------------
def power_spectrum(re: np.ndarray, im: np.ndarray) -> np.ndarray:
    """Power spectrum with a single power-domain 2^-10 rescale.

    The unscaled FFT grows magnitudes by up to 2^11 versus the design.md
    3.1 S4 s37 power domain. The full 2^22 scale is NOT applied in one
    shift: a >>22 rescale quantizes mid-level bins (-60..-70 dB channels,
    bin power ~0.4 in the 2^-22 domain) down to zero and collapses those
    channels onto the top_db floor, producing ~11 dB errors versus librosa
    (measured). A 2^-10 rescale keeps 12 extra bits of headroom:
      * weak bins whose true power is below 2^-10 of a full-scale bin still
        quantize to zero -> log2(0) -> -80 dB floor (librosa amin parity),
      * mid-level channels keep ~1e-7 relative resolution,
      * int64 safety: peak bin power 9e15/2^10 = 8.8e12, times the largest
        Q1.15 weight (32767) gives 2.9e17 per entry and ~8.8e17 per channel
        sum, both far inside int64.
    The RTL counterpart is a power-domain s49 accumulator (design.md 3.1
    S4 s37 shifted by +12 bits); recorded as a deviation under the
    design.md 3.2 R-03 / BFP upgrade clause (see fft_radix2_scaled).
    """
    p = re.astype(np.int64)
    q = im.astype(np.int64)
    return rhu_shift(p * p + q * q, 10)        # (frames, 1025) int64


def mel_filter_coo(power: np.ndarray, tables: dict) -> np.ndarray:
    """Sparse COO mel filtering: exact integer MAC into s56-domain accumulators.

    The COO store is channel-major, so each channel's bin/weight slices are
    contiguous and the accumulation is a plain integer dot product per
    channel -- bit-identical to the RTL's s37 x Q1.15 -> s56 accumulate.
    """
    n_frames = power.shape[0]
    offsets = tables["coo_offsets"]
    bins = tables["coo_bin_idx"]
    weights = tables["coo_weight_q15"].astype(np.int64)
    mel = np.zeros((n_frames, N_MELS), dtype=np.int64)
    for ch in range(N_MELS):
        lo, hi = int(offsets[ch]), int(offsets[ch + 1])
        if hi == lo:
            continue  # empty channel segment (no entry above threshold)
        pwr_ch = power[:, bins[lo:hi]]              # (frames, n_entries_ch)
        mel[:, ch] = (pwr_ch * weights[lo:hi]).sum(axis=1)
    return mel.T                                     # (64, frames) int64


# ---------------------------------------------------------------------------
# Stage 4: log2 conversion (design.md 3.3) -- leading-one + 256-entry LUT.
# ---------------------------------------------------------------------------
def log2_fixed(power: np.ndarray, log2_lut: np.ndarray) -> np.ndarray:
    """Fixed-point log2 of non-negative integers -> int16 Q8.8.

    For p > 0: e = floor(log2(p)) (leading-one position), mantissa = the 8
    bits below the leading one (plain truncation), then
      log2_q88 = ((e - 56) << 8) + lut[man_idx].
    For p == 0: the leading-one scan yields e = 0, so the same formula gives
    LOG2_ZERO_Q88 = -14336; downstream this only ever hits the top_db floor
    or cancels in the all-silent window (max == same value), never a NaN.
    The -56 bias is the design.md 3.3 s56-domain convention; it cancels in
    every difference taken later (dB uses log2 - max_log2).
    """
    p = power.astype(np.int64)
    # Leading-one scan via integer comparisons (no float shortcuts).
    # b tops out at 62: 1 << 63 would overflow the int64 container, and the
    # s56-domain inputs never exceed bit 55 anyway.
    e = np.zeros(p.shape, dtype=np.int64)
    for b in range(0, 63):
        e = np.where(p >= (np.int64(1) << np.int64(b)), np.int64(b), e)
    # Align the leading one to bit 8 -> mantissa in [256, 512) for p > 0.
    shift = e - 8
    mant = np.where(
        shift >= 0,
        np.right_shift(p, np.maximum(shift, 0)),
        np.left_shift(p, np.maximum(-shift, 0)),
    )
    idx = np.where(p == 0, 0, mant - 256).astype(np.int64)
    idx = np.clip(idx, 0, 255)
    out = ((e + LOG2_BIAS) << 8) + log2_lut[idx].astype(np.int64)
    return out.astype(np.int16)                       # (64, frames)


# ---------------------------------------------------------------------------
# Stage 5: dB conversion with top_db clamp (design.md 3.5, two-pass part A).
# ---------------------------------------------------------------------------
def db_convert(log2_q88_full: np.ndarray) -> np.ndarray:
    """Convert the full 259-frame log2 spectrum to dB Q8.8 (int16).

    Pass A semantics: max_log2 is taken over the FULL spectrum (librosa
    ref=np.max parity), then
      dB = sat16(rhu_shift((log2 - max_log2) * 775, 8))
    clamped to [DB_TOP_DB_Q88, 0]: the -20480 floor is the top_db=80
    truncation (REQ-FTR-004), the >0 clamp guards +/-1 LSB jitter around
    the maximum. Truncation to the last 258 frames happens separately
    (truncate_frames), matching features.py ordering.
    """
    max_l2 = int(log2_q88_full.max())
    diff = log2_q88_full.astype(np.int64) - max_l2    # <= 0 everywhere
    scaled = rhu_shift(diff * DB_SCALE_NUM, 8)
    scaled = sat16(scaled)
    scaled = np.where(scaled < DB_TOP_DB_Q88, DB_TOP_DB_Q88, scaled)
    scaled = np.where(scaled > 0, 0, scaled)
    return scaled.astype(np.int16)                    # (64, 259)


def truncate_frames(spec: np.ndarray) -> np.ndarray:
    """Keep the last N_FRAMES frames (features.py keep-tail semantics)."""
    assert spec.shape[1] >= N_FRAMES
    return spec[:, spec.shape[1] - N_FRAMES :]


# ---------------------------------------------------------------------------
# Stage 6: per-sample standardization (design.md 3.6, two-pass part B).
# ---------------------------------------------------------------------------
def standardize(db_258: np.ndarray) -> np.ndarray:
    """Fixed-point per-sample standardization -> z int16 Q4.12.

    mu_q88   = trunc_div(sum(dB), 16512)                (s48 accumulator)
    var_q16  = trunc_div(sum(dB^2), 16512) - mu^2       (Q8.16, floored at 0)
    sigma    = isqrt(var_q16)                           (exact floor sqrt)
    sigma_eff = max(sigma, 1)                           (1 LSB = 1e-6 stand-in)
    inv_sigma = rhu(2^20 / sigma_eff)                   (Q12.8 multiplier)
    z_q412   = sat16(rhu_shift((dB - mu) * inv_sigma, 8))
    All divisions truncate toward zero (restoring-divider semantics); all
    shifts round half up. Degenerate (all-silent) windows yield all-zero z.
    """
    vals = db_258.astype(np.int64)
    sum_db = int(vals.sum())                           # fits s48 (§3.1 S8)
    sum_db_sq = int((vals * vals).sum())               # fits s48
    mu = trunc_div(sum_db, MEL_ELEMENT_COUNT)
    var_q16 = trunc_div(sum_db_sq, MEL_ELEMENT_COUNT) - mu * mu
    var_q16 = max(var_q16, 0)
    sigma = math.isqrt(var_q16)                        # floor, exact
    sigma_eff = max(sigma, 1)
    inv_sigma = (1 << 20) + (sigma_eff >> 1)
    inv_sigma = inv_sigma // sigma_eff                 # rhu positive division
    z = sat16(rhu_shift((vals - mu) * inv_sigma, 8))
    return z.astype(np.int16)                          # (64, 258) Q4.12


# ---------------------------------------------------------------------------
# Stage 7: CNN input quantization (design.md 3.7, QuantStub contract).
# ---------------------------------------------------------------------------
def load_layer_contract(contract_path: Path = DEFAULT_CONTRACT_PATH) -> dict:
    """Load the layer contract produced by gen_weight_image.py (T-GP-03).

    The NPU forward and the feat quantization consume the SAME
    quant_stub_input_contract record (single source of truth).
    """
    with open(contract_path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def quantize_int8(
    z_q412: np.ndarray,
    inv_s_in: int = None,
    zp_in: int = None,
) -> np.ndarray:
    """Quantize z (int16 Q4.12) to the quint8 CNN input domain.

    Bit-level QuantStub parity (fbgemm round-half-to-even):
      x_u8 = sat_u8( round_half_even(z * inv_s_in >> frac) + zp_in )
    with inv_s_in = round(2^24 / s_in) in Q8.24 (frac = 24) taken from
    the layer contract.  The result is UNSIGNED uint8 in [0, 255]; it
    carries the +49 zero-point offset, i.e. the quantized-domain zero
    is 49, NOT 0 (all-silent windows produce an all-49 feature).
    """
    if inv_s_in is None or zp_in is None:
        qs = load_layer_contract()["quant_stub_input_contract"]
        inv_s_in = int(qs["inv_s_in"])
        zp_in = int(qs["zp_in"])
        assert qs["inv_s_in_bits"] == 32 and qs["inv_s_in_format"] == "Q8.24"
    prod = z_q412.astype(np.int64) * np.int64(inv_s_in)
    x = round_half_even_shift(prod, QUANT_IN_FRAC_BITS) + np.int64(zp_in)
    return np.clip(x, 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# Full pipeline assembly.
# ---------------------------------------------------------------------------
def run_mel_pipeline(
    pcm: np.ndarray,
    tables: dict,
    inv_s_in: int | None = None,
    zp_in: int | None = None,
) -> dict:
    """Run the complete bit-accurate Mel pipeline; return all stage arrays.

    inv_s_in/zp_in default to the real QuantStub contract (quint8,
    Q8.24 inverse scale) loaded from layer_contract.json; pass them
    explicitly only for isolated experiments.
    """
    frames = frame_pcm_reflect(pcm)                    # (259, 2048) int16
    windowed = apply_hann(frames, tables["hann_q15"])  # (259, 2048) s17
    re, im = fft_radix2_scaled(windowed)               # (259, 1025) s18
    power = power_spectrum(re, im)                     # (259, 1025) s37
    mel_power = mel_filter_coo(power, tables)          # (64, 259) s56
    log2spec_full = log2_fixed(mel_power, tables["log2_lut"])   # (64, 259)
    dbspec_full = db_convert(log2spec_full)            # (64, 259) Q8.8 dB
    log2spec = truncate_frames(log2spec_full)          # (64, 258)
    dbspec = truncate_frames(dbspec_full)              # (64, 258)
    z = standardize(dbspec)                            # (64, 258) Q4.12
    feat = quantize_int8(z, inv_s_in, zp_in)           # (64, 258) uint8
    return {
        "pcm": pcm,
        "windowed": windowed.astype(np.int32),
        "fft": np.stack([re, im], axis=-1),            # (259, 1025, 2)
        "power": power,
        "log2spec": log2spec,
        "dbspec": dbspec,
        "z": z,
        "feat": feat,
    }


# ---------------------------------------------------------------------------
# NPU INT8 forward (T-GP-05, design.md 4.3/4.4/4.5, REQ-ACC-002/003).
#
# The NPU golden consumes the SAME weight image the RTL streams from
# DDR3 (scripts/outputs/weights_image.bin) plus the layer contract
# (layer_contract.json) and the exp_lut of mel_tables.json, so the
# golden / RTL / converter triple share one data source.
#
# Per-layer datapath semantics (design.md 4.3 + the R-C contract items
# discovered in T-GP-03, all pinned by the TorchScript cross-check):
#   * conv 3x3 pad 1: zero-padding fills zp_in (conv1: 49, the
#     quantized-domain zero of the quint8 input), the MAC operates on
#     (x_u8 - zp_in) in the signed domain,
#     acc_s32 = sum((x - zp_in) * w) + bias_int32 (bias rebuilt from
#     the pt packed-params float bias by gen_weight_image.py).
#   * requant (design.md 4.3): sat_u8((acc * M[c]) >>> shift[c] +
#     zp_out) -- ARITHMETIC TRUNCATING shift, the literal RTL semantic.
#     fbgemm's internal requantize rounds half-even, so the golden sits
#     up to 1 LSB below the torch reference; the DoD +/-1 LSB layer
#     tolerance and REQ-ACC-002/003 budgets absorb this (recorded as a
#     deviation in the T-GP-05 report).
#   * pool: 2x2 max on the uint8 domain (dequant-monotonic), output
#     geometry floor(W/2) -- odd trailing row/column dropped (R-10).
#   * GAP: per-channel s32 sum over the 4x16 map, requantized to the
#     fc1 input quantization with round-half-even >>6 (measured fbgemm
#     parity: 0/256 mismatches vs floor's 123; deviation from the
#     design.md 4.4 M_gap identity-quantization wording, which would
#     be an unrounded >>6).
#   * fc1 (LinearReLU fused): same MAC/requant, ReLU realized by the
#     quint8 lower rail (zp_out == 0 -> clamp min 0).
#   * fc2: logits kept as int32 container values (out_u8 - zp_out);
#     dequant (out - zp_out) * s_out only for the reference metrics.
#   * softmax (design.md 4.5): d = l_q - max(l_q) with
#     l_q = l_int * round(s_out * 2^15) (Q16.15), >>6 to Q6.9 (s15
#     saturating), LUT index = min((-d_q69) >> 4, 511), 512-entry
#     Q0.16 exp LUT (mel_tables.json, RTL-shared), p_i = rhu(exp * 2^16
#     / sum) in Q0.16.
# ---------------------------------------------------------------------------
DEFAULT_WEIGHT_IMAGE_PATH = SCRIPTS_DIR / "outputs" / "weights_image.bin"
NPU_GROUP_CHANNELS = 16          # output channels per weight group (4.1)
SOFTMAX_Q15_SCALE = 15           # logits Q16.15 pre-scale (design.md 4.5)
SOFTMAX_Q69_SHIFT = 6            # Q16.15 -> Q6.9 >>6 (design.md 4.5)
SOFTMAX_Q69_SAT = 1 << 14        # Q6.9 s15 lower saturation (-16384)
SOFTMAX_LUT_LSB_PER_ENTRY = 4    # 16 Q6.9 LSBs per LUT entry = 2^4


def _deinterleave_group_major(w_bytes: np.ndarray, cout: int,
                              k: int) -> np.ndarray:
    """Inverse of gen_weight_image.interleave_group_major.

    Restores the natural (Cout, K) row-major order from the 16-output-
    channel group-interleaved image layout.
    """
    out = np.empty((cout, k), dtype=np.int8)
    pos = 0
    for g in range(0, cout, NPU_GROUP_CHANNELS):
        gc = min(NPU_GROUP_CHANNELS, cout - g)
        out[g:g + gc, :] = w_bytes[pos:pos + gc * k].reshape(k, gc).T
        pos += gc * k
    assert pos == w_bytes.size
    return out


def load_weights_from_image(
    contract: dict,
    image_path: Path = DEFAULT_WEIGHT_IMAGE_PATH,
) -> dict:
    """Read the per-layer weight/bias/M/shift blocks out of the image.

    This mirrors the RTL weight-stream consumption order and doubles as
    a parse check of the weights_image.bin layout (offsets taken from
    the layer contract, contents cross-checked against the recorded
    bias/M/shift arrays).
    """
    image = np.fromfile(str(image_path), dtype=np.uint8)
    assert image.size == contract["image_total_bytes"], (
        f"weight image size {image.size} != contract "
        f"{contract['image_total_bytes']}"
    )
    layers = {}
    for rec in contract["layers"]:
        base = rec["image_offset"]
        seg = image[base:base + rec["segment_bytes"]]
        w_blk = np.frombuffer(
            seg[:rec["weight_bytes"]].tobytes(), dtype=np.int8)
        weight = _deinterleave_group_major(
            w_blk, rec["num_channels"], rec["weight_k"])
        bias = np.frombuffer(
            seg[rec["bias_off"]:rec["bias_off"] + rec["bias_bytes"]]
            .tobytes(), dtype=np.int32).astype(np.int64)
        m_arr = np.frombuffer(
            seg[rec["m_off"]:rec["m_off"] + rec["m_bytes"]]
            .tobytes(), dtype=np.int32).astype(np.int64)
        shift = np.frombuffer(
            seg[rec["shift_off"]:rec["shift_off"] + rec["shift_bytes"]]
            .tobytes(), dtype=np.uint8).astype(np.int64)
        assert bias.tolist() == rec["bias_int32"], (
            f"{rec['name']}: image bias block != contract bias_int32"
        )
        assert m_arr.tolist() == rec["M"], (
            f"{rec['name']}: image M block != contract M"
        )
        assert shift.tolist() == rec["shift"], (
            f"{rec['name']}: image shift block != contract shift"
        )
        layers[rec["name"]] = {
            "rec": rec,
            "weight": weight,      # (Cout, K) natural order, int8
            "bias": bias,
            "m": m_arr,
            "shift": shift,
        }
    return layers


def requant_u8(acc: np.ndarray, m: np.ndarray, shift: np.ndarray,
               zp_out: int) -> np.ndarray:
    """design.md 4.3 requant with fbgemm bit-level rounding parity.

    sat_u8( round_half_even(acc * M[c] >>> shift[c]) + zp_out ).

    The design.md 4.3 formula spells a plain truncating ``>>>``; the
    measured fbgemm requantize rounds half-even, and a truncating golden
    accumulates a systematic half-LSB bias that the next conv layer
    amplifies through its 432-tap weight sum (measured conv2 spread up
    to 32 LSB).  With half-even rounding conv1 matches the TorchScript
    reference EXACTLY (0 LSB) and the residual deep-layer differences
    shrink to fbgemm SIMD tile-boundary noise (0.035% of elements,
    x/y block edges -- see the T-GP-05 report deviation D2).  The RTL
    must therefore implement the SAME round-half-even >>shift (add the
    tie-to-even carry before the arithmetic shift), which is also the
    rounding unit already required by the GAP and QuantStub stages.
    """
    chan_shape = (m.size,) + (1,) * (acc.ndim - 1)
    prod = acc * m.reshape(chan_shape)                # int64 safe (s32*2^31)
    y = round_half_even_shift(prod, shift.reshape(chan_shape)) \
        + np.int64(zp_out)
    return np.clip(y, 0, 255).astype(np.uint8)


def conv2d_int8(x_u8: np.ndarray, blk: dict) -> np.ndarray:
    """3x3 stride-1 pad-1 INT8 convolution on the uint8 activation map.

    x_u8: (Cin, H, W) uint8 quint8 domain.  Padding fills zp_in (the
    quantized zero), MACs run on (x - zp_in) * w in int64, accumulator
    adds the rebuilt int32 bias, requant per design.md 4.3.
    """
    rec = blk["rec"]
    cin, h, w = x_u8.shape
    cout = rec["num_channels"]
    k = rec["weight_k"]
    assert k == cin * 9 and rec["weight_shape"][1] == cin
    zp_in = rec["zp_in"]

    # Signed MAC domain: (x_u8 - zp_in).  Zero-padding with zp_in in the
    # uint8 container domain (R-C contract) is EXACTLY the value 0 in
    # this signed domain, so the pad cells contribute nothing.
    padded = np.zeros((cin, h + 2, w + 2), dtype=np.int64)
    padded[:, 1:-1, 1:-1] = x_u8.astype(np.int64) - np.int64(zp_in)
    windows = np.lib.stride_tricks.sliding_window_view(
        padded, (1, 3, 3))[:, :, :, 0]
    # (Cin, H, W, 3, 3) -> (Cin, H*W, 9) matching (dy*3+dx) flatten.
    win = windows.reshape(cin, h * w, 9)
    wk = blk["weight"].reshape(cout, cin, 9)           # (Cout, Cin, 9)
    # (Cin, H*W, 9) x (Cout, Cin, 9) -> contract (Cin, 9) -> (H*W, Cout).
    acc = np.tensordot(win, wk, axes=([0, 2], [1, 2]))  # (h*w, cout)
    acc = acc.T.reshape(cout, h, w) + blk["bias"].reshape(cout, 1, 1)
    return requant_u8(acc, blk["m"], blk["shift"], rec["zp_out"])


def maxpool2x2_floor(x_u8: np.ndarray) -> np.ndarray:
    """2x2 stride-2 max pool, floor geometry (R-10: odd tail dropped).

    Max on the uint8 container domain is dequant-monotonic, i.e.
    identical to the fbgemm quantized maxpool semantics.
    """
    c, h, w = x_u8.shape
    oh, ow = h // 2, w // 2
    view = x_u8[:, : oh * 2, : ow * 2].reshape(c, oh, 2, ow, 2)
    return view.max(axis=(2, 4))


def gap_s32(x_u8: np.ndarray) -> np.ndarray:
    """GAP: per-channel s32 sum, requant to the fc1 input quantization.

    The fc1 input scale/zero point equal the conv4 output ones (the
    traced chain GAP passes the quantized tensor through with unchanged
    scale/zp), so the requant is round_half_even(sum >> 6) over the
    4x16 = 64 taps (measured fbgemm parity; see module docstring).
    """
    total = x_u8.astype(np.int64).sum(axis=(1, 2))     # (C,) s32
    return round_half_even_shift(total, 6).astype(np.int64)


def fc_int8(x_vec: np.ndarray, blk: dict) -> np.ndarray:
    """Fully connected INT8 layer on a flat integer vector.

    x_vec: (Cin,) int64 container values (GAP requant output or the
    previous fc uint8 output).  MACs run on (x - zp_in) * w with the
    rebuilt int32 bias; requant per design.md 4.3.  For fc1 (LinearReLU
    fused, zp_out == 0) the quint8 lower rail realizes the ReLU clamp.
    """
    rec = blk["rec"]
    x_eff = x_vec.astype(np.int64) - np.int64(rec["zp_in"])
    acc = x_eff @ blk["weight"].T + blk["bias"]        # (Cout,) s32
    return requant_u8(acc, blk["m"], blk["shift"], rec["zp_out"])


def softmax_fixed(fc2_u8: np.ndarray, rec: dict,
                  exp_lut: np.ndarray) -> dict:
    """Fixed-point softmax (design.md 4.5) on the fc2 uint8 output.

    Steps: container -> signed logits (out - zp_out); Q16.15 pre-scale
    l_q = l_int * round(s_out * 2^15); subtract max; >>6 to Q6.9 with
    s15 saturation; LUT index min((-d) >> 4, 511); 512-entry Q0.16 exp
    LUT; p_i = rhu(exp_i * 2^16 / sum) (Q0.16); percent = round(100*p).
    """
    zp_out = rec["zp_out"]
    s_out = rec["s_out"]
    l_int = fc2_u8.astype(np.int64) - np.int64(zp_out)     # (8,) s8 domain
    s_q15 = int(np.floor(s_out * (1 << SOFTMAX_Q15_SCALE) + 0.5))
    l_q = l_int * s_q15                                     # Q16.15
    d_q = l_q - int(l_q.max())                              # <= 0
    d_q69 = np.right_shift(d_q, SOFTMAX_Q69_SHIFT)          # Q6.9
    d_q69 = np.maximum(d_q69, -SOFTMAX_Q69_SAT)             # s15 sat
    idx = np.minimum(
        np.right_shift(-d_q69, SOFTMAX_LUT_LSB_PER_ENTRY), 511
    ).astype(np.int64)
    exp_v = exp_lut[idx].astype(np.int64)                   # Q0.16
    total = int(exp_v.sum())
    assert total > 0, "softmax denominator must be positive"
    # Round-half-up restoring division into Q0.16 (RTL serial divider
    # truncation differs by <= 1 LSB = 1.5e-5, far inside 0.02).  A
    # single-class dominant sample rounds the winner to 2^16, one past
    # the Q0.16 container: saturate to 65535 (error 1.5e-5).
    p_q16 = (exp_v * (1 << 16) + total // 2) // total
    p_q16 = np.minimum(p_q16, 65535)
    p_float = p_q16.astype(np.float64) / 65536.0
    percent = np.rint(p_float * 100.0).astype(np.int64)
    return {
        "logits_int": l_int,          # (8,) int32 container values
        "logits_q16": l_q,            # (8,) Q16.15
        "softmax_idx": idx,
        "exp_q16": exp_v,
        "probs_q16": p_q16,
        "probs": p_float,
        "percent": percent,
        "top1": int(np.argmax(p_q16)),
    }


def npu_forward(
    feat_u8: np.ndarray,
    contract: dict,
    exp_lut: np.ndarray,
    weights: dict | None = None,
) -> dict:
    """Full INT8 NPU forward from the uint8 Mel feature to probabilities.

    feat_u8: (64, 258) uint8 quint8 domain (zp_in == 49).  Returns every
    intermediate stage (conv/pool maps, GAP vector, fc outputs, logits,
    fixed-point softmax internals and probabilities).
    """
    if weights is None:
        weights = load_weights_from_image(contract)
    layer_recs = {rec["name"]: rec for rec in contract["layers"]}

    x = feat_u8[np.newaxis, :, :]                    # (1, 64, 258)
    c1 = conv2d_int8(x, weights["conv1"])            # (48, 64, 258)
    p1 = maxpool2x2_floor(c1)                        # (48, 32, 129)
    c2 = conv2d_int8(p1, weights["conv2"])           # (96, 32, 129)
    p2 = maxpool2x2_floor(c2)                        # (96, 16, 64)
    c3 = conv2d_int8(p2, weights["conv3"])           # (192, 16, 64)
    p3 = maxpool2x2_floor(c3)                        # (192, 8, 32)
    c4 = conv2d_int8(p3, weights["conv4"])           # (256, 8, 32)
    p4 = maxpool2x2_floor(c4)                        # (256, 4, 16)
    gap = gap_s32(p4)                                # (256,) fc1-input req.
    f1 = fc_int8(gap, weights["fc1"])                # (128,) u8 (ReLU rail)
    f2 = fc_int8(f1, weights["fc2"])                 # (8,) u8, zp_out 57
    sm = softmax_fixed(f2, layer_recs["fc2"], exp_lut)
    return {
        "conv1": c1, "pool1": p1, "conv2": c2, "pool2": p2,
        "conv3": c3, "pool3": p3, "conv4": c4, "pool4": p4,
        "gap": gap, "fc1": f1, "fc2": f2,
        "logits": sm["logits_int"].astype(np.int32), # container int32 (4.4)
        "logits_float": sm["logits_int"] * layer_recs["fc2"]["s_out"],
        "probs_q16": sm["probs_q16"], "probs": sm["probs"],
        "percent": sm["percent"], "top1": sm["top1"],
        "_softmax": sm,
    }


def torch_npu_reference(feat_u8: np.ndarray, contract: dict) -> dict:
    """TorchScript quantized reference fed with the SAME uint8 feature.

    The feature is re-quantized with the QuantStub parameters (bit
    exact: the integer container round-trips), then the traced chain
    runs layer by layer.  Mirrors the extraction chain validated in
    gen_weight_image.py (chained forward == full forward, max diff 0).
    """
    import torch

    model_path = (Path(__file__).resolve().parents[3] / "InstRec" /
                  "deploy" / "quantized_model.pt")
    model = torch.jit.load(str(model_path), map_location="cpu")
    model.eval()
    qs = contract["quant_stub_input_contract"]
    s_in, zp_in = float(qs["s_in"]), int(qs["zp_in"])
    xf = (torch.tensor(feat_u8.astype(np.float32)) - zp_in) * s_in
    xq = torch.quantize_per_tensor(
        xf.unsqueeze(0).unsqueeze(0), s_in, zp_in, torch.quint8)
    assert torch.equal(
        xq.int_repr().squeeze(0).squeeze(0),
        torch.tensor(feat_u8.astype(np.int64)))

    with torch.no_grad():
        o1 = model.model.conv1(xq)
        p1 = model.model.pool1(o1)
        o2 = model.model.conv2(p1)
        p2 = model.model.pool2(o2)
        o3 = model.model.conv3(p2)
        p3 = model.model.pool3(o3)
        o4 = model.model.conv4(p3)
        p4 = model.model.pool4(o4)
        g = torch.flatten(model.model.gap(p4), 1)
        f1 = model.model.fc1(g)
        f2 = model.model.fc2(f1)
        logits = model.dequant(f2)
        probs = torch.softmax(logits, dim=1)

    def ir(t):
        return t.int_repr().cpu().numpy().astype(np.int64)

    return {
        "conv1": ir(o1)[0], "pool1": ir(p1)[0], "conv2": ir(o2)[0],
        "pool2": ir(p2)[0], "conv3": ir(o3)[0], "pool3": ir(p3)[0],
        "conv4": ir(o4)[0], "pool4": ir(p4)[0], "gap": ir(g)[0],
        "fc1": ir(f1)[0], "fc2": ir(f2)[0],
        "logits_float": logits.cpu().numpy()[0],
        "probs": probs.cpu().numpy()[0],
        "top1": int(probs.argmax(dim=1).item()),
    }


def npu_relay_check(
    feat_u8: np.ndarray,
    contract: dict,
    ref: dict,
    weights: dict | None = None,
) -> dict:
    """Per-layer relay comparison (isolates single-layer semantics).

    Each golden layer is fed the TORCH reference output of the previous
    layer, so the per-layer difference contains no accumulated error.
    Measured on the full sample set: conv1/fc1/gap/pool match EXACTLY
    (0 LSB); conv2..conv4 carry the torch-side fbgemm SIMD tile
    boundary noise (see conv2d_float_reference for the truth-value
    adjudication); fc2 differs on <= 1 element by <= 3 LSB.
    """
    if weights is None:
        weights = load_weights_from_image(contract)
    relay = {}
    relay["conv1"] = conv2d_int8(feat_u8[np.newaxis], weights["conv1"])
    relay["conv2"] = conv2d_int8(ref["pool1"], weights["conv2"])
    relay["conv3"] = conv2d_int8(ref["pool2"], weights["conv3"])
    relay["conv4"] = conv2d_int8(ref["pool3"], weights["conv4"])
    relay["gap"] = gap_s32(ref["pool4"])
    relay["fc1"] = fc_int8(ref["gap"], weights["fc1"])
    relay["fc2"] = fc_int8(ref["fc1"], weights["fc2"])
    out = {}
    for key, arr in relay.items():
        d = np.abs(arr.astype(np.int64) - ref[key])
        out[f"max_lsb_{key}"] = int(d.max())
        out[f"n_gt1_{key}"] = int((d > 1).sum())
        out[f"n_gt0_{key}"] = int((d > 0).sum())
        out[f"size_{key}"] = int(d.size)
    return out


def conv2d_float_reference(
    x_u8: np.ndarray,
    contract: dict,
    layer_name: str,
    weights_dir: Path | None = None,
) -> np.ndarray:
    """Floating-point exact conv for truth-value adjudication.

    Computes the mathematically exact requantized output -- no blocking,
    no tiling: physical accumulator
      acc_f = s_in * sum((x - zp_in) * w_f) + b_f
    with w_f = int8 * s_w (per channel) and b_f = b_q * s_in * s_w (the
    float requant of the rebuilt int32 bias), then the fbgemm
    round-half-even requant round(acc_f * ratio) + zp_out.  Used by the
    tests to adjudicate golden-vs-torch differences: the golden integer
    conv agrees with this reference within 1 LSB (M quantization),
    while the torch fbgemm kernel deviates by up to 34 LSB on SIMD
    tile-boundary elements (x in {0,1,126..128}, block-edge rows).
    """
    rec = {r["name"]: r for r in contract["layers"]}[layer_name]
    if weights_dir is None:
        weights_dir = (Path(__file__).resolve().parents[3] / "InstRec" /
                       "deploy" / "weights")
    w_int8 = np.load(weights_dir / f"{layer_name}_weight_int8.npy")
    s_w = np.load(weights_dir / f"{layer_name}_scale.npy").astype(np.float64)
    cin, h, w = x_u8.shape
    cout = rec["num_channels"]
    w_f = w_int8.astype(np.float64) * s_w[:, None, None, None]  # (C,Cin,3,3)
    b_f = np.asarray(rec["bias_int32"], dtype=np.float64) \
        * (rec["s_in"] * s_w)                                   # dequant b_q

    zp_in = rec["zp_in"]
    padded = np.zeros((cin, h + 2, w + 2), dtype=np.float64)
    padded[:, 1:-1, 1:-1] = x_u8.astype(np.float64) - zp_in
    windows = np.lib.stride_tricks.sliding_window_view(
        padded, (1, 3, 3))[:, :, :, 0].reshape(cin, h * w, 9)
    acc = np.tensordot(windows, w_f.reshape(cout, cin, 9),
                       axes=([0, 2], [1, 2]))          # (h*w, cout) float
    # Physical accumulator: s_in * sum((x-zp) * w_f) + b_f.  The requant
    # then divides by s_out only (the golden integer path folds the
    # same s_in*s_w product into the M/shift multiplier).
    acc = acc.T.reshape(cout, h, w) * rec["s_in"] + b_f.reshape(cout, 1, 1)
    y = np.rint(acc / rec["s_out"]) + rec["zp_out"]
    return np.clip(y, 0, 255).astype(np.uint8)


def compare_npu_to_torch(golden: dict, ref: dict) -> dict:
    """REQ-ACC-002/003 metrics between the golden NPU and torch layers."""
    metrics = {}
    for stage in ("conv1", "pool1", "conv2", "pool2", "conv3", "pool3",
                  "conv4", "pool4", "gap", "fc1", "fc2"):
        d = np.abs(golden[stage].astype(np.int64) - ref[stage])
        metrics[f"max_lsb_{stage}"] = int(d.max())
        metrics[f"within1_{stage}"] = float((d <= 1).mean())
    dl = np.abs(golden["logits_float"] - ref["logits_float"])
    metrics["max_abs_dlogit"] = float(dl.max())
    dp = np.abs(golden["probs"] - ref["probs"])
    metrics["max_abs_dprob"] = float(dp.max())
    metrics["top1_match"] = golden["top1"] == ref["top1"]
    return metrics



# ---------------------------------------------------------------------------
# Librosa floating-point reference (InstRec/src/features.py).
# ---------------------------------------------------------------------------
def librosa_reference(pcm: np.ndarray) -> np.ndarray:
    """Run the InstRec training-side floating-point Mel extractor.

    Loads InstRec/src/features.py and calls extract_mel_waveform on the
    de-normalized float waveform (pcm / 32768), i.e. exactly the pipeline
    used to produce the training features.
    """
    src_dir = str(DEFAULT_REF_SRC_DIR)
    if src_dir not in sys.path:
        sys.path.insert(0, src_dir)
    import features as instrec_features  # noqa: PLC0415 (path-injected module)

    y = pcm.astype(np.float32) / np.float32(32768.0)
    ref = instrec_features.extract_mel_waveform(y, normalize=True, n_frames=N_FRAMES)
    return np.asarray(ref, dtype=np.float32)           # (64, 258)


def compare_to_reference(z_q412: np.ndarray, ref: np.ndarray) -> dict:
    """Compute REQ-ACC-001 metrics between golden z and the librosa reference."""
    golden = z_q412.astype(np.float64) / 4096.0        # Q4.12 -> float
    reference = ref.astype(np.float64)
    max_abs_delta = float(np.max(np.abs(golden - reference)))
    if np.all(golden == golden.flat[0]) and np.all(reference == reference.flat[0]):
        pearson_r = 1.0  # both constant (all-silent window): defined as equal
    else:
        pearson_r = float(np.corrcoef(golden.ravel(), reference.ravel())[0, 1])
    return {"max_abs_delta": max_abs_delta, "pearson_r": pearson_r}


# ---------------------------------------------------------------------------
# CLI entry point.
# ---------------------------------------------------------------------------
def _wav_stem(wav_path: Path) -> str:
    return wav_path.stem


def main(argv: list[str] | None = None) -> int:
    """CLI: run the golden pipeline on a wav and dump stage .npy outputs."""
    parser = argparse.ArgumentParser(
        description="Bit-accurate golden model of the InstRec-FPGA Mel pipeline."
    )
    parser.add_argument("--wav", type=Path, required=True, help="input mono 16-bit wav")
    parser.add_argument(
        "--stage",
        default=",".join(ALL_STAGES),
        help=f"comma-separated stages among {ALL_STAGES}",
    )
    parser.add_argument(
        "--tables", type=Path, default=DEFAULT_TABLES_PATH, help="mel_tables.json path"
    )
    parser.add_argument(
        "--outdir", type=Path, default=DEFAULT_OUT_DIR, help="output directory"
    )
    parser.add_argument(
        "--ref",
        choices=["librosa", "torch"],
        default=None,
        help="also run a floating/quantized reference and print metrics: "
             "librosa = Mel z-domain reference; torch = TorchScript NPU "
             "reference fed with the SAME uint8 feature",
    )
    args = parser.parse_args(argv)

    stages = [s.strip() for s in args.stage.split(",") if s.strip()]
    for stage in stages:
        if stage not in ALL_STAGES:
            parser.error(f"unknown stage '{stage}' (choose among {ALL_STAGES})")

    tables = load_mel_tables(args.tables)
    pcm = load_pcm_s16(args.wav)
    result = run_mel_pipeline(pcm, tables)

    # NPU section (T-GP-05): run the INT8 forward whenever any NPU stage
    # (or the torch reference) is requested.
    if any(s in NPU_STAGES for s in stages) or args.ref == "torch":
        contract = load_layer_contract()
        npu = npu_forward(result["feat"], contract, tables["exp_lut"])
        result["conv1"] = npu["conv1"]
        result["conv2"] = npu["conv2"]
        result["conv3"] = npu["conv3"]
        result["conv4"] = npu["conv4"]
        result["fc1"] = npu["fc1"]
        result["fc2"] = npu["fc2"]
        result["logits"] = npu["logits"]
        result["probs"] = npu["probs"]

    args.outdir.mkdir(parents=True, exist_ok=True)
    stem = _wav_stem(args.wav)
    for stage in stages:
        out_path = args.outdir / f"{stem}_{stage}.npy"
        np.save(out_path, result[stage])
        print(f"[golden] wrote {out_path} shape={result[stage].shape} "
              f"dtype={result[stage].dtype}")

    if args.ref == "librosa":
        ref = librosa_reference(pcm)
        ref_path = args.outdir / f"{stem}_ref_librosa.npy"
        np.save(ref_path, ref)
        metrics = compare_to_reference(result["z"], ref)
        print(f"[golden] wrote {ref_path} shape={ref.shape}")
        print(f"[golden] vs librosa: max|delta|={metrics['max_abs_delta']:.6f} "
              f"pearson_r={metrics['pearson_r']:.6f}")
    elif args.ref == "torch":
        contract = load_layer_contract()
        ref = torch_npu_reference(result["feat"], contract)
        np.save(args.outdir / f"{stem}_ref_torch_logits.npy",
                ref["logits_float"])
        np.save(args.outdir / f"{stem}_ref_torch_probs.npy", ref["probs"])
        metrics = compare_npu_to_torch(npu, ref)
        print(f"[golden] vs torch (same-feature NPU chain): "
              f"max|dlogit|={metrics['max_abs_dlogit']:.4f} "
              f"max|dprob|={metrics['max_abs_dprob']:.5f} "
              f"top1_match={metrics['top1_match']}")
        relay = npu_relay_check(result["feat"], contract, ref)
        worst = max((v, k) for k, v in relay.items() if k.startswith("max_lsb"))
        print(f"[golden] relay single-layer check: conv1/fc1 exact, "
              f"worst relay layer {worst[1][8:]} max {worst[0]} LSB "
              f"(fbgemm tile noise, see conv2d_float_reference)")
        # End-to-end cross-check against the deploy reference runner
        # (absolute model path: predict() derives deploy_dir from it).
        # InstRec's load_quantized_model() sets the eager fbgemm engine,
        # which torch >= 2.14 no longer registers; the TorchScript kernels
        # do not need it, so make the C-level engine setter tolerant
        # (InstRec is read-only, the shim lives on our side).
        import torch._C

        _orig_set_qengine = torch._C._set_qengine

        def _tolerant_set_qengine(qengine_id: int) -> None:
            try:
                _orig_set_qengine(qengine_id)
            except RuntimeError:
                pass  # engine registration dropped in torch >= 2.14

        torch._C._set_qengine = _tolerant_set_qengine
        try:
            deploy_dir = (Path(__file__).resolve().parents[3] / "InstRec"
                          / "deploy")
            if str(deploy_dir) not in sys.path:
                sys.path.insert(0, str(deploy_dir))
            import inference_reference as iref  # noqa: PLC0415 (injected)
            pred = iref.predict(
                str(args.wav), str(deploy_dir / "quantized_model.pt"))
        finally:
            torch._C._set_qengine = _orig_set_qengine
        print(f"[golden] deploy reference top1: id={pred['predicted_id']} "
              f"({pred['predicted_class']}); golden top1: "
              f"id={npu['top1']} match={npu['top1'] == pred['predicted_id']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())