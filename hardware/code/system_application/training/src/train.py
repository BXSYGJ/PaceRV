from __future__ import annotations
import argparse
import json
import os
import random
import sys
import time
from pathlib import Path
from typing import Dict, Optional, Tuple
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.cuda.amp import GradScaler, autocast
from torch.utils.data import DataLoader, Subset
_ROOT = str(Path(__file__).resolve().parent.parent)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)
from src import dataset as D
from src import model as M
from src.dataset import NUM_CLASSES
try:
    from tqdm import tqdm
except ImportError:
    tqdm = None

def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False

def train_one_epoch(model: nn.Module, loader, criterion: nn.Module, optimizer: torch.optim.Optimizer, device: torch.device, scaler: GradScaler, use_amp: bool, epoch: int, total_epochs: int) -> Tuple[float, float]:
    model.train()
    running_loss = 0.0
    correct = 0
    total = 0
    iterator = loader
    if tqdm is not None:
        iterator = tqdm(loader, desc=f'Train Epoch {epoch + 1:3d}/{total_epochs}', leave=False, dynamic_ncols=True)
    for batch in iterator:
        features, labels = (batch[0], batch[1])
        features = features.to(device, non_blocking=True)
        labels = labels.to(device, non_blocking=True)
        optimizer.zero_grad(set_to_none=True)
        if use_amp:
            with autocast():
                outputs = model(features)
                loss = criterion(outputs, labels)
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
        else:
            outputs = model(features)
            loss = criterion(outputs, labels)
            loss.backward()
            optimizer.step()
        running_loss += loss.item() * features.size(0)
        preds = outputs.argmax(dim=1)
        correct += (preds == labels).sum().item()
        total += labels.size(0)
    avg_loss = running_loss / max(total, 1)
    accuracy = correct / max(total, 1)
    return (avg_loss, accuracy)

@torch.no_grad()
def evaluate(model: nn.Module, loader, criterion: nn.Module, device: torch.device, use_amp: bool, desc: str='Eval') -> Tuple[float, float]:
    model.eval()
    running_loss = 0.0
    correct = 0
    total = 0
    iterator = loader
    if tqdm is not None:
        iterator = tqdm(loader, desc=desc, leave=False, dynamic_ncols=True)
    for batch in iterator:
        features, labels = (batch[0], batch[1])
        features = features.to(device, non_blocking=True)
        labels = labels.to(device, non_blocking=True)
        if use_amp:
            with autocast():
                outputs = model(features)
                loss = criterion(outputs, labels)
        else:
            outputs = model(features)
            loss = criterion(outputs, labels)
        running_loss += loss.item() * features.size(0)
        preds = outputs.argmax(dim=1)
        correct += (preds == labels).sum().item()
        total += labels.size(0)
    avg_loss = running_loss / max(total, 1)
    accuracy = correct / max(total, 1)
    return (avg_loss, accuracy)

def train(args: argparse.Namespace) -> None:
    set_seed(args.seed)
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    use_amp = not args.no_amp and torch.cuda.is_available()
    if use_amp and device.type == 'cuda':
        cap = torch.cuda.get_device_capability(0)
        if cap[0] < 7:
            use_amp = False
            print(f'[警告] GPU {torch.cuda.get_device_name(0)} 为 Pascal 架构（compute capability {cap[0]}.{cap[1]}），无 Tensor Core，自动禁用混合精度（AMP 在 Pascal 上反而降速）。可用 --no-amp 显式指定。')
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    metrics_path = output_dir / 'metrics.jsonl'
    best_ckpt_path = output_dir / 'best_model.pt'
    config_path = output_dir / 'train_config.json'
    print('=' * 70)
    print('Medley-solos-DB 乐器识别 CNN 训练')
    print('=' * 70)
    print(f'设备: {device}')
    if device.type == 'cuda':
        print(f'GPU: {torch.cuda.get_device_name(0)}')
        print(f'显存: {torch.cuda.get_device_properties(0).total_memory / 1024 ** 3:.2f} GB')
    print(f'混合精度: {('启用' if use_amp else '禁用')}')
    print(f'epochs={args.epochs}, batch_size={args.batch_size}, lr={args.lr}')
    print(f'num_workers={args.num_workers}, seed={args.seed}')
    print(f'输出目录: {output_dir.resolve()}')
    print('-' * 70)
    print('[1/4] 加载数据...')
    use_cache = not args.no_cache
    cache_dir = Path(args.cache_dir)
    if use_cache and cache_dir.exists():
        from src.cached_dataset import get_cached_dataloaders
        train_loader, val_loader, test_loader, datasets = get_cached_dataloaders(cache_dir=args.cache_dir, csv_path=args.csv_path, wav_dir=args.data_dir, batch_size=args.batch_size, num_workers=args.num_workers, weighted_sampling=True, pin_memory=device.type == 'cuda', enable_augment=False)
        print(f'  使用缓存特征: {cache_dir.resolve()}')
    else:
        train_loader, val_loader, test_loader, datasets = D.get_dataloaders(wav_dir=args.data_dir, csv_path=args.csv_path, batch_size=args.batch_size, num_workers=args.num_workers, weighted_sampling=True, transform=None, pin_memory=device.type == 'cuda')
        if use_cache:
            print(f'  [警告] 缓存目录 {cache_dir} 不存在，回退到实时特征抽取')
        else:
            print('  实时特征抽取（未使用缓存）')
    meta = D.load_metadata(args.csv_path)
    n_train = len(datasets['training'])
    n_val = len(datasets['validation'])
    n_test = len(datasets['test'])
    print(f'  训练集: {n_train} 样本')
    print(f'  验证集: {n_val} 样本')
    print(f'  测试集: {n_test} 样本')
    pin_mem = device.type == 'cuda'
    if args.limit_train > 0 and args.limit_train < n_train:
        idx = list(range(args.limit_train))
        train_loader = DataLoader(Subset(datasets['training'], idx), batch_size=args.batch_size, shuffle=True, num_workers=args.num_workers, pin_memory=pin_mem, drop_last=False)
        print(f'  [限制] 训练集截断为前 {args.limit_train} 样本')
    if args.limit_val > 0 and args.limit_val < n_val:
        idx = list(range(args.limit_val))
        val_loader = DataLoader(Subset(datasets['validation'], idx), batch_size=args.batch_size, shuffle=False, num_workers=args.num_workers, pin_memory=pin_mem, drop_last=False)
        print(f'  [限制] 验证集截断为前 {args.limit_val} 样本')
    if args.limit_test > 0 and args.limit_test < n_test:
        idx = list(range(args.limit_test))
        test_loader = DataLoader(Subset(datasets['test'], idx), batch_size=args.batch_size, shuffle=False, num_workers=args.num_workers, pin_memory=pin_mem, drop_last=False)
        print(f'  [限制] 测试集截断为前 {args.limit_test} 样本')
    base_weights = D.compute_class_weights(meta, subset='training', normalize=False)
    class_weights = base_weights ** args.weight_power
    if float(class_weights.sum()) > 0:
        class_weights = class_weights * (NUM_CLASSES / class_weights.sum())
    print(f'  类别权重(power={args.weight_power}): {[round(float(w), 4) for w in class_weights.tolist()]}')
    print('[2/4] 构建模型...')
    net = M.InstrumentCNN(num_classes=NUM_CLASSES)
    net = net.to(device)
    n_params = M.count_parameters(net)
    print(f'  模型: {net.__class__.__name__}')
    print(f'  参数量: {n_params:,d}（约 {n_params / 1000000.0:.3f} M）')
    criterion = nn.CrossEntropyLoss(weight=class_weights.to(device))
    optimizer = torch.optim.Adam(net.parameters(), lr=args.lr, weight_decay=0.0001)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs, eta_min=1e-05)
    scaler = GradScaler(enabled=use_amp)
    print('[3/4] 开始训练...')
    best_val_acc = 0.0
    best_epoch = -1
    patience = args.patience
    no_improve = 0
    epoch_times = []
    metrics_path.write_text('', encoding='utf-8')
    for epoch in range(args.epochs):
        epoch_start = time.time()
        train_loss, train_acc = train_one_epoch(net, train_loader, criterion, optimizer, device, scaler, use_amp, epoch, args.epochs)
        val_loss, val_acc = evaluate(net, val_loader, criterion, device, use_amp, desc=f'Val   Epoch {epoch + 1:3d}/{args.epochs}')
        scheduler.step()
        epoch_time = time.time() - epoch_start
        epoch_times.append(epoch_time)
        metrics = {'epoch': epoch + 1, 'train_loss': float(train_loss), 'train_acc': float(train_acc), 'val_loss': float(val_loss), 'val_acc': float(val_acc), 'lr': float(optimizer.param_groups[0]['lr']), 'epoch_time_sec': float(epoch_time)}
        with metrics_path.open('a', encoding='utf-8') as f:
            f.write(json.dumps(metrics, ensure_ascii=False) + '\n')
        print(f'  Epoch {epoch + 1:3d}/{args.epochs} | train_loss={train_loss:.4f} train_acc={train_acc:.4f} | val_loss={val_loss:.4f} val_acc={val_acc:.4f} | lr={optimizer.param_groups[0]['lr']:.2e} | 耗时={epoch_time:.1f}s')
        if val_acc > best_val_acc:
            best_val_acc = val_acc
            best_epoch = epoch + 1
            no_improve = 0
            torch.save({'epoch': epoch + 1, 'model_state_dict': net.state_dict(), 'optimizer_state_dict': optimizer.state_dict(), 'scheduler_state_dict': scheduler.state_dict(), 'best_val_acc': float(best_val_acc), 'val_acc': float(val_acc), 'val_loss': float(val_loss)}, best_ckpt_path)
            print(f'    -> 新最佳 val_acc={best_val_acc:.4f}，已保存 {best_ckpt_path.name}')
        else:
            no_improve += 1
        if no_improve >= patience:
            print(f'  早停：val_acc 连续 {patience} epoch 未提升，停止训练')
            break
    print('[4/4] 训练完成')
    total_time = sum(epoch_times)
    avg_epoch_time = total_time / max(len(epoch_times), 1)
    if best_ckpt_path.exists():
        ckpt = torch.load(best_ckpt_path, map_location=device)
        net.load_state_dict(ckpt['model_state_dict'])
        print(f'  已加载最佳 checkpoint（epoch={ckpt['epoch']}）')
    test_loss, test_acc = evaluate(net, test_loader, criterion, device, use_amp, desc='Test')
    print('=' * 70)
    print('训练总结')
    print('=' * 70)
    print(f'  最佳 epoch:       {best_epoch}')
    print(f'  最佳 val_acc:     {best_val_acc:.4f}')
    print(f'  测试 loss:        {test_loss:.4f}')
    print(f'  测试 acc:         {test_acc:.4f}')
    print(f'  总训练时间:       {total_time:.1f}s')
    print(f'  平均 epoch 耗时:  {avg_epoch_time:.1f}s')
    print(f'  实际运行 epoch 数: {len(epoch_times)}')
    print('=' * 70)
    config = {'epochs': args.epochs, 'batch_size': args.batch_size, 'lr': args.lr, 'num_workers': args.num_workers, 'data_dir': str(args.data_dir), 'csv_path': str(args.csv_path), 'output_dir': str(args.output_dir), 'seed': args.seed, 'use_amp': use_amp, 'device': str(device), 'model': 'InstrumentCNN', 'num_classes': NUM_CLASSES, 'n_params': n_params, 'n_train': n_train, 'n_val': n_val, 'n_test': n_test, 'class_weights': class_weights.tolist(), 'best_epoch': best_epoch, 'best_val_acc': float(best_val_acc), 'test_loss': float(test_loss), 'test_acc': float(test_acc), 'total_time_sec': float(total_time), 'avg_epoch_time_sec': float(avg_epoch_time), 'ran_epochs': len(epoch_times), 'optimizer': 'Adam(weight_decay=1e-4)', 'scheduler': f'CosineAnnealingLR(T_max={args.epochs}, eta_min=1e-5)', 'criterion': 'CrossEntropyLoss(weight=class_weights)', 'weight_power': args.weight_power, 'specaugment': False, 'weighted_sampling': True, 'early_stopping_patience': args.patience, 'use_cache': use_cache and cache_dir.exists(), 'cache_dir': str(args.cache_dir) if use_cache else None}
    with config_path.open('w', encoding='utf-8') as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
    print(f'训练配置已保存: {config_path.resolve()}')

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Medley-solos-DB 乐器识别 CNN 训练脚本', formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument('--epochs', type=int, default=50, help='训练 epoch 数')
    parser.add_argument('--batch-size', type=int, default=64, help='batch size')
    parser.add_argument('--lr', type=float, default=0.001, help='初始学习率')
    parser.add_argument('--patience', type=int, default=15, help='早停 patience（val_acc 连续 N epoch 不提升则停）')
    parser.add_argument('--weight-power', type=float, default=1.0, help='类别权重加幂 p（w=(N/(C*n))^p；p=1 标准逆频率，p=0.5 平方根，p>1 强化少数类）')
    parser.add_argument('--num-workers', type=int, default=0, help='DataLoader 工作进程数（缓存模式建议 0，实时抽取建议 2）')
    parser.add_argument('--data-dir', type=str, default='data/raw/medley_wav', help='wav 目录')
    parser.add_argument('--csv-path', type=str, default='Medley-solos-DB_metadata.csv', help='元数据 CSV 路径')
    parser.add_argument('--output-dir', type=str, default='runs', help='输出目录（checkpoint / metrics / config）')
    parser.add_argument('--seed', type=int, default=42, help='随机种子')
    parser.add_argument('--no-amp', action='store_true', help='禁用混合精度训练')
    parser.add_argument('--limit-train', type=int, default=0, help='限制训练集样本数（0=不限制，冒烟测试用）')
    parser.add_argument('--limit-val', type=int, default=0, help='限制验证集样本数（0=不限制，冒烟测试用）')
    parser.add_argument('--limit-test', type=int, default=0, help='限制测试集样本数（0=不限制，冒烟测试用）')
    parser.add_argument('--cache-dir', type=str, default='data/cache', help='预计算特征缓存目录')
    parser.add_argument('--no-cache', action='store_true', help='禁用缓存，使用实时特征抽取（慢）')
    return parser.parse_args()
if __name__ == '__main__':
    _args = parse_args()
    train(_args)
