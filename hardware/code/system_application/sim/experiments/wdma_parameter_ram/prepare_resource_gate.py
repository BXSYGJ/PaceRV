"""Prepare (never launch) a frozen wide-WDMA PDS compile/synth/dev_map gate."""
import argparse
import hashlib
import json
import re
import shutil
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REPO = ROOT.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run", required=True, type=Path, help="Existing baseline PDS run directory")
    ap.add_argument("--allow-drift", action="store_true", help="Record changed inputs instead of rejecting them")
    ap.add_argument("--variant", choices=("wide", "scalar"), default="wide",
                    help="Compare corrected scalar and corrected wide in separate serial gates")
    args = ap.parse_args()
    run = args.run.resolve()
    manifest = json.loads((run / "source-manifest.json").read_text(encoding="utf-8-sig"))
    drift = [{"Path": f["Path"], "Expected": f["Sha256"], "Actual": digest(Path(f["Path"]))}
             for f in manifest["Files"] if digest(Path(f["Path"])) != f["Sha256"].upper()]
    if drift and not args.allow_drift:
        raise SystemExit("Baseline inputs changed; review drift and explicitly use --allow-drift:\n" + json.dumps(drift, indent=2))
    out = ROOT / "build" / "resource_gate" / (datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    frozen = out / "snapshot"
    frozen.mkdir(parents=True)
    # Copy exact declared inputs plus local includes/readmemh/IP companions.
    for f in manifest["Files"]:
        src = Path(f["Path"])
        dst = frozen / src.relative_to(REPO)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    for folder in ("src", "ipcore", "constraints"):
        shutil.copytree(ROOT / folder, frozen / "instrec_fpga" / folder, dirs_exist_ok=True)
    target = frozen / "instrec_fpga/src/npu/wdma.v"
    candidate = Path(__file__).with_name("wdma_wide_fixed.v" if args.variant == "wide" else "wdma_corrected.v")
    baseline = target.read_text(encoding="utf-8-sig")
    wide = candidate.read_text(encoding="utf-8-sig")
    wide = wide.replace("module wdma_corrected (", "module wdma (")
    # This gate deliberately changes only WDMA. No NPU/conv/wbuf replacements.
    def ports(text):
        return re.sub(r"\s+", "", re.sub(r"//[^\n]*", "", text.split("module wdma", 1)[1].split(");", 1)[0]))
    if ports(baseline) != ports(wide):
        raise SystemExit("WDMA interface mismatch; refuse replacement")
    target.write_text(wide, encoding="utf-8")
    tcl = (run / "build.tcl").read_text(encoding="utf-8-sig")
    tcl = tcl.replace(run.as_posix(), out.as_posix())
    tcl = tcl.replace(REPO.as_posix(), frozen.as_posix())
    # Restore work directory after replacing source repository prefix.
    tcl = tcl.replace((frozen / out.relative_to(REPO)).as_posix(), out.as_posix())
    tcl = re.split(r"(?m)^pnr(?:\s|$)", tcl, maxsplit=1)[0] + "\nexit\n"
    if re.search(r"(?m)^\s*(pnr|report_timing|gen_bit_stream)\b", tcl):
        raise SystemExit("Unexpected implementation command remains")
    (out / "build.tcl").write_text(tcl, encoding="utf-8")
    evidence = {"BaselineRun": str(run), "BaselineManifest": manifest, "Drift": drift,
                "Variant": args.variant, "Candidate": str(candidate), "CandidateSha256": digest(candidate),
                "MappedSourceSha256": digest(target),
                "Replacements": ["instrec_fpga/src/npu/wdma.v"], "StopAfter": "dev_map"}
    (out / "gate-manifest.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    launch = '''# Run only after the active PDS build has exited. Never kills any process.
if (Get-Process pds_shell -ErrorAction SilentlyContinue) { throw "PDS already running; wait for it to finish" }
$pdsRoot = [Environment]::GetEnvironmentVariable("PDS_ROOT", "User")
if (-not $pdsRoot) { $pdsRoot = $env:PDS_ROOT }
$gateDir = $PSScriptRoot
& (Join-Path $pdsRoot "bin/pds_shell.exe") -file (Join-Path $gateDir "build.tcl") -work_dir $gateDir -project_name top_rv_core_pds
if ($LASTEXITCODE -ne 0) { throw "Resource gate failed: $LASTEXITCODE" }
'''
    (out / "launch.ps1").write_text(launch, encoding="utf-8")
    print(out)
    print("Prepared only. Review gate-manifest.json and build.tcl; do not launch while PDS is active.")


if __name__ == "__main__":
    main()
