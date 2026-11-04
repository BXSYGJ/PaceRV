"""Executable specification of `src/ctrl/self_test.v` (contract C-SELFTEST@1).

The module is modelled cycle by cycle in Python (mirroring the always block
line by line) and driven by a minimal timing stub of `ddr3_ctrl_axi`. The stub
is self-contained on purpose: this test must not import the T1 model library
(`tests/ddr3_ctrl_model.py`) so that the two tasks stay independently runnable.

The stub reproduces exactly the `ddr3_ctrl_axi` facts that `self_test` depends
on (contract C-DDR3-CTRL-SEM@1):

  S1  write completion is a combinational pulse on the cycle the last beat is
      accepted, so `done` and the 16th `wready_beat` are the SAME cycle;
  S2  every accepted beat raises `wready_beat` on that cycle;
  S3  4096 cycles without handshake progress abort the command, raise a
      single-cycle `done` to the owner and return to idle;
  S4  read completion is `axi_rvalid && axi_rlast`, `done` on that cycle;
  S5  the read fifo count only reflects a push on the NEXT cycle, therefore
      the `rd_valid` that carries the rlast beat appears one cycle after
      `done`;
  S6  a read command is only granted when the read fifo is empty, so a
      one-cycle `cmd_valid` strobe can be dropped (hence F1/F3 hold it).

Locked vectors (plan section 3.1 T2 acceptance items 1..7):

  * F2 order      - last `wready_beat` and `done` on the same cycle is NOT a
                    failure, the FSM advances to the read command;
  * F2 counter    - `done` with no `wready_beat` mid-burst raises `st_fail`
                    one cycle later with `st_fail_addr == 28'h0030_0000`;
  * F4 boundary   - `done` with `rd_valid == 0` followed by `rd_valid == 1`
                    (the rlast beat) completes with `st_done`, no `st_fail`;
  * F4 counter    - `done` with an always-empty read fifo raises `st_fail`
                    one cycle after `done_q`;
  * F1/F3 hold    - `cmd_valid` survives cycles where the grant is withheld;
  * F5 literals   - 8 write + 8 read command words equal
                    `{wr, 28'h0030_0000 + idx*512, 8'd15}` and the legacy
                    33 -> 28 bit truncation form is gone from the source;
  * F6/F7         - `st_done` and `st_fail` are mutually exclusive and stick
                    in ST_END until the next `st_start`;
  * ports         - the port list is byte-identical to the frozen contract.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

# --------------------------------------------------------------------------- #
# Constants shared with the RTL (must match the module parameters)
# --------------------------------------------------------------------------- #

SELFTEST_BASE = 0x0030_0000
DDR_PATTERN = 0x5A5A_00FF
BURST_LEN = 15                      # beats - 1 (16 beats of 32 B)
CMD_LEN_BITS = 8
CMD_ADDR_BITS = 28

# FSM state encoding (localparams in the RTL).
ST_IDLE, ST_WCMD, ST_WDATA, ST_RCMD, ST_RDATA, ST_END = range(6)

# ddr3_ctrl_axi phases used by the stub.
S_IDLE, S_AW, S_W, S_WLAST, S_DW_AW, S_DW_W, S_AR, S_R = range(8)

SRC_PATH = Path(__file__).resolve().parents[1] / 'src' / 'ctrl' / 'self_test.v'
REPO_ROOT = Path(__file__).resolve().parents[2]


# --------------------------------------------------------------------------- #
# Pattern helpers (1:1 with the RTL pat_word / exp_beat / wdata functions)
# --------------------------------------------------------------------------- #

def pat_word(w_idx: int) -> int:
    """32-bit pattern word for word index w_idx (0..1023)."""
    return DDR_PATTERN ^ (w_idx & 0x3FF)


def beat_from_words(base_word: int) -> int:
    """256-bit beat: word k occupies bits 32*k+31 .. 32*k (big-endian)."""
    value = 0
    for k in range(8):
        value |= (pat_word(base_word + k) & 0xFFFFFFFF) << (32 * k)
    return value


def pack_cmd(is_write: int, addr: int, length: int) -> int:
    """{wr, addr[27:0], len[7:0]} as a 37-bit integer."""
    return ((is_write & 1) << 36) | ((addr & 0x0FFFFFFF) << CMD_LEN_BITS) | (
        length & 0xFF)


def unpack_cmd(cmd: int) -> tuple[int, int, int]:
    return (cmd >> 36) & 1, (cmd >> CMD_LEN_BITS) & 0x0FFFFFFF, cmd & 0xFF


# --------------------------------------------------------------------------- #
# Minimal ddr3_ctrl_axi timing stub
# --------------------------------------------------------------------------- #

class CtrlStub:
    """Cycle-level stand-in for ddr3_ctrl_axi (single master, m3 only).

    Parameters
    ----------
    aw_latency:
        Cycles between the AW assertion and the write-data phase.
    wready_pattern / wready_tail:
        Per-beat acceptance of the write data phase. Beats beyond the end of
        `wready_pattern` use `wready_tail`, which lets a vector stall the IP
        forever (F2 counter-case) or stream every beat (normal run).
    to_limit:
        Watchdog limit (the RTL uses AXI_TO_LIMIT = 4096; a small value keeps
        the vectors short while preserving the S3 semantics).
    r_data_enable:
        When False the S_R phase never raises rvalid, so the read is aborted
        by the watchdog with an empty fifo (F4 counter-case).
    rvalid_period:
        Beat spacing of the read stream. 1 streams one beat per cycle (the
        fifo then keeps one entry outstanding and the rlast cycle still
        shows rd_valid). 2 leaves one idle cycle between beats, so the fifo
        drains completely and the rlast cycle shows rd_valid == 0 with the
        data one cycle later - the exact S5 boundary F4 is built around.
    read_hold_remaining:
        Number of idle cycles on which a read grant is withheld while
        `cmd_valid` is high, reproducing S6 (read grant requires an empty
        fifo). The fifo itself stays empty so the stub never injects stale
        beats into the comparator.
    """

    def __init__(self, aw_latency: int = 1, wready_pattern: tuple[int, ...] = (),
                 wready_tail: bool = True, to_limit: int = 6,
                 r_data_enable: bool = True, r_latency: int = 2,
                 rvalid_period: int = 1, read_hold_remaining: int = 0):
        self.aw_latency = aw_latency
        self.wready_pattern = tuple(wready_pattern)
        self.wready_tail = wready_tail
        self.to_limit = to_limit
        self.r_data_enable = r_data_enable
        self.r_latency = r_latency
        self.rvalid_period = max(1, rvalid_period)
        self.read_hold_remaining = read_hold_remaining

        self.state = S_IDLE
        self.cur_wr = 0
        self.cur_addr = 0
        self.cur_len = 0
        self.beat_cnt = 0
        self.aw_wait = 0
        self.r_wait = 0
        self.r_phase = 0
        self.wlast_window = 0
        self.to_cnt = 0
        self.fifo: list[int] = []

        # observability
        self.accepted: list[dict] = []      # granted commands, in order
        self.wr_beats = 0
        self.rd_pushes = 0
        self.rd_pops = 0
        self.done_cycles: list[int] = []
        self.abort_cycles: list[int] = []
        self.cycle = 0

    # -- combinational outputs of the current cycle --------------------- #

    def _wready_now(self) -> bool:
        if self.wr_beats < len(self.wready_pattern):
            return bool(self.wready_pattern[self.wr_beats])
        return self.wready_tail

    def _arb_en_now(self, is_write: int) -> bool:
        if self.state != S_IDLE:
            return False
        if not is_write and self.read_hold_remaining > 0:
            return False
        return bool(is_write) or (not self.fifo)

    def comb(self, cmd_valid: int, cmd: int) -> dict:
        """Outputs seen by self_test on this cycle (before the clock edge)."""
        is_write, _addr, _length = unpack_cmd(cmd)
        fifo_empty = not self.fifo
        arb_en = self._arb_en_now(is_write)
        grant = bool(cmd_valid) and arb_en

        wready = self._wready_now()
        wready_beat = (self.state == S_W) and wready
        dw_wready = (self.state == S_DW_W) and wready

        rvalid_now = (self.state == S_R) and self.r_data_enable and (
            self.r_wait == 0) and (self.r_phase % self.rvalid_period == 0)
        rlast_now = rvalid_now and (self.beat_cnt >= self.cur_len)

        write_cmpl = (self.state == S_W) and wready and (
            self.beat_cnt >= self.cur_len)
        read_cmpl = (self.state == S_R) and rvalid_now and rlast_now
        to_abort = (self.to_cnt >= self.to_limit) and (
            self.state not in (S_IDLE, S_WLAST))

        done = write_cmpl or read_cmpl or to_abort
        rd_valid = 1 if fifo_empty is False else 0
        return {
            'grant': grant,
            'wready_beat': int(wready_beat),
            'dw_wready': int(dw_wready),
            'rvalid_now': int(rvalid_now),
            'rd_valid': rd_valid,
            'rd_data': self.fifo[0] if self.fifo else 0,
            'done': int(done),
        }

    # -- one clock edge ------------------------------------------------- #

    def clock(self, cmd_valid: int, cmd: int, wdata: int, fb: dict) -> None:
        """Advance the stub by one cycle using this cycle's outputs."""
        is_write, addr, length = unpack_cmd(cmd)

        # ---- watchdog accumulator (mirrors the RTL block) ----
        no_progress = self.state in (S_AW, S_W, S_DW_AW, S_DW_W, S_AR) or (
            self.state == S_R and not fb['rvalid_now'])
        if no_progress:
            self.to_cnt += 1
        else:
            self.to_cnt = 0

        # ---- read fifo push/pop (independent of the FSM phase) ----
        pushed = False
        if self.state == S_R and fb['rvalid_now']:
            self.fifo.append(self._read_payload())
            self.rd_pushes += 1
            pushed = True
        if fb['rd_valid']:
            self.fifo.pop(0)
            self.rd_pops += 1

        if fb['done']:
            self.done_cycles.append(self.cycle)
            if not (self.state == S_W and fb['wready_beat']) and not (
                    self.state == S_R and fb['rvalid_now']):
                self.abort_cycles.append(self.cycle)

        # ---- main FSM (same branch order as the RTL case statement) ----
        if self.state == S_IDLE:
            if fb['grant']:
                self.cur_wr = is_write
                self.cur_addr = addr
                self.cur_len = length
                self.accepted.append({
                    'cycle': self.cycle,
                    'cmd': cmd & ((1 << 37) - 1),
                    'wr': is_write,
                    'addr': addr,
                    'len': length,
                })
                self.beat_cnt = 0
                self.to_cnt = 0
                self.wlast_window = 0
                self.aw_wait = self.aw_latency
                self.state = S_AW if is_write else S_DW_AW

        elif self.state == S_AW:
            if self.aw_wait > 0:
                self.aw_wait -= 1
            elif self.to_cnt >= self.to_limit + 1:
                # awready never came: watchdog abort (S3)
                self.state = S_IDLE
                self.to_cnt = 0
            else:
                self.state = S_W
                self.beat_cnt = 0
                self.to_cnt = 0

        elif self.state == S_W:
            if fb['wready_beat']:
                self.wr_beats += 1
                self.to_cnt = 0
                if self.beat_cnt >= self.cur_len:
                    self.state = S_WLAST
                    self.wlast_window = 0
                else:
                    self.beat_cnt += 1
            elif self.to_cnt >= self.to_limit + 1:
                self.state = S_IDLE
                self.to_cnt = 0

        elif self.state == S_WLAST:
            # Four-cycle epilogue window, then back to idle (RTL S_WLAST).
            if self.wlast_window == 3:
                self.state = S_IDLE
            else:
                self.wlast_window += 1

        elif self.state == S_DW_AW:
            if self.aw_wait > 0:
                self.aw_wait -= 1
            else:
                self.state = S_DW_W
                self.to_cnt = 0

        elif self.state == S_DW_W:
            if fb['dw_wready']:
                self.state = S_AR
                self.to_cnt = 0
                self.r_wait = self.r_latency
                self.beat_cnt = 0
            elif self.to_cnt >= self.to_limit + 1:
                self.state = S_IDLE
                self.to_cnt = 0

        elif self.state == S_AR:
            if self.r_wait > 0:
                self.r_wait -= 1
            else:
                self.state = S_R
                self.r_phase = 0
                self.to_cnt = 0

        elif self.state == S_R:
            if fb['rvalid_now']:
                self.to_cnt = 0
                if self.beat_cnt >= self.cur_len:
                    self.state = S_IDLE
                else:
                    self.beat_cnt += 1
            elif self.to_cnt >= self.to_limit + 1:
                self.state = S_IDLE
                self.to_cnt = 0
            self.r_phase += 1

        # ---- read-grant hold accounting (S6 vector) ----
        if (self.state == S_IDLE and cmd_valid and not is_write
                and self.read_hold_remaining > 0):
            self.read_hold_remaining -= 1

        self.cycle += 1

    def _read_payload(self) -> int:
        """Beat content for the current read command / beat counter."""
        idx = (self.cur_addr - SELFTEST_BASE) >> 9
        return beat_from_words((idx << 7) | (self.beat_cnt << 3))


# --------------------------------------------------------------------------- #
# self_test cycle model (1:1 with src/ctrl/self_test.v)
# --------------------------------------------------------------------------- #

class SelfTestModel:
    """Cycle-accurate model of the self_test always block."""

    def __init__(self):
        self.state = ST_IDLE
        self.cmd_valid = 0
        self.cmd = 0
        self.cmd_idx = 0
        self.beat_idx = 0
        self.wrd_idx = 0
        self.exp_idx = 0
        self.done_q = 0
        self.done_qq = 0
        self.rd_valid_q = 0
        self.rd_data_q = 0
        self.st_done = 0
        self.st_fail = 0
        self.st_fail_addr = 0
        self.trace: list[dict] = []

    # -- combinational views -------------------------------------------- #

    @property
    def cmd_addr(self) -> int:
        """F5: SELFTEST_BASE + ({25'd0, cmd_idx} << 9)."""
        return (SELFTEST_BASE + ((self.cmd_idx << 9) & 0x0FFFFFFF)) & 0x0FFFFFFF

    def wdata(self) -> int:
        return beat_from_words((self.cmd_idx << 7) | self.wrd_idx)

    def exp_beat(self) -> int:
        return beat_from_words(self.exp_idx)

    # -- one clock edge ------------------------------------------------- #

    def update(self, st_start: int, fb: dict) -> None:
        """Mirror of the RTL always @(posedge clk or negedge rst_n) block."""
        state = self.state
        addr = self.cmd_addr          # evaluated with the current cmd_idx

        cmd_valid_n = self.cmd_valid
        cmd_n = self.cmd
        cmd_idx_n = self.cmd_idx
        beat_idx_n = self.beat_idx
        wrd_idx_n = self.wrd_idx
        exp_idx_n = self.exp_idx
        st_done_n = self.st_done
        st_fail_n = self.st_fail
        st_fail_addr_n = self.st_fail_addr
        done_q_n = fb['done'] and self.state == ST_RDATA

        if state == ST_IDLE:
            if st_start:
                cmd_idx_n = 0
                beat_idx_n = 0
                wrd_idx_n = 0
                exp_idx_n = 0
                st_done_n = 0
                st_fail_n = 0
                st_fail_addr_n = 0
                state = ST_WCMD

        elif state == ST_WCMD:
            cmd_n = pack_cmd(1, addr, BURST_LEN)
            cmd_valid_n = 1
            beat_idx_n = 0
            wrd_idx_n = 0
            state = ST_WDATA

        elif state == ST_WDATA:
            if fb['wready_beat']:
                if self.beat_idx == 15:
                    if self.cmd_idx == 7:
                        cmd_idx_n = 0
                        state = ST_RCMD
                    else:
                        cmd_idx_n = self.cmd_idx + 1
                        state = ST_WCMD
                else:
                    beat_idx_n = self.beat_idx + 1
                    wrd_idx_n = self.wrd_idx + 8
            elif fb['done']:
                st_done_n = 0
                st_fail_n = 1
                st_fail_addr_n = addr
                state = ST_END

        elif state == ST_RCMD:
            cmd_n = pack_cmd(0, addr, BURST_LEN)
            cmd_valid_n = 1
            exp_idx_n = self.cmd_idx << 7
            state = ST_RDATA

        elif state == ST_RDATA:
            if self.rd_valid_q:
                if self.rd_data_q != self.exp_beat():
                    st_done_n = 0
                    st_fail_n = 1
                    st_fail_addr_n = addr
                    state = ST_END
                elif (self.exp_idx & 0x7F) == 120:
                    if self.cmd_idx == 7:
                        st_fail_n = 0
                        st_done_n = 1
                        state = ST_END
                    else:
                        cmd_idx_n = self.cmd_idx + 1
                        state = ST_RCMD
                else:
                    exp_idx_n = self.exp_idx + 8
            elif self.done_qq:
                st_done_n = 0
                st_fail_n = 1
                st_fail_addr_n = addr
                state = ST_END

        elif state == ST_END:
            if st_start:
                cmd_idx_n = 0
                beat_idx_n = 0
                wrd_idx_n = 0
                exp_idx_n = 0
                st_done_n = 0
                st_fail_n = 0
                st_fail_addr_n = 0
                state = ST_WCMD

        # done clears the held command strobe (last assignment in the block)
        if fb['done']:
            cmd_valid_n = 0

        self.cmd_valid = cmd_valid_n
        self.cmd = cmd_n
        self.cmd_idx = cmd_idx_n
        self.beat_idx = beat_idx_n
        self.wrd_idx = wrd_idx_n
        self.exp_idx = exp_idx_n
        self.done_qq = self.done_q
        self.rd_valid_q = fb['rd_valid']
        self.rd_data_q = fb['rd_data']
        self.done_q = done_q_n
        self.st_done = st_done_n
        self.st_fail = st_fail_n
        self.st_fail_addr = st_fail_addr_n
        self.state = state


def run(model: SelfTestModel, ctrl: CtrlStub, cycles: int,
        start_cycles: tuple[int, ...] = (1,), record: bool = True) -> list[dict]:
    """Drive model + stub for `cycles` cycles; return the per-cycle trace.

    Each trace entry holds the values visible at the start of cycle N (the
    register state and the combinational inputs computed from it), so
    "st_fail one cycle after done" is asserted as trace[done+1]['st_fail'].
    """
    trace: list[dict] = []
    for cycle in range(cycles):
        st_start = 1 if cycle in start_cycles else 0
        snap_valid = model.cmd_valid
        snap_cmd = model.cmd
        snap_wdata = model.wdata()
        fb = ctrl.comb(snap_valid, snap_cmd)
        if record:
            trace.append({
                'cycle': cycle,
                'state': model.state,
                'cmd_valid': snap_valid,
                'cmd': snap_cmd,
                'wready_beat': fb['wready_beat'],
                'rd_valid': fb['rd_valid'],
                'rd_data': fb['rd_data'],
                'done': fb['done'],
                'done_q': model.done_q,
                'grant': int(fb['grant']),
                'st_done': model.st_done,
                'st_fail': model.st_fail,
                'st_fail_addr': model.st_fail_addr,
            })
        model.update(st_start, fb)
        ctrl.clock(snap_valid, snap_cmd, snap_wdata, fb)
    model.trace = trace
    return trace


# --------------------------------------------------------------------------- #
# Helpers over the trace
# --------------------------------------------------------------------------- #

def index_of_first(trace: list[dict], key: str) -> int:
    for i, row in enumerate(trace):
        if row[key]:
            return i
    return -1


def state_block(text: str, name: str) -> str:
    """Slice the FSM branch body of one `ST_*: begin ... end` block.

    The end marker is the next state label at the same 16-space indentation,
    not the first `ST_` substring (nested `state <= ST_xxx;` assignments would
    truncate the block far too early).
    """
    start = text.index(f'{name}: begin')
    tail = text[start + len(name):]
    m = re.search(r'(?m)^ {16}ST_[A-Z_]+: begin', tail)
    end = start + len(name) + (m.start() if m else len(tail))
    return text[start:end]


# --------------------------------------------------------------------------- #
# Vector 1 + 2: F2 ordering (the failure that wedges the FSM today)
# --------------------------------------------------------------------------- #

def test_last_write_beat_with_done_same_cycle_is_not_a_failure():
    """F2 order: 16th wready_beat and done coincide -> no st_fail, advance."""
    ctrl = CtrlStub(aw_latency=1, wready_tail=True, to_limit=64)
    model = SelfTestModel()
    trace = run(model, ctrl, cycles=80)

    done_i = index_of_first(trace, 'done')
    assert done_i > 0, 'the write burst never completed'
    assert trace[done_i]['state'] == ST_WDATA
    assert trace[done_i]['wready_beat'] == 1, (
        'the completing beat and done must share the cycle (S1/S2)')
    # one cycle later: advanced out of ST_WDATA, never flagged as a failure
    assert trace[done_i + 1]['st_fail'] == 0
    assert trace[done_i + 1]['state'] in (ST_WCMD, ST_RCMD)
    assert model.st_fail == 0 and model.st_done == 0


def test_write_abort_mid_burst_flags_fail_at_command_address():
    """F2 counter-case: done with no wready_beat mid-burst -> st_fail."""
    ctrl = CtrlStub(aw_latency=1, wready_pattern=(1, 1, 1), wready_tail=False,
                    to_limit=5)
    model = SelfTestModel()
    trace = run(model, ctrl, cycles=200)

    done_i = index_of_first(trace, 'done')
    assert done_i > 0, 'the watchdog abort never fired'
    assert trace[done_i]['state'] == ST_WDATA
    assert trace[done_i]['wready_beat'] == 0
    assert trace[done_i + 1]['st_fail'] == 1, 'st_fail must rise 1 cycle after done'
    assert trace[done_i + 1]['st_fail_addr'] == 0x0030_0000
    assert trace[done_i + 1]['state'] == ST_END
    assert model.st_done == 0


# --------------------------------------------------------------------------- #
# Vector 3 + 4: F4 read boundary (done_q one cycle late)
# --------------------------------------------------------------------------- #

def test_full_write_then_read_run_passes_all_sixteen_commands():
    """F4 boundary: 8 writes + 8 reads pass; st_done after the last beat."""
    ctrl = CtrlStub(aw_latency=1, wready_tail=True, to_limit=64)
    model = SelfTestModel()
    trace = run(model, ctrl, cycles=4000)

    assert model.st_done == 1
    assert model.st_fail == 0
    assert model.st_fail_addr == 0
    assert len(ctrl.accepted) == 16, (
        f'expected 8 writes + 8 reads, got {len(ctrl.accepted)} commands')
    assert [c['wr'] for c in ctrl.accepted] == [1] * 8 + [0] * 8

    last_done = ctrl.done_cycles[-1]
    done_i = index_of_first(trace, 'st_done')
    assert done_i > 0
    # With back-to-back read beats the fifo keeps one entry outstanding, so
    # the rlast cycle still shows rd_valid and the last two beats drain on
    # the two following cycles; st_done settles at most three cycles after
    # the completion pulse.
    assert done_i <= last_done + 3, (
        f'st_done at cycle {done_i} more than 3 cycles after done {last_done}')
    # no failure flag ever rose during the whole pass
    assert all(row['st_fail'] == 0 for row in trace)


def test_read_last_beat_done_then_data_one_cycle_later_passes():
    """F4 boundary: done with rd_valid=0, rd_valid=1 next cycle -> st_done."""
    # Beat spacing of 2 leaves the fifo empty on the rlast cycle (S5).
    ctrl = CtrlStub(aw_latency=1, wready_tail=True, to_limit=64,
                    rvalid_period=2)
    model = SelfTestModel()
    trace = run(model, ctrl, cycles=6000)

    assert model.st_done == 1
    assert model.st_fail == 0
    assert len(ctrl.accepted) == 16

    rlast_done = ctrl.done_cycles[-1]
    assert trace[rlast_done]['rd_valid'] == 0, (
        'the rlast cycle must show rd_valid == 0 with a drained fifo (S5)')
    assert trace[rlast_done]['done_q'] == 0
    assert trace[rlast_done + 1]['rd_valid'] == 1, (
        'the rlast beat must be offered one cycle after done (S5)')
    assert trace[rlast_done + 1]['done_q'] == 1, (
        'done_q must guard exactly that cycle')
    # rd_valid wins over done_q: the boundary is a pass, not an abort
    assert trace[rlast_done + 3]['st_done'] == 1
    assert trace[rlast_done + 3]['st_fail'] == 0


def test_read_abort_with_empty_fifo_flags_fail_after_done_q():
    """F4 counter-case: read done with an always-empty fifo -> st_fail."""
    ctrl = CtrlStub(aw_latency=1, wready_tail=True, to_limit=6,
                    r_data_enable=False)
    model = SelfTestModel()
    trace = run(model, ctrl, cycles=4000)

    assert ctrl.abort_cycles, 'the read watchdog abort never fired'
    done_i = ctrl.abort_cycles[0]     # first real abort, not a write completion
    assert trace[done_i]['state'] == ST_RDATA
    assert trace[done_i]['rd_valid'] == 0
    assert trace[done_i + 1]['done_q'] == 1, 'done_q must be done delayed 1 cycle'
    assert trace[done_i + 1]['rd_valid'] == 0
    assert trace[done_i + 3]['st_fail'] == 1, (
        'st_fail must rise after the aligned done_qq witness')
    assert trace[done_i + 3]['st_fail_addr'] == 0x0030_0000
    assert model.st_done == 0


# --------------------------------------------------------------------------- #
# Vector 5: F1/F3 cmd_valid is held until done (S6 fix)
# --------------------------------------------------------------------------- #

def test_read_command_strobe_survives_ungranted_cycles():
    """F1/F3: a read command is not lost when the grant is withheld (S6)."""
    ctrl = CtrlStub(aw_latency=1, wready_tail=True, to_limit=64,
                    read_hold_remaining=4)
    model = SelfTestModel()
    trace = run(model, ctrl, cycles=4000)

    # first granted read command
    read_grants = [c['cycle'] for c in ctrl.accepted if not c['wr']]
    assert read_grants, 'no read command was ever granted'
    first_read_grant = read_grants[0]

    held = [row for row in trace[:first_read_grant]
            if row['cmd_valid'] == 1 and row['grant'] == 0
            and unpack_cmd(row['cmd'])[0] == 0]
    assert len(held) >= 2, (
        'the read strobe was not held across the ungranted cycles '
        f'(only {len(held)} cycle(s))')

    # with the strobe held the command is eventually accepted and the whole
    # pass still completes (the pre-fix one-cycle strobe would wedge here)
    assert len(read_grants) == 8
    assert model.st_done == 1 and model.st_fail == 0


def test_write_command_strobe_is_also_held_until_done():
    """F1: cmd_valid stays high during the whole write burst."""
    ctrl = CtrlStub(aw_latency=1, wready_tail=True, to_limit=64)
    model = SelfTestModel()
    trace = run(model, ctrl, cycles=120)

    first_wdata = next(i for i, row in enumerate(trace)
                       if row['state'] == ST_WDATA)
    done_i = index_of_first(trace, 'done')
    # from the ST_WDATA entry through the completing cycle the strobe is high
    burst = trace[first_wdata:done_i + 1]
    assert len(burst) >= 16, 'the burst was shorter than 16 cycles'
    assert all(row['cmd_valid'] == 1 for row in burst), (
        'cmd_valid dropped during the write burst (F1 requires hold-to-done)')
    # and it is low again right after done
    assert trace[done_i + 1]['cmd_valid'] == 0


# --------------------------------------------------------------------------- #
# Vector 6: F5 address contract and literal command words
# --------------------------------------------------------------------------- #

def test_command_literals_match_address_contract():
    """F5: 8 write + 8 read literals equal {wr, base + idx*512, len=15}."""
    ctrl = CtrlStub(aw_latency=1, wready_tail=True, to_limit=64)
    model = SelfTestModel()
    run(model, ctrl, cycles=4000)
    assert len(ctrl.accepted) == 16

    expected = [pack_cmd(1, SELFTEST_BASE + i * 512, BURST_LEN)
                for i in range(8)]
    expected += [pack_cmd(0, SELFTEST_BASE + i * 512, BURST_LEN)
                 for i in range(8)]
    assert [c['cmd'] for c in ctrl.accepted] == expected
    # the 8 commands of one phase cover 0x300000..0x300FFF (4 KB)
    assert (expected[0] >> 8) & 0x0FFFFFFF == 0x0030_0000
    assert (expected[7] >> 8) & 0x0FFFFFFF == 0x0030_0E00


def test_source_uses_truncation_free_address_expression():
    """F5: the legacy 33 -> 28 bit implicit truncation is gone."""
    text = SRC_PATH.read_text(encoding='utf-8')
    assert "{21'd0, cmd_idx, 9'd0}" not in text
    assert "{25'd0, cmd_idx} << 9" in text


# --------------------------------------------------------------------------- #
# Vector 7: F6/F7 sticky, mutually exclusive results
# --------------------------------------------------------------------------- #

def test_results_are_exclusive_and_sticky_until_next_start():
    """F6/F7: no pass+fail together; ST_END holds until the next st_start."""
    # --- passing run ---
    ctrl = CtrlStub(aw_latency=1, wready_tail=True, to_limit=64)
    model = SelfTestModel()
    run(model, ctrl, cycles=4000)
    assert model.st_done == 1 and model.st_fail == 0
    assert model.state == ST_END
    run(model, ctrl, cycles=100, start_cycles=())
    assert model.st_done == 1 and model.st_fail == 0
    assert model.state == ST_END
    # next start clears both and restarts the command sequence
    run(model, ctrl, cycles=1, start_cycles=(0,))
    assert model.st_done == 0 and model.st_fail == 0
    assert model.state == ST_WCMD

    # --- failing run ---
    ctrl = CtrlStub(aw_latency=1, wready_pattern=(1, 1, 1), wready_tail=False,
                    to_limit=5)
    model = SelfTestModel()
    trace = run(model, ctrl, cycles=200)
    done_i = index_of_first(trace, 'done')
    assert trace[done_i + 1]['st_fail'] == 1
    run(model, ctrl, cycles=100, start_cycles=())
    assert model.st_fail == 1 and model.st_done == 0
    assert model.state == ST_END
    run(model, ctrl, cycles=1, start_cycles=(0,))
    assert model.st_done == 0 and model.st_fail == 0
    assert model.state == ST_WCMD


# --------------------------------------------------------------------------- #
# Static contract checks: port list and FSM ordering in the source
# --------------------------------------------------------------------------- #

EXPECTED_PORTS = (
    ('input', 'wire', None, 'clk'),
    ('input', 'wire', None, 'rst_n'),
    ('input', 'wire', None, 'st_start'),
    ('output', 'reg', None, 'cmd_valid'),
    ('output', 'reg', '[36:0]', 'cmd'),
    ('output', 'wire', '[255:0]', 'wdata'),
    ('input', 'wire', None, 'wready_beat'),
    ('output', 'reg', None, 'rd_ready'),
    ('input', 'wire', '[255:0]', 'rd_data'),
    ('input', 'wire', None, 'rd_valid'),
    ('input', 'wire', None, 'done'),
    ('output', 'reg', None, 'st_done'),
    ('output', 'reg', None, 'st_fail'),
    ('output', 'reg', '[27:0]', 'st_fail_addr'),
)

PORT_RE = re.compile(
    r'\b(input|output|inout)\s+(wire|reg)\s*(\[[^\]]*\])?\s*([A-Za-z_]\w*)')


def _port_block(text: str) -> str:
    start = text.index('module self_test')
    end = text.index(');', start)
    return text[start:end]


def test_port_list_is_frozen_contract():
    """R2.5: the port list matches C-SELFTEST@1 exactly (no instrec_top edit)."""
    block = _port_block(SRC_PATH.read_text(encoding='utf-8'))
    found = []
    for m in PORT_RE.finditer(block):
        direction, kind, width, name = m.groups()
        width = width.replace(' ', '') if width else None
        found.append((direction, kind, width, name))
    assert tuple(found) == EXPECTED_PORTS


def test_git_diff_touches_no_port_direction_line():
    """Acceptance 8: no input/output/inout declaration lines added or removed."""
    try:
        proc = subprocess.run(
            ['git', 'diff', '-U0', '--', 'instrec_fpga/src/ctrl/self_test.v'],
            cwd=REPO_ROOT, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:  # pragma: no cover
        pytest.skip(f'git unavailable: {exc}')
    if proc.returncode != 0:
        pytest.skip(f'git diff failed: {proc.stderr.strip()}')
    decl_re = re.compile(r'^[+-]\s*(?:input|output|inout)\s')
    offenders = [ln for ln in proc.stdout.splitlines()
                 if decl_re.match(ln)]
    assert offenders == [], f'port declaration lines changed: {offenders}'


def test_source_holds_cmd_valid_until_done():
    """F1/F3 in the RTL: no unconditional per-cycle strobe clear is left."""
    text = SRC_PATH.read_text(encoding='utf-8')
    # the pre-fix implementation cleared the strobe every cycle
    assert 'Command strobe is a single-cycle pulse' not in text
    # exactly two clears: the async reset branch and the done-guarded one
    assert len(re.findall(r"cmd_valid\s*<=\s*1'b0;", text)) == 2
    # ... and the guarded clear is the last assignment of the clocked block
    assert re.search(r"if \(done\) begin\s*\n\s*cmd_valid <= 1'b0;", text)
    # one issue site per phase (write command / read command)
    assert len(re.findall(r"cmd_valid\s*<=\s*1'b1;", text)) == 2


def test_source_keeps_fsm_priority_order():
    """F2/F4: beats precede the matching completion witness in source."""
    text = SRC_PATH.read_text(encoding='utf-8')

    wdata = state_block(text, 'ST_WDATA')
    assert 'if (wready_beat)' in wdata
    assert 'else if (done)' in wdata
    assert wdata.index('if (wready_beat)') < wdata.index('else if (done)')

    rdata = state_block(text, 'ST_RDATA')
    assert 'if (rd_valid_q)' in rdata
    assert 'else if (done_qq)' in rdata
    assert rdata.index('if (rd_valid_q)') < rdata.index('else if (done_qq)')
