#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""build_rv32_sw.py - build the InstRec control-core firmware.

The RV32 core in src/cpu/rv32_cpu_subsys.sv boots from an 8 KiB ROM that PDS
initialises with $readmemh("src/cpu/prog.hex", ...).  This script produces that
file from sw/rv32/{start.S,main.c}:

    gcc (xPack riscv-none-elf, native Windows) -> prog.elf -> prog.bin -> prog.hex

Toolchain lookup order (same convention as cpu/scripts/build_app.ps1):
    $RV32_TOOLCHAIN  ->  H:/ST/RV32I  ->  D:/ST/RV32I
A wrong-architecture compiler is a hard error; there is no silent fallback.

Usage:
    python scripts/build_rv32_sw.py             # RV32IM (ENABLE_M=1)
    python scripts/build_rv32_sw.py --no-m      # RV32I  (ENABLE_M=0)
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]          # instrec_fpga/
SW = ROOT / "sw" / "rv32"
OUT = ROOT / "build" / "rv32_sw"
HEX = ROOT / "src" / "cpu" / "prog.hex"
ROM_BYTES = 8 * 1024


def find_prefix() -> Path:
    candidates = []
    env = os.environ.get("RV32_TOOLCHAIN")
    if env:
        candidates.append(Path(env))
    candidates += [Path("H:/ST/RV32I"), Path("D:/ST/RV32I")]
    for cand in candidates:
        exe = cand / "bin" / "riscv-none-elf-gcc.exe"
        if exe.is_file():
            return cand / "bin" / "riscv-none-elf-"
    raise SystemExit("no riscv-none-elf toolchain found (set RV32_TOOLCHAIN)")


def run(cmd: list[str]) -> None:
    print("$ " + " ".join(str(c) for c in cmd))
    res = subprocess.run([str(c) for c in cmd], capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    if res.stdout:
        print(res.stdout, end="")
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        raise SystemExit("command failed (exit %d)" % res.returncode)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-m", action="store_true", help="build RV32I (no M extension)")
    args = ap.parse_args()

    prefix = find_prefix()
    OUT.mkdir(parents=True, exist_ok=True)
    gcc, objcopy, objdump = (str(prefix) + "gcc", str(prefix) + "objcopy",
                             str(prefix) + "objdump")
    march = "rv32i_zicsr_zifencei" if args.no_m else "rv32im_zicsr_zifencei"

    elf = OUT / "prog.elf"
    bin_ = OUT / "prog.bin"
    cmd = [gcc, "-march=" + march, "-mabi=ilp32", "-msmall-data-limit=0",
           "-std=c11", "-O2", "-ffreestanding", "-fno-builtin",
           "-Wall", "-Wextra", "-nostdlib", "-nostartfiles",
           "-Wl,--no-relax", "-Wl,-Map," + str(OUT / "prog.map"),
           "-T", str(SW / "link.ld"), "-o", str(elf),
           str(SW / "start.S"), str(SW / "main.c"), "-lgcc"]
    if not args.no_m:
        cmd.insert(1, "-DENABLE_M=1")
    run(cmd)
    run([objcopy, "-O", "binary", str(elf), str(bin_)])

    data = bin_.read_bytes()
    if len(data) > ROM_BYTES:
        raise SystemExit("firmware is %d bytes, ROM is %d" % (len(data), ROM_BYTES))
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)

    words = [data[i:i + 4] for i in range(0, len(data), 4)]
    lines = ["%08x" % int.from_bytes(w, "little") for w in words]
    HEX.parent.mkdir(parents=True, exist_ok=True)
    HEX.write_text("\n".join(lines) + "\n", encoding="ascii")

    dis = subprocess.run([objdump, "-d", str(elf)], capture_output=True,
                         text=True, encoding="utf-8", errors="replace")
    (OUT / "prog.dis").write_text(dis.stdout, encoding="utf-8")

    print("firmware: %d bytes, %d words -> %s" % (len(data), len(words), HEX))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
