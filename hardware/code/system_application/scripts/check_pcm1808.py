"""Prepare independent integer FIR oracle and measure the designed filter."""
import hashlib
import json
from pathlib import Path
import numpy as np
from scipy.signal import freqz
from gen_pcm1808_filter import coefficients, ROOT


def reference(pairs, coeff):
    history = np.zeros((128, 2), dtype=np.int64)
    acc = 0
    result = []
    for n, pair in enumerate(pairs):
        history[n % 128] = pair
        acc += 147
        if acc >= 160:
            acc -= 160
            samples = history[(n - np.arange(96)) % 128]
            sums = (samples * coeff[acc, :, None]).sum(axis=0)
            # Python round uses ties-to-even, including negative values.
            result.append([max(-32768, min(32767, round(int(v) / 32768))) for v in sums])
    return np.array(result, dtype=np.int64)


def main():
    q = coefficients()
    rng = np.random.default_rng(1808)
    pairs = rng.integers(-32768, 32768, (2048, 2), dtype=np.int64)
    pairs[256:384] = [32767, -32768]
    pairs[512:640] = 0
    expected = reference(pairs, q)
    out = ROOT / 'build/sim/pcm1808'
    out.mkdir(parents=True, exist_ok=True)
    def dump(name, data):
        (out / name).write_text(''.join('%04x%04x\n' % (int(l)&65535, int(r)&65535) for l,r in data), encoding='ascii')
    dump('input.hex', pairs)
    dump('expected.hex', expected)
    pass_max = 0.0
    stop_max = -200.0
    for row in q:
        f, h = freqz(row / 32768, worN=16384, fs=48000)
        db = 20 * np.log10(np.maximum(abs(h), 1e-12))
        pass_max = max(pass_max, float(abs(db[f <= 18500]).max()))
        stop_max = max(stop_max, float(db[f >= 22050].max()))
    assert np.all(q.sum(axis=1) == 32768)
    assert pass_max < 0.1, pass_max
    assert stop_max < -50, stop_max
    # One nominal input second produces exactly 44100 output stereo frames.
    assert (48000 * 147) // 160 == 44100
    report = dict(input_rate=48000, output_rate=44100, phases=147, taps=96,
                  passband_0_to_18500_max_error_db=pass_max,
                  stopband_22050_to_24000_max_db=stop_max,
                  coefficient_sha256=hashlib.sha256(q.astype('<i2').tobytes()).hexdigest(),
                  serial_test_input_frames=len(pairs), golden_output_frames=len(expected),
                  rounding='half-even; signed saturation; 24-bit source high 16 bits')
    path = ROOT / 'reports/pcm1808_filter_20261103.json'
    path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
