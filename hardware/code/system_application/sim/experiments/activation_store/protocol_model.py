"""Row reorder and bounded DDR transactions, independent of vendor IP."""
import random


def canonical_offset(row, col, channel, width, channels):
    stride = ((width * channels + 31) // 32) * 32
    return row * stride + col * channels + channel


def verify(height, width, channels, seed):
    rng = random.Random(seed)
    stride = ((width * channels + 31) // 32) * 32
    ddr = bytearray(height * stride)
    expected = bytearray(height * width * channels)
    writes = reads = stalls = 0
    for row in range(height):
        bank = bytearray(stride)
        seen = set()
        for group in range(channels // 16):
            for col in range(width):
                for lane in range(16):
                    ch = group * 16 + lane
                    val = (row * 73 + col * 19 + ch * 7) & 255
                    off = col * channels + ch
                    assert off not in seen
                    seen.add(off)
                    bank[off] = val
                    expected[(row * width + col) * channels + ch] = val
        assert len(seen) == width * channels
        for beat in range(stride // 32):
            # Address and data may each stall; exactly one acceptance each.
            for _ in range(rng.randrange(8)):
                stalls += 1
            off = row * stride + beat * 32
            ddr[off:off + 32] = bank[beat * 32:beat * 32 + 32]
            writes += 1
    replay = bytearray()
    for row in range(height):
        # No request before whole-row credit; all accepted R beats have space.
        bank = bytearray(stride)
        reserved = stride
        for beat in range(stride // 32):
            assert reserved >= 32
            off = row * stride + beat * 32
            bank[beat * 32:beat * 32 + 32] = ddr[off:off + 32]
            reserved -= 32
            reads += 1
        assert reserved == 0
        replay.extend(bank[:width * channels])
    assert replay == expected
    return writes, reads, stalls


if __name__ == '__main__':
    for geom in [(32,129,48), (16,64,96), (8,32,192), (2,3,32)]:
        result = verify(*geom, seed=17)
        print('PASS', geom, 'writes/reads/stalls=', result)
