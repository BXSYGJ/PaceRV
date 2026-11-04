from __future__ import annotations
import argparse
import json
import multiprocessing as mp
import sys
import time
from pathlib import Path
from typing import List, Tuple
import numpy as np
_ROOT = str(Path(__file__).resolve().parent.parent)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)
from src import dataset as D
from src import features as F
try:
    from tqdm import tqdm
except ImportError:
    tqdm = None

def _extract_one(task: Tuple[str, str, str, bool]) -> Tuple[str, bool, str]:
    uuid4, wav_path, cache_dir_str, force = task
    cache_path = Path(cache_dir_str) / f'{uuid4}.npy'
    if not force and cache_path.exists():
        return (uuid4, True, 'skip')
    try:
        feat = F.extract_mel(wav_path)
        np.save(cache_path, feat)
        return (uuid4, True, 'ok')
    except Exception as e:
        return (uuid4, False, str(e))

def build_cache(args: argparse.Namespace) -> None:
    cache_dir = Path(args.cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    print('=' * 70)
    print('Mel 特征预计算缓存')
    print('=' * 70)
    print(f'wav 目录:   {Path(args.wav_dir).resolve()}')
    print(f'CSV 路径:   {Path(args.csv_path).resolve()}')
    print(f'缓存目录:   {cache_dir.resolve()}')
    print(f'并行进程:   {args.num_workers}')
    print(f'强制重算:   {args.force}')
    print('-' * 70)
    print('[1/3] 加载元数据与文件索引...')
    meta = D.load_metadata(args.csv_path)
    file_index = D.build_file_index(meta, args.wav_dir)
    n_total = len(meta)
    print(f'  元数据样本数: {n_total}')
    print(f'  文件索引数:   {len(file_index)}')
    cache_dir_str = str(cache_dir)
    tasks: List[Tuple[str, str, str, bool]] = []
    n_skip = 0
    for uuid4 in meta['uuid4'].astype(str):
        wav_path = file_index[uuid4]
        cache_path = cache_dir / f'{uuid4}.npy'
        if not args.force and cache_path.exists():
            n_skip += 1
        tasks.append((uuid4, wav_path, cache_dir_str, args.force))
    n_todo = n_total - n_skip
    print(f'  已缓存（跳过）: {n_skip}')
    print(f'  待抽取:         {n_todo}')
    if n_todo == 0:
        print('  所有样本已缓存，无需抽取。')
        _print_cache_stats(cache_dir, n_total)
        if not args.no_pack:
            print('-' * 70)
            print('[打包] 合并为 memory-mapped 大数组...')
            pack_features(cache_dir, meta, force=args.force)
        print('=' * 70)
        return
    print(f'[2/3] 并行抽取特征（{args.num_workers} 进程）...')
    start_time = time.time()
    n_ok = 0
    n_fail = 0
    failed: List[Tuple[str, str]] = []
    if args.num_workers <= 1:
        iterator = (_extract_one(t) for t in tasks)
        if tqdm is not None:
            iterator = tqdm(iterator, total=n_total, desc='抽取', dynamic_ncols=True)
        for uuid4, success, msg in iterator:
            if success:
                n_ok += 1
            else:
                n_fail += 1
                failed.append((uuid4, msg))
    else:
        ctx = mp.get_context('spawn')
        with ctx.Pool(args.num_workers) as pool:
            results = pool.imap_unordered(_extract_one, tasks)
            if tqdm is not None:
                results = tqdm(results, total=n_total, desc='抽取', dynamic_ncols=True)
            for uuid4, success, msg in results:
                if success:
                    n_ok += 1
                else:
                    n_fail += 1
                    failed.append((uuid4, msg))
    elapsed = time.time() - start_time
    print(f'[3/3] 抽取完成')
    print('-' * 70)
    print(f'  成功: {n_ok}')
    print(f'  失败: {n_fail}')
    print(f'  耗时: {elapsed:.1f}s（{elapsed / 60:.1f} 分钟）')
    if n_todo > 0:
        print(f'  平均速度: {n_todo / elapsed:.1f} 样本/秒')
        print(f'  每样本: {elapsed / n_todo * 1000:.1f} ms')
    if failed:
        failed_path = cache_dir / '_failed.txt'
        with failed_path.open('w', encoding='utf-8') as f:
            for uuid4, msg in failed:
                f.write(f'{uuid4}\t{msg}\n')
        print(f'  失败列表已保存: {failed_path.resolve()}')
    _print_cache_stats(cache_dir, n_total)
    if not args.no_pack and n_fail == 0:
        print('-' * 70)
        print('[打包] 合并为 memory-mapped 大数组...')
        pack_features(cache_dir, meta, force=args.force)
    print('=' * 70)

def pack_features(cache_dir: Path, meta, force: bool=False) -> None:
    packed_path = cache_dir / 'all_features.npy'
    idx_path = cache_dir / 'uuid4_to_idx.json'
    if not force and packed_path.exists() and idx_path.exists():
        print('  打包文件已存在，跳过（用 --force 重新打包）')
        return
    uuids = meta['uuid4'].astype(str).tolist()
    n = len(uuids)
    print(f'  打包 {n} 个特征为大数组 (memmap)...')
    sample = np.load(cache_dir / f'{uuids[0]}.npy')
    feat_shape = sample.shape
    all_feats = np.empty((n, *feat_shape), dtype=np.float32)
    if tqdm is not None:
        uuid_iter = tqdm(uuids, desc='打包', dynamic_ncols=True)
    else:
        uuid_iter = uuids
    for i, uuid4 in enumerate(uuid_iter):
        all_feats[i] = np.load(cache_dir / f'{uuid4}.npy')
    np.save(packed_path, all_feats)
    uuid4_to_idx = {uuid4: i for i, uuid4 in enumerate(uuids)}
    with idx_path.open('w', encoding='utf-8') as f:
        json.dump(uuid4_to_idx, f)
    packed_size = packed_path.stat().st_size
    print(f'  打包完成: {packed_path.name}（{packed_size / 1024 ** 3:.2f} GB）')
    print(f'  索引映射: {idx_path.name}（{n} 条）')

def _print_cache_stats(cache_dir: Path, expected: int) -> None:
    n_cached = sum((1 for _ in cache_dir.glob('*.npy')))
    total_size = sum((f.stat().st_size for f in cache_dir.glob('*.npy')))
    print(f'  缓存文件数: {n_cached} / 期望 {expected}')
    print(f'  缓存总大小: {total_size / 1024 ** 3:.2f} GB')
    if n_cached == expected:
        print('  状态: 完整')
    else:
        print(f'  状态: *** 不完整（缺 {expected - n_cached} 个）***')

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Medley-solos-DB Mel 特征预计算缓存', formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument('--wav-dir', type=str, default='data/raw/medley_wav', help='wav 目录')
    parser.add_argument('--csv-path', type=str, default='Medley-solos-DB_metadata.csv', help='元数据 CSV 路径')
    parser.add_argument('--cache-dir', type=str, default='data/cache', help='缓存输出目录')
    parser.add_argument('--num-workers', type=int, default=4, help='并行进程数')
    parser.add_argument('--force', action='store_true', help='强制重新提取（忽略已有缓存）')
    parser.add_argument('--no-pack', action='store_true', help='跳过打包步骤（不合并为 memory-mapped 大数组）')
    return parser.parse_args()
if __name__ == '__main__':
    _args = parse_args()
    build_cache(_args)
