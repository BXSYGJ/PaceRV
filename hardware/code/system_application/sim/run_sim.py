#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Unified Verilator simulation runner for InstRec-FPGA.

One command builds and runs one (or every) SystemVerilog testbench:

    python sim/run_sim.py conv1              # single TB, PASS/FAIL exit code
    python sim/run_sim.py all --jobs 6        # every TB, parallel, summary table
    python sim/run_sim.py mel --keep          # keep the VCD waveform
    python sim/run_sim.py all --jobs 6 --list # show the case matrix only

Design notes (why this is not just ``verilator --binary``)
----------------------------------------------------------
Verilator's ``--binary`` rebuilds the C++ runtime (verilated.cpp,
verilated_timing.cpp, verilated_threads.cpp) for every testbench, which costs
~33 s of g++ time before any RTL compile even starts.  This runner therefore
splits the flow in two:

1. ``verilator --cc --exe --main`` generates the C++ model (1-3 s),
2. a shared, pre-built runtime object cache is dropped into the per-TB
   ``obj`` directory, then ``mingw32-make`` compiles only the generated model
   and links (5-15 s of g++ for a typical TB).

The runtime cache is built once (first invocation) under
``build/sim/_runtime/`` and reused by every case, which is what makes the
"edit one line of RTL, get an answer in tens of seconds" loop possible.

Artifacts live in ``build/sim/<case>/`` (gitignored); the source tree is never
polluted with ``obj_dir``.  Nothing under ``src/``, ``scripts/`` or ``tests/``
is ever written by this tool.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
import wave
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths and toolchain
# ---------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parents[1]          # instrec_fpga/
SIM_DIR = ROOT / "sim"
BUILD = ROOT / "build" / "sim"

MSYS_ROOT = Path(os.environ.get('MSYS_ROOT', 'C:/msys64'))
VERILATOR_DEFAULT = Path(os.environ.get('VERILATOR_BIN', 'C:/msys64/ucrt64/bin/verilator.exe'))
MAKE_EXE = Path(os.environ.get('MAKE_EXE', str(MSYS_ROOT / 'ucrt64/bin/mingw32-make.exe')))

RUNTIME_DIR = BUILD / "_runtime"
RUNTIME_OBJS = ("verilated.o", "verilated_timing.o", "verilated_threads.o")

GOLDEN = ROOT / "reports" / "golden_ref" / "sine_440_full"
HEX_CONV1 = ROOT / "hex_conv1"
WAV_440 = ROOT / "tests" / "fixtures" / "sine_440_full.wav"
CONTRACT_PATH = ROOT / "scripts" / "outputs" / "layer_contract.json"
IMAGE_PATH = ROOT / "scripts" / "outputs" / "weights_image.bin"

VERILATOR_WARN_OFF = [
    "-Wno-WIDTH",
    "-Wno-UNOPTFLAT",
    "-Wno-CASEINCOMPLETE",
    "-Wno-LATCH",
    "-Wno-MULTIDRIVEN",
    "-Wno-COMBDLY",
    "-Wno-INITIALDLY",
    "-Wno-DECLFILENAME",
    "-Wno-VARHIDDEN",
    "-Wno-UNUSEDSIGNAL",
    "-Wno-PINCONNECTEMPTY",
    "-Wno-IMPLICIT",
    "-Wno-SYNCASYNCNET",
    "-Wno-STMTDLY",
    "-Wno-ALWCOMBORDER",
    "-Wno-REALCVT",
    "-Wno-UNDRIVEN",
    "-Wno-EOFNEWLINE",
    "-Wno-BLKSEQ",
]


# ---------------------------------------------------------------------------
# Case description
# ---------------------------------------------------------------------------
@dataclass
class Case:
    name: str
    tb: str                           # testbench file under sim/
    rtl: list[str] = field(default_factory=list)
    timeout: int = 180                # run timeout in seconds
    prepare: str | None = None        # name of the data-preparation hook
    extra_flags: list[str] = field(default_factory=list)
    defines: list[str] = field(default_factory=list)
    overrides: list[tuple] = field(default_factory=list)   # (relpath, regex, repl)
    optional: bool = False            # TB may be delivered by another task
    description: str = ""


# mel submodules (the engine instantiates all of them)
MEL_RTL = [
    "src/mel/mel_engine.v",
    "src/mel/stft_framer.v",
    "src/mel/fft2048_sdf.v",
    "src/mel/mel_filter.v",
    "src/mel/db_norm.v",
    "src/mel/standardize.v",
    "src/mel/hann_rom.v",
    "src/mel/tw_rom_s.v",
]

UI_RTL = [
    "src/ui/ui_renderer.v",
    "src/ui/waveform_disp.v",
    "src/ui/ui_overlay.v",
    "src/ui/bars_disp.v",
    "src/ui/spectrum_disp.v",
    "src/ui/text_disp.v",
    "src/ui/font_rom.v",
    "src/ui/bars_data.v",
    "src/ui/feat_page_buf.v",
    "src/ui/feat_copy_engine.v",
    "src/ui/ui_coord_delay.v",
]

# Include the activation replay/lifecycle dependencies explicitly even while
# a source promotion is in progress; the full-NPU case must compile them.
NPU_RTL = list(dict.fromkeys(
    [str(p.relative_to(ROOT)).replace("\\", "/")
     for p in sorted((ROOT / "src/npu").glob("*.v"))] + [
        "src/npu/activation_row_store_dynamic.v",
        "src/npu/activation_store_mux.v",
        "src/npu/npu_stage_lifecycle.v",
    ]
))

CASES: dict[str, Case] = {}


def register(case: Case) -> None:
    CASES[case.name] = case


register(Case(
    name="demo_dashboard", tb="tb_demo_dashboard.sv",
    rtl=["src/ui/demo_dashboard_renderer.v", "src/ui/demo_dashboard_text.v"], timeout=180,
    description="demo-only labels, five 1080p rasters, video alignment and bars",
))

register(Case(
    name="demo_timeline", tb="tb_demo_timeline.sv",
    rtl=["src/ui/demo_confidence_player.v"], timeout=120,
    description="supplied montage: all 581 ROM rows, top1, final hold and replay",
))

register(Case(
    name="demo_player", tb="tb_demo_player.sv",
    rtl=["src/ui/demo_confidence_player.v"], timeout=120,
    description="scripted demo: idle, debounce, complete bundles, hold and replay",
))

register(Case(
    name="self_test",
    tb="tb_self_test.sv",
    rtl=["src/ctrl/self_test.v"],
    timeout=120,
    # Verilator-compatibility shim (source tree is NOT modified): self_test.v
    # declares `wire [255:0] wdata;` on top of the port of the same name.
    # Verilator rejects the duplicate net (PDS tolerated it); the copy under
    # build/sim/self_test/rtl/ drops the redundant declaration only.
    overrides=[(
        "src/ctrl/self_test.v",
        r"\n    wire \[255:0\] wdata;\n",
        "\n",
    )],
    description="self_test FSM: normal pass, write/read abort, cmd_valid hold",
))

register(Case(
    name="conv1",
    tb="tb_conv_engine.sv",
    rtl=["src/npu/conv_engine.v", "src/npu/requant_unit.v"],
    timeout=300,
    prepare="conv1",
    extra_flags=["--public"],
    description="conv_engine + requant_unit vs golden conv1.npy (792576 values)",
))

register(Case(
    name="mel",
    tb="tb_mel_engine.sv",
    rtl=list(MEL_RTL),
    timeout=300,
    prepare="mel",
    extra_flags=["--public"],
    description="mel_engine with FILL_CREDIT=1025 (deadlock reproduction)",
))

register(Case(
    name="mel_credit",
    tb="tb_mel_engine.sv",
    rtl=list(MEL_RTL),
    timeout=600,
    prepare="mel",
    extra_flags=["--public"],
    overrides=[(
        "src/mel/mel_engine.v",
        r"localparam integer FILL_CREDIT\s*=\s*1025;",
        "localparam integer FILL_CREDIT    = 1280;",
    )],
    description="mel_engine with FILL_CREDIT=1280 (must complete, feat vs golden)",
))

register(Case(
    name="weight_loader",
    tb="tb_weight_loader.sv",
    rtl=["src/ctrl/weight_loader.v"],
    timeout=300,
    prepare="weight_loader",
    description="weight_loader UART framing + DDR3 write/read-back digest (WOK)",
))

register(Case(
    name="weight_loader_serial",
    tb="tb_weight_loader.sv",
    rtl=["src/ctrl/uart_rx.v", "src/ctrl/weight_loader.v"],
    extra_flags=["-DPHYSICAL_UART_RX"],
    timeout=300,
    prepare="weight_loader",
    description="physical serial frames through uart_rx to loader DDR readback/WOK",
))

register(Case(
    name="ctrl_smoke",
    tb="tb_ctrl_smoke.sv",
    rtl=["src/ctrl/sys_ctrl.v", "src/ctrl/uart_debug.v"],
    timeout=180,
    description="sys_ctrl + uart_debug: DDROK and DDR3 STS must survive busy windows",
))

register(Case(
    name="uart_linebuf",
    tb="tb_uart_linebuf.sv",
    rtl=["src/ctrl/uart_debug.v"],
    timeout=120,
    description="128-byte and newline debug lines, TX backpressure and busy/ready recovery",
))

register(Case(
    name="npu_chain",
    tb="tb_npu_chain.sv",
    rtl=[
        "src/npu/gap_unit.v",
        "src/npu/fc_engine.v",
        "src/npu/requant_unit.v",
        "src/npu/softmax_top.v",
    ],
    timeout=300,
    prepare="npu_chain",
    description="gap -> fc1 -> fc2 -> softmax vs golden gap/fc1/fc2/probs",
))

register(Case(
    name="rv_cpu",
    tb="tb_rv_cpu.sv",
    rtl=[
        "src/cpu/rv32_cpu_subsys.sv",
        "../cpu/rtl/rv32_core.sv",
        "../cpu/rtl/rv32_decode.sv",
        "../cpu/rtl/rv32_alu.sv",
        "../cpu/rtl/rv32_muldiv.sv",
        "../cpu/rtl/rv32_btb.sv",
        "../cpu/rtl/rv32_machine.sv",
    ],
    timeout=300,
    description="RV32 control core: firmware boot/ISA/bench + MMIO NPU report",
))

register(Case(
    name="npu_completion",
    tb="tb_npu_completion.sv",
    rtl=NPU_RTL,
    timeout=300,
    description="real npu_top completion and result drain protocol",
))

register(Case(
    name="pcm1808",
    prepare="pcm1808",
    tb="tb_pcm1808.sv",
    rtl=["src/audio/i2s_slave_rx.v", "src/audio/pcm1808_resampler.v",
         "src/audio/pcm1808_coeff_rom.v", "src/audio/audio_cdc_fifo.v"],
    timeout=180,
    description="PCM1808 serial pins, stereo FIR golden, stop/reconnect",
))

register(Case(
    name="pcm1808_27mhz",
    prepare="pcm1808",
    tb="tb_pcm1808.sv",
    rtl=["src/audio/i2s_slave_rx.v", "src/audio/pcm1808_resampler.v",
         "src/audio/pcm1808_coeff_rom.v", "src/audio/audio_cdc_fifo.v"],
    extra_flags=["-GCLK_HALF_NS=18.5185", "-GRX_TIMEOUT=27000",
                 "-GSTUCK_SLOTS=110", "-GLOSS_WAIT_NS=1200000", "-GDRAIN_NS=20000"],
    timeout=180,
    description="PCM1808 diagnostic 27 MHz serial/FIR/CDC and recovery",
))

register(Case(
    name="i2s_capture",
    tb="tb_i2s_capture.sv",
    rtl=["src/audio/i2s_clk_gen.v", "src/audio/i2s_rx.v"],
    timeout=120,
    description="physical Philips I2S source into generated clocks and receiver",
))

register(Case(
    name="audio_fifo",
    tb="tb_audio_fifo.sv",
    rtl=["src/audio/audio_cdc_fifo.v"],
    timeout=120,
    description="dual-clock FIFO capacity, overflow saturation, wrap and reset",
))

register(Case(
    name="text_pipeline",
    tb="tb_text_pipeline.sv",
    rtl=["src/ui/text_disp.v", "src/ui/font_rom.v"],
    timeout=120,
    description="character pipeline vs legacy pixels across all class labels",
))

register(Case(
    name="db_norm_stats",
    tb="tb_db_norm_stats.sv",
    rtl=["src/mel/db_norm.v"],
    timeout=120,
    description="six no-reset dB windows, dropped-head statistics and final flush",
))

register(Case(
    name="dashboard_ui",
    tb="tb_dashboard_ui.sv",
    rtl=["src/ui/dashboard_renderer.v", "src/ui/dashboard_text.v"],
    timeout=180,
    description="1080p actual RTL raster, controls, RAM geometry and empty/0/100 percent states",
))

register(Case(
    name="dynamic_ui",
    tb="tb_dynamic_ui.sv",
    rtl=["src/ui/bars_data.v", "src/ui/bars_disp.v", "src/ui/ui_coord_delay.v",
         "src/ui/feat_copy_engine.v", "src/ui/feat_page_buf.v", "src/ui/spectrum_disp.v"],
    timeout=120,
    description="coherent frame snapshots, transposed feature pages and pixel alignment",
))

register(Case(
    name="requant_reset",
    tb="tb_requant_reset.sv",
    rtl=["src/npu/requant_unit.v"],
    timeout=120,
    description="requant golden arithmetic and asynchronous mid-flight reset flush",
))

register(Case(
    name="framer_repeat",
    tb="tb_framer_repeat.sv",
    rtl=["src/mel/stft_framer.v", "src/mel/hann_rom.v"],
    timeout=120,
    description="two no-reset PCM windows, all reflect and Hann samples exact",
))

register(Case(
    name="uart_rx",
    tb="tb_uart_rx.sv",
    rtl=["src/ctrl/uart_rx.v"],
    timeout=120,
    description="physical UART RX bit sampling, byte sweep and recovery",
))

register(Case(
    name="rv_top_ctrl",
    tb="tb_rv_top_ctrl.sv",
    rtl=["build/sim/rv_top_ctrl/rv_top_ctrl_slice.sv", "src/ctrl/uart_tx.v"],
    prepare="rv_top_ctrl",
    timeout=180,
    description="exact top_rv_core UART arbitration and NPU launch control slice",
))


register(Case(
    name="full_top_ctrl",
    tb="tb_rv_top_ctrl.sv",
    rtl=["build/sim/full_top_ctrl/rv_top_ctrl_slice.sv", "src/ctrl/uart_tx.v"],
    prepare="full_top_ctrl",
    timeout=180,
    description="exact instrec_top UART arbitration and NPU launch control slice",
))

register(Case(
    name="ui_render",
    tb="tb_ui_render.sv",
    rtl=list(UI_RTL),
    timeout=180,
    description="ui_renderer four-layer compositing priority",
))

register(Case(
    name="ui_overlay",
    tb="tb_ui_overlay.sv",
    rtl=["src/ui/ui_overlay.v"],
    timeout=120,
    description="standalone ui_overlay priority, blanking, and one-cycle latency",
))

# T28: direct-drive the DDR3 subsystem against the behavioural IP model.
# The model lives in sim/ddr3_axi_model.sv (one module per file), so ``-y sim``
# lets Verilator resolve it from the module name without listing it twice.
register(Case(
    name="ddr3_subsys",
    tb="tb_ddr3_subsys.sv",
    rtl=[
        "src/ddr3/ddr3_ctrl_axi.v",
        "src/ddr3/ddr3_arbiter.v",
        "src/ctrl/self_test.v",
    ],
    timeout=600,
    extra_flags=["-y", "sim"],
    overrides=[(
        "src/ctrl/self_test.v",
        r"\n    wire \[255:0\] wdata;\n",
        "\n",
    )],
    description="ddr3_ctrl_axi + ddr3_arbiter + self_test + behavioural DDR3 model (T28)",
))

# T37: multi-master AW starvation.  Same DUT and the same behavioural IP model,
# but the masters are driven with the REAL upstream behaviour of audio_sink
# (m0 page writes, cmd_valid held to done) and mel_engine (m2, 516 x len=15
# reads).  Four scenarios split the board symptom into queue time (S_IDLE,
# not watchdog counted) and AW wait time (S_AW, watchdog counted).
register(Case(
    name="ddr3_aw_timeout",
    tb="tb_ddr3_aw_timeout.sv",
    rtl=[
        "src/ddr3/ddr3_ctrl_axi.v",
        "src/ddr3/ddr3_arbiter.v",
        "src/ctrl/self_test.v",
    ],
    timeout=600,
    extra_flags=["-y", "sim"],
    overrides=[(
        "src/ctrl/self_test.v",
        r"\n    wire \[255:0\] wdata;\n",
        "\n",
    )],
    description="multi-master AW timeout: m0/m2 full load vs m3 self_test (T37)",
))


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
def _numpy():
    try:
        import numpy as np
    except ImportError as exc:      # pragma: no cover - environment guard
        raise SystemExit("numpy is required for golden-data preparation: %s" % exc)
    return np


def write_hex(path: Path, values, digits: int) -> int:
    """Write one value per line, zero padded, upper case ($readmemh format)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    mask = (1 << (4 * digits)) - 1
    fmt = "{0:0" + str(digits) + "X}"
    with open(path, "w", encoding="ascii", newline="\n") as handle:
        handle.write("\n".join(fmt.format(int(v) & mask) for v in values))
        handle.write("\n")
    return len(values)


def _toolchain() -> tuple[Path, Path]:
    """Resolve (verilator wrapper, make) and return them."""
    env_bin = os.environ.get("VERILATOR_BIN")
    verilator = Path(env_bin) if env_bin else VERILATOR_DEFAULT
    if not verilator.is_file():
        found = shutil.which("verilator") or shutil.which("verilator.bat")
        if not found:
            raise SystemExit(
                "Verilator not found. Set VERILATOR_BIN or install to %s"
                % VERILATOR_DEFAULT)
        verilator = Path(found)
    if not MAKE_EXE.is_file():
        raise SystemExit("make not found at %s" % MAKE_EXE)
    return verilator, MAKE_EXE


def _build_env() -> dict:
    env = dict(os.environ)
    prelude = os.pathsep.join([
        str(MSYS_ROOT / "ucrt64" / "bin"),
        str(MSYS_ROOT / "usr" / "bin"),
    ])
    env["PATH"] = prelude + os.pathsep + env.get("PATH", "")
    # gcc 16.2 / UCRT64 cannot link -Os builds (std::string move ctor); the
    # Verilator wrapper sets these for the compile step, we set them for make.
    env["OPT"] = "-O2"
    env["LDFLAGS"] = "-static"
    return env


# ---------------------------------------------------------------------------
# Golden-data preparation hooks (npy/wav -> $readmemh tables)
# ---------------------------------------------------------------------------
def prepare_conv1(work: Path) -> None:
    """Golden conv1 (48,64,258) -> suite stream (row, grp, col, lane)."""
    np = _numpy()
    conv1 = np.load(GOLDEN / "conv1.npy")
    chan, rows, cols = conv1.shape
    groups = chan // 16
    stream = conv1.reshape(groups, 16, rows, cols).transpose(2, 0, 3, 1).reshape(-1)
    write_hex(work / "golden_conv1.hex", stream, 2)


def prepare_mel(work: Path) -> None:
    """s16 PCM window -> hex, and golden feat (frame*64+mel) -> hex.

    Both mel cases (FILL_CREDIT=1025 and 1280) read the same tables from
    build/sim/mel/, so the two runs can be scheduled in parallel without
    duplicating the 132k-line PCM file.
    """
    np = _numpy()
    out = BUILD / "mel"
    out.mkdir(parents=True, exist_ok=True)
    with wave.open(str(WAV_440), "rb") as wav:
        frames = wav.getnframes()
        raw = wav.readframes(frames)
    pcm = np.frombuffer(raw, dtype="<i2")
    write_hex(out / "pcm.hex", pcm.view(np.uint16), 4)
    feat = np.load(GOLDEN / "feat.npy")            # (mel, frame)
    write_hex(out / "golden_feat.hex", feat.T.reshape(-1), 2)


def _contract() -> dict:
    import json
    import io
    with io.open(CONTRACT_PATH, encoding="utf-8") as handle:
        return json.load(handle)


def _layer(contract: dict, name: str) -> dict:
    for rec in contract["layers"]:
        if rec["name"] == name:
            return rec
    raise SystemExit("layer %s missing from layer_contract.json" % name)


def _unpack_group_major(weight_bytes: bytes, cout: int, k: int,
                        group_channels: int = 16):
    """Inverse of gen_weight_image.interleave_group_major -> (group, k, cs)."""
    np = _numpy()
    out = np.zeros((cout, k), dtype=np.int32)
    pos = 0
    for g in range(0, cout, group_channels):
        gc = min(group_channels, cout - g)
        block = np.frombuffer(weight_bytes[pos:pos + gc * k], dtype=np.int8)
        out[g:g + gc, :] = block.reshape(k, gc).T
        pos += gc * k
    return out


def prepare_npu_chain(work: Path) -> None:
    """Golden pool4 -> gap -> fc1 -> fc2 -> softmax tables for tb_npu_chain."""
    np = _numpy()
    contract = _contract()
    image = IMAGE_PATH.read_bytes()

    # --- gap input: pool4 (256,4,16) -> (row, grp, col, lane) -------------
    pool4 = np.load(GOLDEN / "pool4.npy")
    chan, rows, cols = pool4.shape
    stream = pool4.reshape(chan // 16, 16, rows, cols).transpose(2, 0, 3, 1).reshape(-1)
    write_hex(work / "pool4.hex", stream, 2)

    # --- expected outputs -------------------------------------------------
    write_hex(work / "gap_exp.hex", np.load(GOLDEN / "gap.npy").astype(np.int32).view(np.uint32), 8)
    write_hex(work / "fc1_exp.hex", np.load(GOLDEN / "fc1.npy"), 2)
    write_hex(work / "fc2_exp.hex", np.load(GOLDEN / "fc2_logits.npy").astype(np.int32) + 57, 2)
    write_hex(work / "probs_exp.hex", np.load(GOLDEN / "probs.npy"), 4)

    # --- layer parameters -------------------------------------------------
    for name, tag, wdigits in (("fc1", "fc1", 8), ("fc2", "fc2", 8)):
        rec = _layer(contract, name)
        base = int(rec["image_offset"])
        seg = image[base:base + int(rec["segment_bytes"])]
        wbytes = seg[:int(rec["weight_bytes"])]
        cout = int(rec["out_shape"][0])
        k = int(rec["weight_k"])
        w2d = _unpack_group_major(wbytes, cout, k)
        # 16-lane groups: lane i = w[group*16+i][k]; pad missing lanes with 0
        words = []
        for g in range(0, cout, 16):
            gc = min(16, cout - g)
            for pos in range(k):
                lane_bytes = [int(w2d[g + lane, pos]) & 0xFF if lane < gc else 0
                              for lane in range(16)]
                for sub in range(4):
                    word = 0
                    for b in range(4):
                        word |= lane_bytes[sub * 4 + b] << (8 * b)
                    words.append(word)
        write_hex(work / ("%s_w.hex" % tag), words, wdigits)

        bias = np.frombuffer(seg[int(rec["bias_off"]):int(rec["bias_off"]) + int(rec["bias_bytes"])], dtype="<i4")
        muls = np.frombuffer(seg[int(rec["m_off"]):int(rec["m_off"]) + int(rec["m_bytes"])], dtype="<i4")
        shifts = np.frombuffer(seg[int(rec["shift_off"]):int(rec["shift_off"]) + int(rec["shift_bytes"])], dtype=np.uint8)
        # fc_engine's contract loader walks three CHANNEL-MAJOR streams
        # (all COUT biases, then all COUT M, then all COUT shifts) and indexes
        # its per-channel RAMs by that running counter, so the table must be
        # laid out the same way.  fc2 is padded to the 16-lane group width.
        ctr = []
        for lane in range(16 * ((cout + 15) // 16)):
            ctr.append(int(bias[lane]) & 0xFFFFFFFF if lane < cout else 0)
        for lane in range(16 * ((cout + 15) // 16)):
            ctr.append(int(muls[lane]) & 0xFFFFFFFF if lane < cout else 0)
        for lane in range(16 * ((cout + 15) // 16)):
            ctr.append(int(shifts[lane]) & 0x7F if lane < cout else 0)
        write_hex(work / ("%s_ctr.hex" % tag), ctr, wdigits)

    # softmax needs the exp LUT relative to the project root; the TB passes
    # the path explicitly, so nothing to copy here.


def prepare_weight_loader(work: Path) -> None:
    """Deterministic 4 x 256-byte weight chunks (payload + expected digest).

    The expected WOK digest mirrors weight_loader's folded accumulator
    bit-exactly: each 256-bit beat adds word0+word4 into acc0, word1+word5
    into acc1, ... and the report value is acc0^acc1^acc2^acc3, all modulo
    2^32 (the RTL accumulators are 32 bits wide).
    """
    np = _numpy()
    rng = np.random.default_rng(20261031)
    payloads = rng.integers(0, 256, size=(4, 256), dtype=np.int64).astype(np.uint8)
    words = payloads.reshape(-1, 32).view(np.uint32).reshape(-1, 8)
    acc = np.zeros(4, dtype=np.uint64)
    for beat in words:
        for lane in range(4):
            acc[lane] = (acc[lane] + int(beat[lane]) + int(beat[lane + 4])) & 0xFFFFFFFF
    digest = int((acc[0] ^ acc[1] ^ acc[2] ^ acc[3]) & 0xFFFFFFFF)
    write_hex(work / "payload.hex", payloads.reshape(-1), 2)
    (work / "digest.txt").write_text("%08X\n" % digest, encoding="ascii")


def prepare_rv_top_ctrl(work: Path, top_source: str = "src/ctrl/top_rv_core.v") -> None:
    """Extract actual top-level control logic, never a reimplementation."""
    source = (ROOT / top_source).read_text(encoding="utf-8")

    def section(start: str, end: str) -> str:
        return source.split(start, 1)[1].split(end, 1)[0]

    uart_gate = "    reg tx_accept_hold;" + section(
        "    reg tx_accept_hold;", "    // ---- RV32 control core")
    uart_inst = "    uart_tx u_uart_tx (" + section(
        "    uart_tx u_uart_tx (", "    uart_rx u_uart_rx (")
    launch = "    reg cpu_npu_pending;" + section(
        "    reg cpu_npu_pending;", "    npu_top ")
    header = """module rv_top_ctrl_slice #(parameter NPU_ENABLE = 0) (
    input wire core_clk, core_clk_rst_n,
    input wire wl_tx_valid, dbg_tx_valid, cpu_tx_valid,
    input wire [7:0] wl_tx_data, dbg_tx_data, cpu_tx_data,
    output wire wl_tx_ready, dbg_tx_ready, cpu_tx_ready, uart_tx,
    input wire sys_run, st_done, st_fail, safe_err, ddr_init_done,
    input wire weight_ok, weight_err, wl_busy, npu_busy_u,
    input wire native_owner_idle, native_fault,
    input wire mel_npu_start, cpu_npu_start,
    output wire launch_out, pending_out
);
    wire tx_byte_ready;
"""
    body = header + uart_gate + uart_inst + launch
    body += "assign launch_out = npu_start;\nassign pending_out = cpu_npu_pending;\nendmodule\n"
    (work / "rv_top_ctrl_slice.sv").write_text(body, encoding="ascii", newline="\n")


def prepare_full_top_ctrl(work: Path) -> None:
    prepare_rv_top_ctrl(work, "src/ctrl/instrec_top.v")


def prepare_pcm1808(work):
    subprocess.run([sys.executable, str(ROOT / "scripts/check_pcm1808.py")],
                   cwd=str(ROOT), check=True, capture_output=True)


PREPARERS = {
    "pcm1808": prepare_pcm1808,
    "conv1": prepare_conv1,
    "mel": prepare_mel,
    "npu_chain": prepare_npu_chain,
    "weight_loader": prepare_weight_loader,
    "rv_top_ctrl": prepare_rv_top_ctrl,
    "full_top_ctrl": prepare_full_top_ctrl,
}


# ---------------------------------------------------------------------------
# Source resolution (with optional per-case textual overrides)
# ---------------------------------------------------------------------------
def _apply_overrides(case: Case, work: Path) -> list[Path]:
    """Return the RTL file list, redirecting overridden files to the work dir."""
    resolved = []
    for rel in case.rtl:
        src = ROOT / rel
        if not src.is_file():
            raise FileNotFoundError("RTL source missing: %s" % src)
        override = None
        for rel_ovr, pattern, repl in case.overrides:
            if rel_ovr == rel:
                override = (pattern, repl)
                break
        if override is None:
            resolved.append(src)
            continue
        text = src.read_text(encoding="utf-8")
        new_text, count = re.subn(override[0], override[1], text)
        if count > 1:
            raise SystemExit(
                "override for %s matched %d times (expected at most 1)" % (rel, count))
        if count == 0:
            # The RTL was fixed upstream, so the simulation-only patch is no
            # longer needed. Use the source file unchanged.
            resolved.append(src)
            continue
        dst = work / "rtl" / Path(rel).name
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(new_text, encoding="utf-8", newline="\n")
        resolved.append(dst)
    return resolved


# ---------------------------------------------------------------------------
# Runtime object cache
# ---------------------------------------------------------------------------
def ensure_runtime(verilator: Path, log) -> bool:
    """Build the shared Verilator C++ runtime objects once."""
    if all((RUNTIME_DIR / obj).is_file() for obj in RUNTIME_OBJS):
        return True

    probe = RUNTIME_DIR / "probe"
    probe.mkdir(parents=True, exist_ok=True)
    src = probe / "tb_probe.sv"
    # The probe must use a delay so Verilator links verilated_timing.cpp into
    # the runtime object set that every case reuses (``--timing`` alone does
    # not pull the timing kernel when the design has no delayed process).
    src.write_text(
        "`timescale 1ns/1ps\n"
        "module tb_probe;\n"
        "  initial begin #1; $display(\"PROBE\"); $finish; end\n"
        "endmodule\n",
        encoding="ascii", newline="\n")
    obj = probe / "obj"
    if obj.exists():
        shutil.rmtree(obj)

    log("building shared Verilator runtime cache (one time, ~35 s) ...")
    cmd = [str(verilator), "--cc", "--exe", "--main", "--timing", "-j", "4",
           "-Wno-fatal", "--top-module", "tb_probe",
           "--Mdir", str(obj), "-o", "tb_probe", str(src)]
    started = time.time()
    res = subprocess.run(cmd, cwd=str(ROOT), env=_build_env(),
                         capture_output=True, text=True, encoding="utf-8",
                         errors="replace")
    if res.returncode != 0:
        log(res.stdout[-4000:])
        log(res.stderr[-4000:])
        raise SystemExit("runtime probe generation failed")
    res = subprocess.run(
        [str(MAKE_EXE), "-f", "Vtb_probe.mk", "-j", "4", "tb_probe"],
        cwd=str(obj), env=_build_env(), capture_output=True, text=True,
        encoding="utf-8", errors="replace")
    if res.returncode != 0:
        log(res.stdout[-4000:])
        log(res.stderr[-4000:])
        raise SystemExit("runtime probe build failed")
    for name in RUNTIME_OBJS:
        produced = obj / name
        if not produced.is_file():
            raise SystemExit(
                "runtime probe did not produce %s (check the verilator log)" % name)
        shutil.copy2(produced, RUNTIME_DIR / name)
    log("runtime cache ready in %.1f s" % (time.time() - started))
    return True


# ---------------------------------------------------------------------------
# One case: generate, build, run
# ---------------------------------------------------------------------------
class CaseResult:
    def __init__(self, case: Case):
        self.name = case.name
        self.ok = False
        self.skipped = False
        self.seconds = 0.0
        self.detail = ""
        self.log_path = BUILD / case.name / "run.log"
        self.output = ""


def _first_failure_line(text: str) -> str:
    patterns = (
        r"^FIRST_MISMATCH.*$",
        r"^MISMATCH_DETAIL.*$",
        r"^CHECK FAIL.*$",
        r"^RESULT: FAIL.*$",
        r"^ERROR:.*$",
    )
    for line in text.splitlines():
        for pat in patterns:
            if re.match(pat, line.strip()):
                return line.strip()[:220]
    return ""


def run_case(case: Case, verilator: Path, args) -> CaseResult:
    result = CaseResult(case)
    started = time.time()
    work = BUILD / case.name
    obj = work / "obj"
    work.mkdir(parents=True, exist_ok=True)
    log_lines: list[str] = []

    def log(message: str) -> None:
        log_lines.append(str(message))

    tb_path = SIM_DIR / case.tb
    if not tb_path.is_file():
        if case.optional:
            result.skipped = True
            result.detail = "TB not delivered yet (%s)" % case.tb
            result.log_path.write_text("SKIPPED: %s\n" % result.detail, encoding="utf-8")
            return result
        result.detail = "missing TB %s" % tb_path
        result.log_path.write_text(result.detail + "\n", encoding="utf-8")
        result.seconds = time.time() - started
        return result

    try:
        # Golden tables were prepared once, serially, before the pool starts
        # (see main): that keeps shared tables race-free under --jobs > 1.
        rtl = _apply_overrides(case, work)
    except Exception as exc:        # noqa: BLE001 - reported, never fatal
        result.detail = "prepare failed: %s" % exc
        result.log_path.write_text(result.detail + "\n", encoding="utf-8")
        result.seconds = time.time() - started
        return result

    if args.clean and obj.exists():
        shutil.rmtree(obj)
    obj.mkdir(parents=True, exist_ok=True)

    exe_name = "sim_%s" % case.name
    top = Path(case.tb).stem
    gen_cmd = [str(verilator), "--cc", "--exe", "--main", "--timing",
               "-j", "4", "-Wno-fatal"]
    gen_cmd += VERILATOR_WARN_OFF
    for define in case.defines:
        gen_cmd.append("-D" + define if not define.startswith("-D") else define)
    gen_cmd += case.extra_flags
    gen_cmd += ["--top-module", top, "--Mdir", str(obj), "-o", exe_name,
                str(tb_path)] + [str(path) for path in rtl]
    if args.trace:
        gen_cmd.append("--trace")
    log("$ " + " ".join(gen_cmd))
    gen = subprocess.run(gen_cmd, cwd=str(ROOT), env=_build_env(),
                         capture_output=True, text=True, encoding="utf-8",
                         errors="replace")
    log(gen.stdout[-8000:])
    if gen.returncode != 0:
        log(gen.stderr[-8000:])
        result.detail = "verilator generation failed (exit %d)" % gen.returncode
        result.log_path.write_text("\n".join(log_lines) + "\n", encoding="utf-8")
        result.seconds = time.time() - started
        return result

    # Shared runtime objects (must be newer than the Verilator headers so make
    # does not rebuild them).
    for name in RUNTIME_OBJS:
        src_obj = RUNTIME_DIR / name
        if src_obj.is_file():
            shutil.copy2(src_obj, obj / name)

    make_cmd = [str(MAKE_EXE), "-f", "V%s.mk" % top, "-j", "4", exe_name]
    log("$ " + " ".join(make_cmd))
    build = subprocess.run(make_cmd, cwd=str(obj), env=_build_env(),
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace")
    log(build.stdout[-8000:])
    if build.returncode != 0:
        log(build.stderr[-8000:])
        result.detail = "g++ build failed (exit %d)" % build.returncode
        result.log_path.write_text("\n".join(log_lines) + "\n", encoding="utf-8")
        result.seconds = time.time() - started
        return result

    exe = obj / (exe_name + ".exe")
    if not exe.is_file():
        result.detail = "executable missing after build"
        result.log_path.write_text("\n".join(log_lines) + "\n", encoding="utf-8")
        result.seconds = time.time() - started
        return result

    log("$ %s" % exe)
    try:
        run = subprocess.run([str(exe)], cwd=str(ROOT), env=_build_env(),
                             capture_output=True, text=True, encoding="utf-8",
                             errors="replace", timeout=case.timeout)
        output = (run.stdout or "") + (run.stderr or "")
        log(output)
        result.output = output
        result.ok = (run.returncode == 0) and ("RESULT: PASS" in output)
        result.detail = "" if result.ok else (
            _first_failure_line(output) or "exit %d" % run.returncode)
    except subprocess.TimeoutExpired as exc:
        partial = exc.stdout or ""
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", "replace")
        log(partial)
        result.detail = "timeout after %ds" % case.timeout
        result.output = partial

    result.seconds = time.time() - started
    result.log_path.write_text("\n".join(log_lines) + "\n", encoding="utf-8",
                               errors="replace")
    return result


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _print_matrix() -> None:
    print("%-14s %-22s %-8s %s" % ("CASE", "TESTBENCH", "TIMEOUT", "DESCRIPTION"))
    print("-" * 96)
    for case in CASES.values():
        mark = "*" if case.optional else " "
        print("%-14s %-22s %-8s%s %s" % (
            case.name + mark, case.tb, "%ds" % case.timeout, "", case.description))
    print("\n* = optional (TB delivered by another task; SKIP when missing)")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="InstRec-FPGA Verilator simulation runner")
    parser.add_argument("target", nargs="?", default="all",
                        help="case name, a comma separated list, or 'all'")
    parser.add_argument("--jobs", "-j", type=int, default=1,
                        help="number of testbenches to build/run concurrently")
    parser.add_argument("--keep", action="store_true",
                        help="keep the waveform (adds --trace, slower)")
    parser.add_argument("--trace", action="store_true", help="alias of --keep")
    parser.add_argument("--clean", action="store_true",
                        help="remove build/sim/<case>/obj before building")
    parser.add_argument("--list", action="store_true", help="list cases and exit")
    parser.add_argument("--verbose", action="store_true",
                        help="stream the per-case log to stdout")
    args = parser.parse_args(argv)
    args.trace = args.trace or args.keep

    if args.list:
        _print_matrix()
        return 0

    if args.target == "all":
        selected = [c for c in CASES.values()]
    else:
        names = [n.strip() for n in args.target.split(",") if n.strip()]
        unknown = [n for n in names if n not in CASES]
        if unknown:
            print("unknown case(s): %s" % ", ".join(unknown), file=sys.stderr)
            print("available: %s" % ", ".join(CASES), file=sys.stderr)
            return 2
        selected = [CASES[n] for n in names]

    try:
        verilator, _ = _toolchain()
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        return 2

    BUILD.mkdir(parents=True, exist_ok=True)
    try:
        ensure_runtime(verilator, print)
    except SystemExit as exc:
        print("runtime cache failure: %s" % exc, file=sys.stderr)
        return 2

    jobs = max(1, min(args.jobs, len(selected)))
    # Serial golden-data preparation: cheap (1-3 s total) and race-free, so a
    # table shared by two cases (mel / mel_credit) is never written twice.
    try:
        for case in selected:
            if case.prepare:
                work = BUILD / case.name
                work.mkdir(parents=True, exist_ok=True)
                PREPARERS[case.prepare](work)
    except Exception as exc:        # noqa: BLE001
        print("data preparation failed: %s" % exc, file=sys.stderr)
        return 2

    started = time.time()
    results: list[CaseResult] = []

    if jobs == 1:
        for case in selected:
            res = run_case(case, verilator, args)
            results.append(res)
            _print_progress(res, args.verbose)
    else:
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            futures = {pool.submit(run_case, case, verilator, args): case
                       for case in selected}
            for future in as_completed(futures):
                case = futures[future]
                try:
                    res = future.result()
                except Exception as exc:        # noqa: BLE001
                    res = CaseResult(case)
                    res.detail = "runner exception: %s" % exc
                results.append(res)
                _print_progress(res, args.verbose)

    results.sort(key=lambda r: list(CASES).index(r.name))
    total = time.time() - started

    print("")
    print("=" * 108)
    print("%-14s %-8s %-9s %s" % ("TB", "RESULT", "TIME", "FIRST FAILURE / NOTE"))
    print("-" * 108)
    for res in results:
        status = "SKIP" if res.skipped else ("PASS" if res.ok else "FAIL")
        print("%-14s %-8s %-9s %s" % (res.name, status, "%.1fs" % res.seconds,
                                      res.detail))
    print("=" * 108)
    passed = sum(1 for r in results if r.ok)
    failed = sum(1 for r in results if not r.ok and not r.skipped)
    skipped = sum(1 for r in results if r.skipped)
    print("total %.1fs | pass %d | fail %d | skip %d | jobs %d"
          % (total, passed, failed, skipped, jobs))
    with open(BUILD / "summary.txt", "w", encoding="utf-8", newline="\n") as handle:
        for res in results:
            handle.write("%s\t%s\t%.1f\t%s\n" % (
                res.name, "SKIP" if res.skipped else ("PASS" if res.ok else "FAIL"),
                res.seconds, res.detail))
        handle.write("total %.1f s jobs %d\n" % (total, jobs))

    return 0 if failed == 0 else 1


def _print_progress(res: CaseResult, verbose: bool) -> None:
    status = "SKIP" if res.skipped else ("PASS" if res.ok else "FAIL")
    print("[%s] %-14s %-5s %6.1fs  %s" % (
        time.strftime("%H:%M:%S"), res.name, status, res.seconds, res.detail))
    if verbose and res.output:
        print(res.output)


if __name__ == "__main__":
    sys.exit(main())
