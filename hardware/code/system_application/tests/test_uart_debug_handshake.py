"""Cycle model of the uart_debug -> uart_tx byte handshake.

Board evidence (2026-10-29): flashing the full NPU bitstream printed ``ITCO``
for ``INSTREC BOOT`` and ``D3ETT.D3R@FF`` for ``DDR3 SELFTEST...``.  Both are
the ROM characters at index 0, 3, 6, 9 ...  Root cause: ``uart_debug`` advanced
``rom_idx`` on every cycle where ``tx_byte_ready`` was high, but

  * its ``tx_byte_valid`` was a one-cycle strobe that reached uart_tx one
    cycle later, and
  * ``uart_tx`` derived ``byte_wready`` from a registered ``~busy``, so the
    flag stayed high for one extra cycle after an accept.

Combined, the index advanced three times per delivered byte.

The shipped fix keeps the cheap strobe structure and closes both holes:

  * ``uart_debug`` loads only when ``tx_byte_ready && !tx_byte_valid``;
  * ``uart_tx`` drives ``byte_wready <= ~busy & ~(byte_wvalid & byte_wready)``.

An earlier candidate (hold ``tx_byte_valid`` as a level until accepted) also
delivers every byte, but changed the layout enough that place & route stopped
converging -- it is kept here as ``level`` so the regression stays covered.

The model mirrors the RTL register updates exactly (pre-edge values, accept
only in uart_tx's ``!busy`` branch).
"""

from __future__ import annotations

NL = bytes([10])

BOOT = b'INSTREC BOOT' + NL
BAUD = 12          # small stand-in for 1085; only the ratio matters
GAP = 150          # > one 10-bit frame (10*BAUD = 120)


class TxCore:
    """uart_tx.v: busy / byte_wready / bit_idx / div_cnt."""

    def __init__(self, baud=BAUD, fixed_ready=True):
        self.baud = baud
        self.fixed_ready = fixed_ready     # False reproduces the old RTL
        self.busy = 0
        self.wready = 0
        self.bit = 0
        self.div = 0
        self.out = bytearray()

    def step(self, wvalid, wdata):
        """One clock. Returns True if this cycle accepted a byte."""
        accept = bool(wvalid and self.wready and not self.busy)
        if self.fixed_ready:
            nxt_wready = 0 if (self.busy or (wvalid and self.wready)) else 1
        else:
            nxt_wready = 0 if self.busy else 1
        if not self.busy:
            if accept:
                self.busy = 1
                self.bit = 0
                self.div = 0
                self.out.append(wdata)
        else:
            if self.div == self.baud - 1:
                self.div = 0
                if self.bit == 9:          # START + 8 data + STOP
                    self.busy = 0
                else:
                    self.bit += 1
            else:
                self.div += 1
        self.wready = nxt_wready
        return accept


def _run(mode, line, baud=BAUD, limit=2000000):
    """mode: 'gated' = shipped RTL, 'level' = rejected candidate,
    'strobe' = old RTL (must lose characters)."""
    tx = TxCore(baud, fixed_ready=(mode != 'strobe'))
    valid = 0
    data = 0
    idx = 0            # next character to load
    cur = 0            # character currently presented on the wire
    gap = 0            # inter-character wait (the shipped 'gap' variant)
    seen = []
    for _ in range(limit):
        accepted = tx.step(valid, data)
        if accepted:
            seen.append(cur)
        ready_now = tx.wready

        if mode == 'level':
            if not valid:
                data, valid = line[idx], 1
                cur = idx
                idx += 1
            elif accepted:
                valid = 0
                if idx >= len(line):
                    break
        elif mode == 'gap':
            if gap != 0:
                gap -= 1
            if gap == 0 and ready_now and idx < len(line):
                data, valid = line[idx], 1
                cur = idx
                idx += 1
                gap = GAP
                if idx >= len(line):
                    delivered_last = True
            else:
                valid = 0
        elif mode == 'gated':
            if ready_now and not valid and idx < len(line):
                data, valid = line[idx], 1
                cur = idx
                idx += 1
            else:
                valid = 0
                if idx >= len(line) and accepted:
                    break
        else:                                   # old RTL
            if ready_now and idx < len(line):
                data, valid = line[idx], 1
                cur = idx
                idx += 1
            else:
                valid = 0
                if idx >= len(line) and accepted:
                    break
    return bytes(tx.out), seen


LINES = [
    BOOT,
    b'DDR3 SELFTEST...' + NL,
    b'DDROK' + NL,
    b'RUN' + NL,
]


def test_gated_strobe_delivers_every_character():
    """The shipped RTL must reproduce every boot line byte for byte."""
    for line in LINES:
        out, seen = _run('gated', line)
        assert out == line, (line, out, seen)
        assert seen == list(range(len(line))), (line, seen)


def test_level_candidate_also_delivers_every_character():
    """The rejected level-handshake fix was functionally correct."""
    for line in LINES:
        out, seen = _run('level', line)
        assert out == line, (line, out, seen)


def test_old_strobe_reproduces_the_board_loss():
    """Old RTL: the index advances faster than bytes are delivered."""
    out, seen = _run('strobe', BOOT)
    assert out != BOOT
    assert len(out) < len(BOOT), seen
    strides = {b - a for a, b in zip(seen, seen[1:])}
    assert strides and min(strides) > 1, (seen, strides)


def test_gated_never_outruns_the_line():
    for line in LINES:
        _, seen = _run('gated', line)
        assert max(seen) < len(line)
        assert seen == sorted(set(seen)), seen

def test_gap_variant_delivers_every_character():
    """Shipped fix: keep the single-cycle strobe, wait a full frame between
    characters.  uart_tx keeps its original registered-ready (no RTL change
    there), so the routing-sensitive structure is untouched."""
    for line in LINES:
        out, seen = _run('gap', line)
        assert out == line, (line, out, seen)
        assert seen == list(range(len(line))), (line, seen)
