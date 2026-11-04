#!/usr/bin/env python3
"""gen_top_core_only.py - derive src/ctrl/top_core_only.v from instrec_top.v.

Why a generator instead of a hand-written copy
----------------------------------------------
``src/ctrl/instrec_top.v`` is the source of the archived full bitstream, so it
must never be edited for a what-if experiment (the build artefacts in
``releases/`` would no longer correspond to their source).  The core-only
build set (T36) nevertheless has to track every functional fix that lands in
``instrec_top.v`` (m0_done, the T21 DDR3 result latch, the T30 weight-loader
TX strobe, ...).  A generator gives both: the full top stays byte-identical
and the trimmed top is re-derived on demand.

What the derived top keeps and what it drops
--------------------------------------------
Kept:  ddr3_wrapper + ddr3_ctrl_axi, sys_ctrl (with the T21 ST_DDREP latch and
       the three DDR3 AXI diagnostic inputs), uart_debug / uart_tx / uart_rx,
       weight_loader, mel_engine, npu_top (conv / pool / gap / fc / softmax),
       self_test, audio_sink, audio_pll, and the PCM capture path
       (i2s_clk_gen / i2s_rx / audio_cdc_fifo) so the Mel -> NPU chain is
       reachable and therefore survives synthesis.
Dropped: ui_renderer and all four layers (bars / text / spectrum / waveform),
       ui_coord_delay, bars_data, feat_copy_engine, feat_page_buf,
       hdmi_tx_if and its iic / vout pads, the whole pix_clk / cfg_clk
       domain, and the I2S board pads.

Why the PCM stream is gated with sys_run
----------------------------------------
Two board measurements bound the design:

* With the capture path removed and the FIFO flags tied (no frame event at
  all) ``win_tick`` became constant, so ``npu_start`` did too, and constant
  folding deleted the whole Mel / NPU datapath: LUT 6806, APM 0, DRM 0.  That
  bitstream proved DDR3 (DDROK, "DDR3 STS 01") but contained no NPU.
* With the capture path live from reset (the obvious fix) the datapath is
  restored (LUT 32615, APM 89, DRM 74.5, routed at iteration 650) but the
  audio page writes on DDR3 master 0 starve the self-test: the arbiter is
  fixed priority P0(audio) > P1 > P2 > P3(self_test) with a 1 ms P3 quota
  while the AXI timeout is AXI_TO_LIMIT = 4096 core_clk cycles (32.8 us).  The
  board printed ``DDR3 ERR @00300000`` with ``DDR3 STS 26`` (to_err = 1,
  dbg_to_state = S_W, st_fail = 1) twice, deterministically.

The fix used here is the run gate: ``audio_sink`` sees the FIFO flags only
while ``sys_run`` is high, i.e. only after sys_ctrl has printed DDROK (or an
error) and reached RUN.  Before that the FIFO looks "not empty, no data", so
no frame event and no injection happen and master 0 stays quiet during the
whole self-test.  After RUN the real PCM stream flows, ``win_tick`` wakes mel
and mel starts the NPU - exactly the ordering the full system intends.

``npu_top1`` drives ``led[2:1]`` and ``npu_busy`` drives ``led[3]`` (both bits
were reserved / constant in instrec_top).  Without a visible consumer the
argmax output is dead and the conv -> pool -> gap -> fc -> softmax chain would
be optimised away again.

The script is deterministic and offline: it reads instrec_top.v, applies a
fixed list of region drops / replacements, verifies that no dropped identifier
survives and writes the result as BOM-less ASCII with LF line endings.

Usage:
    python scripts/gen_top_core_only.py            # regenerate the file
    python scripts/gen_top_core_only.py --check    # exit 1 if it drifted

Every anchor must match exactly once; a refactor of instrec_top.v therefore
fails loudly here instead of silently emitting a wrong top level.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src' / 'ctrl' / 'instrec_top.v'
TARGET = ROOT / 'src' / 'ctrl' / 'top_core_only.v'

TIMESCALE = '`timescale 1ns / 1ps'

# --------------------------------------------------------------------------- #
# Text fragments written into the derived file
# --------------------------------------------------------------------------- #

HEADER = """\
// -----------------------------------------------------------------------------
// File    : top_core_only.v
// Module  : top_core_only
// Project : InstRec-FPGA (PG2L100H-6IFBG676, PDS 2022.2-SP6.4)
// Purpose : Core-only build set (T36). DDR3 + NPU + Mel + weight loader +
//           system control, with the video / UI / HDMI half of instrec_top
//           removed.
//
// GENERATED FILE - do not edit.  It is produced by
//   python scripts/gen_top_core_only.py
// from src/ctrl/instrec_top.v, which stays the untouched source of the
// archived full bitstream (REQ-BLD-004 / release provenance).
//
// Why this build set exists
//   The full top-level needs 34960 LUT (52.49%).  This device stops routing
//   above ~34600 LUT: the m4fix bitstream fits at 34561 (routed, "All
//   Constraints Met") while 34960 stalls with 4000+ unrouted nets forever.
//   The UI half is already board-proven as its own bitstream (top_ui_demo,
//   reports/ui_demo_conclusion.md), so it does not have to occupy LUT here.
//   Removing it brings the core design back under the routing cliff
//   (measured: LUT 32615, placed and routed, WNS +3.862 ns).
//
// Kept     : ddr3_wrapper, ddr3_ctrl_axi, sys_ctrl (incl. the T21 ST_DDREP
//            result latch and the three DDR3 AXI diagnostic inputs),
//            uart_debug, uart_tx, uart_rx, weight_loader, mel_engine,
//            npu_top (conv / pool / gap / fc / softmax), self_test,
//            audio_sink, audio_pll, and the PCM capture path
//            (i2s_clk_gen / i2s_rx / audio_cdc_fifo).
// Dropped  : ui_renderer, bars_data / bars_disp, text_disp, spectrum_disp,
//            waveform drawing, ui_coord_delay, feat_copy_engine,
//            feat_page_buf, hdmi_tx_if, the whole pix_clk / cfg_clk domain,
//            and the iic_* / vout_* / I2S pads.
//
// Clock domains
//   clk      27 MHz board crystal (D18), audio PLL reference
//   clk_nco  216 MHz audio time base (audio_pll), drives the I2S bit clock
//   core_clk 125 MHz DDR3 controller user clock (ddr3_wrapper output); every
//            functional register of this build set lives here
//
// Short-circuited inputs (documented tie-offs, all in one block below)
//   * I2S  : i2s_sd tied to 0 and no I2S pads, so the receiver emits
//            zero-valued stereo frames at the normal 44.1 kHz frame rate.
//   * PCM  : audio_sink only sees the FIFO flags while sys_run is high, so
//            master 0 stays quiet during the DDR3 self-test.  Without this
//            gate the audio page writes starve master 3 (measured on board:
//            "DDR3 ERR @00300000" + "DDR3 STS 26", to_err = 1 in state S_W:
//            fixed priority P0 > P3 with a 1 ms P3 quota against a 32.8 us
//            AXI timeout).
//   * HDMI : hdmi_init_over = 1 / hdmi_init_fail = 0, so sys_ctrl's PLL_WAIT
//            stage no longer waits for an I2C configuration that does not
//            exist here.  Ddrphy CPD lock and ddr_init_done stay real DDR3 IP
//            signals, so DDROK still requires a real DDR3 initialisation plus
//            a real 4 KB write / read-back self-test.
//   * KEY1 : tied high (no re-trigger pin in this build set).
//
// LED map: led[5] = sticky uart_rx_seen, led[3] = npu_busy, led[2:1] =
// npu_top1[1:0].  The last two keep the Mel -> NPU chain and the argmax
// visible to the optimiser and to the board.
//
// Artifact: build/top_core_only-latest.sbit (see scripts/build_sets.json).
// -----------------------------------------------------------------------------

"""

MODULE_HEADER = """\
module top_core_only #(
    // 1 = the NPU starts on the mel window pulse (kept for parity with
    // instrec_top).  Do NOT re-tie this to 0: a constant start lets the
    // optimiser delete the conv / pool / gap / fc / softmax chain.
    parameter NPU_ENABLE = 1
) (
    // ---- board pins ----
    input  wire        clk,          // 27 MHz crystal (D18), audio PLL ref
    input  wire        rst_n,        // KEY0, active low (C22)
    output wire [7:0]  led,          // status LEDs (A20..B17)
    input  wire        uart_rx,      // CP2102 RX (B24), weight upload
    output wire        uart_tx,      // CP2102 TX (C24)
    // ---- DDR3 physical side (ddr3_wrapper pass-through, N3/N2 + 73 pins) ----
    input  wire        ref_clk_p,    // 125 MHz differential reference
    input  wire        ref_clk_n,
    output wire        mem_cs_n,
    output wire        mem_rst_n,
    output wire        mem_ck,
    output wire        mem_ck_n,
    output wire        mem_cke,
    output wire        mem_ras_n,
    output wire        mem_cas_n,
    output wire        mem_we_n,
    output wire        mem_odt,
    output wire [14:0] mem_a,
    output wire [2:0]  mem_ba,
    inout  wire [3:0]  mem_dqs,
    inout  wire [3:0]  mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [3:0]  mem_dm
);
"""

DECLARATIONS = """\
    // ==================================================================
    // Audio chain (clk_nco capture side + core_clk FIFO side).
    // The audio_sink data valid/empty inputs are the run-gated versions
    // (fifo_rd_valid_run / fifo_empty_run, driven once sys_run exists), so
    // the DDR3 master-0 page writes only start after the self-test result
    // has been printed.  See the header note "Why the PCM stream is gated".
    // ==================================================================
    wire [4:0]  bck_phase;
    wire        bck_tick;
    wire [15:0] pcm_l;
    wire [15:0] pcm_r;
    wire        pcm_valid;
    wire        sd_idle;
    wire        fifo_rd_en;
    wire [31:0] fifo_rd_data;
    wire        fifo_rd_valid;
    wire        fifo_empty;
    wire        fifo_full;       // observation tap
    wire [15:0] overflow_cnt;
    wire        m0_cmd_valid;
    wire [36:0] m0_cmd;
    wire [255:0] m0_wdata;
    wire        m0_done;
    wire        win_tick;        // window pulse: mel start
    wire [15:0] win_id;          // observation tap
    wire        mute_flag;       // observation tap
    wire [15:0] audio_err_cnt;   // observation tap
    // Parked I2S pad outputs: no board pin in this build set, but the bit
    // generator keeps driving them, which keeps the clk_nco domain (and
    // therefore the frame cadence that feeds win_tick) alive.
    wire        i2s_bck_unused;
    wire        i2s_lrck_unused;
    // Parked waveform outputs of audio_sink (the waveform layer is gone).
    wire        mute_flag_sync_unused;
    wire [15:0] wave_min_unused;
    wire [15:0] wave_max_unused;
    wire        wave_valid_unused;
    // NPU argmax: consumed by led[2:1] so the softmax chain cannot be pruned
    wire [3:0]  npu_top1;
"""

RUN_GATE = """\
    wire [15:0] uart_rx_byte_cnt;  // observation tap

    // ==================================================================
    // T36 run gate: the PCM stream (and therefore DDR3 master 0) is only
    // presented to audio_sink after sys_run rises, i.e. after sys_ctrl has
    // printed the DDR3 result and entered RUN.  See the header note
    // "Why the PCM stream is gated with sys_run".
    // ==================================================================
    wire fifo_rd_valid_run;
    wire fifo_empty_run;

    assign fifo_rd_valid_run = fifo_rd_valid & sys_run;
    assign fifo_empty_run    = sys_run ? fifo_empty : 1'b0;
"""

RUN_GATE_ANCHOR = '    wire [15:0] uart_rx_byte_cnt;  // observation tap'

FEATURE_PORT = """\
    // ---- Mel feature read port: the NPU owns it in this build set ----
    // The copy engine and the spectrogram page buffer are gone with the UI
    // half, so the feature address is the NPU request with no multiplexer.
    wire [14:0] npu_feat_rd_addr;
    assign mel_feat_rd_addr = npu_feat_rd_addr;
"""

LED_BLOCK = """\
    // ==================================================================
    // T36 harness + LED assembly.
    //
    // led[7:6] self-test stage code            (unchanged)
    // led[5]   uart_rx_seen: sticky "any UART byte received since reset".
    //          This separates a dead PC -> FPGA path from a loader /
    //          protocol problem without an ILA (see the WOK note above).
    // led[4]   SAFE_ERR latched state          (unchanged)
    // led[3]   npu_busy: rises once mel has fired npu_start (first audio
    //          window after RUN) - the cheapest "the NPU really started"
    //          proof, visible without an ILA.
    // led[2:1] npu_top1[1:0]: the argmax consumer that keeps the
    //          conv -> pool -> gap -> fc -> softmax chain from being
    //          optimised away.
    // led[0]   1 Hz heartbeat (active after RUN)
    //
    // Two fields are repurposed relative to instrec_top: led[5] used to be
    // the CDC-FIFO overflow warning (no I2S pad here, so overflow cannot
    // occur) and led[3:1] used to be a constant 0.
    // ==================================================================
    reg uart_rx_seen;

    always @(posedge core_clk or negedge core_clk_rst_n) begin
        if (!core_clk_rst_n) begin
            uart_rx_seen <= 1'b0;
        end else if (rx_byte_valid) begin
            uart_rx_seen <= 1'b1;
        end
    end

    assign led = {stage_code, uart_rx_seen, safe_err, npu_busy_u,
                  npu_top1[1:0], heartbeat};

"""

# --------------------------------------------------------------------------- #
# Region operations (start anchor, end anchor, replacement, optional suffix)
# --------------------------------------------------------------------------- #
# ``end`` is a substring searched AFTER the start anchor; when ``suffix`` is
# given the region also swallows the next line whose stripped text equals it
# (used to take the closing ");" of an instance statement).

REGIONS = (
    # ---- audio / video net declarations -> core-only declaration block ----
    (
        '    // ==================================================================\n'
        '    // Audio chain (clk_nco / core_clk domains)',
        '    wire [3:0]  npu_top1_u;',
        DECLARATIONS,
        None,
    ),
    # ---- HDMI transmitter front end (GPLL_B + I2C + vout pads) ----
    (
        '    // ---- HDMI transmitter front end (GPLL_B + I2C config + pads) ----',
        '.pll_lock       (hdmi_pll_lock)',
        '',
        ');',
    ),
    # ---- LED assembly + T36 harness (sticky rx-seen, npu_busy, argmax) ----
    (
        '    // ==================================================================\n'
        '    // LED assembly (design doc section 2.2.9',
        "assign led = {stage_code, overflow_warn, safe_err, 3'b000, heartbeat};",
        LED_BLOCK,
        None,
    ),
    # ---- the entire UI half: four layers + overlays + spectrogram chain ----
    (
        '    // ---- UI renderer (waveform region; instantiates waveform_disp) ----',
        '.vs_out        (ui_vs)',
        FEATURE_PORT,
        ');',
    ),
)

#: Whole lines that only exist for the video / HDMI domains.
DROP_LINES = (
    'wire pix_clk;',
    'wire rst_pix_n;',
    'wire hdmi_init_over;',
    'wire hdmi_init_fail;',
    'wire hdmi_pll_lock;',
)

#: Exact port connections that must be re-pointed (old, new).  Each target
#: must occur exactly once, so a rename inside instrec_top.v fails here.
SUBS = (
    # sys_ctrl inputs that belonged to the removed domains
    (".hdmi_init_over  (hdmi_init_over)", ".hdmi_init_over  (1'b1)"),
    (".hdmi_init_fail  (hdmi_init_fail)", ".hdmi_init_fail  (1'b0)"),
    (".key1_n          (key1_n)", ".key1_n          (1'b1)"),
    # I2S pads are gone: the bit generator drives parking nets and the serial
    # data input is tied low (zero-valued frames keep the cadence alive).
    (".i2s_bck   (i2s_bck),", ".i2s_bck   (i2s_bck_unused),"),
    (".i2s_lrck  (i2s_lrck)\n    );", ".i2s_lrck  (i2s_lrck_unused)\n    );"),
    # i2s_rx and audio_cdc_fifo take the frame clock as an input; the two
    # source lines differ only in the alignment padding.
    (".i2s_lrck  (i2s_lrck),", ".i2s_lrck  (i2s_lrck_unused),"),
    (".i2s_lrck    (i2s_lrck),", ".i2s_lrck    (i2s_lrck_unused),"),
    (".i2s_sd    (i2s_sd),", ".i2s_sd    (1'b0),"),
    # audio_sink: only the run-gated FIFO status is visible, waveform ports
    # are parked and the waveform read address is tied to 0
    (".fifo_rd_valid (fifo_rd_valid)", ".fifo_rd_valid (fifo_rd_valid_run)"),
    (".fifo_empty    (fifo_empty)", ".fifo_empty    (fifo_empty_run)"),
    (".pix_clk       (pix_clk)", ".pix_clk       (core_clk)"),
    (".vsync_pulse   (vsync_pulse)", ".vsync_pulse   (1'b0)"),
    (".wave_rd_addr  (wave_rd_addr)", ".wave_rd_addr  (11'd0)"),
    (".wave_min      (wave_min)", ".wave_min      (wave_min_unused)"),
    (".wave_max      (wave_max)", ".wave_max      (wave_max_unused)"),
    (".wave_valid    (wave_valid)", ".wave_valid    (wave_valid_unused)"),
    (".mute_flag_sync(mute_flag_sync)", ".mute_flag_sync(mute_flag_sync_unused)"),
    # NPU argmax becomes a visible LED consumer (see the header note)
    (".top1         (npu_top1_u)", ".top1         (npu_top1)"),
    # the run gate itself
    (RUN_GATE_ANCHOR, RUN_GATE.rstrip('\n')),
)

#: Identifiers that must not survive outside a port-connection line.
FORBIDDEN = (
    'pix_clk', 'rst_pix_n', 'pix_x', 'pix_y', 'pix_de', 'pix_hs', 'pix_vs',
    'hdmi_tx_if', 'hdmi_init_over', 'hdmi_init_fail', 'hdmi_pll_lock',
    'iic_tx_scl', 'iic_tx_sda', 'vout_clk', 'vout_de', 'vout_hs', 'vout_vs',
    'vout_data',
    'ui_renderer', 'ui_coord_delay', 'ui_rgb', 'ui_de', 'ui_hs', 'ui_vs',
    'bars_data', 'bars_disp', 'bars_x', 'bars_y', 'bars_on', 'bars_rgb',
    'text_disp', 'text_pct', 'text_rgb', 'text_on', 'top1_s0', 'top1_s1',
    'spectrum_disp', 'spec_x', 'spec_y', 'spec_de', 'spec_rgb', 'spec_on',
    'spec_ram_addr', 'spec_ram_data',
    'feat_copy_engine', 'feat_page_buf', 'copy_src_addr', 'copy_src_en',
    'copy_dst_addr', 'copy_dst_data', 'copy_dst_we', 'copy_dst_page',
    'copy_done_u',
    'npu_top1_u', 'wave_rd_addr', 'wave_min', 'wave_max', 'wave_valid',
    'mute_flag_sync',
)

#: Ports the derived module must expose, in declaration order.
EXPECTED_PORTS = (
    'clk', 'rst_n', 'led', 'uart_rx', 'uart_tx',
    'ref_clk_p', 'ref_clk_n', 'mem_cs_n', 'mem_rst_n', 'mem_ck', 'mem_ck_n',
    'mem_cke', 'mem_ras_n', 'mem_cas_n', 'mem_we_n', 'mem_odt', 'mem_a',
    'mem_ba', 'mem_dqs', 'mem_dqs_n', 'mem_dq', 'mem_dm',
)

PORT_RE = re.compile(r'\b(?:input|output|inout)\s+(?:wire|reg)\s*(?:\[[^\]]*\])?\s*([A-Za-z_]\w*)')


# --------------------------------------------------------------------------- #
# Text helpers
# --------------------------------------------------------------------------- #
def _one(text: str, anchor: str, what: str) -> int:
    """Index of an anchor that must occur exactly once."""
    index = text.find(anchor)
    if index < 0:
        raise SystemExit(f'anchor not found ({what}): {anchor!r}')
    if text.find(anchor, index + 1) >= 0:
        raise SystemExit(f'anchor is not unique ({what}): {anchor!r}')
    return index


def _first(text: str, anchor: str, start: int, what: str) -> int:
    """Index of the first anchor occurrence at or after ``start``.

    End anchors are resolved forward from the (unique) start line, so a signal
    that also appears in a later instance is not ambiguous.
    """
    index = text.find(anchor, start)
    if index < 0:
        raise SystemExit(f'anchor not found ({what}): {anchor!r}')
    return index


def _line_start(text: str, index: int) -> int:
    return text.rfind('\n', 0, index) + 1


def _line_end(text: str, index: int) -> int:
    newline = text.find('\n', index)
    return len(text) if newline < 0 else newline + 1


def replace_region(text: str, start: str, end: str, replacement: str,
                   suffix: str | None = None, what: str = '') -> str:
    """Replace the line range that carries ``start`` .. ``end`` (inclusive)."""
    first = _line_start(text, _one(text, start, what or 'region start'))
    last = _line_end(text, _first(text, end, first, what or 'region end'))
    if suffix is not None:
        cursor = last
        while cursor < len(text):
            line_end = _line_end(text, cursor)
            if text[cursor:line_end].strip() == suffix:
                last = line_end
                break
            cursor = line_end
        else:
            raise SystemExit(f'region terminator {suffix!r} not found after {end!r}')
        # swallow the single blank line that follows an instance statement
        if text[last:last + 1] == '\n':
            last += 1
    return text[:first] + replacement + text[last:]


def drop_line(text: str, prefix: str) -> str:
    """Remove the one line whose stripped text starts with ``prefix``."""
    hits = []
    offset = 0
    for line in text.splitlines(keepends=True):
        if line.strip().startswith(prefix):
            hits.append((offset, offset + len(line)))
        offset += len(line)
    if len(hits) != 1:
        raise SystemExit(f'line {prefix!r} expected exactly one hit, got {len(hits)}')
    start, end = hits[0]
    return text[:start] + text[end:]


def substitute(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f'substitution target {old!r} expected once, got {text.count(old)}')
    return text.replace(old, new)


# --------------------------------------------------------------------------- #
# Generation
# --------------------------------------------------------------------------- #
def generate() -> str:
    text = SOURCE.read_text(encoding='utf-8').replace('\r\n', '\n')

    # 1) file header: everything above `timescale is replaced
    timescale_start = _line_start(text, _one(text, TIMESCALE, 'timescale'))
    text = HEADER + text[timescale_start:]

    # 2) module name + port list
    module_start = _line_start(text, _one(text, 'module instrec_top #(', 'module header'))
    ports_end = _one(text[module_start:], '\n);\n', 'port list terminator') + module_start
    text = text[:module_start] + MODULE_HEADER + text[ports_end + len('\n);\n'):]

    # 3) region drops / replacements (declarations first, then instances)
    for index, (start, end, replacement, suffix) in enumerate(REGIONS):
        text = replace_region(text, start, end, replacement, suffix,
                              what=f'region {index}')

    # 4) single-line removals
    for prefix in DROP_LINES:
        text = drop_line(text, prefix)

    # 5) port re-pointing (includes the run-gate block insertion)
    for old, new in SUBS:
        text = substitute(text, old, new)

    # 6) collapse runs of three or more blank lines left by the drops
    text = re.sub(r'\n{3,}', '\n\n', text)

    validate(text)
    return text


def _mask_comments(text: str) -> list[str]:
    """Drop // and /* */ comments, keeping one output line per input line.

    Comments legitimately name the dropped blocks (the header explains what
    was removed), so the forbidden-identifier scan must only look at live RTL.
    """
    masked = []
    in_block = False
    for line in text.splitlines():
        out = []
        i = 0
        in_string = False
        while i < len(line):
            char = line[i]
            pair = line[i:i + 2]
            if in_block:
                if pair == '*/':
                    in_block = False
                    i += 2
                else:
                    i += 1
                continue
            if in_string:
                out.append(char)
                if char == '"':
                    in_string = False
                i += 1
                continue
            if char == '"':
                in_string = True
                out.append(char)
                i += 1
                continue
            if pair == '//':
                break
            if pair == '/*':
                in_block = True
                i += 2
                continue
            out.append(char)
            i += 1
        masked.append(''.join(out))
    return masked


DECL_START_RE = re.compile(r'^\s*(?:wire|reg|parameter|localparam)\s*'
                           r'(?:signed\s+)?(?:\[[^\]]*\]\s*)?')
BARE_SIGNAL_RE = re.compile(r'\.\s*([A-Za-z_]\w*)\s*\(\s*([A-Za-z_]\w*)\s*\)')
STOP_WORDS = ('wire', 'reg', 'parameter', 'localparam', 'signed')

#: Nets that are implicit (undeclared) in instrec_top.v as well.  PDS accepts
#: them with -system_verilog, so the derived file keeps them byte-identical
#: rather than adding a declaration the reference source does not have.
IMPLICIT_NETS = ('dbg_tx_ready',)


def _declared(text: str) -> set[str]:
    """Identifier set of every wire/reg/parameter/localparam declaration."""
    names: set[str] = set()
    for line in _mask_comments(text):
        code = line.strip()
        if not DECL_START_RE.match(code):
            continue
        body = DECL_START_RE.sub('', code).rstrip(';,')
        for part in body.split(','):
            part = part.split('=')[0].strip()
            match = re.match(r'([A-Za-z_]\w*)', part)
            if match and match.group(1) not in STOP_WORDS:
                names.add(match.group(1))
    return names


def validate(text: str) -> None:
    """Fail loudly if a dropped signal or the wrong module name survives."""
    if 'module top_core_only' not in text:
        raise SystemExit('generated text does not declare module top_core_only')
    if 'module instrec_top' in text:
        raise SystemExit('generated text still declares module instrec_top')

    ports = PORT_RE.findall(text[text.index('module top_core_only'):
                                text.index(');', text.index('module top_core_only'))])
    if tuple(ports) != EXPECTED_PORTS:
        raise SystemExit(f'port list mismatch:\n  expected {EXPECTED_PORTS}\n  actual   {tuple(ports)}')

    for number, line in enumerate(_mask_comments(text), 1):
        if line.lstrip().startswith('.'):
            continue  # instance port connection: a port NAME is not a signal
        for token in FORBIDDEN:
            if re.search(r'\b' + re.escape(token) + r'\b', line):
                raise SystemExit(
                    f'forbidden identifier {token!r} survived at line {number}: {line.strip()}')

    # Every instance connection must name a declared net.  Implicit nets are
    # not used here; the exception above is implicit in instrec_top.v as well,
    # so it is carried over unchanged instead of diverging from the reference.
    declared = _declared(text) | set(EXPECTED_PORTS)
    for number, line in enumerate(_mask_comments(text), 1):
        for _port, signal in BARE_SIGNAL_RE.findall(line):
            if signal in declared or signal in IMPLICIT_NETS:
                continue
            raise SystemExit(
                f'undeclared net {signal!r} at line {number}: {line.strip()}')

    for number, line in enumerate(text.splitlines(), 1):
        if not line.isascii():
            raise SystemExit(f'non-ASCII text at line {number}: {line!r}')


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--check', action='store_true',
                        help='compare with the file on disk, do not write it')
    args = parser.parse_args(argv)

    generated = generate()
    if args.check:
        if not TARGET.exists():
            print(f'{TARGET}: missing')
            return 1
        current = TARGET.read_text(encoding='utf-8').replace('\r\n', '\n')
        if current != generated:
            print(f'{TARGET}: OUT OF DATE, rerun python scripts/gen_top_core_only.py')
            return 1
        print(f'{TARGET}: up to date ({len(generated.splitlines())} lines)')
        return 0

    TARGET.write_text(generated, encoding='utf-8', newline='\n')
    print(f'wrote {TARGET} ({len(generated.splitlines())} lines, '
          f'{len(EXPECTED_PORTS)} port declarations)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))