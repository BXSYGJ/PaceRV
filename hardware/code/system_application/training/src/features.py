from __future__ import annotations
import os
from pathlib import Path
from typing import Iterable, List, Optional, Union
import librosa
import numpy as np
SR: int = 44100
N_FFT: int = 2048
HOP_LENGTH: int = 512
WIN_LENGTH: int = 2048
N_MELS: int = 64
F_MIN: float = 0.0
F_MAX: float = 22050.0
WINDOW: str = 'hann'
N_FRAMES: int = 258
POWER: float = 2.0
PER_SAMPLE_NORM: bool = True
_NORM_EPS: float = 1e-06
_DB_REF: float = 1.0
_DB_AMIN: float = 1e-10
_DB_TOP_DB: Optional[float] = 80.0
FEATURE_SHAPE: tuple = (N_MELS, N_FRAMES)

def _load_audio(wav_path: Union[str, Path]) -> np.ndarray:
    y, _ = librosa.load(str(wav_path), sr=SR, mono=True, dtype=np.float32)
    return y

def _pad_or_truncate_frames(mel: np.ndarray, n_frames: int=N_FRAMES) -> np.ndarray:
    cur = mel.shape[1]
    if cur == n_frames:
        return mel
    if cur < n_frames:
        pad = n_frames - cur
        return np.pad(mel, ((0, 0), (0, pad)), mode='constant', constant_values=0.0)
    return mel[:, cur - n_frames:]

def _to_log_mel(S_power: np.ndarray) -> np.ndarray:
    return librosa.power_to_db(S_power, ref=np.max, amin=_DB_AMIN, top_db=_DB_TOP_DB).astype(np.float32)

def _per_sample_normalize(mel_db: np.ndarray) -> np.ndarray:
    mu = mel_db.mean()
    sigma = mel_db.std()
    return ((mel_db - mu) / (sigma + _NORM_EPS)).astype(np.float32)

def extract_mel_waveform(y: np.ndarray, normalize: bool=PER_SAMPLE_NORM, n_frames: int=N_FRAMES) -> np.ndarray:
    S = librosa.feature.melspectrogram(y=y, sr=SR, n_fft=N_FFT, hop_length=HOP_LENGTH, win_length=WIN_LENGTH, window=WINDOW, n_mels=N_MELS, fmin=F_MIN, fmax=F_MAX, power=POWER, center=True, pad_mode='reflect')
    mel_db = _to_log_mel(S)
    mel_db = _pad_or_truncate_frames(mel_db, n_frames)
    if normalize:
        mel_db = _per_sample_normalize(mel_db)
    return mel_db.astype(np.float32)

def extract_mel(wav_path: Union[str, Path], normalize: bool=PER_SAMPLE_NORM, n_frames: int=N_FRAMES) -> np.ndarray:
    y = _load_audio(wav_path)
    return extract_mel_waveform(y, normalize=normalize, n_frames=n_frames)

def extract_mel_batch(wav_paths: Iterable[Union[str, Path]], normalize: bool=PER_SAMPLE_NORM, n_frames: int=N_FRAMES) -> np.ndarray:
    paths = list(wav_paths)
    out = np.empty((len(paths), N_MELS, n_frames), dtype=np.float32)
    for i, p in enumerate(paths):
        out[i] = extract_mel(p, normalize=normalize, n_frames=n_frames)
    return out

class GlobalStandardizer:

    def __init__(self, mean: Optional[np.ndarray]=None, std: Optional[np.ndarray]=None):
        self.mean = mean
        self.std = std
        self._fitted = mean is not None and std is not None

    def fit(self, wav_paths: Iterable[Union[str, Path]], max_samples: Optional[int]=None) -> 'GlobalStandardizer':
        paths: List[Union[str, Path]] = list(wav_paths)
        if max_samples is not None and len(paths) > max_samples:
            rng = np.random.default_rng(42)
            idx = rng.choice(len(paths), size=max_samples, replace=False)
            paths = [paths[i] for i in idx]
        acc = np.zeros((N_MELS, N_FRAMES), dtype=np.float64)
        acc_sq = np.zeros((N_MELS, N_FRAMES), dtype=np.float64)
        n = 0
        for p in paths:
            feat = extract_mel(p, normalize=False)
            acc += feat
            acc_sq += feat.astype(np.float64) ** 2
            n += 1
        mean = acc / n
        var = acc_sq / n - mean ** 2
        var = np.maximum(var, _NORM_EPS)
        self.mean = mean.astype(np.float32)
        self.std = np.sqrt(var).astype(np.float32)
        self._fitted = True
        return self

    def transform(self, wav_path: Union[str, Path]) -> np.ndarray:
        if not self._fitted:
            raise RuntimeError('GlobalStandardizer 未 fit，请先调用 fit 或 load。')
        feat = extract_mel(wav_path, normalize=False)
        return ((feat - self.mean) / (self.std + _NORM_EPS)).astype(np.float32)

    def transform_array(self, feats: np.ndarray) -> np.ndarray:
        if not self._fitted:
            raise RuntimeError('GlobalStandardizer 未 fit。')
        return ((feats - self.mean) / (self.std + _NORM_EPS)).astype(np.float32)

    def save(self, path: Union[str, Path]) -> None:
        if not self._fitted:
            raise RuntimeError('未 fit，无内容可保存。')
        np.savez(str(path), mean=self.mean, std=self.std)

    @classmethod
    def load(cls, path: Union[str, Path]) -> 'GlobalStandardizer':
        data = np.load(str(path))
        return cls(mean=data['mean'], std=data['std'])

    def __repr__(self) -> str:
        if self._fitted:
            return f'GlobalStandardizer(fitted, mean={self.mean.mean():.4f}, std={self.std.mean():.4f})'
        return 'GlobalStandardizer(not fitted)'

def _self_check() -> None:
    print('=== Mel 特征管线参数 ===')
    print(f'SR={SR}, N_FFT={N_FFT}, HOP={HOP_LENGTH}, WIN={WIN_LENGTH}')
    print(f'N_MELS={N_MELS}, F_MIN={F_MIN}, F_MAX={F_MAX}, WINDOW={WINDOW}')
    print(f'N_FRAMES={N_FRAMES}, POWER={POWER}')
    print(f'FEATURE_SHAPE={FEATURE_SHAPE}')
    print(f'PER_SAMPLE_NORM={PER_SAMPLE_NORM}')
if __name__ == '__main__':
    _self_check()
