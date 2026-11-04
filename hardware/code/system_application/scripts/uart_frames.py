#!/usr/bin/env python3
"""UART layer-export frame parser (tasks.md T-M2-07, design.md 9.2).

Frame layout (all multi-byte fields little-endian):

    AA | layer_id[1] | seq[2] | len[2] | payload[len] | crc16[2]

    layer_id 0..8 selects the stage; bit 7 (0x80) marks sampled export
    (every 16th element of the full tensor).
    crc16 is CRC-16/CCITT-FALSE over layer_id, seq, len and payload.

The parser tolerates leading garbage, resynchronises on the next 0xAA and
drops frames with a bad CRC. reassemble() rebuilds a full tensor from the
per-seq payloads, leaving sampled slots as NaN so a comparison can mask
them.
"""

from __future__ import annotations

import numpy as np

SOF = 0xAA

LAYER_NAMES = {
    0: 'MEL_Q8_8',
    1: 'CONV1',
    2: 'CONV2',
    3: 'CONV3',
    4: 'CONV4',
    5: 'FC1',
    6: 'FC2_LOGITS',
    7: 'PROBS',
    8: 'STATS',
}

# Element dtype and logical shape per stage (design.md 9.2 / 4.4).
LAYER_DTYPES = {
    0: np.int16,
    1: np.uint8,
    2: np.uint8,
    3: np.uint8,
    4: np.uint8,
    5: np.uint8,
    6: np.int32,
    7: np.uint8,
    8: np.int32,
}

LAYER_SHAPES = {
    0: (64, 258),
    1: (48, 64, 258),
    2: (96, 32, 129),
    3: (192, 16, 64),
    4: (256, 8, 32),
    5: (128,),
    6: (8,),
    7: (8,),
    8: (8,),
}


def crc16_ccitt_false(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def build_frame(layer_id, seq, payload):
    body = bytes([layer_id]) + seq.to_bytes(2, 'little') + len(payload).to_bytes(2, 'little') + payload
    return bytes([SOF]) + body + crc16_ccitt_false(body).to_bytes(2, 'little')


def parse_frames(stream):
    """Return [(layer_id, seq, payload), ...] with bad frames dropped."""
    out = []
    i = 0
    n = len(stream)
    while i < n:
        if stream[i] != SOF:
            i += 1
            continue
        if i + 6 > n:
            break
        layer_id = stream[i + 1]
        seq = int.from_bytes(stream[i + 2:i + 4], 'little')
        ln = int.from_bytes(stream[i + 4:i + 6], 'little')
        end = i + 6 + ln + 2
        if end > n:
            break
        payload = stream[i + 6:i + 6 + ln]
        crc = int.from_bytes(stream[i + 6 + ln:end], 'little')
        body = stream[i + 1:i + 6 + ln]
        if crc16_ccitt_false(body) == crc:
            out.append((layer_id, seq, payload))
            i = end
        else:
            # Resynchronise on the next SOF instead of trusting the length.
            i += 1
    return out


def reassemble(frames, layer_id):
    """Rebuild one layer's tensor from its frames (sampled slots become NaN)."""
    base = layer_id & 0x7F
    sampled = bool(layer_id & 0x80)
    dtype = np.dtype(LAYER_DTYPES[base]).newbyteorder('<')
    shape = LAYER_SHAPES[base]
    total = int(np.prod(shape))

    chosen = [(seq, pay) for lid, seq, pay in frames if lid == layer_id]
    if not chosen:
        raise ValueError(f'no frames for layer 0x{layer_id:02x}')
    chosen.sort(key=lambda item: item[0])
    flat = b''.join(pay for _, pay in chosen)
    count = len(flat) // dtype.itemsize
    values = np.frombuffer(flat[:count * dtype.itemsize], dtype=dtype)

    if not sampled:
        return values[:total].reshape(shape)

    full = np.full(total, np.nan, dtype=np.float64)
    step = 16
    slots = min((total + step - 1) // step, len(values))
    full[:slots * step:step] = values[:slots].astype(np.float64)
    return full.reshape(shape)


def compare(frames, layer_id, reference):
    """Compare a reassembled layer against a reference tensor.

    Returns dict with coverage, exact/±1 LSB hit rates and max absolute
    delta; sampled slots (NaN) are excluded from the statistics.
    """
    got = reassemble(frames, layer_id)
    ref = np.asarray(reference)
    if got.shape != ref.shape:
        raise ValueError(f'shape mismatch {got.shape} vs {ref.shape}')
    mask = ~np.isnan(got) if got.dtype == np.float64 else np.ones(got.shape, bool)
    g = got[mask].astype(np.int64)
    r = ref[mask].astype(np.int64)
    delta = np.abs(g - r)
    return {
        'coverage': float(mask.sum()) / mask.size,
        'exact': float((delta == 0).mean()),
        'within_1lsb': float((delta <= 1).mean()),
        'max_abs_delta': int(delta.max()) if delta.size else 0,
    }