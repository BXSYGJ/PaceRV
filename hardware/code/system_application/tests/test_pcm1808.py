"""PCM1808 contract: exact rate, signal preservation and anti-aliasing."""
import sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from gen_pcm1808_filter import coefficients
from check_pcm1808 import reference


def test_one_second_count_and_dc_gain():
    q = coefficients()
    assert (q.sum(axis=1) == 32768).all()
    result = reference(np.tile([12345, -23456], (48000, 1)), q)
    assert result.shape == (44100, 2)
    assert (result[100:] == [12345, -23456]).all()


def test_actual_resampled_tones_and_alias_suppression():
    q = coefficients()
    n = np.arange(9600)
    pairs = np.column_stack((np.rint(12000*np.sin(2*np.pi*1000*n/48000)),
                             np.rint(12000*np.sin(2*np.pi*22500*n/48000)))).astype(np.int64)
    result = reference(pairs, q)[200:]
    rms = np.sqrt((result.astype(float)**2).mean(axis=0))
    assert abs(rms[0] / (12000/np.sqrt(2)) - 1) < 0.002
    assert rms[1] < 5
    # Fit the actual output to a 1 kHz tone on the model's 44.1 kHz axis.
    t = np.arange(len(result)) / 44100
    basis = np.column_stack((np.sin(2*np.pi*1000*t), np.cos(2*np.pi*1000*t)))
    residual = result[:,0] - basis @ np.linalg.lstsq(basis, result[:,0], rcond=None)[0]
    assert 20*np.log10(rms[0] / np.sqrt((residual**2).mean())) > 75


def test_generated_rom_matches_coefficient_asset():
    import re
    text = (Path(__file__).resolve().parents[1] / 'src/audio/pcm1808_coeff_rom.v').read_text()
    words = re.findall(r"13'd(\d+): base_coeff <= 16'h([0-9a-f]{4})", text)
    assert len(words) == 74*96
    q = coefficients()
    for (addr, word), value in zip(words, q[:74].flat):
        assert int(word,16) == (int(value)&65535)
    assert [int(addr) for addr,_ in words] == list(range(74*96))
    corrections = re.findall(r"8'd(\d+): correction = 5'h([0-9a-f]{2})", text)
    assert len(corrections) == 73
    for phase, encoded in corrections:
        phase, correction = int(phase), int(encoded, 16)
        if correction >= 16:
            correction -= 32
        restored = q[147-phase, ::-1].copy()
        restored[47] += correction
        restored[48] -= correction
        assert np.array_equal(restored, q[phase])
