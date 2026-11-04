"""Unit tests for weight_upload.py (tasks.md T-M2-01, PC-side protocol).

DoD coverage on the PC side:
  1. CRC-16/CCITT-FALSE matches the standard check vector.
  2. Frame layout/field order/size and the end-of-image frame.
  3. Chunking covers the whole image exactly once, in order.
  4. NAK/timeout triggers retransmit and the terminal WOK line is parsed.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import weight_upload as wu

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / 'scripts' / 'outputs' / 'weights_image.bin'


def test_crc16_ccitt_false_check_vector():
    # Standard CRC-16/CCITT-FALSE check value.
    assert wu.crc16_ccitt_false(b'123456789') == 0x29B1


def test_frame_layout_and_crc():
    payload = bytes(range(16))
    frame = wu.build_frame(7, payload)
    assert frame[:2] == b'\xAA\x55'
    assert frame[2:4] == (7).to_bytes(2, 'little')
    assert frame[4:6] == (16).to_bytes(2, 'little')
    assert frame[6:22] == payload
    body = frame[2:-2]
    assert frame[-2:] == wu.crc16_ccitt_false(body).to_bytes(2, 'little')
    assert len(frame) == 2 + 2 + 2 + len(payload) + 2


def test_end_frame_has_empty_payload():
    frame = wu.build_frame(wu.END_SEQ, b'')
    assert frame[2:4] == b'\xFF\xFF'
    assert frame[4:6] == b'\x00\x00'
    assert len(frame) == 8


def test_payload_size_is_bounded():
    try:
        wu.build_frame(0, b'x' * (wu.MAX_PAYLOAD + 1))
    except ValueError:
        pass
    else:
        raise AssertionError('oversized payload must be rejected')


def test_iter_frames_covers_image_once():
    image = bytes(range(256)) * 3 + b'abc'   # 771 bytes -> 4 chunks of 256/256/256/3
    frames = list(wu.iter_frames(image))
    assert [seq for seq, _ in frames] == [0, 1, 2, 3, wu.END_SEQ]
    rebuilt = b''.join(payload for seq, payload in frames[:-1])
    assert rebuilt == image


def test_real_image_chunk_count_and_hash():
    image = IMAGE.read_bytes()
    frames = list(wu.iter_frames(image))
    assert len(frames) == (len(image) + 255) // 256 + 1
    assert frames[-1][0] == wu.END_SEQ
    assert hashlib.sha256(image).hexdigest() == (
        '19a74dbec29d3a0f16ab06dc30f70312849977de0c6b345710b046b1908f5d7a')


class FakePort:
    """Mimics pyserial enough for Uploader.run()."""

    def __init__(self, ack_plan, final=b'WOK 19a74dbe\n'):
        self.ack_plan = list(ack_plan)
        self.final = final
        self.final_sent = False
        self.written = []

    def write(self, data):
        self.written.append(data)

    def flush(self):
        pass

    def read(self, size):
        if self.ack_plan:
            item = self.ack_plan.pop(0)
            return b'' if item is None else item.encode()
        if not self.final_sent:
            self.final_sent = True
            return self.final[:size]
        return b''


def test_nak_triggers_retransmit():
    image = bytes(512)
    # frame 0: NAK once then ACK; frame 1: ACK; end frame: no ACK needed.
    port = FakePort(['N', 'K', 'K'], final=b'WOK 19a74dbe\n')
    up = wu.Uploader(port, image, timeout=0.02, retries=3)
    text = up.run()
    assert text.startswith('WOK')
    assert up.retransmits == 1
    # 2 data frames plus the single retransmit; the end frame is not counted.
    assert up.sent_frames == 3


def test_timeout_raises_after_retries():
    image = bytes(256)
    port = FakePort([None] * 20, final=b'')
    up = wu.Uploader(port, image, timeout=0.01, retries=1)
    try:
        up.run()
    except RuntimeError:
        pass
    else:
        raise AssertionError('unacknowledged frame must abort after retries')