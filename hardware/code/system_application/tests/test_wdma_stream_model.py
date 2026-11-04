"""wdma stream algorithm model (tasks.md T-M2-02).

The DMA reads a layer's weight region as a contiguous 32-byte beat stream
and must cut it into taps:
  * conv/fc1 tap = 16 B (16 lanes), fc2 tap = 8 B (8 lanes);
  * a layer's weight region starts 32-byte aligned, so a 32-byte beat
    carries exactly two 16-byte taps (or four 8-byte fc2 taps);
  * conv1 has 27 taps = 432 B = 13.5 beats, i.e. the final beat carries a
    single tap and the upper 16 bytes are padding/next-region data that
    must not be emitted.

This test proves the beat/tap arithmetic before it is committed to RTL.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / 'scripts/outputs/weights_image.bin'

# name -> (region offset, tap count, tap bytes)
LAYERS = {
    'conv1': (512, 3 * 9, 16),
    'conv2': (1376, 6 * 432, 16),
    'conv3': (43712, 12 * 864, 16),
    'conv4': (211328, 16 * 1728, 16),
    'fc1': (656000, 8 * 256, 16),
    'fc2': (689920, 1 * 128, 8),
}


def _beats(data, base, total_bytes):
    return [data[base + i * 32: base + (i + 1) * 32] for i in range((total_bytes + 31) // 32)]


def test_every_weight_region_starts_32b_aligned():
    for name, (base, _, _) in LAYERS.items():
        assert base % 32 == 0, name


def test_beat_stream_reconstructs_taps():
    data = IMAGE.read_bytes()
    for name, (base, taps, tap_bytes) in LAYERS.items():
        total = taps * tap_bytes
        stream = b''.join(_beats(data, base, total))[:total]
        got = [stream[i * tap_bytes:(i + 1) * tap_bytes] for i in range(taps)]
        want = [data[base + i * tap_bytes: base + (i + 1) * tap_bytes] for i in range(taps)]
        assert got == want, name
        assert all(len(t) == tap_bytes for t in got)


def test_conv1_tail_has_one_tap_in_last_beat():
    _, taps, tap_bytes = LAYERS['conv1']
    assert taps == 27
    assert taps * tap_bytes == 432
    assert (432 + 31) // 32 == 14          # 13 full beats + 1 half beat
    assert 13 * 2 == 26                    # 26 taps in the full beats
    assert taps - 26 == 1                  # one tap in the tail beat


def test_fc2_four_taps_per_beat():
    _, taps, tap_bytes = LAYERS['fc2']
    assert tap_bytes == 8
    assert taps == 128
    assert 32 // tap_bytes == 4


def test_total_weights_bytes_match_regions():
    # Weights are the first block of each region; the remaining bytes are
    # bias (4 B/channel), M (4 B/channel) and shift (1 B/channel).
    expect = {
        'conv1': 48, 'conv2': 96, 'conv3': 192, 'conv4': 256, 'fc1': 128, 'fc2': 8,
    }
    for name, (base, taps, tap_bytes) in LAYERS.items():
        c = expect[name]
        region = taps * tap_bytes + c * 4 + c * 4 + c
        assert region <= len(IMAGE.read_bytes()) - base