from __future__ import annotations
from typing import Tuple
import torch
import torch.nn as nn

class InstrumentCNN(nn.Module):

    def __init__(self, num_classes: int=8, dropout: float=0.3) -> None:
        super().__init__()
        self.num_classes = num_classes
        self.conv1 = nn.Conv2d(1, 48, kernel_size=3, padding=1, bias=True)
        self.bn1 = nn.BatchNorm2d(48)
        self.relu1 = nn.ReLU(inplace=True)
        self.pool1 = nn.MaxPool2d(kernel_size=2, stride=2)
        self.conv2 = nn.Conv2d(48, 96, kernel_size=3, padding=1, bias=True)
        self.bn2 = nn.BatchNorm2d(96)
        self.relu2 = nn.ReLU(inplace=True)
        self.pool2 = nn.MaxPool2d(kernel_size=2, stride=2)
        self.conv3 = nn.Conv2d(96, 192, kernel_size=3, padding=1, bias=True)
        self.bn3 = nn.BatchNorm2d(192)
        self.relu3 = nn.ReLU(inplace=True)
        self.pool3 = nn.MaxPool2d(kernel_size=2, stride=2)
        self.conv4 = nn.Conv2d(192, 256, kernel_size=3, padding=1, bias=True)
        self.bn4 = nn.BatchNorm2d(256)
        self.relu4 = nn.ReLU(inplace=True)
        self.pool4 = nn.MaxPool2d(kernel_size=2, stride=2)
        self.gap = nn.AdaptiveAvgPool2d(1)
        self.fc1 = nn.Linear(256, 128)
        self.relu_fc = nn.ReLU(inplace=True)
        self.drop = nn.Dropout(p=dropout)
        self.fc2 = nn.Linear(128, num_classes)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.pool1(self.relu1(self.bn1(self.conv1(x))))
        x = self.pool2(self.relu2(self.bn2(self.conv2(x))))
        x = self.pool3(self.relu3(self.bn3(self.conv3(x))))
        x = self.pool4(self.relu4(self.bn4(self.conv4(x))))
        x = self.gap(x)
        x = torch.flatten(x, start_dim=1)
        x = self.fc1(x)
        x = self.relu_fc(x)
        x = self.drop(x)
        x = self.fc2(x)
        return x

def count_parameters(model: nn.Module) -> int:
    return sum((p.numel() for p in model.parameters() if p.requires_grad))

def model_summary(model: nn.Module, input_shape: Tuple[int, ...]=(1, 1, 64, 258)) -> None:
    print('=' * 70)
    print('模型层参数汇总')
    print('=' * 70)
    total = 0
    for name, param in model.named_parameters():
        n = param.numel()
        total += n
        grad = '可训练' if param.requires_grad else '冻结'
        print(f'  {name:45s} {str(tuple(param.shape)):20s} {n:>10d}  [{grad}]')
    print('-' * 70)
    print(f'  总参数量: {total:,d}（约 {total / 1000000.0:.3f} M）')
    print(f'  INT8 量化后估算大小: {total / 1024 / 1024:.3f} MB')
    print(f'  输入形状: {input_shape}')
    print('=' * 70)

def _self_check() -> None:
    print('=' * 70)
    print('InstrumentCNN 自检')
    print('=' * 70)
    model = InstrumentCNN(num_classes=8)
    n_params = count_parameters(model)
    print(f'可训练参数总数: {n_params:,d}（约 {n_params / 1000000.0:.3f} M）')
    print(f'INT8 量化后估算大小: {n_params / 1024 / 1024:.3f} MB')
    if 600000 <= n_params <= 800000:
        print(f'参数量校验: 通过（目标 60-80 万）')
    else:
        print(f'参数量校验: *** 不在目标区间 60-80 万 ***')
    model.eval()
    x = torch.randn(1, 1, 64, 258, dtype=torch.float32)
    with torch.no_grad():
        y = model(x)
    print(f'输入形状: {tuple(x.shape)}')
    print(f'输出形状: {tuple(y.shape)}')
    assert y.shape == (1, 8), f'输出形状错误: 期望 (1, 8)，得到 {tuple(y.shape)}'
    print('前向传播校验: 通过')
    print()
    model_summary(model)
if __name__ == '__main__':
    _self_check()
