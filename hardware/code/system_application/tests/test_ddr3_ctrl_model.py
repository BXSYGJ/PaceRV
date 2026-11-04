"""Executable specification tests for the DDR3 AXI front end (S1..S7).

One test (or one small test group) per acceptance item of the plan file
`.codeartsdoer/plans/ddr3-unblock-and-parallel-board/plan.md`,
section 3.1 T1, items 1..10. All vectors are deterministic; no RTL build,
no board access and no external toolchain is involved.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ddr3_ctrl_model as dm

# rd_ready masks
FAST = (1, 1, 1, 1)     # every master drains immediately
SLOW = (0, 0, 0, 0)     # nobody drains: the fifo fills up

WR_ADDR = 0x300000      # self-test window, 32-byte aligned
RD_ADDR = 0x300000      # same window for the read vectors
WG_ADDR = 0x100000      # weight mirror
SPEC_ADDR = 0x200000    # spectrum export
PCM_ADDR = 0x000000     # PCM left


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

def beat_payload(master, beat):
    """Deterministic 256-bit write beat: 8 words carry master/beat/lane."""
    value = 0
    for lane in range(8):
        word = (((master + 1) & 0xFF) << 24) | ((beat & 0xFF) << 8) | lane
        value |= word << (32 * lane)
    return value


def split_words(value):
    return [(value >> (32 * lane)) & 0xFFFFFFFF for lane in range(8)]


def _run_write_commands(model, ip, master, addrs, length=dm.BURST_LEN,
                        max_cycles=4000):
    """Hold cmd_valid per write command, advancing wdata on every beat.

    Returns one record per completed command: the accepted beat cycles and
    the CycleOutput of the done pulse.
    """
    cmds = [0, 0, 0, 0]
    cmds[master] = dm.pack_cmd(1, addrs[0], length)
    valid = [0, 0, 0, 0]
    valid[master] = 1
    issued = 1
    beat = 0
    records = []
    current = None
    for _ in range(max_cycles):
        payload = [0, 0, 0, 0]
        if valid[master]:
            payload[master] = beat_payload(master, beat)
        out = model.cycle(valid, cmds, payload, FAST, ip)
        if out.wready_beat:
            assert out.wready_beat == 1 << master
            if current is None:
                current = {'beat_cycles': [], 'done': None}
            current['beat_cycles'].append(out.cycle)
            beat += 1
        if out.done:
            assert current is not None, 'done without a preceding beat'
            current['done'] = out
            records.append(current)
            current = None
            beat = 0
            if issued < len(addrs):
                cmds[master] = dm.pack_cmd(1, addrs[issued], length)
                issued += 1
            else:
                valid[master] = 0
            if len(records) == len(addrs):
                break
    assert len(records) == len(addrs), 'write commands did not complete'
    return records


def _run_single_read(model, ip, master=2, addr=RD_ADDR,
                     length=dm.BURST_LEN, rd_ready=FAST, max_cycles=400):
    """Hold one read command until its done pulse; returns its CycleOutput."""
    cmds = [0, 0, 0, 0]
    cmds[master] = dm.pack_cmd(0, addr, length)
    valid = [0, 0, 0, 0]
    valid[master] = 1
    done_out = None
    trace = []
    for _ in range(max_cycles):
        out = model.cycle(valid, cmds, (0, 0, 0, 0), rd_ready, ip)
        trace.append(out)
        if out.done:
            done_out = out
            break
    assert done_out is not None, 'read command never completed'
    return done_out, trace


def _fill_fifo(model, ip, master=2, length=3):
    """Complete a short read burst with no drain, leaving the fifo non-empty."""
    _run_single_read(model, ip, master=master, length=length, rd_ready=SLOW)
    assert model.rd_fifo_count == length + 1, (
        f'fifo expected {length + 1} beats, got {model.rd_fifo_count}')


def _run_watchdog_vector(wr, never, expected_phase, master=3,
                         limit=dm.AXI_TO_LIMIT):
    """Stall one handshake phase and check the 4096-cycle abort contract."""
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0, never=never)
    cmds = [0, 0, 0, 0]
    cmds[master] = dm.pack_cmd(wr, WR_ADDR, dm.BURST_LEN)
    valid = [0, 0, 0, 0]
    valid[master] = 1
    done_out = None
    for _ in range(limit + 64):
        out = model.cycle(valid, cmds, (0, 0, 0, 0), FAST, ip)
        if out.done:
            done_out = out
            break
    assert done_out is not None, (
        f'{dm.STATE_NAME[expected_phase]} never timed out')
    # The pulse is issued on the edge after 4096 stalled cycles, so the
    # post-edge counter reads limit + 1 (the abort branch does not clear it;
    # the IDLE branch does on the next cycle).
    assert done_out.axi_to_cnt - 1 == limit
    assert done_out.done == 1 << master
    assert done_out.write_cmpl is False and done_out.read_cmpl is False
    assert done_out.to_abort is True
    assert done_out.to_err == 1
    assert done_out.cmd_to_err[master] == 1
    assert done_out.dbg_to_state == expected_phase
    expected_state = dm.S_R_DRAIN if expected_phase == dm.S_R else dm.S_IDLE
    assert done_out.state == expected_state
    # single-cycle pulse: drop the request and confirm no repeat
    valid[master] = 0
    for _ in range(6):
        out = model.cycle(valid, cmds, (0, 0, 0, 0), FAST, ip)
        assert out.done == 0
        expected_idle_or_drain = (dm.S_R_DRAIN if expected_phase == dm.S_R
                                  else dm.S_IDLE)
        assert out.state == expected_idle_or_drain
    assert model.to_err == 1 and model.dbg_to_state == expected_phase
    return model, done_out


# --------------------------------------------------------------------------- #
# Acceptance item 1 (S1): write done is the same cycle as the last beat
# --------------------------------------------------------------------------- #

def test_s1_write_done_pulse_is_combinational_with_the_last_beat():
    addrs = [WR_ADDR + 512 * i for i in range(8)]
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, wusero_last_delay=1)
    records = _run_write_commands(model, ip, 0, addrs)

    for index, record in enumerate(records):
        beats = record['beat_cycles']
        done = record['done']
        assert len(beats) == dm.BURST_LEN + 1
        assert done.write_cmpl is True            # S1 completion predicate
        assert done.wready_beat == 1 << 0         # same-cycle 16th beat
        assert done.done == 1 << 0
        assert done.cycle == beats[-1]            # not a registered pulse
        assert done.state == dm.S_WLAST           # epilogue starts after the edge
        if index + 1 < len(records):
            first_next = records[index + 1]['beat_cycles'][0]
            assert first_next > done.cycle + 1, (
                'a beat was accepted the cycle right after done; the pulse '
                'must already belong to the last beat of the previous burst')
    assert len(model.done_log) == 8
    assert model.to_err == 0
    assert model.wlast_miss_cnt == 0      # wusero_last seen inside the window


# --------------------------------------------------------------------------- #
# Acceptance item 2 (S2): beat sequence 0..15 and incrementing wdata
# --------------------------------------------------------------------------- #

def test_s2_write_beats_advance_0_to_15_with_incrementing_wdata():
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0)
    _run_write_commands(model, ip, 0, [WR_ADDR])

    beats = model.w_beats
    assert len(beats) == dm.BURST_LEN + 1
    for index, (cycle, addr, data, wstrb, dummy, master) in enumerate(beats):
        assert master == 0
        assert addr == WR_ADDR
        assert dummy is False
        assert wstrb == 0xFFFFFFFF               # real writes use full strobes
        assert data == beat_payload(0, index)
        assert split_words(data) == [
            ((1 << 24) | (index << 8) | lane) for lane in range(8)]

    cycles = [beat[0] for beat in beats]
    assert cycles == sorted(cycles)
    assert len(set(cycles)) == dm.BURST_LEN + 1  # strictly one beat per cycle
    for lane in range(8):
        column = [split_words(beat[2])[lane] for beat in beats]
        assert column == sorted(column)          # each 32-bit word increments
        assert column[0] != column[-1]


# --------------------------------------------------------------------------- #
# Acceptance item 3 (S3): 4096-cycle watchdog in all six phases
# --------------------------------------------------------------------------- #

def test_s3_aw_phase_watchdog_aborts_after_4096_stalled_cycles():
    _, done = _run_watchdog_vector(wr=1, never=('aw',),
                                       expected_phase=dm.S_AW)
    assert done.axi_awvalid is True


def test_s3_w_phase_watchdog_aborts_after_4096_stalled_cycles():
    _, done = _run_watchdog_vector(wr=1, never=('w',),
                                       expected_phase=dm.S_W)
    assert done.wready_beat == 0


def test_s3_dw_aw_phase_watchdog_aborts_after_4096_stalled_cycles():
    _, done = _run_watchdog_vector(wr=0, never=('aw',),
                                       expected_phase=dm.S_DW_AW)
    assert done.axi_awvalid is True and done.axi_awlen == 0


def test_s3_dw_w_phase_watchdog_aborts_after_4096_stalled_cycles():
    _, done = _run_watchdog_vector(wr=0, never=('w',),
                                       expected_phase=dm.S_DW_W)
    assert done.axi_wdata == 0


def test_s3_ar_phase_watchdog_aborts_after_4096_stalled_cycles():
    _, done = _run_watchdog_vector(wr=0, never=('ar',),
                                       expected_phase=dm.S_AR)
    assert done.axi_arvalid is True


def test_s3_r_phase_watchdog_aborts_after_4096_stalled_cycles():
    _, done = _run_watchdog_vector(wr=0, never=('r',),
                                       expected_phase=dm.S_R)
    assert done.rd_valid == 0


def test_read_timeout_quarantines_late_rlast_before_accepting_next_read():
    model = dm.Ddr3CtrlAxiModel(axi_to_limit=3)

    class LateResponseIp:
        def signals(self, current):
            st = current.state
            if st in (dm.S_AW, dm.S_DW_AW):
                return dm.IpSignals(awready=1)
            if st in (dm.S_W, dm.S_DW_W):
                return dm.IpSignals(wready=1)
            if st == dm.S_AR:
                return dm.IpSignals(arready=1)
            if st == dm.S_R and len(current.ar_handshakes) == 2:
                return dm.IpSignals(rvalid=1, rdata=0x2222, rlast=1)
            return dm.IpSignals()

    ip = LateResponseIp()
    first_cmds = [0, 0, dm.pack_cmd(0, RD_ADDR, 0), 0]
    first_valid = [0, 0, 1, 0]
    timeout = None
    for _ in range(32):
        out = model.cycle(first_valid, first_cmds, (0, 0, 0, 0), SLOW, ip)
        if out.to_abort:
            timeout = out
            break
    assert timeout is not None
    assert timeout.state == dm.S_R_DRAIN
    assert timeout.to_err == 1 and timeout.dbg_to_state == dm.S_R
    assert len(model.ar_handshakes) == 1

    # Keep a competing read queued while the first transaction's late RLAST
    # arrives. The late data must be discarded, and that cycle cannot grant.
    next_cmds = [dm.pack_cmd(0, WG_ADDR, 0), 0, 0, 0]
    next_valid = [1, 0, 0, 0]
    drain = model.cycle(next_valid, next_cmds, (0, 0, 0, 0), SLOW,
                        lambda _m: dm.IpSignals(rvalid=1,
                                                rdata=0xDEADBEEF,
                                                rlast=1))
    assert drain.state_before == dm.S_R_DRAIN
    assert drain.state == dm.S_IDLE
    assert drain.grant == 0 and drain.done == 0
    assert model.rd_fifo_count == 0
    assert model.r_beats == []

    # The next cycle may grant the queued read; its own terminal response is
    # then captured as the only beat of that transaction.
    grant = model.cycle(next_valid, next_cmds, (0, 0, 0, 0), SLOW, ip)
    assert grant.state == dm.S_DW_AW and grant.grant == 1
    for _ in range(12):
        out = model.cycle(next_valid, next_cmds, (0, 0, 0, 0), SLOW, ip)
        if out.done:
            break
    assert out.read_cmpl is True
    assert model.r_beats[-1][1] == 0x2222


def test_init_gate_masks_stale_r_before_init_then_allows_normal_read():
    model = dm.Ddr3CtrlAxiModel(axi_to_limit=32)

    class InitGatedIp:
        init_done = False

        def signals(self, current):
            if not self.init_done:
                return dm.IpSignals(rvalid=1, rdata=0xDEADBEEF, rlast=1)
            if current.state in (dm.S_AW, dm.S_DW_AW):
                return dm.IpSignals(awready=1)
            if current.state in (dm.S_W, dm.S_DW_W):
                return dm.IpSignals(wready=1)
            if current.state == dm.S_AR:
                return dm.IpSignals(arready=1)
            if current.state == dm.S_R:
                return dm.IpSignals(rvalid=1, rdata=0x12345678, rlast=1)
            return dm.IpSignals()

    ip = InitGatedIp()
    source_valid = [0, 1, 0, 0]
    command = [0, dm.pack_cmd(0, WG_ADDR, 0), 0, 0]
    for _ in range(3):
        valid = source_valid if ip.init_done else (0, 0, 0, 0)
        out = model.cycle(valid, command, (0, 0, 0, 0), SLOW, ip)
        assert out.state == dm.S_IDLE and out.grant == 0 and out.done == 0
        assert model.rd_fifo_count == 0 and model.r_beats == []

    ip.init_done = True
    completed = None
    for _ in range(16):
        out = model.cycle(source_valid, command, (0, 0, 0, 0), SLOW, ip)
        if out.done:
            completed = out
            break
    assert completed is not None and completed.read_cmpl
    assert model.r_beats[-1][1] == 0x12345678
    assert model.rd_fifo_count == 1


def test_s3_rvalid_stream_without_rlast_is_not_guarded_by_the_watchdog():
    """Documented contract fact (not a model deviation): the watchdog only
    accumulates while `S_R && !rvalid` (ddr3_ctrl_axi.v:317-323), so a
    rvalid stream that never asserts rlast latches the FSM in S_R forever.
    Recorded here because T2 must not rely on `done` for that case.
    """
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0,
                    r_start_latency=1, rlast_enable=False)
    cmds = [0, 0, dm.pack_cmd(0, RD_ADDR, dm.BURST_LEN), 0]
    valid = [0, 0, 1, 0]
    for _ in range(dm.AXI_TO_LIMIT + 64):
        out = model.cycle(valid, cmds, (0, 0, 0, 0), FAST, ip)
        assert out.done == 0
    assert model.to_err == 0
    assert model.state == dm.S_R
    assert model.axi_to_cnt == 0          # reset every cycle by rvalid


# --------------------------------------------------------------------------- #
# Acceptance item 4 (S4): read done coincides with rlast
# --------------------------------------------------------------------------- #

def test_s4_read_done_pulse_coincides_with_rlast():
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0,
                    r_start_latency=1)
    done, trace = _run_single_read(model, ip)

    assert done.read_cmpl is True
    assert done.write_cmpl is False and done.to_abort is False
    assert done.done == 1 << 2
    assert done.state == dm.S_IDLE
    assert len(model.r_beats) == dm.BURST_LEN + 1
    last_cycle, last_data, last_rlast = model.r_beats[-1]
    assert last_rlast is True
    assert last_cycle == done.cycle
    # the pulse is single-cycle
    out = model.cycle([0, 0, 0, 0], [0, 0, 0, 0], (0, 0, 0, 0), FAST, ip)
    assert out.done == 0 and out.read_cmpl is False


# --------------------------------------------------------------------------- #
# Acceptance item 5 (S5): rlast cycle rd_valid is 0, next cycle it is 1
# --------------------------------------------------------------------------- #

def test_s5_rlast_beat_becomes_readable_one_cycle_later_when_fifo_was_empty():
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0,
                    r_start_latency=1, rvalid_every=2)
    done, trace = _run_single_read(model, ip)
    trace.append(model.cycle([0, 0, 0, 0], [0, 0, 0, 0], (0, 0, 0, 0),
                             FAST, ip))
    by_cycle = {out.cycle: out for out in trace}

    last_cycle, last_data, last_rlast = model.r_beats[-1]
    assert last_rlast is True
    assert last_cycle == done.cycle

    rlast_out = by_cycle[last_cycle]
    # the push of the rlast beat does not update the count in time
    assert rlast_out.rd_valid == 0
    assert rlast_out.rd_fifo_count == 1
    assert by_cycle[last_cycle - 1].rd_fifo_count == 0   # fifo was empty

    next_out = by_cycle[last_cycle + 1]
    assert next_out.rd_valid == 1 << 2                   # S5 late visibility
    assert next_out.rd_data == last_data
    assert next_out.rd_fifo_count == 0                   # drained immediately
    assert model.rd_fifo_count == 0


# --------------------------------------------------------------------------- #
# Acceptance item 6 (S6): single-cycle cmd_valid is safe for writes only
# --------------------------------------------------------------------------- #

def test_s6_single_cycle_write_cmd_is_latched_while_fifo_is_empty():
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0)
    cmds = [0, 0, 0, 0]
    cmds[1] = dm.pack_cmd(1, WR_ADDR, dm.BURST_LEN)

    out = model.cycle([0, 1, 0, 0], cmds, (0, 0, 0, 0), FAST, ip)
    assert out.arb_en is True
    assert out.grant == 1 << 1 and out.grant_wr is True
    assert out.state == dm.S_AW and out.cur_master == 1
    assert out.cur_wr == 1 and out.cur_addr == WR_ADDR
    assert out.cur_len == dm.BURST_LEN

    # the one-cycle strobe is gone, yet the command stays latched
    out = model.cycle([0, 0, 0, 0], cmds, (0, 0, 0, 0), FAST, ip)
    assert out.state == dm.S_W and out.cur_master == 1
    assert len(model.aw_handshakes) == 1


def test_s6_single_cycle_write_cmd_is_latched_even_when_fifo_is_not_empty():
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=1, w_latency=0, ar_latency=0)
    _fill_fifo(model, ip)
    assert model.rd_fifo_count == 4

    cmds = [0, 0, 0, 0]
    cmds[0] = dm.pack_cmd(1, PCM_ADDR, dm.BURST_LEN)
    out = model.cycle([1, 0, 0, 0], cmds, (0, 0, 0, 0), SLOW, ip)
    # fifo_empty never gates the write path (ddr3_ctrl_axi.v:179)
    assert out.arb_en is True and out.grant == 1 << 0
    assert out.state == dm.S_AW and out.cur_master == 0
    assert model.rd_fifo_count == 4


def test_s6_single_cycle_read_cmd_is_dropped_when_fifo_is_not_empty():
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0)
    _fill_fifo(model, ip)
    aw_before = len(model.aw_handshakes)
    ar_before = len(model.ar_handshakes)

    cmds = [0, 0, 0, 0]
    cmds[1] = dm.pack_cmd(0, WG_ADDR, dm.BURST_LEN)
    out = model.cycle([0, 1, 0, 0], cmds, (0, 0, 0, 0), SLOW, ip)

    assert out.arb_en is False            # read grant needs an empty fifo
    assert out.grant == 0
    assert out.state == dm.S_IDLE
    assert out.cur_master == 2             # still the old (fill) owner
    assert out.cur_rd_master == 2
    assert len(model.aw_handshakes) == aw_before
    assert len(model.ar_handshakes) == ar_before

    # the single-cycle request is gone: nothing happens on the next cycle
    out = model.cycle([0, 0, 0, 0], cmds, (0, 0, 0, 0), SLOW, ip)
    assert out.state == dm.S_IDLE and out.grant == 0


def test_s6_read_cmd_held_until_done_is_accepted_after_the_fifo_drains():
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0)
    _fill_fifo(model, ip)
    aw_before = len(model.aw_handshakes)

    cmds = [0, 0, 0, 0]
    cmds[1] = dm.pack_cmd(0, WG_ADDR, dm.BURST_LEN)
    valid = [0, 1, 0, 0]
    accepted = None
    for _ in range(40):
        drain = [0, 0, 1, 0] if model.rd_fifo_count else SLOW
        out = model.cycle(valid, cmds, (0, 0, 0, 0), drain, ip)
        if out.state_before == dm.S_IDLE and out.grant:
            accepted = out
            break
    assert accepted is not None, 'held read command was never accepted'
    assert accepted.grant == 1 << 1
    assert accepted.state == dm.S_DW_AW
    assert accepted.cur_master == 1
    assert accepted.cur_rd_master == 1     # S7: changes on the read grant
    out = model.cycle(valid, cmds, (0, 0, 0, 0), SLOW, ip)
    assert out.state_before == dm.S_DW_AW
    assert len(model.aw_handshakes) == aw_before + 1   # dummy write issued


def test_s6_single_cycle_write_is_lost_when_a_read_grant_blocks_arb_en():
    """S6 wording refinement: `arb_en` is derived from the SELECTED request,
    so a single-cycle write sharing the cycle with a higher-priority read
    request (fifo non-empty) is dropped too. Upstream must hold cmd_valid.
    """
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0)
    _fill_fifo(model, ip)

    cmds = [0, 0, 0, 0]
    cmds[1] = dm.pack_cmd(0, WG_ADDR, dm.BURST_LEN)      # P1 read, wins
    cmds[3] = dm.pack_cmd(1, PCM_ADDR, dm.BURST_LEN)     # P3 write, loses
    out = model.cycle([0, 1, 0, 1], cmds, (0, 0, 0, 0), SLOW, ip)
    assert out.arb_en is False            # sel = read, fifo non-empty
    assert out.grant == 0
    assert out.state == dm.S_IDLE and out.cur_master == 2
    assert out.wait_cnt[3] == 1           # the write request did queue up
    assert len(model.aw_handshakes) == 1  # only the fill dummy write


# --------------------------------------------------------------------------- #
# Acceptance item 7 (S7): leftover fifo beats keep the old read owner
# --------------------------------------------------------------------------- #

def test_s7_read_abort_keeps_leftover_beats_routed_to_the_old_read_master():
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0,
                    r_start_latency=1, r_valid_budget=4)
    done, _trace = _run_single_read(model, ip, master=2, rd_ready=SLOW,
                                    max_cycles=dm.AXI_TO_LIMIT + 64)

    assert done.done == 1 << 2
    assert done.to_abort is True and done.to_err == 1
    assert done.cmd_to_err[2] == 1
    assert done.dbg_to_state == dm.S_R
    assert done.state == dm.S_R_DRAIN
    assert done.rd_fifo_count == 4        # beats captured before the stall
    assert done.rd_valid == 1 << 2        # still routed to the old owner
    assert done.cur_rd_master == 2

    # A late terminal response is quarantined and discarded before the
    # arbiter can accept another read.
    late = model.cycle([0, 0, 0, 0], [0, 0, 0, 0], (0, 0, 0, 0),
                        SLOW,
                        lambda _model: dm.IpSignals(rvalid=1,
                                                    rdata=0xDEADBEEF,
                                                    rlast=1))
    assert late.state == dm.S_IDLE
    assert late.done == 0
    assert model.rd_fifo_count == 4

    # a competing read request cannot steal the fifo while it is non-empty
    cmds = [0, dm.pack_cmd(0, WG_ADDR, dm.BURST_LEN), 0, 0]
    out = model.cycle([0, 1, 0, 0], cmds, (0, 0, 0, 0), SLOW, ip)
    assert out.arb_en is False and out.state == dm.S_IDLE
    assert out.cur_rd_master == 2

    # draining keeps the old routing and pops the beats in fifo order; the
    # held read request is only granted once the fifo is empty (S6/S7)
    drained = []
    accepted = None
    for _ in range(12):
        out = model.cycle([0, 1, 0, 0], cmds, (0, 0, 0, 0), (0, 0, 1, 0), ip)
        if out.rd_valid:
            assert out.rd_valid == 1 << 2
            drained.append(out.rd_data)
        if out.state_before == dm.S_IDLE and out.grant:
            accepted = out
            break
    assert drained == [ip.r_data_base + i for i in range(4)]
    assert accepted is not None and accepted.grant == 1 << 1
    assert accepted.cur_rd_master == 1


# --------------------------------------------------------------------------- #
# Acceptance item 8: dummy write before every read (both strobe policies)
# --------------------------------------------------------------------------- #

def _assert_dummy_write_layout(model, expected_strb):
    assert len(model.aw_handshakes) == 1
    aw_cycle, aw_addr, aw_len, aw_master, aw_ap = model.aw_handshakes[0]
    assert aw_len == 0                    # one beat
    assert aw_addr == RD_ADDR
    assert aw_master == 2
    assert aw_ap == 1                     # AXI_USER_AP default

    assert len(model.w_beats) == 1        # exactly the masked dummy beat
    w_cycle, w_addr, w_data, w_strb, dummy, master = model.w_beats[0]
    assert dummy is True
    assert w_addr == aw_addr              # same address as the read
    assert w_data == 0
    assert w_strb == expected_strb
    assert master == 2

    assert len(model.ar_handshakes) == 1
    ar_cycle, ar_addr, ar_len, ar_master = model.ar_handshakes[0]
    assert ar_addr == aw_addr             # same address as the dummy write
    assert ar_len == dm.BURST_LEN
    assert ar_master == 2
    assert aw_cycle < w_cycle < ar_cycle  # strict ordering


def test_dummy_write_precedes_read_with_masked_strobes():
    model = dm.Ddr3CtrlAxiModel(dummy_wstrb_all1=False)
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0)
    _run_single_read(model, ip)
    _assert_dummy_write_layout(model, dm.DUMMY_WSTRB_MASKED)


def test_dummy_write_precedes_read_with_all_one_strobes():
    model = dm.Ddr3CtrlAxiModel(dummy_wstrb_all1=True)
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0)
    _run_single_read(model, ip)
    _assert_dummy_write_layout(model, dm.DUMMY_WSTRB_ALL1_VALUE)


# --------------------------------------------------------------------------- #
# Acceptance item 9: rd_fifo_count arithmetic and 16-deep capacity
# --------------------------------------------------------------------------- #

def test_rd_fifo_count_is_unchanged_when_push_and_pop_coincide():
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0,
                    r_start_latency=1)
    done, trace = _run_single_read(model, ip, rd_ready=FAST)

    sr_counts = [out.rd_fifo_count for out in trace
                 if out.state_before == dm.S_R]
    assert sr_counts
    assert sr_counts[0] == 0            # S_R entry cycle: no beat yet
    assert all(count == 1 for count in sr_counts[1:]), sr_counts
    assert max(sr_counts) <= dm.RD_FIFO_DEPTH

    # at least one cycle pushed and popped in the same cycle (count held at 1)
    beat_cycles = {cycle for cycle, _data, _last in model.r_beats}
    coincident = 0
    for prev, cur in zip(trace, trace[1:]):
        if (cur.cycle in beat_cycles and prev.rd_fifo_count == 1
                and cur.rd_fifo_count == 1):
            coincident += 1
    assert coincident == dm.BURST_LEN, coincident
    assert done.rd_fifo_count == 1        # one beat still in flight


def test_rd_fifo_holds_full_16_beat_burst_without_overflow():
    model = dm.Ddr3CtrlAxiModel()
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0,
                    r_start_latency=1)
    done, trace = _run_single_read(model, ip, rd_ready=SLOW)

    counts = [out.rd_fifo_count for out in trace]
    assert max(counts) == dm.RD_FIFO_DEPTH   # exactly a full burst, no more
    assert done.rd_fifo_count == dm.RD_FIFO_DEPTH
    assert model.rd_fifo_wr_ptr == 0         # pointer wrapped after 16 pushes

    # the fifo preserves beat order and holds the whole burst
    drained = []
    for _ in range(dm.RD_FIFO_DEPTH + 4):
        out = model.cycle([0, 0, 0, 0], [0, 0, 0, 0], (0, 0, 0, 0),
                          (0, 0, 1, 0), ip)
        if out.rd_valid:
            drained.append(out.rd_data)
    assert drained == [ip.r_data_base + i for i in range(dm.RD_FIFO_DEPTH)]
    assert model.rd_fifo_count == 0
    assert model.rd_fifo_rd_ptr == 0


# --------------------------------------------------------------------------- #
# Acceptance item 10: arbitration priority and the P3 starvation quota
# --------------------------------------------------------------------------- #

def test_arbiter_fixed_priority_grant_order():
    arb = dm.Ddr3ArbiterModel()
    cmds = [dm.pack_cmd(1, PCM_ADDR, dm.BURST_LEN),
            dm.pack_cmd(0, WG_ADDR, dm.BURST_LEN),
            dm.pack_cmd(0, PCM_ADDR, dm.BURST_LEN),
            dm.pack_cmd(0, SPEC_ADDR, dm.BURST_LEN)]
    assert arb.step((1, 1, 1, 1), cmds, True) == 0
    assert arb.step((0, 1, 1, 1), cmds, True) == 1
    assert arb.step((0, 0, 1, 1), cmds, True) == 2
    assert arb.step((0, 0, 0, 1), cmds, True) == 3
    # arb_en gates the grant (ddr3_arbiter.v:112)
    assert arb.step((1, 0, 0, 0), cmds, False) is None
    assert arb.wait_cnt[0] == 1            # request keeps queueing
    assert arb.step((1, 0, 0, 0), cmds, True) == 0
    assert arb.wait_cnt[0] == 0
    assert arb.addr_err == [0, 0, 0, 0]


def test_arbiter_p3_quota_grants_lowest_priority_after_125000_cycles():
    arb = dm.Ddr3ArbiterModel()
    cmds = [dm.pack_cmd(1, PCM_ADDR, dm.BURST_LEN),
            dm.pack_cmd(0, WG_ADDR, dm.BURST_LEN),
            dm.pack_cmd(0, PCM_ADDR, dm.BURST_LEN),
            dm.pack_cmd(0, SPEC_ADDR, dm.BURST_LEN)]
    arb_valid = (1, 1, 1, 1)
    first_p3 = None
    max_wait_p3 = 0
    for cycle in range(dm.P3_QUOTA_TIMEOUT + 8):
        grant = arb.step(arb_valid, cmds, True)
        max_wait_p3 = max(max_wait_p3, arb.wait_cnt[3])
        if grant == 3:
            first_p3 = cycle
            break
    assert first_p3 == dm.P3_QUOTA_TIMEOUT, (
        f'P3 granted at cycle {first_p3}, quota fires at '
        f'{dm.P3_QUOTA_TIMEOUT}')
    assert max_wait_p3 >= dm.P3_QUOTA_TIMEOUT
    assert arb.wait_cnt[3] == 0            # clear on grant
    assert arb.p3_starve_cnt == 0


def test_ctrl_p3_quota_grant_is_observed_inside_the_controller():
    quota = 32
    model = dm.Ddr3CtrlAxiModel(p3_quota_timeout=quota)
    ip = dm.ReadyIp(aw_latency=0, w_latency=0, ar_latency=0)
    cmds = [dm.pack_cmd(1, PCM_ADDR, 1), 0, 0,
            dm.pack_cmd(0, SPEC_ADDR, 1)]
    valid = [1, 0, 0, 1]

    first_p3 = None
    previous_starve = 0
    for cycle in range(600):
        out = model.cycle(valid, cmds, [beat_payload(0, 0), 0, 0, 0],
                          FAST, ip)
        if out.grant == 1 << 3 and out.state_before == dm.S_IDLE:
            first_p3 = cycle
            assert previous_starve >= quota, previous_starve
            break
        previous_starve = out.p3_starve_cnt
    assert first_p3 is not None, 'P3 quota never produced a grant'
    assert first_p3 >= quota
    assert model.arb.addr_err == [0, 0, 0, 0]
