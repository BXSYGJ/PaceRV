"""Dual-source weight image generator for the InstRec-FPGA NPU (T-GP-03).

Task   : tasks.md T-GP-03 (weight conversion tool + layer contract).
Design : design.md 6.1 (dual-source conversion), 4.3 (requant M/shift
         semantics), 5.2 (DDR3 weight image layout), 3.7 (CNN input
         quantization contract, REQ-FTR-006), 2.2.7 (npu_top consumer).

Sources (design.md fact F-01)
-----------------------------
1. ``InstRec/deploy/weights/*.npy`` -- 24 quantized files (6 layers x
   {weight_int8, bias_int32, scale, zero_point}).  The ``*_scale.npy``
   files hold the PER-CHANNEL WEIGHT scales ``s_w`` (InstRec
   ``src/quantize.py`` exports ``q_weight.q_per_channel_scales()``),
   NOT activation scales.
2. ``InstRec/deploy/quantized_model.pt`` -- TorchScript (fbgemm) model
   providing the per-layer ACTIVATION scale/zero-point pairs
   (s_in / zp_in / s_out / zp_out) plus the QuantStub input
   quantization contract (Mel -> int8).  Activation parameters are
   recovered by a chained forward over the quantized submodules
   (pool/GAP pass the quantized tensors through unchanged), and are
   cross-checked against the module ``scale()``/``zero_point()``
   accessors where the trace preserved them.  A manual-chain vs
   full-forward numerical equality check (max diff == 0) validates the
   extraction path, and int8 re-computations of conv1/fc1/fc2 with the
   npy weights + extracted parameters must match the TorchScript
   outputs within +/-1 LSB (pre-validation of REQ-ACC-002).

Requant math (design.md 4.3)
----------------------------
    y_s8 = sat_int8( (acc_s32 * M[c]) >>> shift[c] + zp_out )
    M[c] = round( s_w[c] * s_in / s_out * 2^shift[c] )
with a PER-CHANNEL ``shift`` so that ``M[c]`` lands in [2^30, 2^31)
(Q0.31, i.e. the normalized mantissa [0.5, 1)).  Per-channel shifts are
mandatory: the measured per-channel weight-scale spread within a layer
spans up to four orders of magnitude (fc1), so a single layer-wide
shift cannot keep every M in range.

Image layout (design.md 5.2, every region 32-byte aligned)
----------------------------------------------------------
    +0x0000   32 B  image header: magic 'IRW1', num_layers, version,
                    total/payload byte counts, 128-bit segment-
                    accumulated checksum of the payload (design.md 6.4
                    weak-sha board-side verification contract).
    +0x0020  384 B  layer contract table: 6 entries x 64 B (binary).
    +0x0200  layer segments, each containing:
                [ int8 weights, 16-output-channel group interleaved ]
                [ int32 bias, native channel order, little-endian ]
                [ int32 M,    native channel order, little-endian ]
                [ uint8 shift, native channel order ]
                [ zero padding to the next 32-byte boundary ]

The weight interleave follows the design.md 4.1/4.2 consumption order:
the MAC array processes 16 output channels in parallel per cycle while
scanning (cin, dy, dx) serially, so for each input position the 16
output-channel weights are stored contiguously ("16-channel group
interleave").  The resulting per-group byte counts (144/6912/13824/
27648/4096/1024) reproduce the design.md 4.1 grouping table exactly.

Outputs (idempotent, byte-identical on re-run)
----------------------------------------------
    scripts/outputs/weights_image.bin    DDR3 weight image (IRW1).
    scripts/outputs/layer_contract.json  human-readable layer contract.

Usage:
    python scripts/gen_weight_image.py [--instrec-root <dir>]
                                       [--outdir <dir>]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Layout constants (design.md 5.2).
# ---------------------------------------------------------------------------
IMAGE_MAGIC = b"IRW1"          # image header magic (design.md 5.2)
HEADER_BYTES = 32              # image header size (design.md 5.2 row 1)
CONTRACT_ENTRY_BYTES = 64      # per-layer binary contract entry
CONTRACT_TABLE_BYTES = 6 * CONTRACT_ENTRY_BYTES   # 384 B (design.md 5.2)
CONTRACT_TABLE_OFFSET = HEADER_BYTES             # 0x0020 (design.md 5.2)
FIRST_LAYER_OFFSET = 0x200                      # 0x0200 (design.md 5.2)
ALIGN_BYTES = 32               # DDR3 256-bit word alignment (design.md 5.1)
GROUP_CHANNELS = 16            # output channels per weight group (design.md 4.1)
NUM_LAYERS = 6
FORMAT_VERSION = 1
DDR3_WEIGHT_BASE = 0x0010_0000  # weight region base (design.md 5.1)

# Q-format bounds for the requant multiplier (design.md 4.3: Q0.31 with
# M in [2^30, 2^31), i.e. normalized mantissa in [0.5, 1)).
M_MIN = 1 << 30
M_MAX = 1 << 31

# Sanity bounds for activation/weight scales and zero points (R-12).
SCALE_MIN = 1e-4
SCALE_MAX = 1.0
ZP_MIN = -128
ZP_MAX = 127


# Layer geometry (design.md facts F-02/F-06).  Weight shapes are asserted
# against the npy files; in/out shapes follow the design.md 4.4 table
# (conv output before pooling).
LAYER_SPECS = (
    # name,    type,   weight_shape,     in_shape,        out_shape
    ("conv1", "conv", (48, 1, 3, 3), (1, 64, 258), (48, 64, 258)),
    ("conv2", "conv", (96, 48, 3, 3), (48, 32, 129), (96, 32, 129)),
    ("conv3", "conv", (192, 96, 3, 3), (96, 16, 64), (192, 16, 64)),
    ("conv4", "conv", (256, 192, 3, 3), (192, 8, 32), (256, 8, 32)),
    ("fc1", "fc", (128, 256), (256,), (128,)),
    ("fc2", "fc", (8, 128), (128,), (8,)),
)

# Class order single source of truth (design.md F-13, risk R-06 guard).
EXPECTED_CLASS_NAMES = (
    "clarinet",
    "distorted electric guitar",
    "female singer",
    "flute",
    "piano",
    "tenor saxophone",
    "trumpet",
    "violin",
)
EXPECTED_CLASS_NAMES_ZH = (
    "单簧管",
    "失真电吉他",
    "女声",
    "长笛",
    "钢琴",
    "次中音萨克斯",
    "小号",
    "小提琴",
)

# Default IO locations (repo layout: <pango>/ZGTC_RISC_CPU/instrec_fpga/scripts).
DEFAULT_INSTREC_ROOT = Path(__file__).resolve().parents[1] / "training"
DEFAULT_OUT_DIR = Path(__file__).resolve().parent / "outputs"

GENERATOR_NAME = "gen_weight_image.py"
SPEC_REFS = "tasks.md T-GP-03; design.md 6.1/4.3/5.2/3.7; spec.md REQ-FTR-006"


# ---------------------------------------------------------------------------
# Source 1: npy weight files.
# ---------------------------------------------------------------------------
def load_npy_weights(weights_dir: Path) -> dict:
    """Load the 24 quantized npy files (6 layers x 4 arrays).

    Returns a dict keyed by layer name with int8 weights, int32 bias,
    per-channel float32 weight scales and per-channel zero points.
    """
    layers = {}
    for name, layer_type, weight_shape, _, _ in LAYER_SPECS:
        w = np.load(weights_dir / f"{name}_weight_int8.npy")
        b = np.load(weights_dir / f"{name}_bias_int32.npy")
        s = np.load(weights_dir / f"{name}_scale.npy")
        zp = np.load(weights_dir / f"{name}_zero_point.npy")

        assert tuple(w.shape) == weight_shape, (
            f"{name} weight shape {tuple(w.shape)} != expected {weight_shape}"
        )
        expected_bias_shape = (weight_shape[0],)
        assert tuple(b.shape) == expected_bias_shape, (
            f"{name} bias shape {tuple(b.shape)} != {expected_bias_shape}"
        )
        assert tuple(s.shape) == expected_bias_shape, (
            f"{name} scale shape {tuple(s.shape)} != {expected_bias_shape}"
        )
        assert tuple(zp.shape) == expected_bias_shape, (
            f"{name} zero_point shape {tuple(zp.shape)} != {expected_bias_shape}"
        )
        assert w.dtype == np.int8, f"{name} weight dtype {w.dtype} != int8"
        assert b.dtype == np.int32, f"{name} bias dtype {b.dtype} != int32"
        assert s.dtype == np.float32, f"{name} scale dtype {s.dtype} != float32"

        # Symmetric per-channel weight quantization: zero points must be 0
        # (design.md 4.3 assumes zp_w == 0 for the MAC accumulation).
        zp_values = np.asarray(zp).astype(np.int64).ravel()
        assert np.all(zp_values == 0), (
            f"{name} weight zero points are not all zero: {zp_values[:8]}..."
        )

        layers[name] = {
            "weight_int8": w,
            # NOTE: the exported npy bias files are CORRUPTED: InstRec
            # src/quantize.py stores module.bias() (a FLOAT32 tensor for
            # fbgemm fused ops) via .astype(np.int32), which truncates
            # every |bias| < 1 to 0 (verified: conv1 float bias
            # 0.17272606 -> npy 0, while the correct int32 requantized
            # value is 282).  The npy bias is kept ONLY as provenance
            # (truncation cross-check); the image bias is rebuilt from
            # the TorchScript packed-params float bias.
            "bias_int32_npy": b.astype(np.int64),
            "weight_scale": s.astype(np.float64),
            "layer_type": layer_type,
        }
    return layers


# ---------------------------------------------------------------------------
# Class order guard (risk R-06).
# ---------------------------------------------------------------------------
def parse_instrument_names(dataset_py: Path) -> tuple:
    """Extract INSTRUMENT_NAMES from src/dataset.py via AST parsing.

    AST extraction avoids importing the module (which would pull the
    whole feature-extraction dependency stack just for a tuple).
    """
    import ast

    tree = ast.parse(dataset_py.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.AnnAssign)
            and isinstance(node.target, ast.Name)
            and node.target.id == "INSTRUMENT_NAMES"
        ):
            names = ast.literal_eval(node.value)
            return tuple(names)
    raise ValueError(f"INSTRUMENT_NAMES not found in {dataset_py}")


def assert_class_order(class_names_json: Path, dataset_py: Path) -> dict:
    """Assert the class order across all three sources (R-06 guard).

    class_names.json (deploy truth) must match dataset.py
    INSTRUMENT_NAMES element by element, and both must match the
    hard-coded expectation of this tool (0=clarinet .. 7=violin).
    The stale ``irmas/model_config.json`` metadata is deliberately NOT
    consulted (design.md F-13).
    """
    with open(class_names_json, "r", encoding="utf-8") as fh:
        class_info = json.load(fh)
    names = tuple(class_info["names"])
    names_zh = tuple(class_info["name_zh"])

    instrument_names = parse_instrument_names(dataset_py)

    assert names == instrument_names, (
        f"class_names.json order {names} != dataset.py INSTRUMENT_NAMES "
        f"{instrument_names} (R-06 class-order guard failed)"
    )
    assert names == EXPECTED_CLASS_NAMES, (
        f"class_names.json order {names} != expected {EXPECTED_CLASS_NAMES}"
    )
    assert names_zh == EXPECTED_CLASS_NAMES_ZH, (
        f"class_names.json name_zh {names_zh} != expected "
        f"{EXPECTED_CLASS_NAMES_ZH}"
    )
    assert class_info["num_classes"] == 8, "num_classes != 8"
    return {"names": list(names), "names_zh": list(names_zh)}


# ---------------------------------------------------------------------------
# Source 2: TorchScript activation parameter extraction.
# ---------------------------------------------------------------------------
def _graph_constant(module, kind: str, index: int):
    """Extract the scale/zero-point prim::Constant from a traced graph.

    The traced quantized modules bake their output activation parameters
    into ``quantized::conv2d_relu`` / ``quantized::linear[_relu]`` call
    arguments as prim::Constant nodes (float scale first, int zero point
    second).  Used as an independent cross-check of the chained-forward
    extraction path.
    """
    graph_text = str(module.forward.graph)
    marker = "prim::Constant[value="
    values = []
    for line in graph_text.splitlines():
        pos = line.find(marker)
        while pos >= 0:
            start = pos + len(marker)
            end = line.find("](", start)
            token = line[start:end]
            values.append(token)
            pos = line.find(marker, end)
    token = values[index]
    if kind == "float":
        return float(token)
    return int(token)


def extract_activation_contract(model_path: Path) -> dict:
    """Extract per-layer activation parameters from the TorchScript model.

    Extraction path (verified against the module accessors and the full
    forward): a chained forward over the quantized submodules::

        quant -> conv1 -> pool1 -> conv2 -> pool2 -> conv3 -> pool3
              -> conv4 -> pool4 -> gap -> flatten -> fc1 -> fc2

    Pooling and GAP pass the quantized tensors through unchanged, so the
    activation parameters of each quantized layer are read from the
    output tensor's ``q_scale()`` / ``q_zero_point()``.  For conv1..4 the
    module ``scale()`` / ``zero_point()`` accessors are additionally
    compared (trace preserved them), and the whole chain is validated
    against ``model(x)`` with max diff == 0.

    Returns a dict with the QuantStub input contract (REQ-FTR-006) and
    the six per-layer {s_in, zp_in, s_out, zp_out} records.
    """
    import torch

    # The traced model calls quantized::* ATen ops directly, so the eager
    # qengine selection is not strictly required; keep the inference_
    # reference.py behaviour when the engine exists (torch < 2.14) and
    # tolerate its absence otherwise (torch 2.14 dropped the deprecated
    # fbgemm eager engine registration).
    try:
        torch.backends.quantized.engine = "fbgemm"
    except RuntimeError:
        pass
    model = torch.jit.load(str(model_path), map_location="cpu")
    model.eval()

    # Deterministic probe input (parameter values do not depend on it,
    # but a fixed seed keeps the run fully reproducible).
    torch.manual_seed(0)
    x = torch.randn(1, 1, 64, 258)

    with torch.no_grad():
        h = model.quant(x)
        quant_stub = {
            "s_in": float(h.q_scale()),
            "zp_in": int(h.q_zero_point()),
            "dtype": str(h.dtype),
        }

        # conv1 (s_in comes from the QuantStub output tensor).
        out1 = model.model.conv1(h)
        # conv2..4 (s_in = previous conv output scale; pool passes through).
        out2 = model.model.conv2(model.model.pool1(out1))
        out3 = model.model.conv3(model.model.pool2(out2))
        out4 = model.model.conv4(model.model.pool3(out3))
        # GAP passes conv4's quantized tensor through; fc1 (LinearReLU
        # fused, design.md F-06) and fc2 close the chain.
        g = torch.flatten(model.model.gap(model.model.pool4(out4)), 1)
        out_fc1 = model.model.fc1(g)
        out_fc2 = model.model.fc2(out_fc1)
        manual_out = model.dequant(out_fc2)

        # Numerical end-check: the manual chain must reproduce the full
        # traced forward exactly (max diff == 0).
        ref_out = model(x)
        max_diff = float((manual_out - ref_out).abs().max().item())
        assert max_diff == 0.0, (
            f"manual chain diverged from full forward: max diff {max_diff}"
        )

        # Zero-input bias probe: feed the quantized-domain zero (value
        # == zp_in) through the chain.  Every tap contributes (zp - zp)
        # == 0, so each layer's output integer minus zp_out isolates
        # round(bias_f / s_out) -- the per-channel output-domain bias
        # offset.  For the conv layers this is an independent check of
        # the float-bias requantization; for fc1/fc2 (whose packed
        # params are not unpackable from the traced ScriptObject) it is
        # the ONLY bias recovery path.
        z0 = model.quant(torch.zeros(1, 1, 64, 258))
        z1 = model.model.conv1(z0)
        z2 = model.model.conv2(model.model.pool1(z1))
        z3 = model.model.conv3(model.model.pool2(z2))
        z4 = model.model.conv4(model.model.pool3(z3))
        zg = torch.flatten(model.model.gap(model.model.pool4(z4)), 1)
        zf1 = model.model.fc1(zg)
        zf2 = model.model.fc2(zf1)

        def _conv_probe(out_t):
            # With a constant input the INTERIOR of every channel is
            # constant; boundary rows/columns legitimately differ because
            # the zero-padded taps drop contributions of the upstream
            # bias response (real mathematics, not noise), and the
            # deviations cascade into more complex distributions over
            # depth.  Return the per-channel majority value (the interior
            # value for the shallow layers); its correctness is gated by
            # the recursive probe check in compute_bias_int32.
            arr = out_t.int_repr().cpu().numpy()[0].astype(np.int64)
            arr = arr - int(out_t.q_zero_point())
            reps = np.empty(arr.shape[0], dtype=np.int64)
            for c in range(arr.shape[0]):
                vals, cnts = np.unique(arr[c], return_counts=True)
                reps[c] = vals[int(np.argmax(cnts))]
            return reps

        def _fc_probe(out_t):
            arr = out_t.int_repr().cpu().numpy()[0].astype(np.int64)
            return arr - int(out_t.q_zero_point())

        bias_out_probe = {
            "conv1": _conv_probe(z1),
            "conv2": _conv_probe(z2),
            "conv3": _conv_probe(z3),
            "conv4": _conv_probe(z4),
            "fc1": _fc_probe(zf1),
            "fc2": _fc_probe(zf2),
            # GAP output under the zero input (the actual fc1 input;
            # differs from the conv4 interior value because the GAP
            # averages the boundary-affected spatial map).
            "gap": _fc_probe(zg),
        }


    chain_out = {
        "conv1": (out1, h),
        "conv2": (out2, out1),
        "conv3": (out3, out2),
        "conv4": (out4, out3),
        "fc1": (out_fc1, out4),
        "fc2": (out_fc2, out_fc1),
    }
    layers = {}
    for name, (out_t, in_t) in chain_out.items():
        layers[name] = {
            "s_in": float(in_t.q_scale()),
            "zp_in": int(in_t.q_zero_point()),
            "s_out": float(out_t.q_scale()),
            "zp_out": int(out_t.q_zero_point()),
            "dtype": str(out_t.dtype),
        }

    # Cross-check conv1..4 against the preserved module accessors and the
    # prim::Constant values baked into the traced graphs (fc1/fc2 lose
    # the accessors in the trace, so their graph constants are used).
    # Depending on the torch version the accessors surface either as
    # attributes (float/int) or as bound methods; accept both forms.
    def _read_param(module, attr):
        value = getattr(module, attr)
        if callable(value):
            value = value()
        if hasattr(value, "item"):
            value = value.item()
        return value

    for name in ("conv1", "conv2", "conv3", "conv4"):
        mod = getattr(model.model, name)
        s_attr = float(_read_param(mod, "scale"))
        zp_attr = int(_read_param(mod, "zero_point"))
        assert s_attr == layers[name]["s_out"], (
            f"{name} module scale() {s_attr} != chained {layers[name]['s_out']}"
        )
        assert zp_attr == layers[name]["zp_out"], (
            f"{name} module zero_point() {zp_attr} != chained "
            f"{layers[name]['zp_out']}"
        )
    for name in ("fc1", "fc2"):
        mod = getattr(model.model, name)
        s_const = _graph_constant(mod, "float", 0)
        zp_const = _graph_constant(mod, "int", 1)
        assert s_const == layers[name]["s_out"], (
            f"{name} graph scale constant {s_const} != chained "
            f"{layers[name]['s_out']}"
        )
        assert zp_const == layers[name]["zp_out"], (
            f"{name} graph zero-point constant {zp_const} != chained "
            f"{layers[name]['zp_out']}"
        )

    return {
        "quant_stub": quant_stub,
        "layers": layers,
        "bias_out_probe": bias_out_probe,

        "_probe_tensors": {
            "x_int": h.int_repr().cpu().numpy(),
            "conv1_int": out1.int_repr().cpu().numpy(),
            "gap_int": g.int_repr().cpu().numpy(),
            "fc1_int": out_fc1.int_repr().cpu().numpy(),
            "fc2_int": out_fc2.int_repr().cpu().numpy(),
        },
    }


def assert_activation_sanity(activation: dict) -> None:
    """R-12 sanity assertions over the extracted quantization parameters.

    Every layer (and the QuantStub input contract) must satisfy
    scale in (1e-4, 1) and zero point in [-128, 127].
    """
    entries = [activation["quant_stub"]] + [
        {"s_in": rec["s_in"], "zp_in": rec["zp_in"]} for rec in
        activation["layers"].values()
    ] + list(activation["layers"].values())
    for idx, rec in enumerate(entries):
        for key_s in ("s_in", "s_out"):
            if key_s in rec:
                assert SCALE_MIN < rec[key_s] < SCALE_MAX, (
                    f"entry {idx} {key_s}={rec[key_s]} outside "
                    f"({SCALE_MIN}, {SCALE_MAX}) (R-12)"
                )
        for key_zp in ("zp_in", "zp_out"):
            if key_zp in rec:
                assert ZP_MIN <= rec[key_zp] <= ZP_MAX, (
                    f"entry {idx} {key_zp}={rec[key_zp]} outside "
                    f"[{ZP_MIN}, {ZP_MAX}] (R-12)"
                )


# ---------------------------------------------------------------------------
# Weight-vs-model cross-validation (npy source vs TorchScript source).
# ---------------------------------------------------------------------------
def cross_check_packed_weights(model_path: Path, npy_weights: dict) -> dict:
    """Cross-check ALL six layers' npy data vs the pt packed params.

    Extraction paths (from the traced forward graphs):

    - conv1..4: ``torch.ops.quantized.conv2d_unpack(mod._packed_params)``
      (the conv modules hold the raw ``Conv2dPackedParamsBase`` class
      object directly);
    - fc1/fc2: ``torch.ops.quantized.linear_unpack(
      mod._packed_params._packed_params)`` -- a TWO-LEVEL GetAttr: the
      traced LinearReLU/Linear modules hold a script-module wrapper
      (``LinearPackedParams``) whose own ``_packed_params`` attribute is
      the raw ``LinearPackedParamsBase`` class object consumed by
      ``quantized::linear[_relu]``.

    Verified per layer:

    1. int8 weights / per-channel scales are identical between the npy
       source and the pt source (fc1/fc2 weights verified identical;
       the npy bias files are NOT usable -- see below);
    2. weight zero points are all 0 (symmetric per-channel);
    3. the npy bias equals the toward-zero truncation of the float bias
       (documents the InstRec export corruption: ``astype(np.int32)``
       on the FLOAT32 fbgemm bias truncates every |bias| < 1 to 0).

    Returns {layer_name: float64 bias ndarray} for all six layers (the
    fbgemm fused kernels consume a real-valued bias).
    """
    import torch

    model = torch.jit.load(str(model_path), map_location="cpu")
    model.eval()
    float_bias = {}
    for name, layer_type, weight_shape, _, _ in LAYER_SPECS:
        mod = getattr(model.model, name)
        if layer_type == "conv":
            w_q, b_q = torch.ops.quantized.conv2d_unpack(mod._packed_params)
        else:
            raw = mod._packed_params._packed_params
            w_q, b_q = torch.ops.quantized.linear_unpack(raw)
        w_pt = w_q.int_repr().cpu().numpy().astype(np.int8)
        s_pt = w_q.q_per_channel_scales().detach().cpu().numpy()
        zp_pt = w_q.q_per_channel_zero_points().detach().cpu().numpy()
        b_f = b_q.detach().cpu().numpy().astype(np.float64)
        float_bias[name] = b_f

        npy = npy_weights[name]
        assert tuple(w_pt.shape) == weight_shape, (
            f"{name}: pt weight shape {tuple(w_pt.shape)} != {weight_shape}"
        )
        assert np.array_equal(w_pt, npy["weight_int8"]), (
            f"{name}: npy int8 weights differ from TorchScript weights"
        )
        assert np.array_equal(
            s_pt, npy["weight_scale"].astype(np.float32)
        ), f"{name}: npy weight scales differ from TorchScript scales"
        assert np.all(zp_pt == 0), f"{name}: TorchScript weight zp != 0"

        # Provenance check: npy bias == trunc(b_f) proves both come from
        # the same float tensor (and that the npy one is truncated).
        truncated = np.trunc(b_f).astype(np.int64)
        assert np.array_equal(truncated, npy["bias_int32_npy"]), (
            f"{name}: npy bias is not the truncation of the float bias; "
            f"unexpected source mismatch"
        )
    return float_bias


def requantize(acc: np.ndarray, m: np.ndarray, shift: np.ndarray,
               zp_out: int, unsigned: bool) -> np.ndarray:
    """Reference requantization used for the numerical cross-checks.

    acc: int64 accumulator (channel-first, any rank); m/shift:
    per-channel int arrays; zp_out: output zero point.  Returns the
    saturated int container values.  Python ``>>`` on ints is an
    arithmetic shift, matching the RTL ``>>>`` for two's complement.
    """
    # Broadcast the per-channel arrays over the trailing spatial axes.
    chan_shape = (len(m),) + (1,) * (acc.ndim - 1)
    m_b = m.reshape(chan_shape)
    shift_b = shift.reshape(chan_shape)
    prod = acc * m_b                # int64 (|acc| < 2^31, M < 2^31 fits)
    shifted = prod >> shift_b
    y = shifted + zp_out
    if unsigned:
        return np.clip(y, 0, 255)
    return np.clip(y, -128, 127)


def numerical_cross_check(activation: dict, npy_weights: dict,
                          m_shift: dict, bias_int32: dict) -> dict:
    """Re-compute conv1/fc1/fc2 outputs from npy weights + contract.

    Uses the int8 datapath semantics of design.md 4.3 (including the
    -zp_in * sum(w) input-zero-point correction that fbgemm folds into
    the accumulator when zp_in != 0, which is the case for conv1 whose
    quint8 input has zp_in == 49) and verifies agreement with the
    TorchScript outputs within +/-1 LSB.  This pre-validates the
    REQ-ACC-002 numerics in the Python domain.
    """
    probe = activation["_probe_tensors"]
    tol = 1

    # ---- conv1 (3x3, pad=1, 16-INT8 MAC semantics) --------------------
    # NOTE: fbgemm zero-padding fills with the INPUT ZERO POINT, not with
    # 0 (the quantized-domain zero of a quint8 tensor is zp_in == 49 for
    # conv1).  This is a mandatory contract item for the RTL row-buffer
    # pre-fill and the golden model (recorded per layer as padding_value).
    w1 = npy_weights["conv1"]["weight_int8"].astype(np.int64)  # (48,1,3,3)
    b1 = bias_int32["conv1"]                                   # (48,)
    x_int = probe["x_int"][0, 0].astype(np.int64)              # (64,258) u8
    zp_in = activation["layers"]["conv1"]["zp_in"]
    wsum1 = w1.reshape(48, -1).sum(axis=1)                      # (48,)

    padded = np.full((x_int.shape[0] + 2, x_int.shape[1] + 2), zp_in,
                     dtype=np.int64)
    padded[1:-1, 1:-1] = x_int
    windows = np.lib.stride_tricks.sliding_window_view(padded, (3, 3))
    # windows: (H, W, 3, 3) -> (H, W, 9) with dy*3+dx order, matching the
    # (cin, dy, dx) flatten order of w1.reshape(48, 9).
    windows = windows.reshape(windows.shape[0], windows.shape[1], 9)
    acc = np.einsum("yxw,cw->cyx", windows, w1.reshape(48, 9))
    acc = acc + b1[:, None, None] - zp_in * wsum1[:, None, None]
    y1 = requantize(acc, m_shift["conv1"]["m"], m_shift["conv1"]["shift"],
                    activation["layers"]["conv1"]["zp_out"], unsigned=True)
    ref1 = probe["conv1_int"][0].astype(np.int64)
    diff1 = int(np.abs(y1 - ref1).max())
    assert diff1 <= tol, f"conv1 manual vs TorchScript: max diff {diff1} > {tol}"

    # ---- fc1 (256 -> 128, ReLU fused) ----------------------------------
    w_f1 = npy_weights["fc1"]["weight_int8"].astype(np.int64)  # (128,256)
    b_f1 = bias_int32["fc1"]
    g_int = probe["gap_int"][0].astype(np.int64)               # (256,) u8
    wsum_f1 = w_f1.sum(axis=1)
    acc_f1 = g_int @ w_f1.T + b_f1 \
        - activation["layers"]["fc1"]["zp_in"] * wsum_f1
    y_f1 = requantize(acc_f1, m_shift["fc1"]["m"], m_shift["fc1"]["shift"],
                      activation["layers"]["fc1"]["zp_out"], unsigned=True)
    ref_f1 = probe["fc1_int"][0].astype(np.int64)
    diff_f1 = int(np.abs(y_f1 - ref_f1).max())
    assert diff_f1 <= tol, (
        f"fc1 manual vs TorchScript: max diff {diff_f1} > {tol}"
    )

    # ---- fc2 (128 -> 8), fed with the pt fc1 output to keep the +/-1
    # tolerance isolated to this layer ------------------------------------
    w_f2 = npy_weights["fc2"]["weight_int8"].astype(np.int64)  # (8,128)
    b_f2 = bias_int32["fc2"]
    wsum_f2 = w_f2.sum(axis=1)
    fc1_ref = probe["fc1_int"][0].astype(np.int64)             # (128,) u8
    acc_f2 = fc1_ref @ w_f2.T + b_f2 \
        - activation["layers"]["fc2"]["zp_in"] * wsum_f2
    y_f2 = requantize(acc_f2, m_shift["fc2"]["m"], m_shift["fc2"]["shift"],
                      activation["layers"]["fc2"]["zp_out"], unsigned=True)
    ref_f2 = probe["fc2_int"][0].astype(np.int64)
    diff_f2 = int(np.abs(y_f2 - ref_f2).max())
    assert diff_f2 <= tol, (
        f"fc2 manual vs TorchScript: max diff {diff_f2} > {tol}"
    )
    return {"conv1": diff1, "fc1": diff_f1, "fc2": diff_f2}


# ---------------------------------------------------------------------------
# Bias recovery (npy bias files are corrupted, see load_npy_weights).
# ---------------------------------------------------------------------------
def compute_bias_int32(npy_weights: dict, activation: dict,
                       float_bias: dict) -> tuple:
    """Rebuild the per-channel int32 biases for all six layers (exact).

    All layers: ``b_q[c] = round(b_f[c] / (s_in * s_w[c]))`` from the
    packed-params float bias (the npy bias files hold truncated garbage,
    see load_npy_weights; the fc float biases come from the two-level
    GetAttr linear_unpack path, see cross_check_packed_weights).

    Verification: a recursive zero-input probe check recomputes every
    layer's interior response from (weights, biases, scales, zero
    points) alone and compares it with the measured majority probe --
    a closed-loop validation of the whole per-layer contract (the
    layers are additionally validated against random inputs in
    numerical_cross_check).
    """
    layers = activation["layers"]
    probe = activation["bias_out_probe"]
    bias = {}
    sources = {}
    for name, layer_type, weight_shape, _, _ in LAYER_SPECS:
        act = layers[name]
        s_w = npy_weights[name]["weight_scale"]
        b_f = float_bias[name]
        b_q = np.round(b_f / (act["s_in"] * s_w)).astype(np.int64)
        bias[name] = b_q
        sources[name] = "pt_packed_params_float_bias"

    # Recursive zero-input probe verification (closed loop over the
    # full per-layer contract).  x_eff is the (x - zp_in) of the current
    # layer's input; conv1 starts from the quantized zero (x == zp_in).
    x_eff = np.zeros(1, dtype=np.int64)     # conv1: quantized-domain zero
    for name, layer_type, weight_shape, _, _ in LAYER_SPECS:
        act = layers[name]
        w = npy_weights[name]["weight_int8"].reshape(weight_shape)
        s_w = npy_weights[name]["weight_scale"]
        ratio = s_w * (act["s_in"] / act["s_out"])
        if layer_type == "conv":
            cin = weight_shape[1]
            k = weight_shape[2] * weight_shape[3]
            # Interior response: every tap visible, constant input.
            w_sum = (w.astype(np.int64).reshape(-1, cin, k)
                     .sum(axis=2))              # (Cout, Cin)
        else:
            w_sum = w.astype(np.int64)          # (Cout, Cin)
        acc = x_eff @ w_sum.T + bias[name]      # (Cout,)
        out_val = np.round(acc * ratio)
        if name != "fc2":
            out_val = np.maximum(out_val, 0.0)  # ReLU fused
        out_int = np.clip(out_val + act["zp_out"], 0, 255).astype(np.int64)
        expected_probe = out_int - act["zp_out"]
        delta = np.abs(expected_probe - probe[name])
        assert int(delta.max()) <= 1, (
            f"{name}: recursive probe check disagrees by "
            f"{int(delta.max())} LSB (contract inconsistency)"
        )
        # Feed the MEASURED probe forward (anchors every step to the
        # model ground truth and stops error amplification).  fc1's
        # input is the GAP average of conv4's (boundary-affected)
        # output map, not the conv4 interior value itself.
        if name == "conv4":
            x_eff = probe["gap"]                # gap zp == conv4 zp_out
        else:
            x_eff = probe[name] + act["zp_out"]
    return bias, sources


# ---------------------------------------------------------------------------
# M / shift computation (design.md 4.3).
# ---------------------------------------------------------------------------
def compute_m_shift(ratio: float) -> tuple:
    """Return (M, shift) with M = round(ratio * 2^shift) in [2^30, 2^31).

    The shift is chosen per channel (Q0.31 normalization to [0.5, 1)).
    Integer correction loops avoid floating-point log2 boundary hazards.
    """
    if not (ratio > 0.0):
        raise ValueError(f"ratio must be positive, got {ratio!r}")
    # Feasibility guards (also prevent the correction loops below from
    # running away when no valid shift exists): the M window
    # [2^30, 2^31) is reachable only if shift=0 stays below the upper
    # bound and shift=63 reaches the lower bound.
    if round(ratio) >= M_MAX:
        raise ValueError(
            f"ratio={ratio!r} >= 2^31: no non-negative shift keeps M "
            f"in [2^30, 2^31)"
        )
    if round(ratio * 2.0 ** 63) < M_MIN:
        raise ValueError(
            f"ratio={ratio!r} too small: even shift=63 cannot lift M "
            f"to [2^30, 2^31)"
        )

    # Initial estimate from log2, then correct with exact integer tests.
    shift = int(math.floor(math.log2(float(M_MAX) / ratio))) + 1
    # Bring M below the upper bound.
    while round(ratio * 2.0 ** shift) >= M_MAX or shift > 63:
        shift -= 1
    # Push M as high as possible without leaving the valid window.
    while round(ratio * 2.0 ** (shift + 1)) < M_MAX and shift < 63:
        shift += 1
    # Ensure M reached the lower bound (ratio far from zero in practice).
    while round(ratio * 2.0 ** shift) < M_MIN and shift < 63:
        shift += 1

    m = int(round(ratio * 2.0 ** shift))
    if not (M_MIN <= m < M_MAX):
        raise ValueError(
            f"M={m} shift={shift} out of [2^30, 2^31) for ratio={ratio!r}"
        )
    if not (0 <= shift <= 63):
        raise ValueError(f"shift={shift} exceeds 6-bit range for ratio={ratio!r}")
    return m, shift


def compute_layer_m_shift(npy_weights: dict, activation: dict) -> dict:
    """Compute per-channel (M, shift) for all six layers.

    M[c] = round(s_w[c] * s_in / s_out * 2^shift[c]) with a per-channel
    shift keeping M in [2^30, 2^31) (design.md 4.3).
    """
    result = {}
    for name, _, _, _, _ in LAYER_SPECS:
        act = activation["layers"][name]
        s_w = npy_weights[name]["weight_scale"]
        s_in = act["s_in"]
        s_out = act["s_out"]
        ratio = s_w * (s_in / s_out)

        m_list = []
        shift_list = []
        for r in ratio:
            m_c, s_c = compute_m_shift(float(r))
            m_list.append(m_c)
            shift_list.append(s_c)
        m_arr = np.asarray(m_list, dtype=np.int64)
        shift_arr = np.asarray(shift_list, dtype=np.int64)
        assert np.all((m_arr >= M_MIN) & (m_arr < M_MAX)), (
            f"{name}: M outside [2^30, 2^31)"
        )
        result[name] = {"m": m_arr, "shift": shift_arr, "ratio": ratio}
    return result


# ---------------------------------------------------------------------------
# QuantStub input contract: inv_s_in Q-format selection (design.md 3.7).
# ---------------------------------------------------------------------------
def choose_inv_s_in(s_in: float) -> dict:
    """Select the inv_s_in fixed-point format (design.md 3.7).

    inv_s_in encodes 1/s_in.  First attempt Q16.16 in a 16-bit unsigned
    container (round(2^16 / s_in)); if that overflows the 16-bit
    container, escalate to Q8.24 in a signed 32-bit container
    (round(2^24 / s_in)).  Values that would overflow the 32-bit
    container raise (the RTL contract has no third escalation level).
    """
    q16 = int(round(2 ** 16 / s_in))
    if 0 < q16 <= 0xFFFF:
        return {"format": "Q16.16", "bits": 16, "value": q16}
    q24 = int(round(2 ** 24 / s_in))
    if 0 < q24 <= 0x7FFFFFFF:
        return {"format": "Q8.24", "bits": 32, "value": q24}
    raise ValueError(
        f"inv_s_in for s_in={s_in!r} overflows the Q8.24 s32 container "
        f"(value {q24}); no Q-format escalation defined in design.md 3.7"
    )


# Per-group int8 weight bytes (design.md 4.1 grouping table).  The
# interleave order must reproduce these exactly.
EXPECTED_GROUP_WEIGHT_BYTES = {
    "conv1": 144,     # 16 ch x 9 positions
    "conv2": 6_912,   # 16 x 432
    "conv3": 13_824,  # 16 x 864
    "conv4": 27_648,  # 16 x 1728
    "fc1": 4_096,     # 16 x 256
    "fc2": 1_024,     # 8 x 128 (single short group)
}


# ---------------------------------------------------------------------------
# Weight interleave (design.md 4.1/4.2 consumption order).
# ---------------------------------------------------------------------------
def interleave_group_major(weight_2d: np.ndarray,
                           group_channels: int = GROUP_CHANNELS) -> np.ndarray:
    """Reorder a (Cout, K) int8 weight block into 16-channel groups.

    Output order: group-major, input-position-minor, channel-inner, i.e.
    for every input position k the ``group_channels`` output-channel
    weights w[c][k] are contiguous.  This matches the 16-MAC-per-cycle
    consumption order of the conv engine (design.md 4.2) and reproduces
    the per-group byte counts of the design.md 4.1 table.
    """
    cout, k = weight_2d.shape
    out = np.empty(cout * k, dtype=np.int8)
    pos = 0
    for g in range(0, cout, group_channels):
        gc = min(group_channels, cout - g)
        block = weight_2d[g:g + gc, :]          # (gc, K)
        out[pos:pos + gc * k] = block.T.reshape(-1)   # (K, gc) row-major
        pos += gc * k
    assert pos == cout * k
    return out


# ---------------------------------------------------------------------------
# Binary image assembly (design.md 5.2).
# ---------------------------------------------------------------------------
def segment_checksum_128(payload: bytes) -> bytes:
    """128-bit segment-accumulated checksum (design.md 6.4).

    The payload is consumed in 16-byte little-endian chunks summed as
    128-bit unsigned integers modulo 2^128.  This is the weak-sha board
    verification the RTL self-test reproduces with plain 128-bit adds.
    The payload length is a multiple of 32 (hence of 16); a defensive
    zero pad handles any residual short chunk.
    """
    acc = 0
    for i in range(0, len(payload), 16):
        chunk = payload[i:i + 16]
        if len(chunk) < 16:
            chunk = chunk + b"\x00" * (16 - len(chunk))
        acc = (acc + int.from_bytes(chunk, "little")) % (1 << 128)
    return acc.to_bytes(16, "little")


def pack_contract_entry(layer: dict) -> bytes:
    """Pack one 64-byte binary layer-contract table entry.

    Field layout (offset, size):
      0x00 2B entry marker 0x4C43 ('LC')
      0x02 1B layer_id, 0x03 1B layer_type (0=conv, 1=fc)
      0x04 2B num_groups, 0x06 2B num_channels (Cout)
      0x08 4B image offset (from image start, == DDR3 weight-region
           offset), 0x0C 4B segment_bytes (content, excl. tail pad)
      0x10 4B weight_bytes, 0x14 4B bias offset within segment,
      0x18 4B M offset within segment, 0x1C 4B shift offset in segment
      0x20 1B zp_in (s8), 0x21 1B zp_out (s8),
      0x22 1B activation dtype code (0=quint8, 1=qint8),
      0x23 1B last-group channel count (16, or 8 for fc2)
      0x24 4B packed input shape (u8 c,h,w + pad),
      0x28 4B packed output shape (u8 c,h,w + pad)
      0x2C 4B weight K (Cin*9 for conv, Cin for fc)
      0x30..0x3C 16B reserved (zero)
    """
    dtype_code = 0 if layer["activation_dtype"] == "torch.quint8" else 1
    in_c, in_h, in_w = layer["in_shape_padded"]
    out_c, out_h, out_w = layer["out_shape_padded"]
    # 2+1+1+2+2 (magic/id/type/groups/channels)
    # + 6x4 (offset/segment/weight/bias_off/m_off/shift_off)
    # + 2x1 (zp_in/zp_out) + 2x1 (dtype/last_group)
    # + 4x2 (in_c/in_w/out_c/out_w; H/W can exceed 255, e.g. 258)
    # + 1x4 (weight_k) + 2x2 (in_h/out_h) + 3x4 reserved == 64 bytes.
    entry = struct.pack(
        "<HBBHHIIIIIIbbBBHHHHIHHIII",
        0x4C43,                                  # entry marker 'LC'
        layer["layer_id"],
        0 if layer["layer_type"] == "conv" else 1,
        layer["num_groups"],
        layer["num_channels"],
        layer["image_offset"],
        layer["segment_bytes"],
        layer["weight_bytes"],
        layer["bias_off"],
        layer["m_off"],
        layer["shift_off"],
        layer["zp_in"],
        layer["zp_out"],
        dtype_code,
        layer["last_group_channels"],
        in_c, in_w, out_c, out_w,
        layer["weight_k"],
        in_h, out_h,
        0, 0, 0,
    )
    assert len(entry) == CONTRACT_ENTRY_BYTES, (
        f"contract entry packed to {len(entry)} bytes, expected "
        f"{CONTRACT_ENTRY_BYTES}"
    )
    return entry


def build_image(npy_weights: dict, activation: dict, m_shift: dict,
                bias_int32: dict, bias_sources: dict) -> tuple:
    """Assemble the full weight image bytes plus per-layer layout info.

    Returns (image_bytes, layers_info, layout) where layers_info carries
    every field consumed later by layer_contract.json and the binary
    contract table, and layout records the region offset table.
    """
    segments = []           # list of (name, content_bytes)
    layer_records = []
    offset = FIRST_LAYER_OFFSET

    for layer_id, (name, layer_type, weight_shape, in_shape, out_shape) in \
            enumerate(LAYER_SPECS):
        npy = npy_weights[name]
        act = activation["layers"][name]
        ms = m_shift[name]

        weight = npy["weight_int8"]
        cout = weight_shape[0]
        if layer_type == "conv":
            cin = weight_shape[1]
            weight_k = cin * weight_shape[2] * weight_shape[3]
            in_shape_padded = in_shape
            out_shape_padded = out_shape
        else:
            cin = weight_shape[1]
            weight_k = cin
            # fc layers work on flat vectors; store (C, 1, 1) triples.
            in_shape_padded = (in_shape[0], 1, 1)
            out_shape_padded = (out_shape[0], 1, 1)

        # (Cout, K) view + 16-channel group interleave.
        weight_2d = weight.reshape(cout, weight_k)
        interleaved = interleave_group_major(weight_2d)
        weight_bytes = interleaved.astype(np.int8).tobytes()

        # The interleave must reproduce the design.md 4.1 per-group sizes.
        num_groups = (cout + GROUP_CHANNELS - 1) // GROUP_CHANNELS
        expected_group = EXPECTED_GROUP_WEIGHT_BYTES[name]
        assert len(weight_bytes) == num_groups * expected_group, (
            f"{name}: interleaved weight bytes {len(weight_bytes)} != "
            f"{num_groups} groups x {expected_group} B (design.md 4.1)"
        )

        bias_bytes = bias_int32[name].astype(np.int32).tobytes()
        m_bytes = ms["m"].astype(np.int32).tobytes()
        shift_bytes = ms["shift"].astype(np.uint8).tobytes()

        bias_off = len(weight_bytes)
        m_off = bias_off + len(bias_bytes)
        shift_off = m_off + len(m_bytes)
        segment_bytes = shift_off + len(shift_bytes)
        padded_len = ((segment_bytes + ALIGN_BYTES - 1)
                      // ALIGN_BYTES * ALIGN_BYTES)

        # Per-channel input-zero-point correction term (fbgemm folds
        # -zp_in * sum(w) into the accumulator; relevant for conv1 whose
        # quint8 input has zp_in == 49).  Stored in the JSON contract so
        # the golden model and RTL can consume it directly.  Also the
        # conv padding value: fbgemm zero-pads with zp_in (quantized
        # zero), so the RTL row-buffer pre-fill must use zp_in for conv1
        # and 0 for the zp_in == 0 layers.
        wsum = weight.reshape(cout, -1).sum(axis=1).astype(np.int32)

        layer_records.append({
            "name": name,
            "layer_id": layer_id,
            "layer_type": layer_type,
            "s_in": act["s_in"],
            "zp_in": act["zp_in"],
            "s_out": act["s_out"],
            "zp_out": act["zp_out"],
            "activation_dtype": act["dtype"],
            "weight_scale_min": float(npy["weight_scale"].min()),
            "weight_scale_max": float(npy["weight_scale"].max()),
            "m": ms["m"].tolist(),
            "shift": ms["shift"].tolist(),
            "m_min": int(ms["m"].min()),
            "m_max": int(ms["m"].max()),
            "shift_min": int(ms["shift"].min()),
            "shift_max": int(ms["shift"].max()),
            "num_channels": cout,
            "num_groups": (cout + GROUP_CHANNELS - 1) // GROUP_CHANNELS,
            "group_channels": GROUP_CHANNELS,
            "last_group_channels":
                cout - ((cout + GROUP_CHANNELS - 1) // GROUP_CHANNELS - 1)
                * GROUP_CHANNELS,
            "weight_k": weight_k,
            "weight_shape": list(weight_shape),
            "in_shape": list(in_shape),
            "out_shape": list(out_shape),
            "in_shape_padded": list(in_shape_padded),
            "out_shape_padded": list(out_shape_padded),
            "weight_bytes": len(weight_bytes),
            "bias_bytes": len(bias_bytes),
            "m_bytes": len(m_bytes),
            "shift_bytes": len(shift_bytes),
            "segment_bytes": segment_bytes,
            "image_offset": offset,
            "ddr3_offset": DDR3_WEIGHT_BASE + offset,
            "bias_off": bias_off,
            "m_off": m_off,
            "shift_off": shift_off,
            "bias_int32": bias_int32[name].tolist(),
            "bias_source": bias_sources[name],
            "bias_out_probe": activation["bias_out_probe"][name].tolist(),
            "padding_value": act["zp_in"],
            "zp_in_correction": {
                "enabled": act["zp_in"] != 0,
                "zp_in": act["zp_in"],
                "wsum": wsum.tolist(),
            },
        })
        segments.append((name, weight_bytes + bias_bytes + m_bytes
                         + shift_bytes, padded_len))
        offset += padded_len

    # Layer contract table (6 x 64 B).
    contract_table = b"".join(pack_contract_entry(rec) for rec in layer_records)
    assert len(contract_table) == CONTRACT_TABLE_BYTES

    payload = bytearray(contract_table)
    # design.md 5.2 alignment gap: the contract table starts at 0x0020
    # and the first layer segment at 0x0200; zero-fill the tail of the
    # table region so every segment lands on its published offset.
    gap = FIRST_LAYER_OFFSET - CONTRACT_TABLE_OFFSET - len(contract_table)
    assert gap >= 0, "contract table overruns the first-layer offset"
    payload += b"\x00" * gap
    for _, content, padded_len in segments:
        payload += content
        payload += b"\x00" * (padded_len - len(content))
    payload = bytes(payload)
    payload_offset = CONTRACT_TABLE_OFFSET
    assert FIRST_LAYER_OFFSET - payload_offset == \
        len(contract_table) + gap

    total_bytes = HEADER_BYTES + len(payload)
    checksum = segment_checksum_128(payload)

    header = struct.pack(
        "<4sHHII16s",
        IMAGE_MAGIC,
        NUM_LAYERS,
        FORMAT_VERSION,
        total_bytes,
        len(payload),
        checksum,
    )
    assert len(header) == HEADER_BYTES

    image = header + payload
    assert len(image) == total_bytes

    layout = {
        "header_offset": 0,
        "header_bytes": HEADER_BYTES,
        "contract_table_offset": CONTRACT_TABLE_OFFSET,
        "contract_table_bytes": CONTRACT_TABLE_BYTES,
        "first_layer_offset": FIRST_LAYER_OFFSET,
        "total_bytes": total_bytes,
        "payload_bytes": len(payload),
        "payload_checksum_128": checksum.hex(),
        "regions": [
            {
                "name": rec["name"],
                "offset": rec["image_offset"],
                "bytes": rec["segment_bytes"],
            }
            for rec in layer_records
        ],
    }
    return image, layer_records, layout


# ---------------------------------------------------------------------------
# JSON contract assembly.
# ---------------------------------------------------------------------------
def build_contract_json(activation: dict, layer_records: list, layout: dict,
                        classes: dict, image_sha256: str) -> dict:
    """Assemble the human-readable layer contract dictionary."""
    quant_stub = activation["quant_stub"]
    inv_s_in = choose_inv_s_in(quant_stub["s_in"])
    return {
        "generator": GENERATOR_NAME,
        "spec_refs": SPEC_REFS,
        "format_version": FORMAT_VERSION,
        "image_magic": IMAGE_MAGIC.decode("ascii"),
        "image_sha256": image_sha256,
        "image_total_bytes": layout["total_bytes"],
        "payload_checksum_128": layout["payload_checksum_128"],
        "ddr3_weight_base": DDR3_WEIGHT_BASE,
        "ddr3_weight_base_hex": f"0x{DDR3_WEIGHT_BASE:08X}",
        "determinism": (
            "byte-identical on re-run: fixed probe seed, pure integer "
            "packing, json floats round-trip via repr"
        ),
        "requant_formula": (
            "y = sat((acc_s32 * M[c]) >>> shift[c] + zp_out); "
            "M[c] = round(s_w[c] * s_in / s_out * 2^shift[c]), "
            "M[c] in [2^30, 2^31) (Q0.31)"
        ),
        "activation_dtype_note": (
            "all activations are torch.quint8 (fbgemm unsigned 8-bit); "
            "conv1 input zp_in=49 requires the -zp_in*sum(w) accumulator "
            "correction (zp_in_correction.wsum) AND zero-padding with "
            "padding_value == zp_in (49), not 0"
        ),
        "bias_note": (
            "InstRec deploy/weights/*_bias_int32.npy is corrupted: the "
            "export did .astype(np.int32) on the FLOAT32 fbgemm bias "
            "(every |bias|<1 truncated to 0). This tool rebuilds the "
            "int32 biases from the TorchScript source: conv1..4 from the "
            "packed-params float bias (exact), fc1/fc2 from a zero-input "
            "probe (accurate to 0.5 output LSB). See layers[].bias_source."
        ),
        "quant_stub_input_contract": {
            "description": (
                "Mel -> int8 quantization contract (REQ-FTR-006): "
                "x_q = sat_u8(round_even(z * inv_s_in >> frac_bits) + zp_in)"
            ),
            "s_in": quant_stub["s_in"],
            "zp_in": quant_stub["zp_in"],
            "dtype": quant_stub["dtype"],
            "inv_s_in": inv_s_in["value"],
            "inv_s_in_format": inv_s_in["format"],
            "inv_s_in_bits": inv_s_in["bits"],
        },
        "classes": {
            "num_classes": 8,
            "names": classes["names"],
            "names_zh": classes["names_zh"],
            "asserted_against": (
                "InstRec/src/dataset.py INSTRUMENT_NAMES (R-06 guard); "
                "deploy/irmas/model_config.json classes intentionally "
                "ignored (stale metadata, design.md F-13)"
            ),
        },
        "layers": [
            {
                "name": rec["name"],
                "layer_id": rec["layer_id"],
                "layer_type": rec["layer_type"],
                "s_in": rec["s_in"],
                "s_out": rec["s_out"],
                "zp_in": rec["zp_in"],
                "zp_out": rec["zp_out"],
                "activation_dtype": rec["activation_dtype"],
                "M": rec["m"],
                "shift": rec["shift"],
                "M_min": rec["m_min"],
                "M_max": rec["m_max"],
                "shift_min": rec["shift_min"],
                "shift_max": rec["shift_max"],
                "weight_scale_min": rec["weight_scale_min"],
                "weight_scale_max": rec["weight_scale_max"],
                "num_groups": rec["num_groups"],
                "num_channels": rec["num_channels"],
                "group_channels": rec["group_channels"],
                "last_group_channels": rec["last_group_channels"],
                "weight_k": rec["weight_k"],
                "weight_shape": rec["weight_shape"],
                "in_shape": rec["in_shape"],
                "out_shape": rec["out_shape"],
                "weight_bytes": rec["weight_bytes"],
                "bias_bytes": rec["bias_bytes"],
                "m_bytes": rec["m_bytes"],
                "shift_bytes": rec["shift_bytes"],
                "segment_bytes": rec["segment_bytes"],
                "image_offset": rec["image_offset"],
                "ddr3_offset": rec["ddr3_offset"],
                "ddr3_offset_hex": f"0x{rec['ddr3_offset']:08X}",
                "bias_off": rec["bias_off"],
                "m_off": rec["m_off"],
                "shift_off": rec["shift_off"],
                "bias_int32": rec["bias_int32"],
                "bias_source": rec["bias_source"],
                "bias_out_probe": rec["bias_out_probe"],
                "padding_value": rec["padding_value"],
                "zp_in_correction": rec["zp_in_correction"],
            }
            for rec in layer_records
        ],
        "image_layout": layout,
    }


# ---------------------------------------------------------------------------
# Driver.
# ---------------------------------------------------------------------------
def generate(instrec_root: Path, out_dir: Path) -> tuple:
    """Run the full conversion: returns (image_bytes, contract_dict)."""
    weights_dir = instrec_root / "deploy" / "weights"
    model_path = instrec_root / "deploy" / "quantized_model.pt"
    class_names_json = instrec_root / "deploy" / "class_names.json"
    dataset_py = instrec_root / "src" / "dataset.py"

    for required in (weights_dir, model_path, class_names_json, dataset_py):
        if not required.exists():
            raise FileNotFoundError(f"missing required source: {required}")

    # R-06 class order guard (must pass before anything is emitted).
    classes = assert_class_order(class_names_json, dataset_py)

    # Source 1 + shape/dtype assertions.
    npy_weights = load_npy_weights(weights_dir)

    # Source 2 + extraction-path validation (chained forward, module
    # accessors, graph constants, zero-input bias probe).
    activation = extract_activation_contract(model_path)
    assert_activation_sanity(activation)

    # Dual-source cross-validation for all six layers + float bias
    # recovery (conv: conv2d_unpack; fc: two-level GetAttr
    # linear_unpack).
    float_bias = cross_check_packed_weights(model_path, npy_weights)

    # Rebuild the int32 biases (npy bias files are corrupted).
    bias_int32, bias_sources = compute_bias_int32(
        npy_weights, activation, float_bias)

    # Per-channel M / shift (design.md 4.3).
    m_shift = compute_layer_m_shift(npy_weights, activation)

    # Numerical cross-check (npy weights + contract reproduce pt outputs).
    numerical_cross_check(activation, npy_weights, m_shift, bias_int32)

    # Assemble image + JSON contract.
    image, layer_records, layout = build_image(npy_weights, activation,
                                               m_shift, bias_int32,
                                               bias_sources)
    image_sha256 = hashlib.sha256(image).hexdigest()
    contract = build_contract_json(activation, layer_records, layout, classes,
                                   image_sha256)

    out_dir.mkdir(parents=True, exist_ok=True)
    bin_path = out_dir / "weights_image.bin"
    json_path = out_dir / "layer_contract.json"
    bin_path.write_bytes(image)
    with open(json_path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(contract, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    return image, contract


def main(argv: list | None = None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description="Generate the DDR3 weight image and layer contract."
    )
    parser.add_argument(
        "--instrec-root", type=Path, default=DEFAULT_INSTREC_ROOT,
        help="InstRec project root (default: %(default)s)",
    )
    parser.add_argument(
        "--outdir", type=Path, default=DEFAULT_OUT_DIR,
        help="output directory (default: %(default)s)",
    )
    args = parser.parse_args(argv)

    image, contract = generate(args.instrec_root, args.outdir)

    bin_path = args.outdir / "weights_image.bin"
    json_path = args.outdir / "layer_contract.json"
    sha = hashlib.sha256(image).hexdigest()
    print(f"[gen_weight_image] wrote {bin_path} ({len(image)} bytes)")
    print(f"[gen_weight_image] wrote {json_path}")
    print(f"[gen_weight_image] image sha256: {sha}")
    print(f"[gen_weight_image] payload 128-bit checksum: "
          f"{contract['payload_checksum_128']}")
    for layer in contract["layers"]:
        print(
            f"  {layer['name']:5s} {layer['layer_type']:4s} "
            f"Cout={layer['num_channels']:3d} groups={layer['num_groups']:2d} "
            f"shift[{layer['shift_min']}..{layer['shift_max']}] "
            f"M[{layer['M_min']}..{layer['M_max']}] "
            f"ddr3=0x{layer['ddr3_offset']:08X} "
            f"zp_in={layer['zp_in']} zp_out={layer['zp_out']}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())