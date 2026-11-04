"""Cycle model of the sys_ctrl DDR3 result latcher / deferred reporter (T21).

Board evidence (2026-10-31, three consecutive flashes): the console dump was
always exactly 30 bytes::

    INSTREC BOOT
    DDR3 SELFTEST...

Neither ``DDROK`` nor ``DDR3 ERR @...`` ever appeared.  Root cause in
``src/ctrl/sys_ctrl.v``: the ``DDR3 SELFTEST...`` line (id 2) was fired behind
``!dbg_busy``, but the conclusion lines (id 3 ``DDROK`` / id 4 ``DDR3 ERR`` /
id 4 timeout) were fired unconditionally.  ``uart_debug`` latches a ROM
request only while ``state == ST_IDLE`` (see ``rom_pending``), so a request
raised during the ~3 ms id-2 drain window is dropped silently.  The DDR3
conclusion arrives 4096 cycles (32.8 us at 125 MHz) after ``st_start``, i.e.
far inside that window -- therefore a passing DDR3 and an aborted DDR3
produced the same 30 bytes and could not be told apart.

Locked behaviour (this file is the executable spec):

  1. the conclusion is latched into ``ddr_result`` / ``ddr_result_arg`` with
     ``ddr_result_pending``; the line is fired from ``ST_DDREP`` only when
     ``!dbg_busy``, so it survives a 3 ms busy window;
  2. FAIL carries ``st_fail_addr`` zero-extended to 32 bits;
  3. TIMEOUT carries ``32'hFFFF_FFFF`` (unchanged from the pre-fix code);
  4. the ``DDR3 STS <hex8>`` byte is
     ``{cmd_to_err[3], to_err, dbg_to_state[2:0], st_fail, st_done}`` in the
     low 8 bits, printed after the conclusion line, exactly once;
  5. no line is printed twice in one round;
  6. reset clears ``ddr_result_pending`` / ``ddr_sts_sent``.

The model mirrors the sys_ctrl always block line by line; the printer mirrors
uart_debug's "accept a ROM request only while idle" latch.
"""

from __future__ import annotations

import re
from pathlib import Path

# --------------------------------------------------------------------------- #
# Constants shared with the RTL (must match src/ctrl/sys_ctrl.v)
# --------------------------------------------------------------------------- #

# FSM state encoding (localparams in sys_ctrl.v).
ST_BOOT, ST_PLL, ST_DDR, ST_DDW, ST_RUN, ST_SAFEERR, ST_WEIGHT, ST_DDREP = range(8)

# Latched conclusion codes.
DDR_RES_NONE, DDR_RES_PASS, DDR_RES_FAIL, DDR_RES_TIME = range(4)

# uart_debug predefined line ids.
LINE_ID_BOOT = 0
LINE_ID_PLLERR = 1
LINE_ID_DDRTEST = 2
LINE_ID_DDROK = 3
LINE_ID_DDRERR = 4
LINE_ID_RUN = 5
LINE_ID_DDRSTS = 6

TIMEOUT_ARG = 0xFFFF_FFFF

# "DDR3 SELFTEST...\\n" is 16 bytes at 115200 8N1 (~1.4 ms) plus the
# inter-character machinery; the board-observed printer window is ~3 ms.
BUSY_3MS = 375_000            # 125 MHz * 3 ms

# The DDR3 self-test itself takes 4096 cycles (32.8 us at 125 MHz), so it
# always completes while id 2 is still draining.
SELFTEST_CYCLES = 4096

# Long enough for: conclusion line (busy 3 ms) -> STS line, plus 10k guard
# cycles to prove nothing is reprinted.
RUN_CYCLES = BUSY_3MS * 2 + 10_000

SRC_SYS_CTRL = Path(__file__).resolve().parents[1] / 'src' / 'ctrl' / 'sys_ctrl.v'
SRC_UART_DEBUG = Path(__file__).resolve().parents[1] / 'src' / 'ctrl' / 'uart_debug.v'
SRC_TOP = Path(__file__).resolve().parents[1] / 'src' / 'ctrl' / 'instrec_top.v'


# --------------------------------------------------------------------------- #
# STS diagnostic byte
# --------------------------------------------------------------------------- #

def sts_code(cmd_to_err3: int, to_err: int, dbg_to_state: int,
             st_fail: int, st_done: int) -> int:
    """``{cmd_to_err[3], to_err, dbg_to_state[2:0], st_fail, st_done}``.

    Seven meaningful bits are packed into the low 8 bits; bit 7 is the zero
    pad, which is what "take the low 8 bits" of the field means here.
    """
    return (((cmd_to_err3 & 1) << 6)
            | ((to_err & 1) << 5)
            | ((dbg_to_state & 0x7) << 2)
            | ((st_fail & 1) << 1)
            | (st_done & 1)) & 0xFF


# --------------------------------------------------------------------------- #
# uart_debug printer stub: one request at a time, accept only while idle
# --------------------------------------------------------------------------- #

class DbgPrinter:
    """Mirrors uart_debug's ROM request latch (``rom_pending`` + ``dbg_busy``).

    A request is accepted only while the printer is idle; requests raised
    while busy are DROPPED (that is the board bug this test guards against).
    Each accepted line occupies the printer for ``busy_cycles`` cycles.
    """

    def __init__(self, busy_cycles: int = BUSY_3MS, initially_busy: bool = False):
        self.busy_cycles = busy_cycles
        self.busy_left = busy_cycles if initially_busy else 0
        self.sent: list[dict] = []
        self.dropped: list[dict] = []

    @property
    def busy(self) -> bool:
        return self.busy_left > 0

    def step(self, fire: int, line_id: int, line_arg: int, cycle: int) -> bool:
        """One clock. Returns True when this cycle accepted a request."""
        busy_now = self.busy
        accepted = bool(fire) and not busy_now
        if accepted:
            self.sent.append({'cycle': cycle, 'id': line_id, 'arg': line_arg})
            self.busy_left = self.busy_cycles
        else:
            if fire:
                self.dropped.append({'cycle': cycle, 'id': line_id,
                                     'arg': line_arg})
            if self.busy_left > 0:
                self.busy_left -= 1
        return accepted


# --------------------------------------------------------------------------- #
# sys_ctrl model (1:1 with the always block, DDR stage subset)
# --------------------------------------------------------------------------- #

class SysCtrlDdrModel:
    """Cycle model of sys_ctrl's DDR stage (ST_DDR / ST_DDW / ST_DDREP).

    Only the DDR-related registers are modelled; the PLL/BOOT stages are
    entered through ``start_in`` because they are covered by other tests.
    """

    def __init__(self, ddr_timeout_cycles: int = 12_500_000,
                 start_in: int = ST_DDW):
        self.ddr_timeout_cycles = ddr_timeout_cycles
        self.reset(start_in)

    def reset(self, start_in: int = ST_DDR) -> None:
        self.state = start_in
        self.timeout_cnt = 0
        self.started = 0
        self.ddr_result = DDR_RES_NONE
        self.ddr_result_arg = 0
        self.ddr_result_pending = 0
        self.ddr_result_sent = 0
        self.ddr_sts_armed = 0
        self.ddr_sts_sent = 0
        self.dbg_line_id = LINE_ID_BOOT
        self.dbg_line_arg = 0
        self.dbg_line_fire = 0
        self.sys_run = 0
        self.err_latch = 0

    def retrigger(self) -> None:
        """ST_RUN -> ST_DDR on KEY1 (sys_ctrl's re-run path)."""
        if self.state != ST_RUN:
            raise AssertionError(
                f'retrigger at state {self.state}, expected ST_RUN')
        self.sys_run = 0
        self.state = ST_DDR

    def update(self, st_done: int, st_fail: int, st_fail_addr: int,
               dbg_busy: int, code: int) -> None:
        """One clock edge; all assignments are non-blocking in the RTL."""
        state = self.state
        timeout_cnt = self.timeout_cnt
        started = self.started
        result = self.ddr_result
        result_arg = self.ddr_result_arg
        pending = self.ddr_result_pending
        sent = self.ddr_result_sent
        armed = self.ddr_sts_armed
        sts_sent = self.ddr_sts_sent
        line_id = self.dbg_line_id
        line_arg = self.dbg_line_arg
        fire = 0
        sys_run = self.sys_run
        err = self.err_latch

        if state == ST_DDR:
            # Kick the self-test and clear the report flags for this round.
            if not dbg_busy:
                line_id = LINE_ID_DDRTEST
                pending = 0
                sent = 0
                armed = 0
                sts_sent = 0
                fire = 1
                timeout_cnt = 0
                started = 0
                state = ST_DDW

        elif state == ST_DDW:
            if not started:
                started = 1
            elif st_done:
                result = DDR_RES_PASS
                result_arg = 0
                pending = 1
                state = ST_DDREP
            elif st_fail:
                result = DDR_RES_FAIL
                result_arg = st_fail_addr & 0x0FFF_FFFF
                pending = 1
                state = ST_DDREP
            elif timeout_cnt >= self.ddr_timeout_cycles:
                result = DDR_RES_TIME
                result_arg = TIMEOUT_ARG
                pending = 1
                state = ST_DDREP
            else:
                timeout_cnt += 1

        elif state == ST_DDREP:
            if pending:
                if not dbg_busy:
                    pending = 0
                    sent = 1
                    armed = 0
                    fire = 1
                    if result == DDR_RES_PASS:
                        line_id = LINE_ID_DDROK
                        line_arg = 0
                    else:
                        line_id = LINE_ID_DDRERR
                        line_arg = result_arg
            elif sent and not sts_sent:
                # arm only after the result line actually occupied the
                # printer (rom_pending rises one edge after the fire)
                if dbg_busy:
                    armed = 1
                elif armed:
                    line_id = LINE_ID_DDRSTS
                    line_arg = code
                    fire = 1
                    sts_sent = 1
            elif sent:
                if result == DDR_RES_PASS:
                    state = ST_RUN
                    sys_run = 1
                else:
                    err = 1
                    state = ST_SAFEERR

        self.state = state
        self.timeout_cnt = timeout_cnt
        self.started = started
        self.ddr_result = result
        self.ddr_result_arg = result_arg
        self.ddr_result_pending = pending
        self.ddr_result_sent = sent
        self.ddr_sts_armed = armed
        self.ddr_sts_sent = sts_sent
        self.dbg_line_id = line_id
        self.dbg_line_arg = line_arg
        self.dbg_line_fire = fire
        self.sys_run = sys_run
        self.err_latch = err


# --------------------------------------------------------------------------- #
# Driver
# --------------------------------------------------------------------------- #

class RunResult:
    """Evidence collected by :func:`run`."""

    def __init__(self, model, printer):
        self.model = model
        self.printer = printer
        self.events: list[dict] = []      # cycles where dbg_line_fire == 1
        self.busy_edges: list[tuple[int, bool]] = []   # (cycle, busy value)
        self.cycles = 0

    @property
    def first_idle_cycle(self) -> int:
        """First cycle on which dbg_busy reads 0 after being 1."""
        for cycle, busy in self.busy_edges:
            if not busy and cycle > 0:
                return cycle
        return -1

    def event_of(self, line_id: int) -> list[dict]:
        return [e for e in self.events if e['id'] == line_id]


def run(model: SysCtrlDdrModel, printer: DbgPrinter, cycles: int, *,
        st_done_at: int | None = None, st_fail_at: int | None = None,
        st_fail_addr: int = 0, cmd_to_err3: int = 0, to_err: int = 0,
        dbg_to_state: int = 0, retrigger_at: int | None = None) -> RunResult:
    """Drive the model + printer for ``cycles`` clocks.

    ``st_done`` / ``st_fail`` behave like self_test's ST_END flags: they rise
    ``st_done_at`` cycles after the current round starts and stay high until
    the next ``st_start`` (matching the sticky F6/F7 contract). A second
    round is started at ``retrigger_at`` (KEY1 in ST_RUN); self_test clears
    its flags there, so the new conclusion is taken ``st_done_at`` cycles
    into that round.
    """
    result = RunResult(model, printer)
    prev_busy = printer.busy
    for cycle in range(cycles):
        if retrigger_at is not None and cycle == retrigger_at:
            model.retrigger()

        round_start = 0
        if retrigger_at is not None and cycle >= retrigger_at:
            round_start = retrigger_at
        st_done = 1 if (st_done_at is not None
                        and cycle >= round_start + st_done_at) else 0
        st_fail = 1 if (st_fail_at is not None
                        and cycle >= round_start + st_fail_at) else 0
        code = sts_code(cmd_to_err3, to_err, dbg_to_state, st_fail, st_done)

        busy_now = printer.busy
        if busy_now != prev_busy:
            result.busy_edges.append((cycle, busy_now))
            prev_busy = busy_now

        if model.dbg_line_fire:
            result.events.append({
                'cycle': cycle,
                'busy': int(busy_now),
                'state': model.state,
                'id': model.dbg_line_id,
                'arg': model.dbg_line_arg,
            })

        printer.step(model.dbg_line_fire, model.dbg_line_id,
                     model.dbg_line_arg, cycle)
        model.update(st_done, st_fail, st_fail_addr, int(busy_now), code)

    result.cycles = cycles
    return result


# --------------------------------------------------------------------------- #
# Vector 1: PASS conclusion survives the 3 ms id-2 busy window
# --------------------------------------------------------------------------- #

def test_pass_result_survives_three_millisecond_busy_window():
    """The id-2 line holds the printer for 3 ms; DDROK must still go out."""
    model = SysCtrlDdrModel(start_in=ST_DDW)
    printer = DbgPrinter(busy_cycles=BUSY_3MS, initially_busy=True)
    run_result = run(model, printer, RUN_CYCLES, st_done_at=SELFTEST_CYCLES)

    # the conclusion really did arrive inside the busy window
    assert SELFTEST_CYCLES < run_result.first_idle_cycle

    # ... and was not dropped
    assert printer.dropped == [], (
        f'uart_debug dropped request(s): {printer.dropped}')
    ddrok = run_result.event_of(LINE_ID_DDROK)
    assert len(ddrok) == 1, f'expected exactly one DDROK fire, got {ddrok}'

    event = ddrok[0]
    assert event['busy'] == 0, 'DDROK must be fired only while !dbg_busy'
    # dbg_line_id becomes 3 on the cycle AFTER busy falls: the fire is visible
    # one register stage later, so the event lands one cycle after idle.
    assert event['cycle'] == run_result.first_idle_cycle + 1, (
        f"DDROK fired at {event['cycle']}, first idle cycle "
        f"{run_result.first_idle_cycle}")

    assert model.state == ST_RUN
    assert model.sys_run == 1 and model.err_latch == 0
    assert model.ddr_result == DDR_RES_PASS


def test_pass_conclusion_is_latched_before_the_printer_frees_up():
    """The latched state, not a busy re-check, is what survives the wait."""
    model = SysCtrlDdrModel(start_in=ST_DDW)
    printer = DbgPrinter(busy_cycles=BUSY_3MS, initially_busy=True)

    # Run only up to the self-test completion plus a few cycles: the printer
    # is still busy, the conclusion must already be latched and pending.
    run(model, printer, SELFTEST_CYCLES + 5, st_done_at=SELFTEST_CYCLES)

    assert printer.busy == 1
    assert model.ddr_result_pending == 1
    assert model.ddr_result == DDR_RES_PASS
    assert model.state == ST_DDREP
    assert model.dbg_line_fire == 0, 'no line may be fired while busy'
    assert printer.sent == [] and printer.dropped == []


# --------------------------------------------------------------------------- #
# Vector 2: FAIL conclusion carries st_fail_addr
# --------------------------------------------------------------------------- #

def test_fail_result_survives_busy_and_carries_fail_address():
    fail_addr = 0x0030_0500
    model = SysCtrlDdrModel(start_in=ST_DDW)
    printer = DbgPrinter(busy_cycles=BUSY_3MS, initially_busy=True)
    run_result = run(model, printer, RUN_CYCLES,
                     st_fail_at=SELFTEST_CYCLES, st_fail_addr=fail_addr)

    assert printer.dropped == []
    ddrerr = run_result.event_of(LINE_ID_DDRERR)
    assert len(ddrerr) == 1, f'expected exactly one DDR3 ERR fire, got {ddrerr}'
    event = ddrerr[0]
    assert event['busy'] == 0
    assert event['cycle'] == run_result.first_idle_cycle + 1
    # {4'd0, st_fail_addr}: zero-extended to 32 bits
    assert event['arg'] == fail_addr
    assert model.ddr_result == DDR_RES_FAIL
    assert model.state == ST_SAFEERR
    assert model.err_latch == 1 and model.sys_run == 0


# --------------------------------------------------------------------------- #
# Vector 3: TIMEOUT conclusion (100 ms watchdog) is not lost either
# --------------------------------------------------------------------------- #

def test_timeout_result_survives_busy_with_legacy_argument():
    """Watchdog semantics unchanged: id 4 with dbg_line_arg = 32'hFFFF_FFFF."""
    timeout_cycles = 50                       # scaled 100 ms watchdog
    model = SysCtrlDdrModel(ddr_timeout_cycles=timeout_cycles, start_in=ST_DDW)
    printer = DbgPrinter(busy_cycles=BUSY_3MS, initially_busy=True)
    run_result = run(model, printer, RUN_CYCLES)

    assert printer.dropped == []
    ddrerr = run_result.event_of(LINE_ID_DDRERR)
    assert len(ddrerr) == 1, f'expected exactly one timeout line, got {ddrerr}'
    event = ddrerr[0]
    assert event['busy'] == 0
    assert event['cycle'] == run_result.first_idle_cycle + 1
    assert event['arg'] == TIMEOUT_ARG == 0xFFFF_FFFF
    assert model.ddr_result == DDR_RES_TIME
    assert model.state == ST_SAFEERR
    assert model.err_latch == 1


# --------------------------------------------------------------------------- #
# Vector 4: DDR3 STS byte encoding
# --------------------------------------------------------------------------- #

def test_sts_byte_encoding_three_reference_vectors():
    """``{cmd_to_err[3], to_err, dbg_to_state, st_fail, st_done}`` low 8 bits."""
    # pass: nothing latched, self-test completed
    assert sts_code(0, 0, 0, 0, 1) == 0x01
    # master-3 timeout while in S_W (2): cmd_to_err[3]=1, to_err=1
    assert sts_code(1, 1, 2, 1, 0) == 0x6A
    # read-side stuck in S_R (7) without a self-test conclusion
    assert sts_code(0, 0, 7, 0, 0) == 0x1C
    # every field is isolated
    assert sts_code(1, 0, 0, 0, 0) == 0x40
    assert sts_code(0, 1, 0, 0, 0) == 0x20
    assert sts_code(0, 0, 4, 0, 0) == 0x10      # S_DW_AW
    assert sts_code(0, 0, 5, 0, 0) == 0x14      # S_DW_W
    assert sts_code(0, 0, 6, 0, 0) == 0x18      # S_AR


def test_sts_line_is_printed_after_the_conclusion_with_the_same_code():
    model = SysCtrlDdrModel(start_in=ST_DDW)
    printer = DbgPrinter(busy_cycles=BUSY_3MS, initially_busy=True)
    run_result = run(model, printer, RUN_CYCLES, st_done_at=SELFTEST_CYCLES,
                     cmd_to_err3=1, to_err=1, dbg_to_state=2)

    assert printer.dropped == []
    ddrok = run_result.event_of(LINE_ID_DDROK)
    sts = run_result.event_of(LINE_ID_DDRSTS)
    assert len(ddrok) == 1 and len(sts) == 1
    # conclusion first, then the diagnostic byte
    assert sts[0]['cycle'] > ddrok[0]['cycle']
    # the STS line also waits for the conclusion line to drain (3 ms)
    assert sts[0]['busy'] == 0
    assert sts[0]['cycle'] >= ddrok[0]['cycle'] + BUSY_3MS
    expected = sts_code(1, 1, 2, 0, 1)
    assert expected == 0x69
    assert sts[0]['arg'] == expected, (
        f"STS arg 0x{sts[0]['arg']:02X} != 0x{expected:02X}")


# --------------------------------------------------------------------------- #
# Vector 5: each line is printed exactly once per round
# --------------------------------------------------------------------------- #

def test_each_line_is_printed_once_per_round():
    model = SysCtrlDdrModel(start_in=ST_DDW)
    printer = DbgPrinter(busy_cycles=BUSY_3MS, initially_busy=True)
    run_result = run(model, printer, RUN_CYCLES, st_done_at=SELFTEST_CYCLES,
                     cmd_to_err3=1, to_err=1, dbg_to_state=2)

    ids = [event['id'] for event in run_result.events]
    assert ids.count(LINE_ID_DDROK) == 1, ids
    assert ids.count(LINE_ID_DDRSTS) == 1, ids
    assert ids.count(LINE_ID_DDRERR) == 0, ids
    assert len(ids) == 2, f'unexpected extra lines: {ids}'
    # and the printer saw exactly the same two lines (nothing dropped)
    assert [s['id'] for s in printer.sent] == ids


# --------------------------------------------------------------------------- #
# Vector 6: a second round (KEY1 re-trigger) starts from a clean slate
# --------------------------------------------------------------------------- #

def test_second_round_reprints_result_and_sts_exactly_once():
    """KEY1 re-trigger: flags must be reset by ST_DDR, not leak from round 1.

    Round 1 prints DDROK + DDR3 STS once.  The re-trigger goes ST_RUN -> ST_DDR,
    which clears ddr_result_pending / ddr_result_sent / ddr_sts_armed /
    ddr_sts_sent before firing id 2 again, so round 2 prints the pair once
    more - never zero times (stale ``sent``) and never twice.
    """
    model = SysCtrlDdrModel(start_in=ST_DDW)
    printer = DbgPrinter(busy_cycles=BUSY_3MS, initially_busy=True)
    retrigger_at = RUN_CYCLES            # after round 1 finished (ST_RUN)
    # Round 2 needs: wait for the round-1 STS line, id 2 (3 ms), the latched
    # result line (3 ms) and finally the STS line's fire cycle.
    total_cycles = retrigger_at + RUN_CYCLES + BUSY_3MS + 20_000
    run_result = run(model, printer, total_cycles,
                     st_done_at=SELFTEST_CYCLES, retrigger_at=retrigger_at)

    assert printer.dropped == [], (
        f'uart_debug dropped request(s): {printer.dropped}')
    events = run_result.events
    ddrok = [e for e in events if e['id'] == LINE_ID_DDROK]
    sts = [e for e in events if e['id'] == LINE_ID_DDRSTS]
    ddrerr = [e for e in events if e['id'] == LINE_ID_DDRERR]

    assert len(ddrok) == 2, [e['cycle'] for e in ddrok]
    assert len(sts) == 2, [e['cycle'] for e in sts]
    assert ddrerr == []

    # one pair per round, each conclusion before its STS line
    assert ddrok[0]['cycle'] < sts[0]['cycle'] < ddrok[1]['cycle'] < sts[1]['cycle']
    assert ddrok[0]['cycle'] < retrigger_at < ddrok[1]['cycle']

    # round 2 starts from an idle printer and ends in ST_RUN again
    assert all(e['busy'] == 0 for e in ddrok + sts)
    assert model.state == ST_RUN and model.sys_run == 1
    assert model.ddr_result_pending == 0 and model.ddr_result_sent == 1
    assert model.ddr_sts_sent == 1


# --------------------------------------------------------------------------- #
# Vector 7: reset clears the report flags
# --------------------------------------------------------------------------- #

def test_reset_clears_pending_and_sent_flags():
    model = SysCtrlDdrModel(start_in=ST_DDW)
    printer = DbgPrinter(busy_cycles=BUSY_3MS, initially_busy=True)
    run(model, printer, SELFTEST_CYCLES + 5, st_done_at=SELFTEST_CYCLES)
    assert model.ddr_result_pending == 1          # latched, waiting for idle

    model.reset(start_in=ST_DDR)
    assert model.ddr_result_pending == 0
    assert model.ddr_result_sent == 0
    assert model.ddr_sts_armed == 0
    assert model.ddr_sts_sent == 0
    assert model.ddr_result == DDR_RES_NONE
    assert model.ddr_result_arg == 0
    assert model.dbg_line_fire == 0
    assert model.state == ST_DDR


# --------------------------------------------------------------------------- #
# Static source contracts
# --------------------------------------------------------------------------- #

def test_rtl_packs_the_sts_byte_in_documented_order():
    text = SRC_SYS_CTRL.read_text(encoding='utf-8')
    m = re.search(r'assign\s+ddr_sts_code\s*=\s*\{(.*?)\};', text, re.S)
    assert m, 'ddr_sts_code concatenation not found'
    fields = [f.strip() for f in m.group(1).split(',')]
    assert fields == ['ddr_cmd_to_err', 'ddr_to_err', 'ddr_dbg_to_state'], fields


def test_rtl_result_fire_is_gated_by_dbg_busy():
    text = SRC_SYS_CTRL.read_text(encoding='utf-8')
    start = text.index('ST_DDREP: begin')
    block = text[start:text.index('ST_WEIGHT: begin', start)]
    # exactly one fire site per line
    assert len(re.findall(r"dbg_line_fire\s*<=\s*1'b1;", block)) == 2, block
    # the result line is gated by !dbg_busy, the STS line by an observed
    # busy window (rom_pending rises one edge after the result fire, so
    # !dbg_busy alone would still be true on the following cycle)
    assert 'if (!dbg_busy)' in block
    assert 'if (dbg_busy)' in block
    assert 'ddr_result_sent && !ddr_sts_sent' in block
    assert 'ddr_sts_armed' in block
    # the result line ids are no longer fired from ST_DDW
    ddw_start = text.index('ST_DDW: begin')
    ddw = text[ddw_start:text.index('ST_DDREP: begin', ddw_start)]
    assert "dbg_line_fire <= 1'b1;" not in ddw, (
        'ST_DDW must latch only; the line is fired from ST_DDREP')
    # reset clears every report flag (the FSM always block's async branch;
    # the CDC blocks have their own if (!rst_n) begin earlier in the file)
    fsm_rst = text.index("            state        <= ST_BOOT;")
    rst_start = text.rindex("if (!rst_n) begin", 0, fsm_rst)
    rst = text[rst_start:text.index("st_start     <= 1'b0;", fsm_rst)]
    for flag in ('ddr_result_pending', 'ddr_result_sent', 'ddr_sts_armed',
                 'ddr_sts_sent'):
        assert re.search(rf"{flag}\s*<=\s*1'b0;", rst), (
            f'{flag} is not cleared on reset')


def _rom_case_bytes(text: str, line_id: int) -> bytes:
    """Expand one ``3'dN: begin`` branch of rom_char() into its ASCII bytes."""
    start = text.index('function [7:0] rom_char;')
    rom = text[start:text.index('endfunction', start)]
    branch = rom[rom.index(f"3'd{line_id}: begin"):]
    branch = branch[:branch.index('endcase')]
    return bytes(int(h, 16) for h in
                 re.findall(r"5'd\d+:\s*rom_char = 8'h([0-9a-fA-F]{2});",
                            branch))


# The board-criteria strings printed by sys_ctrl. id 4 is a 10-byte prefix
# (the 8 hex digits and '\n' come from the ST_HEX/ST_EOL path), id 6 is a
# 9-byte prefix (2 hex digits + '\n' follow).
LEGACY_LINE_BYTES = {
    0: b'INSTREC BOOT\n',
    1: b'PLL LOCK ERR\n',
    2: b'DDR3 SELFTEST...\n',
    3: b'DDROK\n',
    4: b'DDR3 ERR @',
    5: b'RUN\n',
    6: b'DDR3 STS ',
}


def test_rtl_uart_debug_keeps_every_line_byte_exact():
    """id 0..5 must stay byte-identical so board_check --expect keeps working."""
    text = SRC_UART_DEBUG.read_text(encoding='utf-8')
    for line_id, expected in LEGACY_LINE_BYTES.items():
        got = _rom_case_bytes(text, line_id)
        assert got == expected, f'line id {line_id}: {got!r} != {expected!r}'


def test_rtl_uart_debug_knows_the_sts_line():
    text = SRC_UART_DEBUG.read_text(encoding='utf-8')
    assert 'LINE_DDRSTS' in text
    assert "localparam [2:0] LINE_ID_DDRSTS = 3'd6;" in text
    # 9-byte ASCII prefix followed by 2 hex digits and the newline
    assert re.search(r"""localparam LINE_DDRSTS\s*=\s*"DDR3 STS ";""", text)
    assert re.search(r"localparam \[4:0\] LINE_LEN_DDRSTS\s*=\s*5'd9;", text)
    # the 2-digit branch exists next to the 8-digit (id 4) branch
    assert "LINE_ID_DDRSTS &&" in text
    assert 'hex_left <= 4\'d2;' in text
    # only the low 8 bits of dbg_line_arg are used, shifted into the top
    # nibble pair so the shared MSB-first shifter emits 2 digits
    assert "{dbg_line_arg[7:0], 24'd0}" in text
    # the ROM text is a plain ASCII case table (the project convention)
    assert _rom_case_bytes(text, 6) == b'DDR3 STS '
    # and id 6 is routed to ST_HEX (2 nibbles), not left on the RUN default
    assert re.search(r"rom_len\s*=\s*LINE_LEN_DDRSTS", text)


def test_rtl_top_connects_the_ddr3_diagnostic_taps():
    text = SRC_TOP.read_text(encoding='utf-8')
    inst = text[text.index('sys_ctrl u_sys_ctrl ('):]
    inst = inst[:inst.index(');')]
    for port, net in (('ddr_dbg_to_state', 'ddr_dbg_to_state'),
                      ('ddr_to_err', 'ddr_to_err'),
                      ('ddr_cmd_to_err', 'ddr_cmd_to_err')):
        assert re.search(rf'\.{port}\s*\(\s*{net}\s*\)', inst), (
            f'{port} is not connected in instrec_top')