from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build" / "sim" / "npu_lifecycle_ddr3"
OUT.mkdir(parents=True, exist_ok=True)
exe = OUT / "tb_npu_ddr3_lifecycle.exe"
cmd = ["verilator.bat", "--binary", "--timing", "-Wno-fatal", "--top-module", "tb_npu_ddr3_lifecycle",
       "--Mdir", str(OUT / "obj_dir"),
       "-I" + str(ROOT / "src" / "ddr3"), "-I" + str(ROOT / "sim"),
       str(ROOT / "sim" / "experiments" / "npu_lifecycle" / "ddr3_arbiter.v"), str(ROOT / "src" / "ddr3" / "ddr3_ctrl_axi.v"),
       str(ROOT / "sim" / "ddr3_axi_model.sv"), str(ROOT / "sim" / "experiments" / "npu_m1_bridge" / "npu_m1_bridge.v"),
       str(ROOT / "sim" / "experiments" / "npu_lifecycle" / "tb_npu_ddr3_lifecycle.sv"), "-o", str(exe)]
build = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)
(OUT / "build.log").write_text(build.stdout + build.stderr, encoding="utf-8")
if build.returncode:
    print(build.stdout); print(build.stderr); raise SystemExit(build.returncode)
run = subprocess.run([str(exe)], cwd=ROOT, text=True, capture_output=True)
(OUT / "run.log").write_text(run.stdout + run.stderr, encoding="utf-8")
print(run.stdout, end="")
print(run.stderr, end="")
raise SystemExit(run.returncode)
