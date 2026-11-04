from __future__ import annotations
import argparse
import copy
import json
import shutil
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader
import torch.ao.quantization as tq
from torch.ao.quantization import default_per_channel_qconfig
from sklearn.metrics import accuracy_score, confusion_matrix, f1_score, precision_recall_fscore_support
_ROOT = str(Path(__file__).resolve().parent.parent)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)
from src.dataset import INSTRUMENT_NAMES, NUM_CLASSES
from src.model import InstrumentCNN, count_parameters
from src.cached_dataset import CachedMedleyDataset
from src import features as F
INSTRUMENT_NAMES_ZH: Tuple[str, ...] = ('单簧管', '失真电吉他', '女声', '长笛', '钢琴', '次中音萨克斯', '小号', '小提琴')
FUSE_MODULES_LIST: List[List[str]] = [['conv1', 'bn1', 'relu1'], ['conv2', 'bn2', 'relu2'], ['conv3', 'bn3', 'relu3'], ['conv4', 'bn4', 'relu4'], ['fc1', 'relu_fc']]
FUSE_MODULES_LIST_WRAPPED: List[List[str]] = [[f'model.{m}' for m in group] for group in FUSE_MODULES_LIST]

class QuantWrapper(nn.Module):

    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self.model = model
        self.quant = tq.QuantStub()
        self.dequant = tq.DeQuantStub()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.quant(x)
        x = self.model(x)
        x = self.dequant(x)
        return x

def load_fp32_model(checkpoint_path: Path, device: torch.device) -> InstrumentCNN:
    model = InstrumentCNN(num_classes=NUM_CLASSES, dropout=0.3)
    ckpt = torch.load(str(checkpoint_path), map_location=device)
    state_dict = ckpt['model_state_dict'] if 'model_state_dict' in ckpt else ckpt
    model.load_state_dict(state_dict)
    model.to(device)
    model.eval()
    return model

def get_checkpoint_info(checkpoint_path: Path) -> Dict[str, Any]:
    ckpt = torch.load(str(checkpoint_path), map_location='cpu')
    return {'checkpoint_path': str(checkpoint_path), 'epoch': int(ckpt.get('epoch', -1)), 'val_acc': float(ckpt.get('val_acc', ckpt.get('best_val_acc', 0.0)))}

def build_calib_loader(cache_dir: Path, csv_path: Path, batch_size: int, num_samples: int) -> DataLoader:
    dataset = CachedMedleyDataset(subset='training', cache_dir=cache_dir, csv_path=csv_path, return_meta=False)
    total = len(dataset)
    if num_samples >= total:
        indices = list(range(total))
    else:
        labels = dataset.get_labels()
        rng = np.random.default_rng(42)
        indices = []
        per_class = max(1, num_samples // NUM_CLASSES)
        for c in range(NUM_CLASSES):
            cls_idx = np.where(labels == c)[0]
            if len(cls_idx) > 0:
                chosen = rng.choice(cls_idx, size=min(per_class, len(cls_idx)), replace=False)
                indices.extend(chosen.tolist())
        if len(indices) < num_samples:
            remaining = num_samples - len(indices)
            pool = np.setdiff1d(np.arange(total), np.array(indices))
            extra = rng.choice(pool, size=min(remaining, len(pool)), replace=False)
            indices.extend(extra.tolist())
        indices = indices[:num_samples]
    subset_ds = torch.utils.data.Subset(dataset, indices)
    loader = DataLoader(subset_ds, batch_size=batch_size, shuffle=False, num_workers=0, pin_memory=False)
    print(f'  校准样本数: {len(subset_ds)}（从训练集 {total} 中分层采样）')
    return loader

def build_eval_loader(subset: str, cache_dir: Path, csv_path: Path, batch_size: int) -> DataLoader:
    dataset = CachedMedleyDataset(subset=subset, cache_dir=cache_dir, csv_path=csv_path, return_meta=False)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False, num_workers=0, pin_memory=False)
    return loader

def run_inference_cpu(model: nn.Module, loader: DataLoader, desc: str='eval') -> Tuple[np.ndarray, np.ndarray, float]:
    model.eval()
    y_true_list: List[np.ndarray] = []
    y_pred_list: List[np.ndarray] = []
    warmup_done = False
    t_start = 0.0
    with torch.no_grad():
        for batch in loader:
            feats = batch[0]
            labels = batch[1]
            if isinstance(labels, torch.Tensor):
                labels_np = labels.cpu().numpy()
            else:
                labels_np = np.asarray(labels)
            if not warmup_done:
                _ = model(feats)
                warmup_done = True
                t_start = time.perf_counter()
                logits = model(feats)
                preds = logits.argmax(dim=1).cpu().numpy()
                y_true_list.append(labels_np.astype(np.int64))
                y_pred_list.append(preds.astype(np.int64))
                continue
            logits = model(feats)
            preds = logits.argmax(dim=1).cpu().numpy()
            y_true_list.append(labels_np.astype(np.int64))
            y_pred_list.append(preds.astype(np.int64))
    elapsed = time.perf_counter() - t_start
    y_true = np.concatenate(y_true_list)
    y_pred = np.concatenate(y_pred_list)
    return (y_true, y_pred, elapsed)

def compute_metrics(y_true: np.ndarray, y_pred: np.ndarray) -> Dict[str, Any]:
    accuracy = accuracy_score(y_true, y_pred)
    macro_f1 = f1_score(y_true, y_pred, average='macro', zero_division=0)
    micro_f1 = f1_score(y_true, y_pred, average='micro', zero_division=0)
    weighted_f1 = f1_score(y_true, y_pred, average='weighted', zero_division=0)
    p, r, f1, s = precision_recall_fscore_support(y_true, y_pred, labels=list(range(NUM_CLASSES)), zero_division=0)
    per_class = []
    for i in range(NUM_CLASSES):
        per_class.append({'id': i, 'instrument': INSTRUMENT_NAMES[i], 'precision': float(p[i]), 'recall': float(r[i]), 'f1': float(f1[i]), 'support': int(s[i])})
    cm = confusion_matrix(y_true, y_pred, labels=list(range(NUM_CLASSES)))
    return {'accuracy': float(accuracy), 'macro_f1': float(macro_f1), 'micro_f1': float(micro_f1), 'weighted_f1': float(weighted_f1), 'per_class': per_class, 'confusion_matrix': cm.tolist(), 'n_samples': int(len(y_true))}

def quantize_static(model: InstrumentCNN, calib_loader: DataLoader, device: torch.device) -> Tuple[nn.Module, Dict[str, Any]]:
    print('\n[静态量化] 开始 eager mode PTQ...')
    quant_info: Dict[str, Any] = {'method': 'static', 'engine': 'fbgemm'}
    torch.backends.quantized.engine = 'fbgemm'
    quant_info['engine'] = torch.backends.quantized.engine
    wrapped = QuantWrapper(copy.deepcopy(model))
    wrapped.eval()
    tq.fuse_modules(wrapped, FUSE_MODULES_LIST_WRAPPED, inplace=True)
    print('  Conv-BN-ReLU 融合完成')
    wrapped.qconfig = default_per_channel_qconfig
    print(f'  qconfig: {wrapped.qconfig}')
    prepared_model = tq.prepare(wrapped, inplace=False)
    print('  prepare 完成（已插入 observer）')
    prepared_model.eval()
    n_calib = 0
    with torch.no_grad():
        for batch in calib_loader:
            feats = batch[0].to(device)
            prepared_model(feats)
            n_calib += feats.shape[0]
    print(f'  校准完成（{n_calib} 样本前向传播）')
    quant_info['n_calib_samples'] = n_calib
    quantized_model = tq.convert(prepared_model, inplace=False)
    quantized_model.eval()
    print('  convert 完成（已生成量化模型）')
    quantized_types = (nn.quantized.Conv2d, nn.quantized.Linear)
    n_quantized = 0
    for name, module in quantized_model.named_modules():
        if isinstance(module, quantized_types):
            n_quantized += 1
    quant_info['n_quantized_layers'] = n_quantized
    print(f'  量化层总数: {n_quantized}')
    return (quantized_model, quant_info)

def quantize_dynamic(model: InstrumentCNN) -> Tuple[nn.Module, Dict[str, Any]]:
    print('\n[动态量化] 开始动态 PTQ...')
    quant_info: Dict[str, Any] = {'method': 'dynamic', 'engine': 'fbgemm'}
    torch.backends.quantized.engine = 'fbgemm'
    quant_info['engine'] = torch.backends.quantized.engine
    wrapped = QuantWrapper(copy.deepcopy(model))
    wrapped.eval()
    quantized_model = tq.quantize_dynamic(wrapped, {nn.Linear, nn.Conv2d}, dtype=torch.qint8)
    quantized_model.eval()
    print('  动态量化完成（Linear + Conv2d 权重已量化为 qint8）')
    quant_info['n_calib_samples'] = 0
    quant_info['n_quantized_layers'] = -1
    return (quantized_model, quant_info)

def export_layer_weights(quantized_model: nn.Module, fp32_model: InstrumentCNN, output_dir: Path, quant_method: str) -> List[Dict[str, Any]]:
    weights_dir = output_dir / 'weights'
    weights_dir.mkdir(parents=True, exist_ok=True)
    layer_infos: List[Dict[str, Any]] = []
    quantized_types = (nn.quantized.Conv2d, nn.quantized.Linear, nn.quantized.dynamic.Conv2d, nn.quantized.dynamic.Linear)
    for name, module in quantized_model.named_modules():
        if isinstance(module, quantized_types):
            if hasattr(module, 'weight') and callable(module.weight):
                try:
                    q_weight = module.weight()
                except TypeError:
                    q_weight = module.weight
            elif hasattr(module, '_weight'):
                q_weight = module._weight
            else:
                continue
            if not hasattr(q_weight, 'int_repr'):
                continue
            int8_weight = q_weight.int_repr().cpu().numpy().astype(np.int8)
            clean_name = name.replace('model.', '') if name.startswith('model.') else name
            try:
                scales = q_weight.q_per_channel_scales().cpu().numpy().astype(np.float32)
                zero_points = q_weight.q_per_channel_zero_points().cpu().numpy().astype(np.int32)
            except Exception:
                scales = np.array([q_weight.q_scale()], dtype=np.float32)
                zero_points = np.array([q_weight.q_zero_point()], dtype=np.int32)
            q_bias = module.bias()
            if q_bias is not None:
                bias_int32 = q_bias.detach().cpu().numpy().astype(np.int32)
            else:
                bias_int32 = None
            np.save(str(weights_dir / f'{clean_name}_weight_int8.npy'), int8_weight)
            np.save(str(weights_dir / f'{clean_name}_scale.npy'), scales)
            np.save(str(weights_dir / f'{clean_name}_zero_point.npy'), zero_points)
            if bias_int32 is not None:
                np.save(str(weights_dir / f'{clean_name}_bias_int32.npy'), bias_int32)
            info = {'layer': clean_name, 'type': type(module).__name__, 'weight_shape': list(int8_weight.shape), 'scale_shape': list(scales.shape), 'int8_size_kb': round(int8_weight.nbytes / 1024, 2), 'has_bias': bias_int32 is not None}
            layer_infos.append(info)
            print(f'  导出 {clean_name}: weight {int8_weight.shape} → int8, scale {scales.shape}')
    for name, module in fp32_model.named_modules():
        if isinstance(module, nn.BatchNorm2d):
            running_mean = module.running_mean.detach().cpu().numpy().astype(np.float32)
            running_var = module.running_var.detach().cpu().numpy().astype(np.float32)
            weight = module.weight.detach().cpu().numpy().astype(np.float32)
            bias = module.bias.detach().cpu().numpy().astype(np.float32)
            eps = float(module.eps)
            np.save(str(weights_dir / f'{name}_running_mean.npy'), running_mean)
            np.save(str(weights_dir / f'{name}_running_var.npy'), running_var)
            np.save(str(weights_dir / f'{name}_weight.npy'), weight)
            np.save(str(weights_dir / f'{name}_bias.npy'), bias)
            np.save(str(weights_dir / f'{name}_eps.npy'), np.array(eps, dtype=np.float32))
            info = {'layer': name, 'type': 'BatchNorm2d', 'weight_shape': list(weight.shape), 'scale_shape': [], 'int8_size_kb': round(weight.nbytes / 1024, 2), 'has_bias': True}
            layer_infos.append(info)
    return layer_infos

def export_feature_params(output_dir: Path) -> Dict[str, Any]:
    params = {'sr': F.SR, 'n_fft': F.N_FFT, 'hop_length': F.HOP_LENGTH, 'win_length': F.WIN_LENGTH, 'window': F.WINDOW, 'n_mels': F.N_MELS, 'n_frames': F.N_FRAMES, 'f_min': F.F_MIN, 'f_max': F.F_MAX, 'power': F.POWER, 'top_db': 80.0, 'normalization': 'per_sample', 'input_shape': [1, F.N_MELS, F.N_FRAMES], 'dtype': 'float32'}
    with (output_dir / 'feature_params.json').open('w', encoding='utf-8') as f:
        json.dump(params, f, indent=2, ensure_ascii=False)
    return params

def export_class_names(output_dir: Path) -> Dict[str, Any]:
    id_to_name = {str(i): INSTRUMENT_NAMES[i] for i in range(NUM_CLASSES)}
    id_to_name_zh = {str(i): INSTRUMENT_NAMES_ZH[i] for i in range(NUM_CLASSES)}
    data = {'num_classes': NUM_CLASSES, 'names': list(INSTRUMENT_NAMES), 'name_zh': list(INSTRUMENT_NAMES_ZH), 'id_to_name': id_to_name, 'id_to_name_zh': id_to_name_zh}
    with (output_dir / 'class_names.json').open('w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    return data

def export_inference_reference(output_dir: Path) -> None:
    code = '"""端到端推理参考实现：任意 wav 文件 → 预测类别与置信度。\n\n本脚本提供 FPGA 部署的对拍参考实现，加载量化后的模型完成端到端推理。\n特征抽取参数严格遵循 feature_params.json，类别顺序遵循 class_names.json。\n\n使用示例\n--------\n::\n\n    python deploy/inference_reference.py path/to/audio.wav\n    python deploy/inference_reference.py path/to/audio.wav --model deploy/quantized_model.pt\n"""\n\nfrom __future__ import annotations\n\nimport argparse\nimport json\nimport sys\nfrom pathlib import Path\n\nimport numpy as np\nimport torch\nimport torch.nn as nn\n\n# 将项目根目录加入 sys.path（本脚本位于 deploy/，根目录为其父目录）\n_ROOT = str(Path(__file__).resolve().parent.parent)\nif _ROOT not in sys.path:\n    sys.path.insert(0, _ROOT)\n\nfrom src.model import InstrumentCNN  # noqa: E402\nfrom src.features import extract_mel  # noqa: E402\nfrom src.dataset import INSTRUMENT_NAMES, NUM_CLASSES  # noqa: E402\nimport torch.ao.quantization as tq  # noqa: E402\n\n\nclass QuantWrapper(nn.Module):\n    """量化包装模型（与 src/quantize.py 中定义一致）。\n\n    静态/动态量化均通过此包装保存，加载时须用同一结构。\n    """\n\n    def __init__(self, model: nn.Module) -> None:\n        super().__init__()\n        self.model = model\n        self.quant = tq.QuantStub()\n        self.dequant = tq.DeQuantStub()\n\n    def forward(self, x: torch.Tensor) -> torch.Tensor:\n        x = self.quant(x)\n        x = self.model(x)\n        x = self.dequant(x)\n        return x\n\n\ndef load_class_names(deploy_dir: Path) -> dict:\n    """加载类别名称映射。"""\n    with (deploy_dir / "class_names.json").open("r", encoding="utf-8") as f:\n        return json.load(f)\n\n\ndef load_feature_params(deploy_dir: Path) -> dict:\n    """加载特征管线参数。"""\n    with (deploy_dir / "feature_params.json").open("r", encoding="utf-8") as f:\n        return json.load(f)\n\n\ndef load_quantized_model(model_path: Path) -> torch.nn.Module:\n    """加载量化后的模型。\n\n    量化模型以 TorchScript 格式保存（torch.jit.trace + save），\n    加载时用 torch.jit.load，自包含无需原始类定义。\n    量化模型只能在 CPU 上推理。\n    """\n    torch.backends.quantized.engine = "fbgemm"\n    model = torch.jit.load(str(model_path), map_location="cpu")\n    model.eval()\n    return model\n\n\ndef predict(wav_path: str | Path, model_path: str | Path = "deploy/quantized_model.pt") -> dict:\n    """任意 wav → 预测类别。\n\n    Parameters\n    ----------\n    wav_path : str | Path\n        wav 文件路径。\n    model_path : str | Path\n        量化模型路径，默认 ``deploy/quantized_model.pt``。\n\n    Returns\n    -------\n    dict\n        包含以下字段：\n        - ``predicted_class`` : str — 预测类别英文名\n        - ``predicted_class_zh`` : str — 预测类别中文名\n        - ``predicted_id`` : int — 预测类别 ID\n        - ``confidence`` : float — 最大类别 softmax 概率\n        - ``all_probs`` : list — 全部类别 softmax 概率\n        - ``logits`` : list — 原始 logits\n    """\n    wav_path = Path(wav_path)\n    model_path = Path(model_path)\n    deploy_dir = model_path.parent if model_path.exists() else Path("deploy")\n\n    # 1. 加载类别名称\n    class_info = load_class_names(deploy_dir)\n    names = class_info["names"]\n    names_zh = class_info["name_zh"]\n\n    # 2. 抽取 Mel 特征 (64, 258)\n    feat = extract_mel(wav_path, normalize=True)\n\n    # 3. 构造输入张量 (1, 1, 64, 258)\n    x = torch.from_numpy(feat).unsqueeze(0).unsqueeze(0).float()  # (1, 1, 64, 258)\n\n    # 4. 加载量化模型\n    model = load_quantized_model(model_path)\n\n    # 5. 前向推理\n    with torch.no_grad():\n        logits = model(x)\n        probs = torch.softmax(logits, dim=1)\n        pred_id = int(logits.argmax(dim=1).item())\n        confidence = float(probs[0, pred_id].item())\n\n    return {\n        "predicted_class": names[pred_id],\n        "predicted_class_zh": names_zh[pred_id],\n        "predicted_id": pred_id,\n        "confidence": confidence,\n        "all_probs": probs[0].cpu().numpy().tolist(),\n        "logits": logits[0].cpu().numpy().tolist(),\n    }\n\n\ndef main() -> None:\n    """命令行入口。"""\n    parser = argparse.ArgumentParser(description="wav → 乐器类别推理")\n    parser.add_argument("wav_path", type=str, help="wav 文件路径")\n    parser.add_argument(\n        "--model",\n        type=str,\n        default="deploy/quantized_model.pt",\n        help="量化模型路径",\n    )\n    args = parser.parse_args()\n\n    result = predict(args.wav_path, args.model)\n    print(f"文件: {args.wav_path}")\n    print(f"预测类别: {result[\'predicted_class\']}（{result[\'predicted_class_zh\']}）")\n    print(f"类别 ID: {result[\'predicted_id\']}")\n    print(f"置信度: {result[\'confidence\']:.4f}")\n    print(f"各类概率:")\n    deploy_dir = Path(args.model).parent\n    class_info = load_class_names(deploy_dir)\n    for i, (name, name_zh, prob) in enumerate(\n        zip(class_info["names"], class_info["name_zh"], result["all_probs"])\n    ):\n        bar = "█" * int(prob * 50)\n        print(f"  {i} {name_zh:8s} ({name:30s}) {prob:.4f} {bar}")\n\n\nif __name__ == "__main__":\n    main()\n'
    with (output_dir / 'inference_reference.py').open('w', encoding='utf-8') as f:
        f.write(code)

def export_quantization_config(output_dir: Path, quant_info: Dict[str, Any], args: argparse.Namespace, fp32_metrics: Dict[str, Any], int8_metrics: Dict[str, Any]) -> None:
    config = {'quant_method': quant_info['method'], 'quant_engine': quant_info['engine'], 'dtype': 'qint8', 'weight_quant': 'per_channel_symmetric', 'activation_quant': 'per_tensor_affine' if quant_info['method'] == 'static' else 'none', 'n_calibration_samples': quant_info.get('n_calib_samples', 0), 'n_quantized_layers': quant_info.get('n_quantized_layers', -1), 'fuse_modules': FUSE_MODULES_LIST, 'fp32_test_accuracy': fp32_metrics['accuracy'], 'int8_test_accuracy': int8_metrics['accuracy'], 'accuracy_drop': fp32_metrics['accuracy'] - int8_metrics['accuracy'], 'fp32_macro_f1': fp32_metrics['macro_f1'], 'int8_macro_f1': int8_metrics['macro_f1'], 'macro_f1_drop': fp32_metrics['macro_f1'] - int8_metrics['macro_f1'], 'args': {'checkpoint': args.checkpoint, 'cache_dir': args.cache_dir, 'batch_size': args.batch_size, 'num_calibration_samples': args.num_calibration_samples, 'quant_method_requested': args.quant_method}}
    with (output_dir / 'quantization_config.json').open('w', encoding='utf-8') as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

def generate_deployment_report(output_dir: Path, quant_info: Dict[str, Any], fp32_metrics: Dict[str, Any], int8_metrics: Dict[str, Any], fp32_perf: Dict[str, float], int8_perf: Dict[str, float], layer_infos: List[Dict[str, Any]], fp32_size_kb: float, int8_size_kb: float, ckpt_info: Dict[str, Any]) -> None:
    from datetime import date

    def pct(x: float) -> str:
        return f'{x * 100:.2f}%'

    def pt(x: float) -> str:
        return f'{x * 100:+.2f}pt'
    lines: List[str] = []
    lines.append('# INT8 量化与部署交接报告')
    lines.append('')
    lines.append(f'> 生成时间：{date.today().isoformat()}')
    lines.append(f'> 模型：InstrumentCNN（685,864 参数，8 类乐器识别）')
    lines.append(f'> Checkpoint：{ckpt_info['checkpoint_path']}（epoch {ckpt_info['epoch']}, val_acc={ckpt_info['val_acc'] * 100:.2f}%）')
    lines.append('')
    lines.append('## 1. 量化概览')
    lines.append('')
    lines.append(f'- 量化方法：**{quant_info['method']} PTQ**（Post-Training Quantization）')
    lines.append(f'- 量化引擎：{quant_info['engine']}')
    lines.append('- 量化精度：INT8（权重 per-channel symmetric，激活 per-tensor affine）')
    lines.append(f'- 校准样本数：{quant_info.get('n_calib_samples', 0)}')
    lines.append(f'- 量化层总数：{quant_info.get('n_quantized_layers', 'N/A')}')
    lines.append(f'- 量化后模型大小：{int8_size_kb:.1f} KB')
    lines.append(f'- 融合分组：{FUSE_MODULES_LIST}')
    lines.append('')
    lines.append('## 2. 精度对比')
    lines.append('')
    lines.append('| 指标 | FP32 | INT8 | 差异 |')
    lines.append('|------|------|------|------|')
    lines.append(f'| 测试准确率 | {pct(fp32_metrics['accuracy'])} | {pct(int8_metrics['accuracy'])} | {pt(int8_metrics['accuracy'] - fp32_metrics['accuracy'])} |')
    lines.append(f'| macro-F1 | {pct(fp32_metrics['macro_f1'])} | {pct(int8_metrics['macro_f1'])} | {pt(int8_metrics['macro_f1'] - fp32_metrics['macro_f1'])} |')
    lines.append(f'| micro-F1 | {pct(fp32_metrics['micro_f1'])} | {pct(int8_metrics['micro_f1'])} | {pt(int8_metrics['micro_f1'] - fp32_metrics['micro_f1'])} |')
    lines.append(f'| weighted-F1 | {pct(fp32_metrics['weighted_f1'])} | {pct(int8_metrics['weighted_f1'])} | {pt(int8_metrics['weighted_f1'] - fp32_metrics['weighted_f1'])} |')
    lines.append(f'| 推理耗时 | {fp32_perf['elapsed_sec']:.2f}s | {int8_perf['elapsed_sec']:.2f}s | {fp32_perf['elapsed_sec'] / int8_perf['elapsed_sec']:.2f}x |')
    lines.append(f'| 单样本耗时 | {fp32_perf['per_sample_ms']:.2f}ms | {int8_perf['per_sample_ms']:.2f}ms | {fp32_perf['per_sample_ms'] / int8_perf['per_sample_ms']:.2f}x |')
    lines.append(f'| 吞吐量 | {fp32_perf['throughput']:.1f}样本/秒 | {int8_perf['throughput']:.1f}样本/秒 | {int8_perf['throughput'] / fp32_perf['throughput']:.2f}x |')
    lines.append(f'| 样本数 | {fp32_metrics['n_samples']} | {int8_metrics['n_samples']} | - |')
    lines.append('')
    acc_drop = fp32_metrics['accuracy'] - int8_metrics['accuracy']
    status = '✅ 通过（< 3pt）' if acc_drop < 0.03 else '⚠️ 超标（≥ 3pt）'
    lines.append(f'**准确率下降校验：{acc_drop * 100:.2f}pt — {status}**')
    lines.append('')
    lines.append('## 3. 模型大小对比')
    lines.append('')
    lines.append('| 格式 | 大小 |')
    lines.append('|------|------|')
    lines.append(f'| FP32 state_dict | {fp32_size_kb / 1024:.2f} MB |')
    lines.append(f'| INT8 quantized | {int8_size_kb / 1024:.2f} MB |')
    lines.append(f'| 压缩比 | {fp32_size_kb / int8_size_kb:.2f}x |')
    lines.append('')
    lines.append('## 4. 逐层量化参数')
    lines.append('')
    lines.append('| 层名 | 类型 | 权重形状 | INT8 大小(KB) | scale 形状 |')
    lines.append('|------|------|----------|--------------|-----------|')
    for info in layer_infos:
        lines.append(f'| {info['layer']} | {info['type']} | {info['weight_shape']} | {info['int8_size_kb']} | {info['scale_shape']} |')
    lines.append('')
    lines.append('## 5. 每类指标对比（测试集）')
    lines.append('')
    lines.append('| ID | 乐器 | FP32 F1 | INT8 F1 | 差异 |')
    lines.append('|----|------|---------|---------|------|')
    for i in range(NUM_CLASSES):
        fp32_f1 = fp32_metrics['per_class'][i]['f1']
        int8_f1 = int8_metrics['per_class'][i]['f1']
        lines.append(f'| {i} | {INSTRUMENT_NAMES[i]} | {pct(fp32_f1)} | {pct(int8_f1)} | {pt(int8_f1 - fp32_f1)} |')
    lines.append('')
    lines.append('## 6. 部署交接件清单')
    lines.append('')
    lines.append('| 文件 | 用途 |')
    lines.append('|------|------|')
    lines.append('| `quantized_model.pt` | 量化后模型 state_dict，可直接加载推理 |')
    lines.append('| `quantization_config.json` | 量化配置与精度对比元信息 |')
    lines.append('| `weights/` | 逐层量化权重（int8 权重 + per-channel scale + int32 bias），FPGA 对拍用 |')
    lines.append('| `feature_params.json` | Mel 特征管线参数，FPGA 须严格一致 |')
    lines.append('| `class_names.json` | 类别名称与 ID 映射（含中英文） |')
    lines.append('| `inference_reference.py` | 任意 wav → 标签的端到端参考实现 |')
    lines.append('| `deployment_report.md` | 本报告 |')
    lines.append('')
    lines.append('## 7. FPGA 部署注意事项')
    lines.append('')
    lines.append('1. **特征管线参数须严格一致**：见 `feature_params.json`，')
    lines.append('   采样率 44100Hz、n_fft 2048、hop 512、n_mels 64、n_frames 258。')
    lines.append('2. **类别顺序**：见 `class_names.json`，ID 0-7 对应：')
    for i in range(NUM_CLASSES):
        lines.append(f'   - {i}: {INSTRUMENT_NAMES[i]}（{INSTRUMENT_NAMES_ZH[i]}）')
    lines.append('3. **逐层权重**：`weights/` 目录下，')
    lines.append('   `int8 权重 × scale ≈ FP32 权重`，bias 为 int32。')
    lines.append('4. **BatchNorm**：静态量化已将 BN 融合到 Conv（Conv-BN-ReLU fuse），')
    lines.append('   `weights/` 中的 BN 参数来自 FP32 原模型，仅供对拍参考。')
    lines.append('5. **输入标准化**：per-sample 零均值单位方差，')
    lines.append('   FPGA 须复现此标准化步骤。')
    lines.append('6. **量化引擎**：x86 CPU 使用 FBGEMM，ARM/嵌入式须改用 QNNPACK。')
    lines.append('7. **推理设备**：量化模型仅支持 CPU 推理，不支持 CUDA。')
    lines.append('')
    with (output_dir / 'deployment_report.md').open('w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

def get_model_size_kb(model: nn.Module) -> float:
    import io
    buf = io.BytesIO()
    torch.save(model.state_dict(), buf)
    return buf.tell() / 1024

def get_file_size_kb(path: Path) -> float:
    return path.stat().st_size / 1024

def main() -> None:
    parser = argparse.ArgumentParser(description='INT8 量化与部署交接（Medley-solos-DB 乐器识别）', formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument('--checkpoint', type=str, default='runs/best_model.pt', help='FP32 checkpoint 路径')
    parser.add_argument('--cache-dir', type=str, default='data/cache', help='特征缓存目录')
    parser.add_argument('--csv-path', type=str, default='Medley-solos-DB_metadata.csv', help='元数据 CSV 路径')
    parser.add_argument('--wav-dir', type=str, default='data/raw/medley_wav', help='wav 目录（未使用，保留接口兼容）')
    parser.add_argument('--output-dir', type=str, default='deploy', help='部署交接件输出目录')
    parser.add_argument('--batch-size', type=int, default=64, help='batch 大小')
    parser.add_argument('--num-calibration-samples', type=int, default=500, help='校准样本数')
    parser.add_argument('--quant-method', type=str, default='static', choices=['static', 'dynamic'], help='量化方法（static 优先，失败回退 dynamic）')
    args = parser.parse_args()
    checkpoint_path = Path(args.checkpoint)
    cache_dir = Path(args.cache_dir)
    csv_path = Path(args.csv_path)
    output_dir = Path(args.output_dir)
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / 'weights').mkdir(exist_ok=True)
    device = torch.device('cpu')
    print('=' * 70)
    print('INT8 量化与部署交接')
    print('=' * 70)
    print(f'Checkpoint: {checkpoint_path}')
    print(f'缓存目录: {cache_dir}')
    print(f'输出目录: {output_dir}')
    print(f'设备: {device}（量化模型仅支持 CPU）')
    print('\n[1/6] 加载 FP32 模型...')
    ckpt_info = get_checkpoint_info(checkpoint_path)
    fp32_model = load_fp32_model(checkpoint_path, device)
    n_params = count_parameters(fp32_model)
    print(f'  参数量: {n_params:,d}（约 {n_params / 1000000.0:.3f} M）')
    print(f'  epoch: {ckpt_info['epoch']}, val_acc: {ckpt_info['val_acc'] * 100:.2f}%')
    print('\n[2/6] 评估 FP32 基线（CPU）...')
    test_loader = build_eval_loader('test', cache_dir, csv_path, args.batch_size)
    print(f'  测试集样本数: {len(test_loader.dataset)}')
    y_true, y_pred, fp32_elapsed = run_inference_cpu(fp32_model, test_loader, 'FP32 test')
    fp32_metrics = compute_metrics(y_true, y_pred)
    n_test = fp32_metrics['n_samples']
    fp32_perf = {'elapsed_sec': fp32_elapsed, 'per_sample_ms': fp32_elapsed / n_test * 1000, 'throughput': n_test / fp32_elapsed}
    print(f'  FP32 准确率: {fp32_metrics['accuracy'] * 100:.2f}%')
    print(f'  FP32 macro-F1: {fp32_metrics['macro_f1'] * 100:.2f}%')
    print(f'  FP32 推理耗时: {fp32_elapsed:.2f}s ({fp32_perf['per_sample_ms']:.2f}ms/样本)')
    fp32_size_kb = get_model_size_kb(fp32_model)
    print(f'  FP32 模型大小: {fp32_size_kb / 1024:.2f} MB')
    print(f'\n[3/6] INT8 量化（请求方法: {args.quant_method}）...')
    quantized_model = None
    quant_info = None
    if args.quant_method == 'static':
        try:
            calib_loader = build_calib_loader(cache_dir, csv_path, args.batch_size, args.num_calibration_samples)
            quantized_model, quant_info = quantize_static(fp32_model, calib_loader, device)
        except Exception as e:
            print(f'\n  ⚠️ 静态量化失败: {type(e).__name__}: {e}')
            print('  自动回退到动态量化...')
            quantized_model, quant_info = quantize_dynamic(fp32_model)
    else:
        quantized_model, quant_info = quantize_dynamic(fp32_model)
    print('\n[4/6] 评估 INT8 量化模型（CPU）...')
    y_true_q, y_pred_q, int8_elapsed = run_inference_cpu(quantized_model, test_loader, 'INT8 test')
    int8_metrics = compute_metrics(y_true_q, y_pred_q)
    int8_perf = {'elapsed_sec': int8_elapsed, 'per_sample_ms': int8_elapsed / n_test * 1000, 'throughput': n_test / int8_elapsed}
    print(f'  INT8 准确率: {int8_metrics['accuracy'] * 100:.2f}%')
    print(f'  INT8 macro-F1: {int8_metrics['macro_f1'] * 100:.2f}%')
    print(f'  INT8 推理耗时: {int8_elapsed:.2f}s ({int8_perf['per_sample_ms']:.2f}ms/样本)')
    acc_drop = fp32_metrics['accuracy'] - int8_metrics['accuracy']
    print(f'\n  准确率下降: {acc_drop * 100:.2f}pt', end='')
    if acc_drop < 0.03:
        print(' ✅ 通过（< 3pt）')
    else:
        print(' ⚠️ 超标（≥ 3pt）')
    print('\n[5/6] 导出部署交接件...')
    quantized_model_path = output_dir / 'quantized_model.pt'
    example_input = torch.randn(1, 1, F.N_MELS, F.N_FRAMES)
    traced_model = torch.jit.trace(quantized_model, example_input)
    traced_model.save(str(quantized_model_path))
    int8_size_kb = get_file_size_kb(quantized_model_path)
    print(f'  quantized_model.pt (TorchScript): {int8_size_kb / 1024:.2f} MB')
    print('  逐层量化权重导出到 weights/...')
    layer_infos = export_layer_weights(quantized_model, fp32_model, output_dir, quant_info['method'])
    export_feature_params(output_dir)
    print('  feature_params.json')
    export_class_names(output_dir)
    print('  class_names.json')
    export_inference_reference(output_dir)
    print('  inference_reference.py')
    export_quantization_config(output_dir, quant_info, args, fp32_metrics, int8_metrics)
    print('  quantization_config.json')
    generate_deployment_report(output_dir, quant_info, fp32_metrics, int8_metrics, fp32_perf, int8_perf, layer_infos, fp32_size_kb, int8_size_kb, ckpt_info)
    print('  deployment_report.md')
    print('\n[6/6] 量化完成汇总')
    print('=' * 70)
    print(f'  量化方法: {quant_info['method']}')
    print(f'  量化引擎: {quant_info['engine']}')
    print(f'  FP32 准确率: {fp32_metrics['accuracy'] * 100:.2f}%')
    print(f'  INT8 准确率: {int8_metrics['accuracy'] * 100:.2f}%')
    print(f'  准确率下降: {acc_drop * 100:.2f}pt')
    print(f'  FP32 macro-F1: {fp32_metrics['macro_f1'] * 100:.2f}%')
    print(f'  INT8 macro-F1: {int8_metrics['macro_f1'] * 100:.2f}%')
    print(f'  FP32 模型大小: {fp32_size_kb / 1024:.2f} MB')
    print(f'  INT8 模型大小: {int8_size_kb / 1024:.2f} MB')
    print(f'  压缩比: {fp32_size_kb / int8_size_kb:.2f}x')
    print(f'  FP32 推理耗时: {fp32_elapsed:.2f}s')
    print(f'  INT8 推理耗时: {int8_elapsed:.2f}s')
    print(f'  加速比: {fp32_elapsed / int8_elapsed:.2f}x')
    print(f'  交接件目录: {output_dir}')
    print('=' * 70)
if __name__ == '__main__':
    main()
