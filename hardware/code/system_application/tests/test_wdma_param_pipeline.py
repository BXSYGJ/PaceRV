"""Cycle model of the wdma parameter-table read pipeline (2026-10-31).

`u_wdma` used to hold three per-channel tables (bias / M / shift) in
separately-addressed arrays read asynchronously, which PDS mapped to
LUTRAM/FF: 8004 LUT / 18608 FF, and the worst core_clk path
(`c_cnt -> m_s32`, 0.8 ns logic + 8.8 ns route) lived inside them.

They are now one 1024x32 block RAM (768 used, padded so the look-ahead of the
last element lands on a zeroed word) with a single synchronous read port:

    [  0..255] bias      [256..511] M      [512..767] shift

The read port returns data one cycle after the address is presented: while
`S_GRP` is at element t it consumes `pq` (= element t) and presents `pa` for
element t+1, and registers element t+2 for the next cycle.  `pa` is preset to
1 when entering `S_GRP` (element 0 was latched during `S_CS_FIL`) and to 0 one
cycle earlier in `S_CS_CMD`.

Nothing else checks this: a one-cycle slip would still compile, still route
and still produce data -- just for the neighbouring channel.  This model
compares the pipelined address/data pairing against the direct indexing the
old code used, for both contract shapes.
"""

from __future__ import annotations

import pytest

BIAS_BASE = 0
M_BASE = 256
S_BASE = 512
TABLE = list(range(1024))


def _fc_expect(c_cnt, cout):
    if c_cnt < cout:
        return BIAS_BASE + c_cnt
    if c_cnt < 2 * cout:
        return M_BASE + (c_cnt - cout)
    return S_BASE + (c_cnt - 2 * cout)


def _conv_expect(c_cnt, cout, grp_mod):
    ctr = grp_mod * 16 + (c_cnt & 15)
    if c_cnt < 16:
        return ctr
    if c_cnt < 32:
        return M_BASE + ctr
    return S_BASE + ctr


def _idx(is_fc, c_cnt, cout, grp_mod):
    return _fc_expect(c_cnt, cout) if is_fc else _conv_expect(c_cnt, cout, grp_mod)


def simulate(is_fc, cout, grp_mod=0):
    """Replay S_CS_CMD -> S_CS_FIL -> S_GRP with RTL register semantics.

      S_CS_CMD : pa <= 0
      S_CS_FIL : pq <= TABLE[0] ; pa <= 1
      S_GRP t  : use pq(=element t) ; pq <= TABLE[pa] ; pa <= idx(t+2)
    """
    total = 3 * cout if is_fc else 48
    pa = 0
    pq = TABLE[pa]          # latched in S_CS_FIL
    pa = 1                  # advanced in S_CS_FIL
    data_trace, pa_trace = [], []
    for c_cnt in range(total):
        data_trace.append((c_cnt, pq))
        pa_trace.append((c_cnt, pa))
        pq = TABLE[pa]      # data for the address presented this cycle
        pa = _idx(is_fc, c_cnt + 2, cout, grp_mod) if c_cnt + 2 <= total else 0
    return pa_trace, data_trace


@pytest.mark.parametrize('cout', [8, 128])
def test_fc_pipeline_matches_direct_indexing(cout):
    _, data_trace = simulate(True, cout)
    for c_cnt, pq in data_trace:
        assert pq == _fc_expect(c_cnt, cout), (c_cnt, pq, _fc_expect(c_cnt, cout))
    assert len(data_trace) == 3 * cout


@pytest.mark.parametrize('cout', [48, 96, 192, 256])
def test_conv_pipeline_matches_direct_indexing(cout):
    # grp_mod is deliberately 0 here: S_CS_FIL currently clears grp_mod in the
    # same branch that enters S_GRP, so S_GRP always indexes channel group 0
    # even though S_NEXT increments it.  See STATUS "wdma 组索引被清零" --
    # that behaviour is preserved unchanged by this refactor and must be
    # settled on the board before being touched.
    for grp_mod in (0,):
        _, data_trace = simulate(False, cout, grp_mod)
        for c_cnt, pq in data_trace:
            assert pq == _conv_expect(c_cnt, cout, grp_mod), (grp_mod, c_cnt, pq)
        assert len(data_trace) == 48


def test_group_index_is_cleared_on_entry():
    """Document the existing (suspicious) behaviour: grp_mod is zeroed inside
    S_CS_FIL on the transition into S_GRP, so the parameter table is always
    indexed from channel group 0 even though S_NEXT increments grp_mod."""
    from pathlib import Path
    src = (Path(__file__).resolve().parents[1] / "src/npu/wdma.v").read_text(encoding="utf-8")
    assert "grp_mod   <= 5'd0;" in src
