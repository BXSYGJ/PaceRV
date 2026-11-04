from __future__ import annotations
import argparse
import json
import time
from pathlib import Path
from typing import Dict, List, Tuple
import numpy as np
import torch
from torch.utils.data import DataLoader
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei', 'DejaVu Sans']
plt.rcParams['axes.unicode_minus'] = False
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix, f1_score, precision_recall_fscore_support
import sys as _sys
_ROOT = str(Path(__file__).resolve().parent.parent)
if _ROOT not in _sys.path:
    _sys.path.insert(0, _ROOT)
from src.dataset import INSTRUMENT_NAMES, NUM_CLASSES
from src.model import InstrumentCNN, count_parameters
from src.cached_dataset import CachedMedleyDataset

def run_inference(model: torch.nn.Module, loader: DataLoader, device: torch.device, desc: str='eval') -> Tuple[np.ndarray, np.ndarray, float]:
    model.eval()
    y_true_list: List[np.ndarray] = []
    y_pred_list: List[np.ndarray] = []
    warmup_done = False
    elapsed = 0.0
    with torch.no_grad():
        for batch in loader:
            feats = batch[0].to(device, non_blocking=True)
            labels = batch[1]
            if isinstance(labels, torch.Tensor):
                labels_np = labels.cpu().numpy()
            else:
                labels_np = np.asarray(labels)
            if not warmup_done:
                _ = model(feats)
                if device.type == 'cuda':
                    torch.cuda.synchronize()
                warmup_done = True
                t_start = time.perf_counter()
                logits = model(feats)
                if device.type == 'cuda':
                    torch.cuda.synchronize()
                preds = logits.argmax(dim=1).cpu().numpy()
                y_true_list.append(labels_np.astype(np.int64))
                y_pred_list.append(preds.astype(np.int64))
                continue
            logits = model(feats)
            if device.type == 'cuda':
                torch.cuda.synchronize()
            preds = logits.argmax(dim=1).cpu().numpy()
            y_true_list.append(labels_np.astype(np.int64))
            y_pred_list.append(preds.astype(np.int64))
    elapsed = time.perf_counter() - t_start
    y_true = np.concatenate(y_true_list)
    y_pred = np.concatenate(y_pred_list)
    return (y_true, y_pred, elapsed)

def compute_metrics(y_true: np.ndarray, y_pred: np.ndarray) -> Dict:
    accuracy = accuracy_score(y_true, y_pred)
    macro_f1 = f1_score(y_true, y_pred, average='macro', zero_division=0)
    micro_f1 = f1_score(y_true, y_pred, average='micro', zero_division=0)
    weighted_f1 = f1_score(y_true, y_pred, average='weighted', zero_division=0)
    p, r, f1, s = precision_recall_fscore_support(y_true, y_pred, labels=list(range(NUM_CLASSES)), zero_division=0)
    per_class = []
    for i in range(NUM_CLASSES):
        per_class.append({'id': i, 'instrument': INSTRUMENT_NAMES[i], 'precision': float(p[i]), 'recall': float(r[i]), 'f1': float(f1[i]), 'support': int(s[i])})
    cm = confusion_matrix(y_true, y_pred, labels=list(range(NUM_CLASSES)))
    return {'accuracy': float(accuracy), 'macro_f1': float(macro_f1), 'micro_f1': float(micro_f1), 'weighted_f1': float(weighted_f1), 'per_class': per_class, 'confusion_matrix': cm, 'n_samples': int(len(y_true))}

def plot_confusion_matrix(cm: np.ndarray, output_path: Path, title: str='测试集混淆矩阵') -> None:
    fig, ax = plt.subplots(figsize=(10, 8), dpi=120)
    row_sums = cm.sum(axis=1, keepdims=True)
    row_sums_safe = np.where(row_sums == 0, 1, row_sums)
    cm_norm = cm / row_sums_safe
    im = ax.imshow(cm_norm, cmap='Blues', vmin=0, vmax=1)
    labels = [name[:18] for name in INSTRUMENT_NAMES]
    ax.set_xticks(range(NUM_CLASSES))
    ax.set_yticks(range(NUM_CLASSES))
    ax.set_xticklabels(labels, rotation=45, ha='right', fontsize=9)
    ax.set_yticklabels(labels, fontsize=9)
    ax.set_xlabel('预测类别', fontsize=11)
    ax.set_ylabel('真实类别', fontsize=11)
    ax.set_title(title, fontsize=13)
    for i in range(NUM_CLASSES):
        for j in range(NUM_CLASSES):
            v = cm[i, j]
            if v == 0:
                continue
            color = 'white' if cm_norm[i, j] > 0.5 else 'black'
            weight = 'bold' if i == j else 'normal'
            ax.text(j, i, str(int(v)), ha='center', va='center', color=color, fontsize=8, fontweight=weight)
    fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04, label='行归一化比例')
    plt.tight_layout()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, bbox_inches='tight')
    plt.close(fig)

def _fmt_pct(x: float) -> str:
    return f'{x * 100:.2f}%'

def _fmt_pct_plain(x: float) -> str:
    return f'{x * 100:.2f}'

def generate_report(test_metrics: Dict, val_metrics: Dict, test_perf: Dict, val_perf: Dict, ckpt_info: Dict, model_info: Dict, output_path: Path) -> None:
    from datetime import date
    lines: List[str] = []
    lines.append('# Medley-solos-DB 乐器识别模型评估报告')
    lines.append('')
    lines.append(f'> 生成时间：{date.today().isoformat()}')
    lines.append(f'> 模型：InstrumentCNN（{model_info['n_params']:,} 参数）')
    lines.append(f'> Checkpoint：{ckpt_info['checkpoint_path']}（epoch {ckpt_info['epoch']}, val_acc={ckpt_info['val_acc'] * 100:.2f}%）')
    lines.append('')
    lines.append('## 1. 评估概览')
    lines.append('')
    lines.append('| 指标 | 测试集 | 验证集 |')
    lines.append('|------|--------|--------|')
    lines.append(f'| 总体准确率 | {_fmt_pct(test_metrics['accuracy'])} | {_fmt_pct(val_metrics['accuracy'])} |')
    lines.append(f'| macro-F1 | {_fmt_pct(test_metrics['macro_f1'])} | {_fmt_pct(val_metrics['macro_f1'])} |')
    lines.append(f'| micro-F1 | {_fmt_pct(test_metrics['micro_f1'])} | {_fmt_pct(val_metrics['micro_f1'])} |')
    lines.append(f'| weighted-F1 | {_fmt_pct(test_metrics['weighted_f1'])} | {_fmt_pct(val_metrics['weighted_f1'])} |')
    lines.append(f'| 推理耗时 | {test_perf['elapsed_sec']:.2f}s | {val_perf['elapsed_sec']:.2f}s |')
    lines.append(f'| 单样本耗时 | {test_perf['per_sample_ms']:.2f}ms | {val_perf['per_sample_ms']:.2f}ms |')
    lines.append(f'| 吞吐量 | {test_perf['throughput']:.1f}样本/秒 | {val_perf['throughput']:.1f}样本/秒 |')
    lines.append(f'| 样本数 | {test_metrics['n_samples']} | {val_metrics['n_samples']} |')
    lines.append('')
    lines.append('## 2. 每类详细指标（测试集）')
    lines.append('')
    lines.append('| id | 乐器 | 样本数 | Precision | Recall | F1 | Support |')
    lines.append('|----|------|--------|-----------|--------|----|---------|')
    for c in test_metrics['per_class']:
        lines.append(f'| {c['id']} | {c['instrument']} | {c['support']} | {_fmt_pct(c['precision'])} | {_fmt_pct(c['recall'])} | {_fmt_pct(c['f1'])} | {c['support']} |')
    lines.append('')
    lines.append('### 2.1 每类详细指标（验证集，对比用）')
    lines.append('')
    lines.append('| id | 乐器 | Precision | Recall | F1 | Support |')
    lines.append('|----|------|-----------|--------|----|---------|')
    for c in val_metrics['per_class']:
        lines.append(f'| {c['id']} | {c['instrument']} | {_fmt_pct(c['precision'])} | {_fmt_pct(c['recall'])} | {_fmt_pct(c['f1'])} | {c['support']} |')
    lines.append('')
    lines.append('## 3. 混淆矩阵（测试集）')
    lines.append('')
    lines.append('> 行=真实类别，列=预测类别；对角线为正确分类数。')
    lines.append('')
    cm = test_metrics['confusion_matrix']
    short_names = [n[:12] for n in INSTRUMENT_NAMES]
    header = '| 真实\\预测 | ' + ' | '.join(short_names) + ' |'
    sep = '|----------|' + '|'.join(['------'] * NUM_CLASSES) + '|'
    lines.append(header)
    lines.append(sep)
    for i in range(NUM_CLASSES):
        row_cells = ' | '.join((str(int(cm[i, j])) for j in range(NUM_CLASSES)))
        lines.append(f'| {short_names[i]} | {row_cells} |')
    lines.append('')
    lines.append('## 4. 错误分析')
    lines.append('')
    off_diag = []
    for i in range(NUM_CLASSES):
        for j in range(NUM_CLASSES):
            if i != j and cm[i, j] > 0:
                off_diag.append((int(cm[i, j]), INSTRUMENT_NAMES[i], INSTRUMENT_NAMES[j]))
    off_diag.sort(key=lambda x: x[0], reverse=True)
    lines.append('### 4.1 最容易混淆的类别对（Top 5）')
    lines.append('')
    lines.append('| 排名 | 真实类别 | 误判为 | 错分数 | 占该类比例 |')
    lines.append('|------|----------|--------|--------|-----------|')
    for rank, (cnt, true_name, pred_name) in enumerate(off_diag[:5], 1):
        true_id = INSTRUMENT_NAMES.index(true_name)
        row_total = int(cm[true_id, :].sum())
        ratio = cnt / row_total if row_total > 0 else 0.0
        lines.append(f'| {rank} | {true_name} | {pred_name} | {cnt} | {ratio * 100:.2f}% |')
    lines.append('')
    lines.append('### 4.2 各类别主要错误模式')
    lines.append('')
    for i in range(NUM_CLASSES):
        row_total = int(cm[i, :].sum())
        correct = int(cm[i, i])
        if row_total == 0:
            continue
        err_total = row_total - correct
        if err_total == 0:
            lines.append(f'- **{INSTRUMENT_NAMES[i]}**：无错误（{correct}/{row_total} 全部正确）')
            continue
        mis = []
        for j in range(NUM_CLASSES):
            if j != i and cm[i, j] > 0:
                mis.append((int(cm[i, j]), INSTRUMENT_NAMES[j]))
        mis.sort(key=lambda x: x[0], reverse=True)
        top_mis = ', '.join((f'→{name}({cnt})' for cnt, name in mis[:2]))
        lines.append(f'- **{INSTRUMENT_NAMES[i]}**：正确 {correct}/{row_total} ({_fmt_pct(correct / row_total)})，错分 {err_total} 个；主要误判：{top_mis}')
    lines.append('')
    lines.append('## 5. 推理性能')
    lines.append('')
    lines.append('| 指标 | 值 |')
    lines.append('|------|-----|')
    lines.append(f'| 测试集总推理耗时 | {test_perf['elapsed_sec']:.2f}s |')
    lines.append(f'| 测试集平均单样本耗时 | {test_perf['per_sample_ms']:.2f}ms |')
    lines.append(f'| 测试集吞吐量 | {test_perf['throughput']:.1f}样本/秒 |')
    lines.append(f'| 验证集总推理耗时 | {val_perf['elapsed_sec']:.2f}s |')
    lines.append(f'| 验证集平均单样本耗时 | {val_perf['per_sample_ms']:.2f}ms |')
    lines.append(f'| 验证集吞吐量 | {val_perf['throughput']:.1f}样本/秒 |')
    lines.append(f'| GPU | {test_perf['device']} |')
    lines.append(f'| Batch Size | {test_perf['batch_size']} |')
    lines.append('')
    lines.append('## 6. 模型信息')
    lines.append('')
    lines.append('| 项目 | 值 |')
    lines.append('|------|-----|')
    lines.append('| 架构 | 4ConvBlock + GAP + 2FC |')
    lines.append(f'| 参数量 | {model_info['n_params']:,} |')
    lines.append(f'| INT8 量化后大小 | {model_info['int8_mb']:.3f} MB |')
    lines.append(f'| 输入形状 | {model_info['input_shape']} |')
    lines.append(f'| 输出类别 | {model_info['num_classes']} |')
    lines.append(f'| Checkpoint epoch | {ckpt_info['epoch']} |')
    lines.append(f'| 训练时最佳 val_acc | {_fmt_pct(ckpt_info['val_acc'])} |')
    lines.append('')
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text('\n'.join(lines), encoding='utf-8')

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Medley-solos-DB 乐器识别模型评估脚本', formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument('--checkpoint', type=str, default='runs/best_model.pt', help='checkpoint 路径')
    parser.add_argument('--cache-dir', type=str, default='data/cache', help='特征缓存目录')
    parser.add_argument('--csv-path', type=str, default='Medley-solos-DB_metadata.csv', help='元数据 CSV 路径')
    parser.add_argument('--wav-dir', type=str, default='data/raw/medley_wav', help='wav 目录（评估时不强制需要，仅用于接口兼容）')
    parser.add_argument('--batch-size', type=int, default=64, help='评估 batch size')
    parser.add_argument('--output-dir', type=str, default='reports', help='报告输出目录')
    parser.add_argument('--no-plot', action='store_true', help='禁用混淆矩阵图生成')
    return parser.parse_args()

def main() -> None:
    args = parse_args()
    checkpoint_path = Path(args.checkpoint)
    cache_dir = Path(args.cache_dir)
    csv_path = Path(args.csv_path)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    if torch.cuda.is_available():
        device = torch.device('cuda')
        device_name = torch.cuda.get_device_name(0)
    else:
        device = torch.device('cpu')
        device_name = 'CPU'
    print(f'[info] 推理设备: {device_name}')
    print(f'[info] 加载 checkpoint: {checkpoint_path}')
    ckpt = torch.load(str(checkpoint_path), map_location=device, weights_only=False)
    ckpt_epoch = int(ckpt.get('epoch', -1))
    ckpt_val_acc = float(ckpt.get('best_val_acc', ckpt.get('val_acc', 0.0)))
    print(f'[info] epoch={ckpt_epoch}, val_acc={ckpt_val_acc * 100:.2f}%')
    model = InstrumentCNN(num_classes=NUM_CLASSES, dropout=0.3)
    model.load_state_dict(ckpt['model_state_dict'])
    model.to(device)
    n_params = count_parameters(model)
    int8_mb = n_params / 1024 / 1024
    print(f'[info] 模型参数量: {n_params:,}（INT8 ≈ {int8_mb:.3f} MB）')
    print(f'[info] 加载测试集与验证集（cache={cache_dir}）')
    test_ds = CachedMedleyDataset(subset='test', cache_dir=cache_dir, csv_path=csv_path, file_index=None, return_meta=False)
    val_ds = CachedMedleyDataset(subset='validation', cache_dir=cache_dir, csv_path=csv_path, file_index=None, return_meta=False)
    print(f'[info] 测试集样本数: {len(test_ds)}')
    print(f'[info] 验证集样本数: {len(val_ds)}')
    test_loader = DataLoader(test_ds, batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=device.type == 'cuda', drop_last=False)
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=device.type == 'cuda', drop_last=False)
    print('[info] 在测试集上推理...')
    y_true_test, y_pred_test, t_test = run_inference(model, test_loader, device, desc='test')
    print(f'[info] 测试集推理耗时: {t_test:.2f}s')
    print('[info] 在验证集上推理...')
    y_true_val, y_pred_val, t_val = run_inference(model, val_loader, device, desc='val')
    print(f'[info] 验证集推理耗时: {t_val:.2f}s')
    test_metrics = compute_metrics(y_true_test, y_pred_test)
    val_metrics = compute_metrics(y_true_val, y_pred_val)
    test_perf = {'elapsed_sec': t_test, 'per_sample_ms': t_test * 1000 / max(1, len(test_ds)), 'throughput': len(test_ds) / t_test if t_test > 0 else float('inf'), 'device': device_name, 'batch_size': args.batch_size}
    val_perf = {'elapsed_sec': t_val, 'per_sample_ms': t_val * 1000 / max(1, len(val_ds)), 'throughput': len(val_ds) / t_val if t_val > 0 else float('inf'), 'device': device_name, 'batch_size': args.batch_size}
    print('=' * 60)
    print('评估结果汇总')
    print('=' * 60)
    print(f'测试集: accuracy={test_metrics['accuracy'] * 100:.2f}%, macro-F1={test_metrics['macro_f1'] * 100:.2f}%, weighted-F1={test_metrics['weighted_f1'] * 100:.2f}%')
    print(f'验证集: accuracy={val_metrics['accuracy'] * 100:.2f}%, macro-F1={val_metrics['macro_f1'] * 100:.2f}%, weighted-F1={val_metrics['weighted_f1'] * 100:.2f}%')
    print(f'测试集吞吐量: {test_perf['throughput']:.1f} 样本/秒')
    print('=' * 60)
    cm_png_path = output_dir / 'confusion_matrix.png'
    if not args.no_plot:
        print(f'[info] 生成混淆矩阵图: {cm_png_path}')
        plot_confusion_matrix(test_metrics['confusion_matrix'], cm_png_path, title='测试集混淆矩阵（InstrumentCNN）')
    ckpt_info = {'epoch': ckpt_epoch, 'val_acc': ckpt_val_acc, 'checkpoint_path': str(checkpoint_path)}
    model_info = {'n_params': n_params, 'int8_mb': int8_mb, 'input_shape': '(1, 64, 258)', 'num_classes': NUM_CLASSES}
    report_path = output_dir / 'evaluation_report.md'
    print(f'[info] 生成评估报告: {report_path}')
    generate_report(test_metrics=test_metrics, val_metrics=val_metrics, test_perf=test_perf, val_perf=val_perf, ckpt_info=ckpt_info, model_info=model_info, output_path=report_path)
    json_path = output_dir / 'evaluation_metrics.json'
    json_payload = {'checkpoint': str(checkpoint_path), 'epoch': ckpt_epoch, 'val_acc_at_train': ckpt_val_acc, 'test': {'n_samples': test_metrics['n_samples'], 'accuracy': test_metrics['accuracy'], 'macro_f1': test_metrics['macro_f1'], 'micro_f1': test_metrics['micro_f1'], 'weighted_f1': test_metrics['weighted_f1'], 'per_class': test_metrics['per_class'], 'confusion_matrix': test_metrics['confusion_matrix'].tolist(), 'elapsed_sec': test_perf['elapsed_sec'], 'per_sample_ms': test_perf['per_sample_ms'], 'throughput': test_perf['throughput']}, 'validation': {'n_samples': val_metrics['n_samples'], 'accuracy': val_metrics['accuracy'], 'macro_f1': val_metrics['macro_f1'], 'micro_f1': val_metrics['micro_f1'], 'weighted_f1': val_metrics['weighted_f1'], 'per_class': val_metrics['per_class'], 'confusion_matrix': val_metrics['confusion_matrix'].tolist(), 'elapsed_sec': val_perf['elapsed_sec'], 'per_sample_ms': val_perf['per_sample_ms'], 'throughput': val_perf['throughput']}, 'model': {'n_params': n_params, 'int8_mb': int8_mb, 'input_shape': '(1, 64, 258)', 'num_classes': NUM_CLASSES}, 'device': device_name, 'batch_size': args.batch_size}
    json_path.write_text(json.dumps(json_payload, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'[info] JSON 指标已保存: {json_path}')
    print('[done] 评估完成。')
if __name__ == '__main__':
    main()
