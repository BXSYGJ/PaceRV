#!/usr/bin/env python3
"""Generate the Verilator-input copy of src/ctrl/self_test.v.

Why this exists
---------------
``src/ctrl/self_test.v`` declares its 256-bit beat output twice: once in the
port list (``output wire [255:0] wdata``) and once again in the module body
(``wire [255:0] wdata;`` right after ``wr_base``). PDS tolerates the
redeclaration, Verilator 5.050 rejects the file with::

    %Error: .../self_test.v:136:18: Duplicate declaration of signal: 'wdata'

Editing ``src/**`` is out of scope for the simulation task, so this script
derives a byte-identical copy with only that one redundant declaration line
removed. The copy lives under ``build/`` (gitignored) and is regenerated on
every simulation run, so it can never drift from the RTL source.

If the RTL is fixed upstream the duplicate line disappears and this script
becomes a plain copy (it reports ``patched = False``).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SRC = REPO_ROOT / "src" / "ctrl" / "self_test.v"
OUT_DIR = REPO_ROOT / "build" / "sim_ddr3"
OUT = OUT_DIR / "self_test_sim.v"

# Standalone redeclaration of the port already declared as
# "output wire [255:0] wdata,". The port line ends with a comma, this one
# ends with a semicolon and has no "output"/"input"/"inout" keyword.
REDECL_RE = re.compile(r"^\s*wire\s*\[\s*255\s*:\s*0\s*\]\s*wdata\s*;\s*$")


def derive() -> tuple[Path, bool]:
    if not SRC.is_file():
        raise SystemExit(f"self_test.v not found: {SRC}")

    text = SRC.read_text(encoding="utf-8")
    out_lines: list[str] = []
    patched = False
    for line in text.splitlines(keepends=True):
        if REDECL_RE.match(line):
            patched = True
            continue
        out_lines.append(line)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    # BOM-less UTF-8, LF preserved from the source file.
    OUT.write_bytes("".join(out_lines).encode("utf-8"))
    return OUT, patched


def main() -> int:
    out, patched = derive()
    print(f"self_test sim copy : {out}")
    print(f"duplicate 'wire [255:0] wdata;' removed : {patched}")
    if not patched:
        print("NOTE: source no longer contains the duplicate declaration "
              "(the RTL was fixed); the copy is a plain copy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())