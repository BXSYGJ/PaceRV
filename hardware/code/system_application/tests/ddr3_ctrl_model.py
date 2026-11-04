"""Cycle-accurate executable specification of ddr3_ctrl_axi + ddr3_arbiter.

S6 verdict: single-cycle cmd_valid is safe for writes only; reads MUST hold cmd_valid until done.

One `Ddr3CtrlAxiModel.cycle()` call advances exactly one core_clk cycle. Every
register of src/ddr3/ddr3_ctrl_axi.v has a field of the same name, and the
combinational outputs are evaluated in the same order the RTL implies. RTL
anchors (line numbers refer to the delivered sources):

    state / cur_* / beat_cnt / wlast_*     ddr3_ctrl_axi.v:137-150
    read fifo (16 x 256, wr/rd ptr/count)  ddr3_ctrl_axi.v:152-157
    fifo_empty, in-flight valid masking    ddr3_ctrl_axi.v:166-175
    arb_en (read grant needs empty fifo)   ddr3_ctrl_axi.v:179
    IP-side outputs (aw/w/ar, wstrb)       ddr3_ctrl_axi.v:206-224
    wready_beat                            ddr3_ctrl_axi.v:231-232
    rd_fifo_pop / rd_valid / rd_data       ddr3_ctrl_axi.v:235-243
    write_cmpl / read_cmpl / done          ddr3_ctrl_axi.v:247-252
    sequential body                        ddr3_ctrl_axi.v:265-456
    read fifo push/pop                     ddr3_ctrl_axi.v:285-299
    wusero_last epilogue                   ddr3_ctrl_axi.v:302-314
    watchdog accumulator                   ddr3_ctrl_axi.v:317-323
    FSM case                               ddr3_ctrl_axi.v:326-454
    arbiter select / quota / grant         ddr3_arbiter.v:91-122
    arbiter wait / starve / addr_err       ddr3_arbiter.v:151-200

Semantics fixed by this model (plan file section 2.2.1, table S1..S7):

    S1  write completion is a combinational pulse on the last accepted beat
        (`write_cmpl`, not a registered `done_q`).
    S2  `wready_beat` is one-hot to the command owner, produced on every
        accepted `S_W` beat; the 16th pulse is the same cycle as `done`.
    S3  each handshake phase carries a 4096-cycle watchdog
        (`S_AW/S_W/S_DW_AW/S_DW_W/S_AR`, plus `S_R` while `!rvalid`); the
        abort pulses `done` to `cur_master`, latches `to_err`/`cmd_to_err`
        and records the phase in `dbg_to_state`.
    S4  read completion is `(state == S_R) && rvalid && rlast`.
    S5  the push cycle does not update `rd_fifo_count`, so when the fifo was
        empty the `rlast` cycle shows `rd_valid == 0` and the next cycle
        shows `rd_valid == 1 << cur_rd_master` with the correct head data.
    S6  `arb_en = (state == S_IDLE) && (grant_wr || fifo_empty)`; a read
        grant needs an empty fifo, so a single-cycle read `cmd_valid` is
        dropped while the fifo drains (writes are unaffected).
    S7  `cur_rd_master` only changes on a read grant; after a read timeout
        abort the leftover fifo beats keep routing to the old read master.

CycleOutput contract: the pulse/level fields (`done`, `wready_beat`,
`rd_valid`, `write_cmpl`, `read_cmpl`, `to_abort`, the `axi_*` outputs) are
the combinational values of the cycle that was just driven, while `state`,
`beat_cnt`, `axi_to_cnt`, `rd_fifo_count`, `to_err`, `cmd_to_err`,
`dbg_to_state`, `cur_*`, `wait_cnt`, `p3_starve_cnt` and `addr_err` are the
register values after the clock edge.
"""

from __future__ import annotations

from dataclasses import dataclass

# --------------------------------------------------------------------------- #
# Constants (must match the RTL parameters / localparams)
# --------------------------------------------------------------------------- #

# FSM state encoding, ddr3_ctrl_axi.v:125-132.
S_IDLE = 0
S_AW = 1
S_W = 2
S_WLAST = 3
S_DW_AW = 4
S_DW_W = 5
S_AR = 6
S_R = 7
S_R_DRAIN = 8

STATE_NAME = {
    S_IDLE: 'S_IDLE',
    S_AW: 'S_AW',
    S_W: 'S_W',
    S_WLAST: 'S_WLAST',
    S_DW_AW: 'S_DW_AW',
    S_DW_W: 'S_DW_W',
    S_AR: 'S_AR',
    S_R: 'S_R',
    S_R_DRAIN: 'S_R_DRAIN',
}

AXI_TO_LIMIT = 4096                 # ddr3_ctrl_axi.v:64
P3_QUOTA_TIMEOUT = 125000           # ddr3_ctrl_axi.v:66 (1 ms at 125 MHz)
RD_FIFO_DEPTH = 16                 # ddr3_ctrl_axi.v:153
BURST_LEN = 15                      # beats - 1 (512 B per command)
MASK_28 = (1 << 28) - 1
MASK_256 = (1 << 256) - 1
DUMMY_WSTRB_MASKED = 0x00000000     # DUMMY_WSTRB_ALL1 = 0
DUMMY_WSTRB_ALL1_VALUE = 0xFFFFFFFF  # DUMMY_WSTRB_ALL1 = 1

# Design doc section 5.1 windows, mirrored by ddr3_arbiter.v:135-139.
REGIONS = (
    (0x000000, 0x083FFF),   # PCM left ring buffer
    (0x084000, 0x0C5FFF),   # PCM right archive
    (0x100000, 0x1B7FFF),   # weight mirror
    (0x200000, 0x20FFFF),   # log2-spectrum export
    (0x300000, 0x30FFFF),   # self-test pattern
)


# --------------------------------------------------------------------------- #
# Command bundle helpers ({wr(1), addr[27:0], len[7:0]} = 37 bits)
# --------------------------------------------------------------------------- #

def pack_cmd(wr, addr, length):
    """Pack the 37-bit upstream command bundle."""
    return ((1 if wr else 0) << 36) | ((addr & MASK_28) << 8) | (length & 0xFF)


def cmd_wr(cmd):
    return (cmd >> 36) & 0x1


def cmd_addr(cmd):
    return (cmd >> 8) & MASK_28


def cmd_len(cmd):
    return cmd & 0xFF


def addr_legal(addr, length):
    """Arbiter region/alignment/length check (ddr3_arbiter.v:135-144)."""
    if addr & 0x1F:                  # 32-byte alignment
        return False
    if length > BURST_LEN:           # 16-beat maximum burst
        return False
    return any(lo <= addr <= hi for lo, hi in REGIONS)


def onehot_index(bits):
    """Return the index of the single set bit of a one-hot value."""
    if not bits:
        return None
    if bits & (bits - 1):
        raise AssertionError(f'value 0x{bits:X} is not one-hot')
    return bits.bit_length() - 1


# --------------------------------------------------------------------------- #
# IP-side (module input) signals for one cycle
# --------------------------------------------------------------------------- #

class IpSignals:
    """DDR3 user-port inputs driven by the IP stub for a single cycle."""

    __slots__ = ('awready', 'wready', 'arready', 'rvalid', 'rdata', 'rlast',
                 'wusero_last')

    def __init__(self, awready=0, wready=0, arready=0, rvalid=0, rdata=0,
                 rlast=0, wusero_last=0):
        self.awready = awready
        self.wready = wready
        self.arready = arready
        self.rvalid = rvalid
        self.rdata = rdata
        self.rlast = rlast
        self.wusero_last = wusero_last


def _ip_signals(ip, model):
    """Accept None, a callable or an object exposing `.signals(model)`."""
    if ip is None:
        return IpSignals()
    handler = getattr(ip, 'signals', None)
    if handler is not None:
        return handler(model)
    return ip(model)


# --------------------------------------------------------------------------- #
# Per-cycle observation record
# --------------------------------------------------------------------------- #

@dataclass(frozen=True)
class CycleOutput:
    """Outputs and post-edge register values of one core_clk cycle."""

    cycle: int
    state_before: int
    state: int
    done: int
    write_cmpl: bool
    read_cmpl: bool
    to_abort: bool
    wready_beat: int
    rd_valid: int
    rd_data: int
    axi_awvalid: bool
    axi_awaddr: int
    axi_awlen: int
    axi_awuser_id: int
    axi_awuser_ap: int
    axi_wdata: int
    axi_wstrb: int
    axi_arvalid: bool
    axi_araddr: int
    axi_arlen: int
    axi_aruser_id: int
    axi_aruser_ap: int
    grant: int
    grant_wr: bool
    arb_en: bool
    beat_cnt: int
    rd_fifo_count: int
    axi_to_cnt: int
    to_err: int
    cmd_to_err: tuple
    dbg_to_state: int
    cur_master: int
    cur_rd_master: int
    cur_wr: int
    cur_addr: int
    cur_len: int
    wlast_window: int
    wlast_miss_cnt: int
    wait_cnt: tuple
    p3_starve_cnt: int
    addr_err: tuple


# --------------------------------------------------------------------------- #
# Arbiter model (1:1 with ddr3_arbiter.v)
# --------------------------------------------------------------------------- #

class Ddr3ArbiterModel:
    """Fixed-priority arbiter with the P3 starvation quota.

    Mirrors ddr3_arbiter.v:91-122 (combinational selection, grant gated by
    arb_en) and :151-200 (wait counters, saturating P3 starve counter,
    sticky addr_err).
    """

    def __init__(self, p3_quota_timeout=P3_QUOTA_TIMEOUT):
        self.p3_quota_timeout = p3_quota_timeout
        self.wait_cnt = [0, 0, 0, 0]
        self.p3_starve_cnt = 0
        self.addr_err = [0, 0, 0, 0]

    def select(self, arb_valid):
        """Combinational one-hot selection (ddr3_arbiter.v:94-109)."""
        if self.p3_starve_cnt >= self.p3_quota_timeout and arb_valid[3]:
            return 3
        for i in range(4):
            if arb_valid[i]:
                return i
        return None

    def advance(self, arb_valid, grant, cmds):
        """Register updates of one clock edge (ddr3_arbiter.v:159-198)."""
        for i in range(4):
            if arb_valid[i] and grant != i:
                self.wait_cnt[i] += 1
            else:
                self.wait_cnt[i] = 0
        if arb_valid[3] and grant != 3:
            if self.p3_starve_cnt < self.p3_quota_timeout:
                self.p3_starve_cnt += 1
        else:
            self.p3_starve_cnt = 0
        if grant is not None and not addr_legal(cmd_addr(cmds[grant]),
                                                cmd_len(cmds[grant])):
            self.addr_err[grant] = 1

    def step(self, arb_valid, cmds, arb_en):
        """One arbiter cycle; returns the granted master index or None."""
        sel = self.select(arb_valid)
        grant = sel if (arb_en and sel is not None) else None
        self.advance(arb_valid, grant, cmds)
        return grant


# --------------------------------------------------------------------------- #
# Controller model (1:1 with ddr3_ctrl_axi.v)
# --------------------------------------------------------------------------- #

class Ddr3CtrlAxiModel:
    """Cycle-accurate model of the DDR3 AXI front end.

    FSM: IDLE -> (write) AW -> W -> WLAST(4) -> IDLE
                (read)  DW_AW -> DW_W -> AR -> R -> IDLE

    `cycle()` drives one core_clk cycle and returns a `CycleOutput`. The
    accepted AXI transactions are appended to `aw_handshakes`, `w_beats`,
    `ar_handshakes` and `r_beats` so tests can assert the datapath order.
    """

    def __init__(self, dummy_wstrb_all1=False, axi_user_ap=True,
                 axi_to_limit=AXI_TO_LIMIT,
                 p3_quota_timeout=P3_QUOTA_TIMEOUT):
        self.dummy_wstrb_all1 = dummy_wstrb_all1
        self.axi_user_ap = axi_user_ap
        self.axi_to_limit = axi_to_limit
        self.dummy_strb = (DUMMY_WSTRB_ALL1_VALUE if dummy_wstrb_all1
                           else DUMMY_WSTRB_MASKED)
        self.arb = Ddr3ArbiterModel(p3_quota_timeout)

        # Command registers, ddr3_ctrl_axi.v:137-150.
        self.state = S_IDLE
        self.cur_wr = 0
        self.cur_addr = 0
        self.cur_len = 0
        self.cur_master = 0
        self.cur_rd_master = 0
        self.beat_cnt = 0
        self.wlast_window = 0
        self.wlast_seen = False
        self.axi_to_cnt = 0
        self.to_err = 0
        self.cmd_to_err = [0, 0, 0, 0]
        self.dbg_to_state = 0
        self.wlast_miss_cnt = 0

        # 16 x 256 elastic read fifo, ddr3_ctrl_axi.v:152-157.
        self.rd_fifo_mem = [0] * RD_FIFO_DEPTH
        self.rd_fifo_wr_ptr = 0
        self.rd_fifo_rd_ptr = 0
        self.rd_fifo_count = 0

        # Observation logs (accepted transactions only).
        self.aw_handshakes = []      # (cycle, addr, len, master, ap)
        self.w_beats = []            # (cycle, addr, data, wstrb, dummy, master)
        self.ar_handshakes = []      # (cycle, addr, len, master)
        self.r_beats = []            # (cycle, data, rlast)
        self.done_log = []           # (cycle, master, write_cmpl, read_cmpl, to_abort)
        self.cycle_idx = 0

    # -- read fifo head ------------------------------------------------ #

    @property
    def rd_fifo_head(self):
        return self.rd_fifo_mem[self.rd_fifo_rd_ptr]

    # -- one core_clk cycle -------------------------------------------- #

    def cycle(self, cmd_valid=None, cmds=None, wdata=None, rd_ready=None,
              ip=None):
        """Drive one core_clk cycle.

        cmd_valid : 4 upstream request lines (held until done per protocol)
        cmds      : 4 packed 37-bit command bundles
        wdata     : 4 upstream 256-bit write beat payloads
        rd_ready  : 4 upstream read pacing lines
        ip        : None (all inputs low), a callable, or an object with
                    `.signals(model)` returning `IpSignals`
        """
        if cmd_valid is None:
            cmd_valid = (0, 0, 0, 0)
        if cmds is None:
            cmds = (0, 0, 0, 0)
        if wdata is None:
            wdata = (0, 0, 0, 0)
        if rd_ready is None:
            rd_ready = (0, 0, 0, 0)

        sig = _ip_signals(ip, self)
        st = self.state
        cycle_idx = self.cycle_idx

        # ---- combinational: in-flight masking + arbitration ----------- #
        # ddr3_ctrl_axi.v:173-175
        busy = st != S_IDLE
        arb_valid = tuple(bool(cmd_valid[i]) and not (busy and self.cur_master == i)
                          for i in range(4))
        # ddr3_arbiter.v:91-112
        sel = self.arb.select(arb_valid)
        grant_wr = cmd_wr(cmds[sel]) if sel is not None else cmd_wr(cmds[3])
        fifo_empty = self.rd_fifo_count == 0
        # ddr3_ctrl_axi.v:179
        arb_en = (st == S_IDLE) and (bool(grant_wr) or fifo_empty)
        grant = sel if (arb_en and sel is not None) else None

        # ---- combinational: IP-side outputs -------------------------- #
        # ddr3_ctrl_axi.v:206-224
        axi_awvalid = st in (S_AW, S_DW_AW)
        axi_awaddr = self.cur_addr
        axi_awlen = 0 if st == S_DW_AW else (self.cur_len & 0xF)
        axi_awuser_id = self.cur_master
        axi_wdata = (0 if st == S_DW_W
                     else (wdata[self.cur_master] & MASK_256))
        axi_wstrb = self.dummy_strb if st == S_DW_W else 0xFFFFFFFF
        axi_arvalid = st == S_AR
        axi_araddr = self.cur_addr
        axi_arlen = self.cur_len & 0xF
        axi_aruser_id = self.cur_master

        # ---- combinational: upstream-facing outputs ------------------ #
        # ddr3_ctrl_axi.v:231-232
        wready_beat = (1 << self.cur_master) if (st == S_W and sig.wready) else 0
        # ddr3_ctrl_axi.v:235-243
        fifo_pop = self.rd_fifo_count != 0 and bool(rd_ready[self.cur_rd_master])
        rd_valid = (1 << self.cur_rd_master) if self.rd_fifo_count != 0 else 0
        rd_data = self.rd_fifo_head
        # ddr3_ctrl_axi.v:247-252
        write_cmpl = (st == S_W and bool(sig.wready) and
                      self.beat_cnt == (self.cur_len & 0xF))
        read_cmpl = (st == S_R and bool(sig.rvalid) and bool(sig.rlast))
        to_abort = (self.axi_to_cnt >= self.axi_to_limit and
                    st not in (S_IDLE, S_WLAST, S_R_DRAIN))
        done_pulse = write_cmpl or read_cmpl or to_abort
        done = (1 << self.cur_master) if done_pulse else 0

        # ---- accepted AXI transactions of this cycle ----------------- #
        if axi_awvalid and sig.awready:
            self.aw_handshakes.append(
                (cycle_idx, axi_awaddr, axi_awlen, self.cur_master,
                 int(bool(self.axi_user_ap))))
        if st in (S_W, S_DW_W) and sig.wready:
            self.w_beats.append((cycle_idx, self.cur_addr, axi_wdata, axi_wstrb,
                                 st == S_DW_W, self.cur_master))
        if axi_arvalid and sig.arready:
            self.ar_handshakes.append(
                (cycle_idx, axi_araddr, axi_arlen, self.cur_master))
        if st == S_R and sig.rvalid:
            self.r_beats.append((cycle_idx, int(sig.rdata) & MASK_256,
                                 bool(sig.rlast)))
        if done_pulse:
            self.done_log.append((cycle_idx, self.cur_master, write_cmpl,
                                  read_cmpl, to_abort))

        # ---- sequential: read fifo push/pop (v:285-299) -------------- #
        push = (st == S_R) and bool(sig.rvalid)
        next_mem = self.rd_fifo_mem
        if push:
            next_mem = list(self.rd_fifo_mem)
            next_mem[self.rd_fifo_wr_ptr] = int(sig.rdata) & MASK_256
        wr_ptr = ((self.rd_fifo_wr_ptr + 1) & (RD_FIFO_DEPTH - 1)
                  if push else self.rd_fifo_wr_ptr)
        rd_ptr = ((self.rd_fifo_rd_ptr + 1) & (RD_FIFO_DEPTH - 1)
                  if fifo_pop else self.rd_fifo_rd_ptr)
        if push and not fifo_pop:
            count = self.rd_fifo_count + 1
        elif fifo_pop and not push:
            count = self.rd_fifo_count - 1
        else:
            count = self.rd_fifo_count
        if count > RD_FIFO_DEPTH:
            raise AssertionError(
                f'read fifo overflow at cycle {cycle_idx}: count={count}')

        # ---- sequential: wusero_last epilogue (v:302-314) ------------ #
        state = st
        wlast_window = self.wlast_window
        wlast_seen = self.wlast_seen
        wlast_miss_cnt = self.wlast_miss_cnt
        if st == S_WLAST:
            if sig.wusero_last:
                wlast_seen = True
            if self.wlast_window == 3:
                if not self.wlast_seen and not sig.wusero_last:
                    wlast_miss_cnt += 1
                state = S_IDLE
            else:
                wlast_window = self.wlast_window + 1

        # ---- sequential: watchdog accumulator (v:317-323) ------------ #
        if st in (S_AW, S_W, S_DW_AW, S_DW_W, S_AR) or (st == S_R and not sig.rvalid):
            axi_to_cnt = self.axi_to_cnt + 1
        else:
            axi_to_cnt = 0

        # ---- sequential: main FSM (v:326-454) ------------------------ #
        cur_wr = self.cur_wr
        cur_addr = self.cur_addr
        cur_len = self.cur_len
        cur_master = self.cur_master
        cur_rd_master = self.cur_rd_master
        beat_cnt = self.beat_cnt
        to_err = self.to_err
        cmd_to_err = list(self.cmd_to_err)
        dbg_to_state = self.dbg_to_state
        timeout = self.axi_to_cnt >= self.axi_to_limit

        if st == S_IDLE:
            if grant is not None:
                cur_wr = cmd_wr(cmds[grant])
                cur_addr = cmd_addr(cmds[grant])
                cur_len = cmd_len(cmds[grant])
                cur_master = grant
                if not cur_wr:
                    # S7: fifo drain owner follows the read grant only.
                    cur_rd_master = grant
                beat_cnt = 0
                axi_to_cnt = 0
                wlast_seen = False
                wlast_window = 0
                state = S_AW if cur_wr else S_DW_AW
        elif st == S_AW:
            if sig.awready:
                axi_to_cnt = 0
                state = S_W
            elif timeout:
                to_err = 1
                cmd_to_err[cur_master] = 1
                dbg_to_state = S_AW
                state = S_IDLE
        elif st == S_W:
            if sig.wready:
                axi_to_cnt = 0
                beat_cnt = (self.beat_cnt + 1) & 0xF
                if self.beat_cnt == (self.cur_len & 0xF):
                    wlast_window = 0
                    wlast_seen = False
                    state = S_WLAST
            elif timeout:
                to_err = 1
                cmd_to_err[cur_master] = 1
                dbg_to_state = S_W
                state = S_IDLE
        elif st == S_DW_AW:
            if sig.awready:
                axi_to_cnt = 0
                state = S_DW_W
            elif timeout:
                to_err = 1
                cmd_to_err[cur_master] = 1
                dbg_to_state = S_DW_AW
                state = S_IDLE
        elif st == S_DW_W:
            if sig.wready:
                axi_to_cnt = 0
                state = S_AR
            elif timeout:
                to_err = 1
                cmd_to_err[cur_master] = 1
                dbg_to_state = S_DW_W
                state = S_IDLE
        elif st == S_AR:
            if sig.arready:
                axi_to_cnt = 0
                state = S_R
            elif timeout:
                to_err = 1
                cmd_to_err[cur_master] = 1
                dbg_to_state = S_AR
                state = S_IDLE
        elif st == S_R:
            if sig.rvalid:
                axi_to_cnt = 0
                if sig.rlast:
                    state = S_IDLE
            elif timeout:
                to_err = 1
                cmd_to_err[cur_master] = 1
                dbg_to_state = S_R
                # Keep the AXI port quarantined so a late response cannot be
                # mistaken for the next read transaction.
                state = S_R_DRAIN
        elif st == S_R_DRAIN:
            # Late beats are discarded; RLAST releases the quarantine.
            if sig.rvalid and sig.rlast:
                state = S_IDLE
        elif st == S_WLAST:
            if self.wlast_window == 3:
                state = S_IDLE
        else:
            state = S_IDLE

        # ---- sequential: arbiter counters (ddr3_arbiter.v:159-198) --- #
        self.arb.advance(arb_valid, grant, cmds)

        # ---- commit register updates --------------------------------- #
        self.rd_fifo_mem = next_mem
        self.rd_fifo_wr_ptr = wr_ptr
        self.rd_fifo_rd_ptr = rd_ptr
        self.rd_fifo_count = count
        self.state = state
        self.cur_wr = cur_wr
        self.cur_addr = cur_addr
        self.cur_len = cur_len
        self.cur_master = cur_master
        self.cur_rd_master = cur_rd_master
        self.beat_cnt = beat_cnt
        self.wlast_window = wlast_window
        self.wlast_seen = wlast_seen
        self.wlast_miss_cnt = wlast_miss_cnt
        self.axi_to_cnt = axi_to_cnt
        self.to_err = to_err
        self.cmd_to_err = cmd_to_err
        self.dbg_to_state = dbg_to_state
        self.cycle_idx += 1

        # ---- notify the IP stub of write completion (side evidence) - #
        if write_cmpl:
            note = getattr(ip, 'note_write_done', None)
            if note is not None:
                note()
        return CycleOutput(
            cycle=cycle_idx,
            state_before=st,
            state=self.state,
            done=done,
            write_cmpl=write_cmpl,
            read_cmpl=read_cmpl,
            to_abort=to_abort,
            wready_beat=wready_beat,
            rd_valid=rd_valid,
            rd_data=rd_data,
            axi_awvalid=axi_awvalid,
            axi_awaddr=axi_awaddr,
            axi_awlen=axi_awlen,
            axi_awuser_id=axi_awuser_id,
            axi_awuser_ap=int(bool(self.axi_user_ap)),
            axi_wdata=axi_wdata,
            axi_wstrb=axi_wstrb,
            axi_arvalid=axi_arvalid,
            axi_araddr=axi_araddr,
            axi_arlen=axi_arlen,
            axi_aruser_id=axi_aruser_id,
            axi_aruser_ap=int(bool(self.axi_user_ap)),
            grant=0 if grant is None else (1 << grant),
            grant_wr=bool(grant_wr),
            arb_en=arb_en,
            beat_cnt=self.beat_cnt,
            rd_fifo_count=self.rd_fifo_count,
            axi_to_cnt=self.axi_to_cnt,
            to_err=self.to_err,
            cmd_to_err=tuple(self.cmd_to_err),
            dbg_to_state=self.dbg_to_state,
            cur_master=self.cur_master,
            cur_rd_master=self.cur_rd_master,
            cur_wr=self.cur_wr,
            cur_addr=self.cur_addr,
            cur_len=self.cur_len,
            wlast_window=self.wlast_window,
            wlast_miss_cnt=self.wlast_miss_cnt,
            wait_cnt=tuple(self.arb.wait_cnt),
            p3_starve_cnt=self.arb.p3_starve_cnt,
            addr_err=tuple(self.arb.addr_err),
        )


# --------------------------------------------------------------------------- #
# Deterministic IP-side stub
# --------------------------------------------------------------------------- #

class ReadyIp:
    """DDR3 user-port behaviour stub used by the contract tests.

    `never` selects phases that stay un-ready (`'aw'` covers S_AW and S_DW_AW,
    `'w'` covers S_W and S_DW_W). Read beats stream one per `rvalid_every`
    cycles starting `r_start_latency` cycles into S_R, with `rlast` on the
    programmed final beat unless `rlast_enable` is False. `r_valid_budget`
    caps the number of read beats (partial-burst timeouts). `signals()` is
    stateful and must be called exactly once per cycle (the model does so).
    """

    def __init__(self, aw_latency=0, w_latency=0, ar_latency=0,
                 r_start_latency=1, rvalid_every=1, r_valid_budget=None,
                 never=(), rlast_enable=True, wusero_last_delay=1,
                 r_data_base=0x10000000):
        self.aw_latency = aw_latency
        self.w_latency = w_latency
        self.ar_latency = ar_latency
        self.r_start_latency = r_start_latency
        self.rvalid_every = rvalid_every
        self.r_valid_budget = r_valid_budget
        self.never = set(never)
        self.rlast_enable = rlast_enable
        self.wusero_last_delay = wusero_last_delay
        self.r_data_base = r_data_base
        self._state = None
        self._in_stage = 0
        self._r_beat = 0
        self._r_valid_sent = 0
        self._wlast_left = None

    def signals(self, model):
        st = model.state
        if st != self._state:
            self._state = st
            self._in_stage = 0
            if st == S_R:
                self._r_beat = 0
                self._r_valid_sent = 0
        else:
            self._in_stage += 1

        awready = int(st in (S_AW, S_DW_AW) and 'aw' not in self.never
                      and self._in_stage >= self.aw_latency)
        wready = int(st in (S_W, S_DW_W) and 'w' not in self.never
                     and self._in_stage >= self.w_latency)
        arready = int(st == S_AR and 'ar' not in self.never
                      and self._in_stage >= self.ar_latency)

        rvalid = 0
        rdata = 0
        rlast = 0
        if (st == S_R and 'r' not in self.never
                and self._in_stage >= self.r_start_latency):
            budget_ok = (self.r_valid_budget is None or
                         self._r_valid_sent < self.r_valid_budget)
            slot = (self._in_stage - self.r_start_latency)
            if budget_ok and slot % self.rvalid_every == 0:
                rvalid = 1
        if rvalid:
            rdata = self.r_data_base + self._r_beat
            if self.rlast_enable and self._r_beat == (model.cur_len & 0xF):
                rlast = 1
            self._r_beat += 1
            self._r_valid_sent += 1

        wusero_last = 0
        if self._wlast_left is not None:
            if self._wlast_left == 0:
                wusero_last = 1
                self._wlast_left = None
            else:
                self._wlast_left -= 1

        return IpSignals(awready=awready, wready=wready, arready=arready,
                         rvalid=rvalid, rdata=rdata, rlast=rlast,
                         wusero_last=wusero_last)

    def note_write_done(self):
        self._wlast_left = self.wusero_last_delay
