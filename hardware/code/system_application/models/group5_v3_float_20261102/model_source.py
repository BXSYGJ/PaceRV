"""轻量量化友好 CNN 模型（Medley-solos-DB 乐器识别）。

本模块定义一个 4 层卷积 + 2 层全连接的轻量 CNN，用于 8 类乐器识别。
模型面向 INT8 量化部署，仅使用量化友好算子（Conv2d + BatchNorm2d + ReLU
+ MaxPool2d + AdaptiveAvgPool2d + Linear + Dropout），不使用 skip connection
与函数式激活，便于后续 BN fold 与 Conv-BN-ReLU fuse。

架构概览
--------
输入: (B, 1, 64, 258)  — batch, channel=1, n_mels=64, n_frames=258

::

    ConvBlock1: Conv2d(1,   48, 3, p=1) + BN + ReLU + MaxPool2d(2) → (48,  32, 129)
    ConvBlock2: Conv2d(48,  96, 3, p=1) + BN + ReLU + MaxPool2d(2) → (96,  16,  64)
    ConvBlock3: Conv2d(96, 192, 3, p=1) + BN + ReLU + MaxPool2d(2) → (192,  8,  32)
    ConvBlock4: Conv2d(192,256, 3, p=1) + BN + ReLU + MaxPool2d(2) → (256,  4,  16)
    AdaptiveAvgPool2d(1) → (256, 1, 1) → flatten → (256,)
    FC1: Linear(256, 128) + ReLU + Dropout(0.3)
    FC2: Linear(128, 8)

参数量约 68.6 万，INT8 量化后约 0.69 MB，满足 ≤0.8 MB 部署约束。

设计要点
--------
1. 量化友好：所有激活用 ``nn.ReLU`` 模块而非函数式；BN 紧跟 Conv，便于 fuse；
   无 skip connection，避免 fold 困难。
2. 全局平均池化：替代大尺寸 Flatten + FC，显著降低参数量与过拟合风险。
3. Dropout：FC 后接 Dropout(0.3) 缓解小数据集过拟合。
"""

from __future__ import annotations

from typing import Tuple

import torch
import torch.nn as nn

# ============================================================================
# 模型定义
# ============================================================================
class InstrumentCNN(nn.Module):
    """轻量量化友好 CNN（8 类乐器识别）。

    Parameters
    ----------
    num_classes : int, default 8
        输出类别数（Medley-solos-DB 共 8 类乐器）。
    dropout : float, default 0.3
        全连接层 Dropout 概率。

    Notes
    -----
    输入形状 ``(B, 1, 64, 258)``，输出形状 ``(B, num_classes)`` 的 logits。
    仅含量化友好算子，可直接用于 PyTorch PTQ/QAT 流程。
    """

    def __init__(self, num_classes: int = 8, dropout: float = 0.3) -> None:
        super().__init__()
        self.num_classes = num_classes

        # ------------------------------------------------------------------
        # 卷积主干：4 个 ConvBlock，每个 Conv+BN+ReLU+MaxPool
        # ------------------------------------------------------------------
        self.conv1 = nn.Conv2d(1,   48, kernel_size=3, padding=1, bias=True)
        self.bn1   = nn.BatchNorm2d(48)
        self.relu1 = nn.ReLU(inplace=True)
        self.pool1 = nn.MaxPool2d(kernel_size=2, stride=2)

        self.conv2 = nn.Conv2d(48,  96, kernel_size=3, padding=1, bias=True)
        self.bn2   = nn.BatchNorm2d(96)
        self.relu2 = nn.ReLU(inplace=True)
        self.pool2 = nn.MaxPool2d(kernel_size=2, stride=2)

        self.conv3 = nn.Conv2d(96, 192, kernel_size=3, padding=1, bias=True)
        self.bn3   = nn.BatchNorm2d(192)
        self.relu3 = nn.ReLU(inplace=True)
        self.pool3 = nn.MaxPool2d(kernel_size=2, stride=2)

        self.conv4 = nn.Conv2d(192, 256, kernel_size=3, padding=1, bias=True)
        self.bn4   = nn.BatchNorm2d(256)
        self.relu4 = nn.ReLU(inplace=True)
        self.pool4 = nn.MaxPool2d(kernel_size=2, stride=2)

        # 全局平均池化 → (B, 256, 1, 1)
        self.gap = nn.AdaptiveAvgPool2d(1)

        # ------------------------------------------------------------------
        # 分类头：FC1 + ReLU + Dropout + FC2
        # ------------------------------------------------------------------
        self.fc1     = nn.Linear(256, 128)
        self.relu_fc = nn.ReLU(inplace=True)
        self.drop    = nn.Dropout(p=dropout)
        self.fc2     = nn.Linear(128, num_classes)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """前向传播。

        Parameters
        ----------
        x : torch.Tensor
            输入特征，形状 ``(B, 1, 64, 258)``。

        Returns
        -------
        torch.Tensor
            输出 logits，形状 ``(B, num_classes)``。
        """
        # 主干卷积
        x = self.pool1(self.relu1(self.bn1(self.conv1(x))))
        x = self.pool2(self.relu2(self.bn2(self.conv2(x))))
        x = self.pool3(self.relu3(self.bn3(self.conv3(x))))
        x = self.pool4(self.relu4(self.bn4(self.conv4(x))))

        # 全局平均池化并展平
        x = self.gap(x)
        x = torch.flatten(x, start_dim=1)  # (B, 256)

        # 分类头
        x = self.fc1(x)
        x = self.relu_fc(x)
        x = self.drop(x)
        x = self.fc2(x)
        return x


class DualHeadInstrumentCNN(nn.Module):
    """Dual-head CNN for joint activity + dominance prediction.

    Extends :class:`InstrumentCNN` with a second output head that predicts
    the inter-group dominance (energy share) distribution over the same
    ``num_classes`` instrument groups.

    Architecture
    ------------
    The shared backbone and the activity head use layer names IDENTICAL to
    :class:`InstrumentCNN` (``conv1..4``, ``bn1..4``, ``relu1..4``,
    ``pool1..4``, ``gap``, ``fc1``, ``relu_fc``, ``drop``, ``fc2``). A v2
    ``InstrumentCNN`` checkpoint can therefore be warm-start loaded with
    ``load_state_dict(state, strict=False)``: only the dominance-head keys
    (``dom_*``) will be reported as missing, everything else transfers,
    including the trained activity head ``fc2``.

    The dominance head mirrors the activity head structure
    (``Linear(256->128) + ReLU + Dropout + Linear(128->num_classes)``) but
    is trained from scratch; its logits are meant to be passed through a
    softmax to obtain a share distribution over groups.

    Grad-CAM / inference compatibility
    -----------------------------------
    ``forward`` returns ONLY the activity logits of shape ``(B,
    num_classes)`` so existing consumers (:mod:`src.gradcam`, webapp
    inference) keep working unchanged when the checkpoint is swapped to
    this dual-head model. ``src.gradcam._find_cam_module`` automatically
    locates ``pool4`` as the last 4-D spatial layer (its output (B, 256,
    H/16, W/16) keeps H>1/W>1 while ``gap`` emits (B, 256, 1, 1)), and the
    backward pass flows through the shared backbone exactly as before.
    Use :meth:`forward_dual` when both outputs are needed (training loop,
    dominance-enabled inference).

    Parameters
    ----------
    num_classes : int, default 5
        Number of instrument groups (activity head and dominance head both
        output ``num_classes`` logits).
    dropout : float, default 0.3
        Dropout probability used in both heads.

    Notes
    -----
    Input shape ``(B, 1, 64, 130)`` (64 mel bands x 130 frames, 1.5 s
    window). ``forward`` returns activity logits ``(B, num_classes)``;
    ``forward_dual`` returns the tuple ``(activity_logits,
    dominance_logits)``.
    """

    def __init__(self, num_classes: int = 5, dropout: float = 0.3) -> None:
        super().__init__()
        self.num_classes = num_classes

        # ----------------------------------------------------------------------
        # Shared backbone: identical layer names/structure to InstrumentCNN
        # (required for v2 weight warm start and gradcam pool4 probing).
        # ----------------------------------------------------------------------
        self.conv1 = nn.Conv2d(1,   48, kernel_size=3, padding=1, bias=True)
        self.bn1   = nn.BatchNorm2d(48)
        self.relu1 = nn.ReLU(inplace=True)
        self.pool1 = nn.MaxPool2d(kernel_size=2, stride=2)

        self.conv2 = nn.Conv2d(48,  96, kernel_size=3, padding=1, bias=True)
        self.bn2   = nn.BatchNorm2d(96)
        self.relu2 = nn.ReLU(inplace=True)
        self.pool2 = nn.MaxPool2d(kernel_size=2, stride=2)

        self.conv3 = nn.Conv2d(96, 192, kernel_size=3, padding=1, bias=True)
        self.bn3   = nn.BatchNorm2d(192)
        self.relu3 = nn.ReLU(inplace=True)
        self.pool3 = nn.MaxPool2d(kernel_size=2, stride=2)

        self.conv4 = nn.Conv2d(192, 256, kernel_size=3, padding=1, bias=True)
        self.bn4   = nn.BatchNorm2d(256)
        self.relu4 = nn.ReLU(inplace=True)
        self.pool4 = nn.MaxPool2d(kernel_size=2, stride=2)

        self.gap = nn.AdaptiveAvgPool2d(1)

        # ----------------------------------------------------------------------
        # Activity head: same names as InstrumentCNN (fc1/relu_fc/drop/fc2)
        # so the trained v2 classifier transfers via strict=False loading.
        # ----------------------------------------------------------------------
        self.fc1     = nn.Linear(256, 128)
        self.relu_fc = nn.ReLU(inplace=True)
        self.drop    = nn.Dropout(p=dropout)
        self.fc2     = nn.Linear(128, num_classes)

        # ----------------------------------------------------------------------
        # Dominance head: fresh head over the shared backbone feature.
        # ----------------------------------------------------------------------
        self.dom_fc1   = nn.Linear(256, 128)
        self.dom_relu  = nn.ReLU(inplace=True)
        self.dom_drop  = nn.Dropout(p=dropout)
        self.dom_fc2   = nn.Linear(128, num_classes)

    # ------------------------------------------------------------------
    # Shared backbone feature extraction
    # ------------------------------------------------------------------
    def _backbone(self, x: torch.Tensor) -> torch.Tensor:
        """Run the shared convolutional backbone.

        Parameters
        ----------
        x : torch.Tensor
            Input of shape ``(B, 1, 64, n_frames)``.

        Returns
        -------
        torch.Tensor
            Flattened global-average-pooled feature of shape ``(B, 256)``.
        """
        x = self.pool1(self.relu1(self.bn1(self.conv1(x))))
        x = self.pool2(self.relu2(self.bn2(self.conv2(x))))
        x = self.pool3(self.relu3(self.bn3(self.conv3(x))))
        x = self.pool4(self.relu4(self.bn4(self.conv4(x))))
        x = self.gap(x)
        return torch.flatten(x, start_dim=1)  # (B, 256)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """Forward pass returning ONLY the activity head logits.

        Kept signature-compatible with :class:`InstrumentCNN` so that
        :mod:`src.gradcam` and existing inference code work unchanged.

        Returns
        -------
        torch.Tensor
            Activity logits of shape ``(B, num_classes)`` (apply sigmoid).
        """
        feat = self._backbone(x)
        h = self.relu_fc(self.fc1(feat))
        h = self.drop(h)
        return self.fc2(h)

    def forward_dual(self, x: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
        """Forward pass returning both heads' logits.

        Parameters
        ----------
        x : torch.Tensor
            Input of shape ``(B, 1, 64, n_frames)``.

        Returns
        -------
        tuple of torch.Tensor
            ``(activity_logits, dominance_logits)``, each of shape
            ``(B, num_classes)``. Apply sigmoid to the first and softmax to
            the second at consumption time.
        """
        feat = self._backbone(x)
        # Activity head
        h = self.relu_fc(self.fc1(feat))
        h = self.drop(h)
        act_logits = self.fc2(h)
        # Dominance head
        d = self.dom_relu(self.dom_fc1(feat))
        d = self.dom_drop(d)
        dom_logits = self.dom_fc2(d)
        return act_logits, dom_logits


# ============================================================================
# 工具函数
# ============================================================================
def count_parameters(model: nn.Module) -> int:
    """返回模型可训练参数总数。

    Parameters
    ----------
    model : nn.Module
        PyTorch 模型。

    Returns
    -------
    int
        可训练参数总数（requires_grad=True 的参数元素数之和）。
    """
    return sum(p.numel() for p in model.parameters() if p.requires_grad)


def model_summary(
    model: nn.Module,
    input_shape: Tuple[int, ...] = (1, 1, 64, 258),
) -> None:
    """打印模型各层参数与总参数量。

    Parameters
    ----------
    model : nn.Module
        待汇总的模型。
    input_shape : tuple
        输入张量形状（含 batch 维），默认 ``(1, 1, 64, 258)``。
    """
    print("=" * 70)
    print("模型层参数汇总")
    print("=" * 70)
    total = 0
    for name, param in model.named_parameters():
        n = param.numel()
        total += n
        grad = "可训练" if param.requires_grad else "冻结"
        print(f"  {name:45s} {str(tuple(param.shape)):20s} {n:>10d}  [{grad}]")
    print("-" * 70)
    print(f"  总参数量: {total:,d}（约 {total / 1e6:.3f} M）")
    print(f"  INT8 量化后估算大小: {total / 1024 / 1024:.3f} MB")
    print(f"  输入形状: {input_shape}")
    print("=" * 70)


# ============================================================================
# 自检
# ============================================================================
def _self_check() -> None:
    """模块自检：构造模型、打印参数量、前向传播随机输入验证输出形状。"""
    print("=" * 70)
    print("InstrumentCNN 自检")
    print("=" * 70)

    model = InstrumentCNN(num_classes=8)
    n_params = count_parameters(model)
    print(f"可训练参数总数: {n_params:,d}（约 {n_params / 1e6:.3f} M）")
    print(f"INT8 量化后估算大小: {n_params / 1024 / 1024:.3f} MB")

    # 参数量区间校验
    if 600_000 <= n_params <= 800_000:
        print(f"参数量校验: 通过（目标 60-80 万）")
    else:
        print(f"参数量校验: *** 不在目标区间 60-80 万 ***")

    # 前向传播
    model.eval()
    x = torch.randn(1, 1, 64, 258, dtype=torch.float32)
    with torch.no_grad():
        y = model(x)
    print(f"输入形状: {tuple(x.shape)}")
    print(f"输出形状: {tuple(y.shape)}")
    assert y.shape == (1, 8), f"输出形状错误: 期望 (1, 8)，得到 {tuple(y.shape)}"
    print("前向传播校验: 通过")

    # 详细层参数汇总
    print()
    model_summary(model)


if __name__ == "__main__":
    _self_check()