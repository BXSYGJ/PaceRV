#!/usr/bin/env python3
"""Upload the INT8 weight image to the board over UART (T-M2-01).

Wire protocol (PC -> FPGA), every field little-endian:

    SOF0=0xAA  SOF1=0x55 | seq[2] | len[2] | payload[len] | crc16[2]

    seq      0..N-1 chunk index; 0xFFFF marks the end-of-image frame
    len      1..256 payload bytes (0 for the end frame)
    crc16    CRC-16/CCITT-FALSE over seq, len and payload
             (poly 0x1021, init 0xFFFF, no reflection, xorout 0)

Board -> PC:
    'K' (0x4B)   chunk accepted
    'N' (0x4E)   chunk rejected, retransmit
    "WOK <8hex>\n"        final image checksum accepted
    "WERR @<hex> want <x> got <y>\n"  first mismatch

The PC waits for 'K' after each frame and retransmits on timeout. The image
size is padded to the payload boundary; padding bytes are part of the image
and therefore part of the final checksum.
"""

import argparse
import hashlib
import sys
import time

SOF = b'\xAA\x55'
END_SEQ = 0xFFFF
MAX_PAYLOAD = 256


def crc16_ccitt_false(data):
    """CRC-16/CCITT-FALSE (init 0xFFFF, poly 0x1021, no reflection)."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def build_frame(seq, payload):
    if seq == END_SEQ:
        if payload:
            raise ValueError('end frame must have an empty payload')
    elif not 1 <= len(payload) <= MAX_PAYLOAD:
        raise ValueError(f'payload must be 1..{MAX_PAYLOAD} bytes, got {len(payload)}')
    body = seq.to_bytes(2, 'little') + len(payload).to_bytes(2, 'little') + payload
    return SOF + body + crc16_ccitt_false(body).to_bytes(2, 'little')


def iter_frames(image, chunk=MAX_PAYLOAD):
    count = (len(image) + chunk - 1) // chunk
    for seq in range(count):
        yield seq, image[seq * chunk:(seq + 1) * chunk]
    yield END_SEQ, b''


class Uploader:
    def __init__(self, port, image, baud=115200, retries=3, timeout=0.5, progress=None):
        self.image = image
        self.port = port
        self.baud = baud
        self.retries = retries
        self.timeout = timeout
        self.progress = progress
        self.sent_frames = 0
        self.retransmits = 0

    def _wait_ack(self, deadline):
        while time.time() < deadline:
            byte = self.port.read(1)
            if not byte:
                continue
            if byte == b'K':
                return 'K'
            if byte == b'N':
                return 'N'
        return None

    def run(self):
        frames = list(iter_frames(self.image))
        data_frames = frames[:-1]          # last entry is the end frame
        total = len(data_frames)
        # The board is slow to drain its UART FIFO after a frame; the
        # timeout is per-frame and generous enough for 256 B at 115200.
        for index, (seq, payload) in enumerate(data_frames):
            frame = build_frame(seq, payload)
            attempts = 0
            while True:
                self.port.write(frame)
                self.port.flush()
                ack = self._wait_ack(time.time() + self.timeout)
                self.sent_frames += 1
                if ack == 'K':
                    break
                if ack == 'N' or ack is None:
                    self.retransmits += 1
                    attempts += 1
                    if attempts > self.retries:
                        raise RuntimeError(f'frame {index} (seq {seq}) not acknowledged')
            if self.progress:
                self.progress(index + 1, total)

        # End frame: wait for the terminal WOK/WERR line.
        self.port.write(build_frame(END_SEQ, b''))
        self.port.flush()
        deadline = time.time() + 5.0
        line = bytearray()
        while time.time() < deadline:
            data = self.port.read(64)
            if not data:
                continue
            line.extend(data)
            if b'\n' in line:
                break
        text = bytes(line).decode('ascii', 'replace').strip()
        return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='COM5')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--image', default='scripts/outputs/weights_image.bin')
    ap.add_argument('--chunk', type=int, default=MAX_PAYLOAD)
    ap.add_argument('--retries', type=int, default=3)
    ap.add_argument('--timeout', type=float, default=0.5)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    with open(args.image, 'rb') as fh:
        image = fh.read()
    print(f'image {args.image}: {len(image)} bytes, sha256 {hashlib.sha256(image).hexdigest()}')

    if args.dry_run:
        frames = list(iter_frames(image, args.chunk))
        print(f'frames: {len(frames)} (including end frame)')
        print(f'first frame: {build_frame(*frames[0])[:16].hex(" ")} ...')
        return 0

    try:
        import serial
    except ImportError:
        print('pyserial not installed: pip install pyserial', file=sys.stderr)
        return 2

    port = serial.Serial(args.port, args.baud, timeout=0.05)

    def show(done, total):
        if done % 64 == 0 or done == total:
            print(f'  {done}/{total} frames')

    try:
        text = Uploader(port, image, args.baud, args.retries, args.timeout, show).run()
    finally:
        port.close()

    print(f'board reply: {text}')
    ok = text.startswith('WOK')
    print('UPLOAD OK' if ok else 'UPLOAD FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())