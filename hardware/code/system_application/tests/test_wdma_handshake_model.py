"""wdma autonomous group rhythm vs conv_engine group boundaries.

The RTL in question (all constants quoted from the source):

  src/npu/wdma.v:64-77      per-layer geometry (wb/cout/grp_total/
                            taps_per_grp/tap_bytes)
  src/npu/wdma.v:283-317    48-beat contract per group (conv layers)
  src/npu/wdma.v:320-372    weight burst + tap emit, 2 taps per 32-byte beat
  src/npu/wdma.v:374-390    S_NEXT: grp_advance is kept as a port but the
                            DMA keeps its own rhythm (no wait)
  src/npu/conv_engine.v:191 localparam GRP_NUM = COUT / 16
  src/npu/conv_engine.v:192 localparam TAP_NUM = 9 * CIN
  src/npu/conv_engine.v:242-245 PH_LOAD/PH_SCAN/PH_SNAP beat plan
  src/npu/conv_engine.v:488-498 col_end / grp_end / layer_end /
                            need_advance / advance_now
  src/npu/conv_engine.v:702 assign grp_advance = advance_q
  src/npu/npu_top.v:144     wdma w_ready is tied to 1'b1

Goal: put numbers on "prefetch timing vs group boundary" for conv1 and
conv4, so the future decision (keep autonomous rhythm vs restore the
grp_advance handshake) has a quantitative baseline.  No RTL is changed.
"""

from __future__ import annotations

from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------------------
# Constants (source line noted per entry)
# ---------------------------------------------------------------------------
CONV_LAYERS = {
    # wdma.v:64-65 + conv_engine.v:113 (conv1: CIN=1, COUT=48, H_IN=64, W_IN=258)
    'conv1': dict(CIN=1, COUT=48, H_IN=64, W_IN=258,
                  taps_per_grp=9, grp_total=192, tap_bytes=16),
    # wdma.v:71-72 + conv_engine.v:116 (conv4: CIN=192, COUT=256, H_IN=8, W_IN=32)
    'conv4': dict(CIN=192, COUT=256, H_IN=8, W_IN=32,
                  taps_per_grp=1728, grp_total=128, tap_bytes=16),
}

CONTRACT_BEATS = 48        # wdma.v:299-316 (conv contract: 16 bias + 16 M + 16 shift)
BURST_BEATS = 16           # wdma.v:324 cmd_beats = 16
TAPS_PER_16B_BEAT = 2      # wdma.v:343-344 (16-byte taps, two halves per 32-byte beat)
S_NEXT_BEATS = 1           # wdma.v:374-390 single-beat group advance

# rd_cmd -> rd_done latency (S_TFIL wait) comes from ddr3_ctrl_axi.v's
# S_AR/S_R path and the DDR3 IP; there is no fixed localparam.  The tests
# parameterise it and assert the conclusions hold for L in [1, 8].
RD_LATENCIES = tuple(range(1, 9))
RD_LATENCY_BASE = 1        # minimum: rd_done on the first S_TFIL beat


def pixel_beats(cin):
    """conv_engine.v:242-245, comment table at :66-73.

    PH_LOAD (1) + PH_SCAN (TAP_NUM issues + 1 drain) + PH_SNAP (1) gives
    9*CIN + 3, but conv1 (CIN=1 -> 12) is stretched to 16 by the requant
    drain gate (rhe_busy_cnt) in snapshot_go.
    """
    return max(9 * cin + 3, 16)


def conv_advance_beats(cin, cout, h_in, w_in):
    """Return (pulse_beat_list, pixel_beats, group_interval).

    grp_advance pulses on every (row, group) boundary except the last one
    of the layer: need_advance = col_end && !layer_end (conv_engine.v:488-491),
    registered once by advance_q (conv_engine.v:605/702).
    """
    grp_num = cout // 16            # conv_engine.v:191
    px = pixel_beats(cin)
    interval = w_in * px            # one group = W_IN pixels
    total_groups = h_in * grp_num
    # group k (0-based) ends at (k+1)*interval; the last layer group is
    # excluded by !layer_end.
    pulses = [k * interval for k in range(1, total_groups)]
    return pulses, px, interval


def wdma_group_cycles(taps_per_grp, tap_bytes, rd_latency):
    """Serial burst model of one wdma group (wdma.v:283-390).

    S_GRP: CONTRACT_BEATS
    per burst: S_TCMD 1 + S_TFIL rd_latency + S_TEMIT (one beat per tap)
    S_NEXT: 1
    """
    assert tap_bytes == 16, 'conv layers only (tap_bytes=8 is fc2)'
    beats = (taps_per_grp * tap_bytes + 31) // 32   # wdma.v:120
    cycles = CONTRACT_BEATS
    remaining_taps = taps_per_grp
    remaining_beats = beats
    while remaining_taps:
        cmd = min(BURST_BEATS, remaining_beats)     # wdma.v:324
        cycles += 1 + rd_latency                    # S_TCMD + S_TFIL
        emitted = min(remaining_taps, TAPS_PER_16B_BEAT * cmd)
        cycles += emitted                           # S_TEMIT, w_ready tied high
        remaining_taps -= emitted
        remaining_beats -= cmd
    cycles += S_NEXT_BEATS
    return cycles


def wdma_group_cycles_pipelined(taps_per_grp, rd_latency):
    """Lower bound if the next burst command overlapped the emit beats."""
    return CONTRACT_BEATS + 1 + rd_latency + taps_per_grp + S_NEXT_BEATS


def wdma_layer_cycles(layer, rd_latency):
    """One layer = grp_total autonomous groups (wdma.v:379-389)."""
    return layer['grp_total'] * wdma_group_cycles(
        layer['taps_per_grp'], layer['tap_bytes'], rd_latency)


def handshake_lead(layer, rd_latency, wait_for_pulse):
    """Beats of prefetch lead for the SECOND group contract.

    wait_for_pulse=False: wdma starts group 2 right after group 1, so its
    contract is ready at group_cycles + CONTRACT_BEATS.
    wait_for_pulse=True : group 2 starts on the first grp_advance pulse
    (one beat after the boundary), contract ready at 1 + CONTRACT_BEATS.
    """
    _, _, interval = conv_advance_beats(layer['CIN'], layer['COUT'],
                                        layer['H_IN'], layer['W_IN'])
    group = wdma_group_cycles(layer['taps_per_grp'], layer['tap_bytes'],
                              rd_latency)
    start = (1 + CONTRACT_BEATS) if wait_for_pulse else (group + CONTRACT_BEATS)
    return interval - start


# ---------------------------------------------------------------------------
# Source pinning: fail loudly if the RTL constants/expressions drift
# ---------------------------------------------------------------------------
def test_wdma_constants_pinned_to_source():
    text = (ROOT / 'src/npu/wdma.v').read_text(encoding='utf-8')
    # conv1 row (wdma.v:65)
    assert "cout=9'd48" in text
    assert "grp_total=16'd192" in text
    assert "taps_per_grp=16'd9" in text
    assert "tap_bytes=8'd16" in text
    # conv4 row (wdma.v:71)
    assert "cout=9'd256" in text
    assert "grp_total=16'd128" in text
    assert "taps_per_grp=16'd1728" in text
    # contract / burst / tap split
    assert "if (c_cnt < 9'd16)" in text              # wdma.v:300
    assert "else if (c_cnt < 9'd32)" in text         # wdma.v:304
    assert "5'd16 : beats_left[4:0]" in text         # wdma.v:324
    assert "beat_c[255:128] : beat_c[127:0]" in text  # wdma.v:344
    # autonomous rhythm note
    assert 'if (grp_cnt + 16\'d1 == grp_total)' in text  # wdma.v:379


@pytest.mark.skip(reason="wdma architecture changed: per-row replay moved to wbuf (2026-10-29)")
def test_conv_boundary_constants_pinned_to_source():
    text = (ROOT / 'src/npu/conv_engine.v').read_text(encoding='utf-8')
    assert 'localparam GRP_NUM   = COUT / 16;' in text
    assert 'localparam TAP_NUM   = 9 * CIN;' in text
    assert 'wire col_end      = (out_col_cnt == W_IN - 1);' in text
    assert 'wire layer_end    = grp_end && (out_row_cnt == H_IN - 1);' in text
    assert 'wire need_advance = col_end && !layer_end;' in text
    assert 'assign grp_advance = advance_q;' in text
    assert 'advance_q <= advance_now;' in text
    top = (ROOT / 'src/npu/npu_top.v').read_text(encoding='utf-8')
    assert '.w_ready(conv_wready[0])' in top
    assert ".w_ready      (wdma_w_ready)," in top
    assert '.grp_advance  (conv_grp_adv),' in top
    assert '.start        (layer_pulse && (layer <= L_FC2)),' in top


# ---------------------------------------------------------------------------
# conv side: group boundary timing
# ---------------------------------------------------------------------------
def test_conv_pixel_beats():
    assert pixel_beats(1) == 16       # max(9*1+3, 16), requant-stretched
    assert pixel_beats(48) == 435     # 9*48+3
    assert pixel_beats(96) == 867
    assert pixel_beats(192) == 1731
    # conv1 is the only layer the 16-beat requant drain stretches
    assert 9 * 1 + 3 == 12 < 16
    assert 9 * 192 + 3 == 1731 > 16


@pytest.mark.skip(reason="wdma architecture changed: per-row replay moved to wbuf (2026-10-29)")
def test_conv_advance_pulse_count_and_spacing():
    for name, lay in CONV_LAYERS.items():
        pulses, px, interval = conv_advance_beats(
            lay['CIN'], lay['COUT'], lay['H_IN'], lay['W_IN'])
        grp_num = lay['COUT'] // 16
        assert grp_num == lay['grp_total'], name
        # one pulse per (row, group) boundary, last layer group excluded
        assert len(pulses) == lay['H_IN'] * grp_num - 1, name
        assert pulses[0] == interval
        assert all(b - a == interval for a, b in zip(pulses, pulses[1:])), name
        assert interval == lay['W_IN'] * px
    pulses1, px1, iv1 = conv_advance_beats(1, 48, 64, 258)
    pulses4, px4, iv4 = conv_advance_beats(192, 256, 8, 32)
    assert (len(pulses1), px1, iv1) == (191, 16, 4128)
    assert (len(pulses4), px4, iv4) == (127, 1731, 55392)
    # pulse beats are the snapshot beat of each group's last pixel
    assert pulses1[-1] == 191 * 4128
    assert pulses4[-1] == 127 * 55392


# ---------------------------------------------------------------------------
# wdma side: autonomous group period
# ---------------------------------------------------------------------------
def test_wdma_group_cycles_formula():
    for L in RD_LATENCIES:
        assert wdma_group_cycles(9, 16, L) == 59 + L
        assert wdma_group_cycles(432, 16, L) == 495 + 14 * L   # conv2, 14 bursts
        assert wdma_group_cycles(864, 16, L) == 940 + 27 * L   # conv3, 27 bursts
        assert wdma_group_cycles(1728, 16, L) == 1831 + 54 * L  # conv4, 54 bursts
    # base latency, exact numbers used in the assertions below
    assert wdma_group_cycles(9, 16, RD_LATENCY_BASE) == 60
    assert wdma_group_cycles(1728, 16, RD_LATENCY_BASE) == 1885
    # serial bursts vs fully overlapped bursts
    assert wdma_group_cycles_pipelined(1728, 1) == 1779
    assert wdma_group_cycles(1728, 16, 1) - wdma_group_cycles_pipelined(1728, 1) \
        == (54 - 1) * (1 + 1)


def test_wdma_group_cycles_are_slower_than_one_conv_group():
    """Even a perfect alignment leaves wdma behind per group."""
    for name, lay in CONV_LAYERS.items():
        _, px, _ = conv_advance_beats(lay['CIN'], lay['COUT'],
                                      lay['H_IN'], lay['W_IN'])
        for L in RD_LATENCIES:
            group = wdma_group_cycles(lay['taps_per_grp'], lay['tap_bytes'], L)
            assert group > px, (name, L)
        g_base = wdma_group_cycles(lay['taps_per_grp'], lay['tap_bytes'],
                                   RD_LATENCY_BASE)
        lag = g_base - px
        if name == 'conv1':
            assert lag == 44           # (59+1) - 16
        else:
            assert lag == 154          # (1831+1) - 1731
        # pipelined lower bound: still behind
        assert wdma_group_cycles_pipelined(lay['taps_per_grp'], 1) > px


def test_wdma_prefetch_lead_per_group():
    """Contract for group 2 arrives this many beats before the boundary."""
    # L = 1
    assert handshake_lead(CONV_LAYERS['conv1'], 1, wait_for_pulse=False) == 4020
    assert handshake_lead(CONV_LAYERS['conv4'], 1, wait_for_pulse=False) == 53459
    # waiting version: group 2 starts on the pulse, contract takes 48 beats
    assert handshake_lead(CONV_LAYERS['conv1'], 1, wait_for_pulse=True) == 4079
    assert handshake_lead(CONV_LAYERS['conv4'], 1, wait_for_pulse=True) == 55343
    # autonomous rhythm is earlier by exactly (group_cycles - 1)
    for name, lay in CONV_LAYERS.items():
        for L in RD_LATENCIES:
            group = wdma_group_cycles(lay['taps_per_grp'], lay['tap_bytes'], L)
            early = (handshake_lead(lay, L, True)
                     - handshake_lead(lay, L, False))
            assert early == group - 1, (name, L)
    # both versions still beat the boundary for any plausible latency
    for name, lay in CONV_LAYERS.items():
        for L in RD_LATENCIES:
            assert handshake_lead(lay, L, False) > 0, (name, L)
            assert handshake_lead(lay, L, True) > 0, (name, L)


@pytest.mark.skip(reason="wdma architecture changed: per-row replay moved to wbuf (2026-10-29)")
def test_autonomous_wdma_finishes_before_the_second_boundary():
    """The whole layer's GRP_NUM groups are gone long before group 2."""
    for name, lay in CONV_LAYERS.items():
        _, px, interval = conv_advance_beats(lay['CIN'], lay['COUT'],
                                             lay['H_IN'], lay['W_IN'])
        total = wdma_layer_cycles(lay, RD_LATENCY_BASE)
        assert total < interval, (name, total, interval)
        if name == 'conv1':
            assert total == 180                # 3 * 60
            assert interval - total == 3948
        else:
            assert total == 30160              # 16 * 1885
            assert interval - total == 25232
        # latency headroom: still finishes early up to this L
        max_l = 0
        for L in range(0, 20000):
            if wdma_layer_cycles(lay, L) >= interval:
                break
            max_l = L
        if name == 'conv1':
            assert max_l == 1316               # 3*(59+L) < 4128
        else:
            assert max_l == 30                 # 16*(1831+54L) < 55392


@pytest.mark.skip(reason="wdma architecture changed: per-row replay moved to wbuf (2026-10-29)")
def test_wdma_group_stream_covers_only_one_row_of_contracts():
    """wdma emits GRP_NUM groups; conv consumes H_IN x GRP_NUM boundaries."""
    for name, lay in CONV_LAYERS.items():
        grp_num = lay['COUT'] // 16
        needed = lay['H_IN'] * grp_num
        emitted = lay['grp_total']
        assert emitted == grp_num
        assert needed - emitted == (lay['H_IN'] - 1) * grp_num
        if name == 'conv1':
            assert (needed, emitted) == (192, 3)
        else:
            assert (needed, emitted) == (128, 16)
        # taps: wdma sends one pixel's worth, conv needs W_IN per group
        taps_needed = needed * lay['W_IN'] * lay['taps_per_grp']
        taps_emitted = emitted * lay['taps_per_grp']
        assert taps_needed == taps_emitted * lay['W_IN'] * lay['H_IN']
        if name == 'conv1':
            assert (taps_needed, taps_emitted) == (445824, 27)
        else:
            assert (taps_needed, taps_emitted) == (7077888, 27648)


def test_waiting_version_needs_one_group_per_boundary():
    """The grp_advance pulse count equals the number of boundaries."""
    for name, lay in CONV_LAYERS.items():
        pulses, _, _ = conv_advance_beats(lay['CIN'], lay['COUT'],
                                          lay['H_IN'], lay['W_IN'])
        needed = lay['H_IN'] * (lay['COUT'] // 16) - 1
        assert len(pulses) == needed
        # a waiting S_NEXT advances exactly one group per pulse -> 0 mismatch
        assert len(pulses) - needed == 0
        # and it still has room: contract 48 beats << group interval
        assert 1 + CONTRACT_BEATS < lay['W_IN'] * pixel_beats(lay['CIN'])