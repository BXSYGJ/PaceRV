#!/usr/bin/env python3
"""Regenerate the per-layer golden references with correct dtypes/shapes.

Why this tool exists
--------------------
``scripts/outputs/golden/`` is the ARCHIVE of the first golden runs and is
kept as-is (frozen evidence).  It is NOT a usable per-layer reference set:

  * ``<stem>_feat.npy`` was written as int8 and is all-zero on the
    full-scale sine, while the current ``run_mel_pipeline`` emits uint8
    0..255 (zp_in = 49 domain);
  * conv2/conv3/conv4 and the pool maps were never dumped;
  * ``<stem>_fc2.npy`` is the u8 container (out_u8) while the per-layer
    export (wire layer 0x06) carries the int32 container value
    ``out_u8 - zp_out`` (zp_out = 57);
  * ``<stem>_probs.npy`` is float64, while the UI/wire probability
    layer is Q0.16.

Feeding those files to ``compare_layers.py --ref`` produces false
differences.  This tool re-runs the authoritative golden model
(``golden_pipeline.run_mel_pipeline`` + ``golden_pipeline.npu_forward``)
from the source wav and writes ONE dtype-correct directory per stem:

    reports/golden_ref/<stem>/
        feat.npy                  uint8  (64, 258)   zp_in = 49
        conv1.npy .. conv4.npy    uint8  conv output scale
        pool1.npy .. pool4.npy    uint8
        gap.npy                   int32  (256,)      round_half_even(sum >> 6)
        fc1.npy                   uint8  (128,)
        fc2_logits.npy            int32  (8,)        fc2_u8 - zp_out(57)
        probs.npy                 uint16 (8,)        Q0.16
        probs_float.npy           float64 (8,)       Q0.16 / 65536 (human)
        probs_u8_percent.npy      uint8  (8,)        compare_layers encoding
        probs_u8_q0_8.npy         uint8  (8,)        compare_layers encoding
        stats.json                per-file min/max/unique summary
        manifest.json             dtype/shape/source/contract-layer per file

The archive directory is never written: ``_check_out_root`` rejects any
output root equal to or below ``scripts/outputs/golden``.

Usage
-----
    python scripts/gen_golden_refs.py
    python scripts/gen_golden_refs.py --stem sine_440_full
    python scripts/gen_golden_refs.py --wav path/to/track.wav
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

import compare_layers as cl
import golden_pipeline as gp

SCRIPTS_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPTS_DIR.parent
PANGO_ROOT = Path(__file__).resolve().parents[3]

DEFAULT_ARCHIVE_DIR = gp.DEFAULT_OUT_DIR          # scripts/outputs/golden
DEFAULT_OUT_ROOT = PROJECT_DIR / "reports" / "golden_ref"
DEFAULT_CONTRACT_PATH = gp.DEFAULT_CONTRACT_PATH
DEFAULT_WEIGHTS_PATH = gp.DEFAULT_WEIGHT_IMAGE_PATH
DEFAULT_TABLES_PATH = gp.DEFAULT_TABLES_PATH

FIXTURE_DIR = PROJECT_DIR / "tests" / "fixtures"
IRMAS_DIR = PANGO_ROOT / "InstRec" / "data" / "demo" / "irmas_test"
WAV_SEARCH_DIRS = (FIXTURE_DIR, IRMAS_DIR)

WIRE_LAYER_NAMES = {
    0: "MEL_Q8_8",
    1: "CONV1",
    2: "CONV2",
    3: "CONV3",
    4: "CONV4",
    5: "FC1",
    6: "FC2_LOGITS",
    7: "PROBS",
    8: "STATS",
}

# stage -> (wire layer id, contract layer name, contract layer_id)
# contract layer_id is the layer_contract.json ``layer_id`` (0=conv1 ..
# 5=fc2), a DIFFERENT numbering from the UART wire layer id (0=MEL ..
# 7=PROBS).  None means the stage has no contract record / no wire layer.
STAGE_META = {
    "feat": (0, "quant_stub_input", None),
    "conv1": (1, "conv1", 0),
    "conv2": (2, "conv2", 1),
    "conv3": (3, "conv3", 2),
    "conv4": (4, "conv4", 3),
    "pool1": (None, None, None),
    "pool2": (None, None, None),
    "pool3": (None, None, None),
    "pool4": (None, None, None),
    "gap": (None, None, None),
    "fc1": (5, "fc1", 4),
    "fc2_logits": (6, "fc2", 5),
    "probs": (7, None, None),
    "probs_float": (7, None, None),
    "probs_u8_percent": (7, None, None),
    "probs_u8_q0_8": (7, None, None),
}

# Written in this order (matches the task file list, probs variants last).
STAGE_ORDER = (
    "feat",
    "conv1", "conv2", "conv3", "conv4",
    "pool1", "pool2", "pool3", "pool4",
    "gap", "fc1", "fc2_logits",
    "probs", "probs_float", "probs_u8_percent", "probs_u8_q0_8",
)

SOURCE_TEXT = {
    "feat": "golden_pipeline.run_mel_pipeline()['feat']",
    "conv1": "golden_pipeline.npu_forward()['conv1'] (conv2d_int8)",
    "conv2": "golden_pipeline.npu_forward()['conv2'] (conv2d_int8)",
    "conv3": "golden_pipeline.npu_forward()['conv3'] (conv2d_int8)",
    "conv4": "golden_pipeline.npu_forward()['conv4'] (conv2d_int8)",
    "pool1": "golden_pipeline.npu_forward()['pool1'] (maxpool2x2_floor)",
    "pool2": "golden_pipeline.npu_forward()['pool2'] (maxpool2x2_floor)",
    "pool3": "golden_pipeline.npu_forward()['pool3'] (maxpool2x2_floor)",
    "pool4": "golden_pipeline.npu_forward()['pool4'] (maxpool2x2_floor)",
    "gap": "golden_pipeline.npu_forward()['gap'] (gap_s32, int64 -> int32)",
    "fc1": "golden_pipeline.npu_forward()['fc1'] (fc_int8, ReLU rail)",
    "fc2_logits": "golden_pipeline.npu_forward()['logits'] "
                  "(fc2_u8 - zp_out=57, int32)",
    "probs": "golden_pipeline.npu_forward()['probs_q16'] "
             "(softmax_fixed Q0.16, int64 -> uint16)",
    "probs_float": "golden_pipeline.npu_forward()['probs'] (Q0.16 / 65536)",
    "probs_u8_percent": "compare_layers.encode_probs(npu, 'percent')",
    "probs_u8_q0_8": "compare_layers.encode_probs(npu, 'q0.8')",
}

NOTE_TEXT = {
    "feat": "Mel feature, uint8 quint8 container, zp_in = 49",
    "gap": "fc1 input requant (conv4 output scale/zp), 4x16=64 taps >> 6",
    "fc2_logits": "signed container value, NOT the u8 logits array",
    "probs": "Q0.16 fixed-point probabilities (0..65535)",
    "probs_float": "human-readable copy; not an integer wire reference",
    "probs_u8_percent": "u8 wire encoding selected by "
                        "--probs-encoding percent (default)",
    "probs_u8_q0_8": "u8 wire encoding selected by --probs-encoding q0.8",
}


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _check_out_root(out_root, archive_dir=DEFAULT_ARCHIVE_DIR) -> Path:
    """Reject an output root that would write into the frozen archive."""
    root = Path(out_root).resolve()
    archive = Path(archive_dir).resolve()
    if root == archive or archive in root.parents:
        raise ValueError(
            f"output root {root} is the archived golden directory "
            f"{archive} or a path below it; choose a separate directory "
            f"(default: {DEFAULT_OUT_ROOT})")
    return root


def discover_archive_stems(archive_dir=DEFAULT_ARCHIVE_DIR) -> list:
    """Stems recorded in the frozen archive (``<stem>_feat.npy``)."""
    d = Path(archive_dir)
    stems = [p.name[:-len("_feat.npy")] for p in d.glob("*_feat.npy")]
    return sorted(stem for stem in stems if stem)


def find_wav(stem: str, wav_dirs=WAV_SEARCH_DIRS):
    """Locate ``<stem>.wav`` in the fixture / InstRec search dirs."""
    for directory in wav_dirs:
        path = Path(directory) / f"{stem}.wav"
        if path.is_file():
            return path
    return None


def _validate_stem(stem: str) -> str:
    if not stem or Path(stem).name != stem:
        raise ValueError(f"invalid stem {stem!r}: must be a bare file stem")
    return stem


def _json_scalar(value):
    """JSON-safe min/max for int and float arrays."""
    if isinstance(value, (np.integer, int)):
        return int(value)
    return float(value)


def _stage_stats(arr: np.ndarray) -> dict:
    a = np.asarray(arr)
    return {
        "dtype": str(a.dtype),
        "shape": list(a.shape),
        "min": _json_scalar(a.min()),
        "max": _json_scalar(a.max()),
        "n_unique": int(np.unique(a).size),
    }


def _save_stage(out_dir: Path, stage: str, arr: np.ndarray) -> dict:
    """Write one ``<stage>.npy`` and return its manifest entry."""
    path = out_dir / f"{stage}.npy"
    np.save(path, arr)
    wire_id, contract_layer, contract_layer_id = STAGE_META[stage]
    entry = {
        "file": path.name,
        "dtype": str(arr.dtype),
        "shape": list(arr.shape),
        "wire_layer_id": wire_id,
        "contract_layer": contract_layer,
        "contract_layer_id": contract_layer_id,
        "source": SOURCE_TEXT[stage],
        "sha256": _sha256_file(path),
    }
    note = NOTE_TEXT.get(stage)
    if note:
        entry["note"] = note
    return entry


def _write_json(path: Path, payload: dict) -> None:
    text = json.dumps(payload, indent=2, ensure_ascii=True) + "\n"
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def build_stem_reference(wav_path, contract, tables, weights) -> dict:
    """Run the golden pipeline for one wav; returns feat + npu_forward."""
    pcm = gp.load_pcm_s16(Path(wav_path))
    feat = np.asarray(gp.run_mel_pipeline(pcm, tables)["feat"])
    npu = gp.npu_forward(feat, contract, tables["exp_lut"], weights)
    return {"feat": feat, "npu": npu}


def stage_arrays(feat: np.ndarray, npu: dict, contract: dict) -> dict:
    """Map the npu_forward result onto the typed output files.

    The conversions are the minimal safe widening/narrowing that keeps
    every value bit-identical:
      gap int64 -> int32, logits int32, probs_q16 int64 -> uint16.
    """
    recs = {rec["name"]: rec for rec in contract["layers"]}
    zp_out = int(recs["fc2"]["zp_out"])

    fc2 = np.asarray(npu["fc2"]).astype(np.int64)
    logits = np.asarray(npu["logits"])
    expected = fc2 - np.int64(zp_out)
    if not np.array_equal(logits.astype(np.int64), expected):
        raise RuntimeError(
            "fc2 logits mismatch: npu_forward['logits'] != fc2_u8 - "
            f"zp_out({zp_out})")

    gap = np.asarray(npu["gap"])
    if gap.size and (gap.min() < np.iinfo(np.int32).min
                     or gap.max() > np.iinfo(np.int32).max):
        raise RuntimeError("gap values do not fit in int32")

    probs_q16 = np.asarray(npu["probs_q16"]).astype(np.int64)
    if probs_q16.size and (probs_q16.min() < 0 or probs_q16.max() > 65535):
        raise RuntimeError("probs_q16 outside the uint16 container")

    out = {
        "feat": np.asarray(feat, np.uint8),
        "gap": gap.astype(np.int32),
        "fc1": np.asarray(npu["fc1"], np.uint8),
        "fc2_logits": logits.astype(np.int32),
        "probs": probs_q16.astype(np.uint16),
        "probs_float": np.asarray(npu["probs"], np.float64),
        "probs_u8_percent": cl.encode_probs(npu, "percent"),
        "probs_u8_q0_8": cl.encode_probs(npu, "q0.8"),
    }
    for stage in ("conv1", "conv2", "conv3", "conv4",
                  "pool1", "pool2", "pool3", "pool4"):
        out[stage] = np.asarray(npu[stage], np.uint8)
    return out


def generate_stem(stem, wav_path, out_root, contract, tables, weights,
                  contract_path=DEFAULT_CONTRACT_PATH,
                  weights_path=DEFAULT_WEIGHTS_PATH,
                  tables_path=DEFAULT_TABLES_PATH) -> dict:
    """Regenerate and write the full reference set for one stem."""
    stem = _validate_stem(stem)
    out_dir = Path(out_root) / stem
    out_dir.mkdir(parents=True, exist_ok=True)

    built = build_stem_reference(wav_path, contract, tables, weights)
    arrays = stage_arrays(built["feat"], built["npu"], contract)

    files = {}
    stats = {"stem": stem, "files": {}}
    for stage in STAGE_ORDER:
        arr = arrays[stage]
        files[stage] = _save_stage(out_dir, stage, arr)
        stats["files"][stage] = _stage_stats(arr)

    npu = built["npu"]
    stats["golden_top1"] = int(npu["top1"])
    stats["probs_q16_sum"] = int(arrays["probs"].astype(np.int64).sum())
    stats["percent"] = [int(v) for v in np.asarray(npu["percent"])]
    _write_json(out_dir / "stats.json", stats)

    manifest = {
        "generator": "gen_golden_refs.py",
        "format_version": 1,
        "stem": stem,
        "source_wav": str(Path(wav_path)),
        "mel_tables": str(tables_path),
        "layer_contract": str(contract_path),
        "weights_image": {
            "path": str(weights_path),
            "sha256": contract["image_sha256"],
        },
        "wire_layer_map": {f"0x{k:02x}": v
                           for k, v in WIRE_LAYER_NAMES.items()},
        "golden_top1": int(npu["top1"]),
        "files": files,
    }
    _write_json(out_dir / "manifest.json", manifest)
    return manifest


def _collect_targets(stems, wavs, archive_dir=DEFAULT_ARCHIVE_DIR) -> dict:
    """stem -> explicit wav path (or None to search the wav dirs)."""
    targets = {}
    for stem in stems:
        targets[_validate_stem(stem)] = None
    for wav in wavs:
        path = Path(wav)
        if not path.is_file():
            raise FileNotFoundError(f"wav not found: {path}")
        targets[path.stem] = path
    if targets:
        return dict(sorted(targets.items()))
    discovered = discover_archive_stems(archive_dir)
    for stem in discovered:
        targets[stem] = None
    for path in sorted(Path(FIXTURE_DIR).glob("*.wav")):
        targets.setdefault(path.stem, None)
    return dict(sorted(targets.items()))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Regenerate dtype-correct per-layer golden references "
                    "(MEL/CONV/POOL/GAP/FC/PROBS) into reports/golden_ref/.")
    parser.add_argument("--stem", action="append", default=[],
                        help="golden stem, repeatable (default: archive "
                             "stems + tests/fixtures wavs)")
    parser.add_argument("--wav", type=Path, action="append", default=[],
                        help="explicit source wav (stem = file stem), "
                             "repeatable")
    parser.add_argument("--out-root", type=Path, default=DEFAULT_OUT_ROOT,
                        help="output root (default: %(default)s)")
    parser.add_argument("--contract", type=Path,
                        default=DEFAULT_CONTRACT_PATH)
    parser.add_argument("--weights", type=Path, default=DEFAULT_WEIGHTS_PATH)
    parser.add_argument("--tables", type=Path, default=DEFAULT_TABLES_PATH)
    args = parser.parse_args(argv)

    try:
        out_root = _check_out_root(args.out_root)
        targets = _collect_targets(args.stem, args.wav)
    except (ValueError, FileNotFoundError) as exc:
        print(f"[gen_golden_refs] {exc}", file=sys.stderr)
        return 2
    if not targets:
        print("[gen_golden_refs] no stem to generate: pass --stem or --wav "
              f"or populate {DEFAULT_ARCHIVE_DIR}", file=sys.stderr)
        return 2

    contract = gp.load_layer_contract(Path(args.contract))
    tables = gp.load_mel_tables(Path(args.tables))
    weights = gp.load_weights_from_image(contract, Path(args.weights))

    failures = []
    for stem, wav in targets.items():
        wav_path = wav or find_wav(stem)
        if wav_path is None:
            failures.append(stem)
            print(f"[gen_golden_refs] {stem}: no source wav in "
                  f"{[str(d) for d in WAV_SEARCH_DIRS]}; use --wav",
                  file=sys.stderr)
            continue
        try:
            manifest = generate_stem(
                stem, wav_path, out_root, contract, tables, weights,
                contract_path=Path(args.contract),
                weights_path=Path(args.weights),
                tables_path=Path(args.tables))
        except (RuntimeError, ValueError, OSError) as exc:
            failures.append(stem)
            print(f"[gen_golden_refs] {stem}: {exc}", file=sys.stderr)
            continue
        feat = np.asarray(np.load(out_root / stem / "feat.npy"))
        n_unique = int(np.unique(feat).size)
        print(f"[gen_golden_refs] {stem}: feat {feat.dtype} {feat.shape} "
              f"min={int(feat.min())} max={int(feat.max())} "
              f"unique={n_unique} top1={manifest['golden_top1']}; "
              f"{len(manifest['files']) + 2} files -> {out_root / stem}")

    if failures:
        print(f"[gen_golden_refs] {len(failures)} stem(s) failed: "
              f"{', '.join(failures)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())