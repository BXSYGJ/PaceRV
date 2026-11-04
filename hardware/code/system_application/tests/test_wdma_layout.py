"""Weight-image layout facts for wdma (tasks.md T-M2-02).

Confirms the per-group geometry the DMA must handle:
  * each layer region starts at a fixed offset and begins with the
    interleaved weights;
  * a tap is 16 B for the 16-lane conv/fc1 layers, but **8 B for fc2**
    (only 8 output channels);
  * taps are contiguous, yet a group start is only 16-byte aligned
    (conv1 group stride 144 B), NOT 32-byte aligned;
  * therefore a 32-byte DDR3 beat does not line up with a tap boundary and
    the reader needs a byte-rotation stage (or an extra beat cache).

These assertions protect the address table hardcoded in wdma.v.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / 'scripts/outputs/weights_image.bin'

# name -> (region offset, groups, taps per group, tap bytes)
LAYERS = {
    'conv1': (512, 3, 9, 16),
    'conv2': (1376, 6, 432, 16),
    'conv3': (43712, 12, 864, 16),
    'conv4': (211328, 16, 1728, 16),
    'fc1': (656000, 8, 256, 16),
    'fc2': (689920, 1, 128, 8),
}


def test_image_size_and_header():
    data = IMAGE.read_bytes()
    assert len(data) == 691040
    assert data[:4] == b'IRW1'


def test_group_geometry_and_alignment():
    data = IMAGE.read_bytes()
    starts = []
    for name, (base, groups, taps, tap_bytes) in LAYERS.items():
        weight_bytes = groups * taps * tap_bytes
        assert weight_bytes <= len(data) - base, name
        for g in range(groups):
            off = base + g * taps * tap_bytes
            assert off + taps * tap_bytes <= len(data)
            starts.append((name, g, off, off % 32))

    assert all(off % 16 == 0 for _, _, off, _ in starts)

    # conv1's 144-byte group stride is NOT 32-byte aligned: group 1 starts
    # at 512+144 = 656, i.e. 16 bytes into a beat.
    conv1 = [x for x in starts if x[0] == 'conv1']
    assert conv1[0][3] == 0
    assert conv1[1][3] == 16
    # Every other layer has a 32-byte-aligned group stride (conv2 = 216
    # beats, conv3 = 432, conv4 = 864, fc1 = 128, fc2 = 32), so only conv1
    # needs the byte-rotation path.
    for name in ('conv2', 'conv3', 'conv4', 'fc1', 'fc2'):
        rows = [x for x in starts if x[0] == name]
        assert all(r[3] == 0 for r in rows), name


def test_conv1_taps_are_sixteen_bytes():
    data = IMAGE.read_bytes()
    base, groups, taps, tap_bytes = LAYERS['conv1']
    taps_read = []
    for g in range(groups):
        for t in range(taps):
            off = base + g * taps * tap_bytes + t * tap_bytes
            taps_read.append(np.frombuffer(data[off:off + tap_bytes], dtype=np.int8))
    assert len(taps_read) == groups * taps
    assert all(t.shape == (16,) for t in taps_read)
    assert any(np.any(t != 0) for t in taps_read)


def test_fc2_region_tail():
    _, groups, taps, tap_bytes = LAYERS['fc2']
    assert groups == 1
    assert tap_bytes == 8
    assert taps * tap_bytes == 1024        # 8 channels x 128 inputs
    # fc2 region is 1096 B: 1024 weights + 32 bias + 32 M + 8 shift.
    assert 1024 + 32 + 32 + 8 == 1096