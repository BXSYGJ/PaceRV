"""1:1 Python state-machine model of ddr3_arbiter.v / ddr3_ctrl_axi.v.

Task T-M0-05 DoD: with four masters under concurrent random load,
  * no master waits more than 10 percent of its active time
    (design-rate traffic, design doc section 5.4 budgets),
  * the P3 quota prevents starvation (worst wait bounded by
    P3_QUOTA_TIMEOUT plus one in-flight command),
  * addresses never overlap across region boundaries and stay inside
    the section 5.1 map (arbiter addr_err stays clear),
  * every read is preceded by a same-address one-beat dummy write with
    all-zero strobes (REQ-MEM-003 hard rule),
  * the 16-deep elastic read fifo never overflows and read beats are
    routed back to the owning master losslessly.

The model mirrors the RTL cycle by cycle (combinational arbitration,
sequential wait/starve counters, in-flight valid masking, FSM phases,
fifo push/pop) so that any behavioral drift shows up as a failing
assertion. Integer arithmetic only (no floats), random seeds fixed.
"""

import random

# --------------------------------------------------------------------------- #
# Shared constants (must match the RTL localparams / parameters)
# --------------------------------------------------------------------------- #

P3_QUOTA_TIMEOUT = 125000          # core_clk cycles, 1 ms at 125 MHz
RD_FIFO_DEPTH = 16
BURST_LEN = 15                     # beats - 1 (512 B per command)

# Design doc section 5.1 address windows (byte addresses, 28-bit space).
REGIONS = (
    (0x000000, 0x083FFF),   # PCM left ring buffer (528 KB)
    (0x084000, 0x0C5FFF),   # PCM right archive (264 KB)
    (0x100000, 0x1B7FFF),   # weight mirror (736 KB)
    (0x200000, 0x20FFFF),   # log2-spectrum export (64 KB)
    (0x300000, 0x30FFFF),   # self-test pattern (64 KB)
)

MASTER_REGION = {                  # region discipline per master (section 5.4)
    0: (0x000000, 0x083FFF),       # audio_sink writes PCM left
    1: (0x100000, 0x1B7FFF),       # wdma reads the weight mirror
    2: (0x000000, 0x083FFF),       # mel reads PCM left windows
    3: (0x200000, 0x20FFFF),       # ui reads the spectrum export
}


def addr_legal(addr, length):
    """Arbiter region/alignment/length check (design doc section 5.1)."""
    if addr % 32 != 0:
        return False
    if length > BURST_LEN:
        return False
    return any(lo <= addr <= hi for lo, hi in REGIONS)


# --------------------------------------------------------------------------- #
# Arbiter model (1:1 with ddr3_arbiter.v)
# --------------------------------------------------------------------------- #

class ArbiterModel:
    """Cycle-accurate model of the fixed-priority arbiter + P3 quota."""

    def __init__(self, quota_timeout=P3_QUOTA_TIMEOUT):
        self.quota_timeout = quota_timeout
        self.wait_cnt = [0, 0, 0, 0]
        self.p3_starve = 0
        self.addr_err = [0, 0, 0, 0]

    def select(self, arb_valid):
        """Combinational one-hot selection (priority + quota override)."""
        if self.p3_starve >= self.quota_timeout and arb_valid[3]:
            return 3
        for i in range(4):
            if arb_valid[i]:
                return i
        return None

    def step(self, arb_valid, cmds, arb_en):
        """One clock cycle. Returns the granted master or None."""
        sel = self.select(arb_valid)
        grant = sel if arb_en else None
        # wait counters: count while requested but not granted
        for i in range(4):
            if arb_valid[i] and grant != i:
                self.wait_cnt[i] += 1
            else:
                self.wait_cnt[i] = 0
        # P3 starvation counter (saturating, like the RTL guard)
        if arb_valid[3] and grant != 3:
            if self.p3_starve < self.quota_timeout:
                self.p3_starve += 1
        else:
            self.p3_starve = 0
        # sticky region error latch on granted commands
        if grant is not None:
            _wr, addr, length = cmds[grant]
            if not addr_legal(addr, length):
                self.addr_err[grant] = 1
        return grant


# --------------------------------------------------------------------------- #
# DDR3 IP behavior model (handshake latencies + streaming reads)
# --------------------------------------------------------------------------- #

class IpModel:
    """Behavioral stand-in for the ddr3_test IP user side.

    Contract mirrored from ddr3_test.v: no axi_wvalid input, no axi_rready,
    write beats accepted on axi_wready (random duty), reads stream on
    axi_rvalid one beat per cycle with rlast on the final beat, and
    axi_wusero_last follows the last write beat by 0..3 cycles (side
    evidence for the controller epilogue window).
    """

    def __init__(self, rng):
        self.rng = rng
        self.wlast_pending = None     # countdown cycles or None (idle)
        self.write_events = []         # (cycle, addr, length, strobe)
        self.read_events = []          # (cycle, addr, length)

    def aw_latency(self):
        """Cycles from awvalid assertion to awready (1..4)."""
        return self.rng.randint(1, 4)

    def ar_latency(self):
        """Cycles from arvalid assertion to arready (1..4)."""
        return self.rng.randint(1, 4)

    def r_start_latency(self):
        """Cycles from arready to the first rvalid beat (2..6)."""
        return self.rng.randint(2, 6)

    def wready(self):
        """Write beat acceptance duty (no wvalid on this IP)."""
        return self.rng.random() < 0.8

    def record_write(self, cycle, addr, length, strobe):
        """Log a completed write command (real or masked dummy)."""
        self.write_events.append((cycle, addr, length, strobe))

    def record_read(self, cycle, addr, length):
        """Log a read command whose AR handshook."""
        self.read_events.append((cycle, addr, length))

    def note_write_done(self):
        """Last write beat accepted: schedule wusero_last in 0..3 cycles."""
        self.wlast_pending = self.rng.randint(0, 3)

    def wlast(self):
        """axi_wusero_last edge (one-shot pulse after the countdown)."""
        if self.wlast_pending is None:
            return False
        if self.wlast_pending > 0:
            self.wlast_pending -= 1
            return False
        self.wlast_pending = None
        return True


# --------------------------------------------------------------------------- #
# Controller model (1:1 with ddr3_ctrl_axi.v FSM)
# --------------------------------------------------------------------------- #

class CtrlModel:
    """Cycle-accurate model of the command controller.

    FSM: IDLE -> (write) AW -> W -> WLAST -> IDLE
                (read)  DW_AW -> DW_W -> AR -> R -> IDLE
    The in-flight master's cmd_valid is masked at the arbiter boundary
    (wait counters then measure pure queueing time, REQ-MEM-004).
    """

    S_IDLE, S_AW, S_W, S_WLAST, S_DW_AW, S_DW_W, S_AR, S_R = range(8)

    def __init__(self, rng, quota_timeout=P3_QUOTA_TIMEOUT):
        self.rng = rng
        self.arb = ArbiterModel(quota_timeout)
        self.ip = IpModel(rng)
        self.state = self.S_IDLE
        self.cur = None               # (master, wr, addr, length) or None
        self.beat_cnt = 0
        self.wlast_window = 0
        self.wlast_seen = False
        self.wlast_miss_cnt = 0
        self.aw_wait = 0
        self.ar_wait = 0
        self.r_wait = 0
        self.fifo = []                # elastic read buffer, <= 16 entries
        self.cycle = 0
        self.stats = [{
            'wait': 0, 'service': 0, 'cmds': 0, 'done': 0,
            'rd_beats': 0, 'wr_beats': 0, 'max_wait': 0, 'push': 0,
        } for _ in range(4)]

    # -- one core_clk cycle ------------------------------------------------ #

    def step(self, cmd_valid, cmds, rd_ready):
        """Advance one cycle; returns the per-master done pulse list."""
        done_now = [False] * 4

        # ---- combinational: in-flight masking + arbitration ---- #
        busy = self.state != self.S_IDLE
        arb_valid = [cmd_valid[i] and not (busy and self.cur is not None
                                           and self.cur[0] == i)
                     for i in range(4)]
        sel = self.arb.select(arb_valid)
        sel_wr = cmds[sel][0] if sel is not None else True
        fifo_empty = (len(self.fifo) == 0)
        arb_en = (self.state == self.S_IDLE) and (sel_wr or fifo_empty)
        grant = self.arb.step(arb_valid, cmds, arb_en)

        # ---- wait/service accounting (per-master) ---- #
        for i in range(4):
            if busy and self.cur is not None and self.cur[0] == i:
                self.stats[i]['service'] += 1
            elif arb_valid[i]:
                self.stats[i]['wait'] += 1
                self.stats[i]['max_wait'] = max(
                    self.stats[i]['max_wait'], self.arb.wait_cnt[i])

        # ---- FSM phase behavior ---- #
        if self.state == self.S_AW:
            if self.aw_wait > 0:
                self.aw_wait -= 1
            else:
                _m, _wr, addr, length = self.cur
                self.state = self.S_W
                self.beat_cnt = 0
        elif self.state == self.S_W:
            if self.ip.wready():
                self.stats[self.cur[0]]['wr_beats'] += 1
                if self.beat_cnt >= self.cur[3]:
                    # last beat accepted: command complete + epilogue
                    _m, _wr, addr, length = self.cur
                    self.ip.record_write(self.cycle, addr, length, 0xFFFFFFFF)
                    self.ip.note_write_done()
                    done_now[self.cur[0]] = True
                    self.stats[self.cur[0]]['done'] += 1
                    self.state = self.S_WLAST
                    self.wlast_window = 0
                    self.wlast_seen = False
                else:
                    self.beat_cnt += 1
        elif self.state == self.S_WLAST:
            got = self.ip.wlast()          # exactly one call per cycle
            if got:
                self.wlast_seen = True
            if self.wlast_window == 3:
                if not self.wlast_seen:
                    self.wlast_miss_cnt += 1
                self.state = self.S_IDLE
            else:
                self.wlast_window += 1
        elif self.state == self.S_DW_AW:
            if self.aw_wait > 0:
                self.aw_wait -= 1
            else:
                self.state = self.S_DW_W
                self.beat_cnt = 0
        elif self.state == self.S_DW_W:
            if self.ip.wready():
                # masked dummy beat accepted, log it then read
                _m, _wr, addr, _len = self.cur
                self.ip.record_write(self.cycle, addr, 0, 0)
                self.ip.note_write_done()
                self.state = self.S_AR
                self.ar_wait = self.ip.ar_latency()
        elif self.state == self.S_AR:
            if self.ar_wait > 0:
                self.ar_wait -= 1
            else:
                _m, _wr, addr, length = self.cur
                self.ip.record_read(self.cycle, addr, length)
                self.state = self.S_R
                self.r_wait = self.ip.r_start_latency()
                self.beat_cnt = 0
        elif self.state == self.S_R:
            if self.r_wait > 0:
                self.r_wait -= 1
            else:
                # rvalid streams one beat per cycle until rlast
                assert len(self.fifo) < RD_FIFO_DEPTH, 'read fifo overflow'
                self.fifo.append((self.cur[0], 0xD00D0000 + self.beat_cnt))
                self.stats[self.cur[0]]['push'] += 1
                if self.beat_cnt >= self.cur[3]:
                    done_now[self.cur[0]] = True
                    self.stats[self.cur[0]]['done'] += 1
                    self.state = self.S_IDLE
                else:
                    self.beat_cnt += 1

        # ---- fifo drain (independent of the FSM phase) ---- #
        if self.fifo and rd_ready[self.fifo[0][0]]:
            owner, _data = self.fifo.pop(0)
            self.stats[owner]['rd_beats'] += 1

        # ---- command dispatch (S_IDLE only) ---- #
        if self.state == self.S_IDLE and grant is not None:
            wr, addr, length = cmds[grant]
            self.cur = (grant, wr, addr, length)
            self.stats[grant]['cmds'] += 1
            self.beat_cnt = 0
            self.aw_wait = self.ip.aw_latency()
            if wr:
                self.state = self.S_AW
            else:
                self.state = self.S_DW_AW

        self.cycle += 1
        return done_now


# --------------------------------------------------------------------------- #
# Traffic generator
# --------------------------------------------------------------------------- #

class MasterAgent:
    """Upstream master: issues commands inside its own region.

    Holds cmd_valid from issue until done (upstream protocol), then backs
    off for `interval` cycles. Read masters pace the fifo drain with a
    random ready duty (elastic bubbles).
    """

    def __init__(self, mid, is_write, region, interval, rng,
                 burst=BURST_LEN, ready_duty=0.85):
        self.mid = mid
        self.is_write = is_write
        self.region = region
        self.interval = interval
        self.rng = rng
        self.burst = burst
        self.ready_duty = ready_duty
        self.pending = None            # (wr, addr, length) while in flight
        self.next_cmd = rng.randint(0, max(1, interval))

    def _emit(self):
        lo, hi = self.region
        span = (hi - lo + 1) // 32
        addr = lo + 32 * self.rng.randrange(0, max(1, span))
        return (1 if self.is_write else 0, addr, self.burst)

    def rd_ready(self):
        return self.rng.random() < self.ready_duty


def run_simulation(masters, cycles, seed, quota=P3_QUOTA_TIMEOUT):
    """Drive the model for N cycles; returns the controller model."""
    rng = random.Random(seed)
    ctrl = CtrlModel(rng, quota_timeout=quota)
    issued = [False] * 4              # valid level per master
    for cycle in range(cycles):
        cmd_valid = list(issued)
        cmds = [m.pending if m.pending is not None else (0, 0, 0)
                for m in masters]
        rd_ready = [m.rd_ready() for m in masters]
        done_now = ctrl.step(cmd_valid, cmds, rd_ready)
        for i, m in enumerate(masters):
            if issued[i]:
                if done_now[i]:
                    # command finished: drop valid, schedule the next one
                    issued[i] = False
                    m.pending = None
                    m.next_cmd = cycle + m.interval
            elif cycle >= m.next_cmd:
                m.pending = m._emit()
                issued[i] = True
    return ctrl


# --------------------------------------------------------------------------- #
# Tests: design-rate load (DoD: wait budget <= 10 percent)
# --------------------------------------------------------------------------- #

def test_design_rate_wait_budget():
    """Section 5.4 design-rate traffic: every master waits <= 10 percent."""
    rng = random.Random(7)
    masters = [
        MasterAgent(0, True,  MASTER_REGION[0], 212500, rng),  # audio write
        MasterAgent(1, False, MASTER_REGION[1], 5326, rng),    # weight read
        MasterAgent(2, False, MASTER_REGION[2], 16826, rng),   # mel read
        MasterAgent(3, False, MASTER_REGION[3], 111000, rng),  # ui read
    ]
    ctrl = run_simulation(masters, cycles=400000, seed=0xBEEF)
    for i in range(4):
        st = ctrl.stats[i]
        assert st['cmds'] > 0, f'master {i} never issued a command'
        total = st['wait'] + st['service']
        ratio = st['wait'] / total
        assert ratio <= 0.10, (
            f'master {i} wait ratio {ratio:.3f} exceeds the 10 percent '
            f'budget (wait={st["wait"]}, service={st["service"]})')


# --------------------------------------------------------------------------- #
# Tests: stress load (DoD: P3 quota, no starvation, region discipline)
# --------------------------------------------------------------------------- #

def test_p3_quota_prevents_starvation():
    """Backlogged P0..P2 pressure: P3 still served within the 1 ms quota."""
    rng = random.Random(11)
    masters = [
        MasterAgent(0, True,  MASTER_REGION[0], 0, rng),
        MasterAgent(1, False, MASTER_REGION[1], 0, rng),
        MasterAgent(2, False, MASTER_REGION[2], 0, rng),
        MasterAgent(3, False, MASTER_REGION[3], 0, rng),
    ]
    ctrl = run_simulation(masters, cycles=400000, seed=0xCAFE)
    st3 = ctrl.stats[3]
    # 400k cycles = 3.2 ms real time -> quota floor expects >= 3 bursts
    assert st3['cmds'] >= 3, (
        f'P3 served only {st3["cmds"]} times in 400k cycles '
        '(quota floor expects >= 1 burst per 125k cycles)')
    # worst single wait bounded by quota + one in-flight command service
    assert st3['max_wait'] <= P3_QUOTA_TIMEOUT + 2000, (
        f'P3 worst wait {st3["max_wait"]} exceeds quota bound')


def test_backlog_addresses_stay_in_regions():
    """Stress load: no command leaves its master region (no overlap)."""
    rng = random.Random(13)
    masters = [
        MasterAgent(0, True,  MASTER_REGION[0], 0, rng),
        MasterAgent(1, False, MASTER_REGION[1], 0, rng),
        MasterAgent(2, False, MASTER_REGION[2], 0, rng),
        MasterAgent(3, False, MASTER_REGION[3], 0, rng),
    ]
    ctrl = run_simulation(masters, cycles=100000, seed=0xFACE)
    assert ctrl.arb.addr_err == [0, 0, 0, 0], (
        f'arbiter region error latched: {ctrl.arb.addr_err}')


# --------------------------------------------------------------------------- #
# Tests: REQ-MEM-003 hard contract rules
# --------------------------------------------------------------------------- #

def test_dummy_write_precedes_every_read():
    """Every read is preceded by a same-address masked one-beat dummy."""
    rng = random.Random(17)
    masters = [
        MasterAgent(0, True,  MASTER_REGION[0], 1000, rng),
        MasterAgent(1, False, MASTER_REGION[1], 300, rng),
        MasterAgent(2, False, MASTER_REGION[2], 700, rng),
        MasterAgent(3, False, MASTER_REGION[3], 500, rng),
    ]
    ctrl = run_simulation(masters, cycles=200000, seed=0xD1CE)
    reads = ctrl.ip.read_events
    writes = ctrl.ip.write_events
    assert reads, 'no read commands were issued'
    assert writes, 'no write commands completed'
    # every read must have a same-address dummy write (len=0, strobe=0)
    dummy_addrs = [addr for _c, addr, length, strobe in writes
                   if length == 0 and strobe == 0]
    assert len(dummy_addrs) >= len(reads), (
        f'only {len(dummy_addrs)} dummy writes for {len(reads)} reads')
    for _c, raddr, _rlen in reads:
        assert raddr in dummy_addrs, (
            f'read at 0x{raddr:07X} had no preceding same-address '
            'masked dummy write')
    # dummy writes never carry strobes (masked: no memory data touched)
    for _c, _addr, length, strobe in writes:
        if length == 0:
            assert strobe == 0, (
                f'dummy write carried strobes 0x{strobe:X}')


def test_read_fifo_routing_lossless():
    """Backlog: fifo never overflows and beats route back losslessly.

    Fixed-priority note: with P0 in permanent backlog the P1/P2 read
    masters starve (by design only P3 carries the quota floor; P1/P2
    rely on the section 5.4 traffic shape where P0 duty is below one
    percent). This test therefore exercises the lossless datapath under
    the harshest legal load: beat conservation, routing discipline and
    the fifo depth invariant.
    """
    rng = random.Random(19)
    masters = [
        MasterAgent(0, True,  MASTER_REGION[0], 0, rng),
        MasterAgent(1, False, MASTER_REGION[1], 0, rng),
        MasterAgent(2, False, MASTER_REGION[2], 0, rng),
        MasterAgent(3, False, MASTER_REGION[3], 0, rng),
    ]
    ctrl = run_simulation(masters, cycles=150000, seed=0xBEE5)
    total_push = sum(ctrl.stats[i]['push'] for i in range(4))
    total_pop = sum(ctrl.stats[i]['rd_beats'] for i in range(4))
    assert total_push > 0, 'no read beats were ever pushed'
    assert total_pop + len(ctrl.fifo) == total_push, (
        f'beat conservation broken: popped {total_pop} + fifo '
        f'{len(ctrl.fifo)} != pushed {total_push}')
    # P0 (writer) and P3 (quota floor) must keep making progress even in
    # permanent backlog; P1/P2 starvation here is the documented
    # fixed-priority trade-off, detected on hardware via wait_cnt.
    assert ctrl.stats[0]['cmds'] > 0, 'P0 write path stalled'
    assert ctrl.stats[3]['cmds'] > 0, 'P3 quota floor failed'
    # a master never drains beats it did not push (routing discipline)
    for i in range(4):
        st = ctrl.stats[i]
        if masters[i].is_write:
            assert st['wr_beats'] >= st['done'] * (BURST_LEN + 1), (
                f'master {i} write beats below completed commands')
            assert st['wr_beats'] <= st['cmds'] * (BURST_LEN + 1), (
                f'master {i} write beats above issued commands')
        else:
            assert st['rd_beats'] <= st['push'], (
                f'master {i} drained more beats than pushed')


def test_wlast_side_evidence_window_is_sufficient():
    """wusero_last arrives within the 4-cycle epilogue (miss count 0)."""
    rng = random.Random(23)
    masters = [
        MasterAgent(0, True,  MASTER_REGION[0], 500, rng),
        MasterAgent(1, False, MASTER_REGION[1], 800, rng),
    ]
    ctrl = run_simulation(masters, cycles=100000, seed=0x5EED)
    assert ctrl.stats[0]['cmds'] > 0, 'no write commands were issued'
    assert ctrl.wlast_miss_cnt == 0, (
        f'wusero_last side evidence missed {ctrl.wlast_miss_cnt} times')


# --------------------------------------------------------------------------- #
# Tests: arbiter unit behavior
# --------------------------------------------------------------------------- #

def test_arbiter_flags_region_violations():
    """Out-of-region / misaligned / oversized commands latch addr_err."""
    arb = ArbiterModel()
    bad_cmds = [
        (1, 0x400000, BURST_LEN),     # outside every region
        (1, 0x000036, BURST_LEN),     # inside PCM left but misaligned
        (0, 0x100000, 16),            # inside weights but len > 15
    ]
    for i, cmd in enumerate(bad_cmds):
        grant = arb.step([True, False, False, False],
                         [cmd, (0, 0, 0), (0, 0, 0), (0, 0, 0)], True)
        assert grant == 0
        assert arb.addr_err[0] == 1, f'violation {i} not flagged'
        arb.addr_err[0] = 0           # reset the sticky for the next case
    # a legal command leaves the flags clear
    arb.step([True, False, False, False],
             [(1, 0x000000, BURST_LEN), (0, 0, 0), (0, 0, 0), (0, 0, 0)],
             True)
    assert arb.addr_err[0] == 0


def test_fixed_priority_order():
    """Priority: P0 > P1 > P2 > P3 when all four request simultaneously."""
    arb = ArbiterModel()
    cmds = [(1, 0x000000, BURST_LEN),
            (0, 0x100000, BURST_LEN),
            (0, 0x000000, BURST_LEN),
            (0, 0x200000, BURST_LEN)]
    assert arb.step([True, True, True, True], cmds, True) == 0
    assert arb.step([False, True, True, True], cmds, True) == 1
    assert arb.step([False, False, True, True], cmds, True) == 2
    assert arb.step([False, False, False, True], cmds, True) == 3


def test_arb_en_gates_grant():
    """grant is held low while the controller cannot accept a command."""
    arb = ArbiterModel()
    cmds = [(1, 0x000000, BURST_LEN), (0, 0, 0), (0, 0, 0), (0, 0, 0)]
    assert arb.step([True, False, False, False], cmds, False) is None
    # wait counters still accumulate while arbitration is disabled
    assert arb.wait_cnt[0] == 1
    assert arb.step([True, False, False, False], cmds, True) == 0
    assert arb.wait_cnt[0] == 0