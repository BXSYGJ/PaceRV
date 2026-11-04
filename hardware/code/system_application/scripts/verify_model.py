"""Check frozen model lineage and hardware weight bytes without the dataset."""
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'training'))
from src.model import InstrumentCNN
from gen_weight_image import load_npy_weights, cross_check_packed_weights, assert_class_order


def main():
    train = ROOT / 'training'
    ckpt = torch.load(train / 'runs/best_model.pt', map_location='cpu', weights_only=False)
    model = InstrumentCNN().eval()
    model.load_state_dict(ckpt['model_state_dict'], strict=True)
    count = sum(p.numel() for p in model.parameters())
    assert count == 685864
    assert ckpt['epoch'] == 6 and abs(ckpt['val_acc'] - 0.9396107613050945) < 1e-12
    assert_class_order(train / 'deploy/class_names.json', train / 'src/dataset.py')
    weights = load_npy_weights(train / 'deploy/weights')
    cross_check_packed_weights(train / 'deploy/quantized_model.pt', weights)
    contract = json.loads((ROOT / 'scripts/outputs/layer_contract.json').read_text(encoding='utf-8'))
    image = (ROOT / 'scripts/outputs/weights_image.bin').read_bytes()
    assert hashlib.sha256(image).hexdigest() == contract['image_sha256']
    qt = torch.jit.load(str(train / 'deploy/quantized_model.pt'), map_location='cpu')
    x = qt.quant(torch.zeros(1, 1, 64, 258))
    assert x.q_zero_point() == 49
    assert abs(x.q_scale() - contract['quant_stub_input_contract']['s_in']) < 1e-12
    for layer in contract['layers']:
        name = layer['name']
        w = weights[name]['weight_int8']
        flat = w.reshape(w.shape[0], -1)
        chunks = []
        for offset in range(0, flat.shape[0], 16):
            n = min(16, flat.shape[0] - offset)
            group = flat[offset:offset + n]
            chunks.append(group.T.tobytes())
        packed = b''.join(chunks)
        assert len(packed) == layer['weight_bytes'], name
        start = layer['image_offset']
        assert image[start:start + len(packed)] == packed, name
        if name.startswith('conv'):
            fused = torch.nn.utils.fusion.fuse_conv_bn_eval(getattr(model, name), getattr(model, 'bn' + name[-1]))
            scales = torch.tensor(weights[name]['weight_scale'], dtype=torch.float64)
            expected = torch.quantize_per_channel(fused.weight.detach(), scales, torch.zeros(len(scales), dtype=torch.int64), 0, torch.qint8)
            assert np.array_equal(expected.int_repr().numpy(), w), name
        else:
            scales = torch.tensor(weights[name]['weight_scale'], dtype=torch.float64)
            expected = torch.quantize_per_channel(getattr(model, name).weight.detach(), scales, torch.zeros(len(scales), dtype=torch.int64), 0, torch.qint8)
            assert np.array_equal(expected.int_repr().numpy(), w), name
    print('PASS: 685864 parameters; checkpoint -> fused INT8 weights -> TorchScript -> six image segments; class order and input quantization')


if __name__ == '__main__':
    main()
