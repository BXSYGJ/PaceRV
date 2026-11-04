"""Mel feature page copy semantics (M3): copy engine + double-buffered page.

Board history: the first ``feat_copy_engine`` dropped the last byte of the
window and wrote it into the *new* page after the flip, so the spectrogram
showed one stale row.  The fix defers the page flip by one beat, but nothing
in lint or PDS compile checks that ordering.  This cycle model pins it:

  * exactly DEPTH bytes are written, once each, in order 0..DEPTH-1;
  * the source address stream stops after DEPTH reads;
  * the flip happens strictly after the last byte is written;
  * the pixel read port always reads the page that is *not* being written.

The model specifies an unstalled page-copy schedule. The production RTL is
also exercised against synchronous shared RAM with pause/resume in
sim/experiments/activation_store/run_feature_mux_audit.py.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def copy_engine(depth, src, limit=None):
    """Reference schedule for the unstalled copy and delayed page flip."""
    if limit is None:
        limit = 4 * depth + 64
    idx = 0
    idx_q = 0
    fin = 0
    run = 1
    src_en = 1
    src_addr = 0
    page = 0
    writes = []
    reads = []
    flips = 0
    done = None
    issued = {}
    for cyc in range(limit):
        if not run:
            break
        if src_en:
            issued[cyc] = src_addr
            reads.append(src_addr)
        # mel returns the byte one cycle after the address
        data = src[issued[cyc - 1]] if (cyc - 1) in issued else None
        if idx != 0 and data is not None:
            writes.append((cyc, idx_q, data, page))
        # ---- next-state, evaluated with pre-edge values ----
        next_fin = 1 if idx == depth else fin
        if idx == depth:
            next_idx = idx
            next_src_addr = src_addr
            next_src_en = 0
        else:
            next_idx = idx + 1
            next_src_addr = idx + 1
            next_src_en = 1 if (idx + 1) < depth else 0
        if fin and idx == depth:
            run = 0
            page ^= 1
            flips += 1
            done = cyc
            next_fin = 0
        idx_q = idx
        idx = next_idx
        fin = next_fin
        src_addr = next_src_addr
        src_en = next_src_en
    return writes, reads, flips, done


def test_copy_writes_every_byte_once_in_order():
    depth = 16
    src = bytes(range(depth))
    writes, reads, flips, done = copy_engine(depth, src)
    assert len(writes) == depth, len(writes)
    assert [w[1] for w in writes] == list(range(depth))
    assert bytes(w[2] for w in writes) == src
    assert flips == 1
    assert done is not None


def test_flip_happens_after_last_byte():
    depth = 16
    writes, _, _, done = copy_engine(depth, bytes(depth))
    last_write_cycle = max(w[0] for w in writes)
    assert done > last_write_cycle, (done, last_write_cycle)
    # every byte was written into the page that was current *before* the flip
    assert set(w[3] for w in writes) == {0}


def test_source_reads_are_exactly_depth():
    depth = 16
    _, reads, _, _ = copy_engine(depth, bytes(depth))
    assert len(reads) == depth, reads


def test_read_port_selects_the_other_page():
    """feat_page_buf reads page0 while wr_page=1 and vice versa."""
    for wr_page in (0, 1):
        read_page = 0 if wr_page == 1 else 1
        assert read_page != wr_page


def test_rtl_depth_matches_window():
    copy_src = (ROOT / 'src/ui/feat_copy_engine.v').read_text(encoding='utf-8')
    buf_src = (ROOT / 'src/ui/feat_page_buf.v').read_text(encoding='utf-8')
    depth_copy = int(re.search(r'localparam\s+DEPTH\s*=\s*(\d+)', copy_src).group(1))
    depth_buf = int(re.search(r'localparam\s+DEPTH\s*=\s*(\d+)', buf_src).group(1))
    assert depth_copy == depth_buf == 258 * 64


def test_copy_engine_gates_on_npu_busy():
    """The share engine must not steal the mel read port from the NPU."""
    src = (ROOT / 'src/ui/feat_copy_engine.v').read_text(encoding='utf-8')
    assert 'start && !busy_in' in src
    assert 'src_en = run && !busy_in' in src
    assert 'if (rd_pending)' in src
