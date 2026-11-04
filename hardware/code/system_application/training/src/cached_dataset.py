from __future__ import annotations
import json
from pathlib import Path
from typing import Callable, Dict, Optional, Tuple, Union
import numpy as np
import pandas as pd
import torch
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler
import sys
_ROOT = str(Path(__file__).resolve().parent.parent)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)
from src import dataset as D
from src.dataset import NUM_CLASSES, VALID_SUBSETS, build_file_index, compute_class_weights, load_metadata

class CachedMedleyDataset(Dataset):

    def __init__(self, subset: str, cache_dir: Union[str, Path], csv_path: Union[str, Path], file_index: Optional[Dict[str, str]]=None, return_meta: bool=True, enable_augment: Optional[bool]=None, freq_mask_max: int=8, time_mask_max: int=20):
        if subset not in VALID_SUBSETS:
            raise ValueError(f'subset 必须是 {VALID_SUBSETS}，得到 {subset!r}')
        self.subset = subset
        self.cache_dir = Path(cache_dir)
        self.return_meta = return_meta
        self.enable_augment = subset == 'training' and bool(enable_augment)
        self.freq_mask_max = int(freq_mask_max)
        self.time_mask_max = int(time_mask_max)
        meta = load_metadata(csv_path)
        self._meta_full = meta
        self.meta = meta[meta['subset'] == subset].reset_index(drop=True)
        self.file_index = file_index
        if len(self.meta) == 0:
            raise RuntimeError(f'subset={subset!r} 在元数据中无样本')
        self._uuid4s = self.meta['uuid4'].astype(str).to_numpy()
        self._labels = self.meta['instrument_id'].to_numpy(dtype=np.int64)
        if return_meta:
            self._track_ids = self.meta['track_id'].to_numpy(dtype=np.int64)
            self._instruments = self.meta['instrument'].astype(str).to_numpy()
        self._memmap = None
        self._row_indices = None
        packed_path = self.cache_dir / 'all_features.npy'
        idx_path = self.cache_dir / 'uuid4_to_idx.json'
        if packed_path.exists() and idx_path.exists():
            with idx_path.open('r', encoding='utf-8') as f:
                uuid4_to_idx = json.load(f)
            self._row_indices = np.array([uuid4_to_idx[u] for u in self._uuid4s], dtype=np.int64)
            self._memmap = np.load(str(packed_path), mmap_mode='r')
        else:
            self._check_cache()

    def _check_cache(self) -> None:
        for i in range(min(3, len(self._uuid4s))):
            cache_path = self.cache_dir / f'{self._uuid4s[i]}.npy'
            if not cache_path.exists():
                raise FileNotFoundError(f'缓存文件不存在: {cache_path}。请先运行 `python src/cache_features.py` 预计算特征。')

    def __len__(self) -> int:
        return len(self.meta)

    def __getitem__(self, idx: int) -> Union[Tuple[torch.Tensor, int, Dict], Tuple[torch.Tensor, int]]:
        label = int(self._labels[idx])
        if self._memmap is not None:
            row = int(self._row_indices[idx])
            feat = np.asarray(self._memmap[row], dtype=np.float32)
        else:
            cache_path = self.cache_dir / f'{self._uuid4s[idx]}.npy'
            feat = np.load(cache_path)
        if self.enable_augment:
            feat = self._specaugment(feat)
        if not feat.flags.writeable:
            feat = feat.copy()
        feat_t = torch.from_numpy(np.ascontiguousarray(feat)).unsqueeze(0).float()
        if self.return_meta:
            meta_dict = {'uuid4': str(self._uuid4s[idx]), 'track_id': int(self._track_ids[idx]), 'instrument': str(self._instruments[idx]), 'instrument_id': label, 'subset': self.subset}
            return (feat_t, label, meta_dict)
        return (feat_t, label)

    def _specaugment(self, feat: np.ndarray) -> np.ndarray:
        n_mels, n_frames = feat.shape
        masked = feat.copy()
        n_freq_masks = int(np.random.randint(1, 3))
        for _ in range(n_freq_masks):
            w = int(np.random.randint(0, self.freq_mask_max + 1))
            if w == 0:
                continue
            f0 = int(np.random.randint(0, n_mels - w + 1))
            masked[f0:f0 + w, :] = 0.0
        n_time_masks = int(np.random.randint(1, 3))
        for _ in range(n_time_masks):
            w = int(np.random.randint(0, self.time_mask_max + 1))
            if w == 0:
                continue
            t0 = int(np.random.randint(0, n_frames - w + 1))
            masked[:, t0:t0 + w] = 0.0
        return masked

    def get_labels(self) -> np.ndarray:
        return self._labels

def get_cached_dataloaders(cache_dir: Union[str, Path], csv_path: Union[str, Path], wav_dir: Optional[Union[str, Path]]=None, batch_size: int=64, num_workers: int=2, weighted_sampling: bool=False, pin_memory: bool=True, enable_augment: Optional[bool]=None) -> Tuple[DataLoader, DataLoader, DataLoader, Dict[str, CachedMedleyDataset]]:
    meta = load_metadata(csv_path)
    D.check_no_leakage(meta)
    file_index = build_file_index(meta, wav_dir) if wav_dir else None
    datasets: Dict[str, CachedMedleyDataset] = {}
    loaders: Dict[str, DataLoader] = {}
    for subset in VALID_SUBSETS:
        ds = CachedMedleyDataset(subset=subset, cache_dir=cache_dir, csv_path=csv_path, file_index=file_index, enable_augment=enable_augment)
        datasets[subset] = ds
        if subset == 'training' and weighted_sampling:
            class_weights = compute_class_weights(meta, subset=subset, normalize=True)
            labels = ds.get_labels()
            sample_weights = class_weights[torch.from_numpy(labels)].numpy()
            sampler = WeightedRandomSampler(weights=sample_weights, num_samples=len(sample_weights), replacement=True)
            loader = DataLoader(ds, batch_size=batch_size, sampler=sampler, num_workers=num_workers, pin_memory=pin_memory, drop_last=False)
        else:
            shuffle = subset == 'training' and (not weighted_sampling)
            loader = DataLoader(ds, batch_size=batch_size, shuffle=shuffle, num_workers=num_workers, pin_memory=pin_memory, drop_last=False)
        loaders[subset] = loader
    return (loaders['training'], loaders['validation'], loaders['test'], datasets)
if __name__ == '__main__':
    import sys as _sys
    _csv = _sys.argv[1] if len(_sys.argv) > 1 else 'Medley-solos-DB_metadata.csv'
    _cache = _sys.argv[2] if len(_sys.argv) > 2 else 'data/cache'
    print(f'缓存目录: {_cache}')
    print(f'CSV 路径: {_csv}')
    if not Path(_cache).exists():
        print(f'缓存目录不存在，请先运行 cache_features.py')
        _sys.exit(1)
    n_cached = sum((1 for _ in Path(_cache).glob('*.npy')))
    print(f'缓存文件数: {n_cached}')
    meta = load_metadata(_csv)
    print(f'元数据样本数: {len(meta)}')
    for s in VALID_SUBSETS:
        n = len(meta[meta['subset'] == s])
        print(f'  {s}: {n} 样本')
