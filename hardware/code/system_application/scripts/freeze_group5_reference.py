"""Freeze the user's five-group activity model; NOT an FPGA INT8 export.

Reads the sibling training project without modifying it. The frozen NumPy
state includes both heads so activity and dominance cannot be confused.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

import numpy as np
import torch


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source, out = args.source.resolve(), args.output.resolve()
    if out.exists():
        raise SystemExit("Output already exists; preserve frozen assets")
    checkpoint = source / "runs/group5_v3/best_model.pth"
    model_source = source / "src/model.py"
    config = json.loads((source / "runs/group5_v3/train_config.json").read_text(encoding="utf-8"))
    names = ["strings", "woodwinds", "brass", "percussion", "keys"]
    ckpt = torch.load(checkpoint, map_location="cpu", weights_only=False)
    assert ckpt["group_names"] == config["group_names"] == names
    assert config["n_frames"] == 130 and ckpt["model_class"] == "DualHeadInstrumentCNN"
    spec = importlib.util.spec_from_file_location("group5_source_model", model_source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    model = module.DualHeadInstrumentCNN(num_classes=5).eval()
    model.load_state_dict(ckpt["model_state_dict"], strict=True)
    torch.set_num_threads(4)
    cache = source / "data/group5_cache_v3"
    features = np.load(cache / "all_features.npy", mmap_mode="r")
    labels = np.load(cache / "labels.npy", mmap_mode="r")
    split = json.loads((cache / "split.json").read_text(encoding="utf-8"))
    val = np.asarray(split["val_indices"])
    # Select real held-out examples covering every group and an ensemble.
    rows = list(dict.fromkeys(int(val[np.flatnonzero(labels[val, g] > .5)[0]]) for g in range(5)))
    rows += [int(val[np.flatnonzero(np.sum(labels[val] > .5, axis=1) >= 2)[0]])]
    rows = list(dict.fromkeys(rows))
    x = np.asarray(features[rows], dtype=np.float32)
    if x.ndim == 3:
        x = x[:, None]
    assert x.shape[1:] == (1, 64, 130)
    with torch.no_grad():
        act_logits, dom_logits = model.forward_dual(torch.from_numpy(x))
        activities = torch.sigmoid(act_logits)
        active = activities > .5
        dom = torch.softmax(dom_logits, dim=1) * active
        totals = dom.sum(dim=1, keepdim=True)
        dominance = torch.where(totals > 0, dom / totals.clamp(min=1e-8), torch.zeros_like(dom))
    assert bool(torch.isfinite(activities).all())
    out.mkdir(parents=True)
    np.savez_compressed(out / "float_state.npz", **{k: v.cpu().numpy() for k, v in ckpt["model_state_dict"].items()})
    np.savez_compressed(out / "reference_vectors.npz", features=x, row_indices=rows,
                        labels=np.asarray(labels[rows]), activity_logits=act_logits.numpy(),
                        activities=activities.numpy(), dominance_logits=dom_logits.numpy(),
                        dominance=dominance.numpy())
    (out / "model_source.py").write_bytes(model_source.read_bytes())
    (out / "train_config.json").write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report = dict(target="five_group_multilabel_activity", fpga_deployed=False,
                  quantized=False, checkpoint_epoch=ckpt["epoch"], group_order=names,
                  input_shape=[1, 1, 64, 130], sample_rate_hz=44100, segment_samples=66150,
                  activity_activation="independent sigmoid; sum is not normalized",
                  dominance_activation="separate softmax head, mask activity > 0.5, renormalize",
                  source_checkpoint=str(checkpoint), source_checkpoint_sha256=sha(checkpoint),
                  source_model_sha256=sha(model_source), torch_version=torch.__version__,
                  strict_state_load=True, validation_rows=rows, activities=activities.tolist(),
                  activity_sums=activities.sum(dim=1).tolist(),
                  limitations=["Float reference only; INT8 calibration and bit-exact RTL migration pending",
                               "Small selected validation fixture is not a new accuracy evaluation",
                               "Current FPGA 8-class softmax and 258-frame window are incompatible"],
                  assets={p.name: sha(p) for p in sorted(out.iterdir()) if p.is_file()})
    (out / "manifest.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
