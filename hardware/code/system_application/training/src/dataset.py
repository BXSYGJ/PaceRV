from __future__ import annotations
import os
import re
from pathlib import Path
from typing import Callable, Dict, Optional, Tuple, Union
import numpy as np
import pandas as pd
import torch
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler
from . import features as F
INSTRUMENT_NAMES: Tuple[str, ...] = ('clarinet', 'distorted electric guitar', 'female singer', 'flute', 'piano', 'tenor saxophone', 'trumpet', 'violin')
NUM_CLASSES: int = len(INSTRUMENT_NAMES)
VALID_SUBSETS: Tuple[str, ...] = ('training', 'validation', 'test')
_FILENAME_RE = re.compile('^Medley-solos-DB_(?P<subset>[a-z]+)-(?P<instrument_id>\\d+)_(?P<uuid4>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\.wav\\.wav$')

def load_metadata(csv_path: Union[str, Path]) -> pd.DataFrame:
    meta = pd.read_csv(str(csv_path))
    expected = {'subset', 'instrument', 'instrument_id', 'track_id', 'uuid4'}
    missing = expected - set(meta.columns)
    if missing:
        raise ValueError(f'元数据缺少列: {missing}，实际列: {list(meta.columns)}')
    meta['instrument_id'] = meta['instrument_id'].astype(np.int64)
    meta['track_id'] = meta['track_id'].astype(np.int64)
    return meta

def build_file_index(meta: pd.DataFrame, wav_dir: Union[str, Path]) -> Dict[str, str]:
    wav_dir = str(wav_dir)
    index: Dict[str, str] = {}
    for fname in os.listdir(wav_dir):
        m = _FILENAME_RE.match(fname)
        if not m:
            continue
        index[m.group('uuid4')] = os.path.join(wav_dir, fname)
    meta_uuids = set(meta['uuid4'].astype(str))
    missing = meta_uuids - set(index.keys())
    if missing:
        raise FileNotFoundError(f'元数据中 {len(missing)} 个 uuid4 在 wav_dir 找不到对应文件，例如: {sorted(missing)[:3]}')
    extra = set(index.keys()) - meta_uuids
    if extra:
        print(f'[warn] wav_dir 中有 {len(extra)} 个文件不在元数据中（已忽略）')
    return index

def compute_class_counts(meta: pd.DataFrame, subset: Optional[str]=None) -> Dict[int, int]:
    df = meta if subset is None else meta[meta['subset'] == subset]
    counts = df.groupby('instrument_id').size().to_dict()
    return {int(k): int(v) for k, v in counts.items()}

def compute_class_weights(meta: pd.DataFrame, subset: Optional[str]=None, normalize: bool=True) -> torch.Tensor:
    counts = compute_class_counts(meta, subset)
    n_total = sum(counts.values())
    weights = np.zeros(NUM_CLASSES, dtype=np.float32)
    for cid in range(NUM_CLASSES):
        n_c = counts.get(cid, 0)
        if n_c == 0:
            weights[cid] = 0.0
        else:
            weights[cid] = n_total / (NUM_CLASSES * n_c)
    if normalize and weights.sum() > 0:
        weights = weights * (NUM_CLASSES / weights.sum())
    return torch.from_numpy(weights)

def check_no_leakage(meta: pd.DataFrame, verbose: bool=True) -> bool:
    subsets = list(VALID_SUBSETS)
    tracks = {s: set(meta.loc[meta['subset'] == s, 'track_id'].astype(int).unique()) for s in subsets}
    if verbose:
        print('=' * 60)
        print('防泄漏校验：track_id 跨 subset 重叠分析')
        print('=' * 60)
        for s in subsets:
            print(f'  {s:10s}: {len(tracks[s]):4d} 个 track_id')
    ok = True
    for i in range(len(subsets)):
        for j in range(i + 1, len(subsets)):
            s1, s2 = (subsets[i], subsets[j])
            inter = tracks[s1] & tracks[s2]
            if verbose:
                status = 'OK' if not inter else 'LEAK'
                print(f'  {s1} ∩ {s2}: {len(inter):4d} 重叠  [{status}]')
                if inter:
                    print(f'    重叠 track_id 样例: {sorted(inter)[:10]}')
            if inter:
                ok = False
    union = set().union(*tracks.values())
    if verbose:
        print(f'  track_id 总数 (并集): {len(union)}')
        print(f'  各 subset track_id 数之和: {sum((len(t) for t in tracks.values()))}')
        if ok:
            print('  => 校验通过：无标签泄漏')
        else:
            print('  => 校验失败：存在 track_id 跨 subset 重叠，存在泄漏风险！')
        print('=' * 60)
    return ok

class MedleyDataset(Dataset):

    def __init__(self, subset: str, wav_dir: Union[str, Path], csv_path: Union[str, Path], transform: Optional[Callable[[Union[str, Path]], np.ndarray]]=None, file_index: Optional[Dict[str, str]]=None, return_meta: bool=True):
        if subset not in VALID_SUBSETS:
            raise ValueError(f'subset 必须是 {VALID_SUBSETS}，得到 {subset!r}')
        self.subset = subset
        self.wav_dir = str(wav_dir)
        self.transform = transform if transform is not None else F.extract_mel
        self.return_meta = return_meta
        meta = load_metadata(csv_path)
        self._meta_full = meta
        self.meta = meta[meta['subset'] == subset].reset_index(drop=True)
        if file_index is None:
            file_index = build_file_index(meta, wav_dir)
        self.file_index = file_index
        if len(self.meta) == 0:
            raise RuntimeError(f'subset={subset!r} 在元数据中无样本')

    def __len__(self) -> int:
        return len(self.meta)

    def __getitem__(self, idx: int) -> Union[Tuple[torch.Tensor, int, Dict], Tuple[torch.Tensor, int]]:
        row = self.meta.iloc[idx]
        uuid4 = str(row['uuid4'])
        wav_path = self.file_index[uuid4]
        label = int(row['instrument_id'])
        feat = self.transform(wav_path)
        if feat.ndim != 2 or feat.shape != (F.N_MELS, F.N_FRAMES):
            raise ValueError(f'特征形状错误: 期望 {(F.N_MELS, F.N_FRAMES)}，得到 {feat.shape}')
        feat_t = torch.from_numpy(np.ascontiguousarray(feat)).unsqueeze(0).float()
        if self.return_meta:
            meta_dict = {'uuid4': uuid4, 'track_id': int(row['track_id']), 'instrument': str(row['instrument']), 'instrument_id': label, 'subset': self.subset, 'wav_path': wav_path}
            return (feat_t, label, meta_dict)
        return (feat_t, label)

    def get_labels(self) -> np.ndarray:
        return self.meta['instrument_id'].to_numpy(dtype=np.int64)

def get_dataloaders(wav_dir: Union[str, Path], csv_path: Union[str, Path], batch_size: int=32, num_workers: int=0, weighted_sampling: bool=False, transform: Optional[Callable[[Union[str, Path]], np.ndarray]]=None, pin_memory: bool=False) -> Tuple[DataLoader, DataLoader, DataLoader, Dict[str, MedleyDataset]]:
    meta = load_metadata(csv_path)
    file_index = build_file_index(meta, wav_dir)
    datasets: Dict[str, MedleyDataset] = {}
    loaders: Dict[str, DataLoader] = {}
    for subset in VALID_SUBSETS:
        ds = MedleyDataset(subset=subset, wav_dir=wav_dir, csv_path=csv_path, transform=transform, file_index=file_index)
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
    import sys
    csv_path = sys.argv[1] if len(sys.argv) > 1 else 'Medley-solos-DB_metadata.csv'
    wav_dir = sys.argv[2] if len(sys.argv) > 2 else 'data/raw/medley_wav'
    meta = load_metadata(csv_path)
    print(f'元数据: {len(meta)} 行')
    print(f'类别名: {INSTRUMENT_NAMES}')
    for s in VALID_SUBSETS:
        print(f'  {s}: {compute_class_counts(meta, s)}')
    check_no_leakage(meta)
