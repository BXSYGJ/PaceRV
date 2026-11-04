"""Python model of the M3 UI overlay path (spectrum + compositor + page copy).

The three modules below are modelled cycle-by-cycle from the RTL so the
board-level pixel comparison and any later RTL edit have a bit-exact
reference.  RTL line numbers refer to the current sources:

  src/ui/spectrum_disp.v      : mapping, window, heat map, 1-beat read
  src/ui/ui_overlay.v         : layer priority, 1-beat output register
  src/ui/feat_copy_engine.v   : idx/idx_q two-stage copy alignment
  src/ui/feat_page_buf.v      : 258x64 double-buffered page (16512 bytes)

Nothing here is allowed to invent numbers: every constant is quoted from
the RTL line that defines it.
"""

from __future__ import annotations

from itertools import product
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------------------
# spectrum_disp.v
# ---------------------------------------------------------------------------
# localparams X0/Y0/WD/HT, spectrum_disp.v:32-35
X0 = 80
Y0 = 80
WD = 512
HT = 256

# Page geometry: 64 rows x 258 cols, feat_page_buf.v:28 (DEPTH = 258*64)
PAGE_COLS = 258
PAGE_ROWS = 64
PAGE_DEPTH = PAGE_COLS * PAGE_ROWS  # 16512

# spectrum_disp.v:55-59 (5-stop heat map thresholds 32/96/160/224)
HEAT_MAP = (
    (32, 0x000020),
    (96, 0x002080),
    (160, 0x00A0C0),
    (224, 0xE0C040),
    (256, 0xFFFFE0),
)


def spectrum_in_region(x, y):
    # spectrum_disp.v:37  in_region = (x >= X0) && (x < X0+WD) && ...
    return X0 <= x < X0 + WD and Y0 <= y < Y0 + HT


def spectrum_col(dx):
    # spectrum_disp.v:42-43  col_p = dx * 258; col = col_p[17:9]  == (dx*258) >> 9
    return (dx * PAGE_COLS) >> 9


def spectrum_row(dy):
    # spectrum_disp.v:46  row = dy[7:2] == dy >> 2
    return dy >> 2


def spectrum_addr(row, col):
    # spectrum_disp.v:50  {row,8'd0} + {8'd0,row,1'd0} + {6'd0,col}
    return ((row << 8) + (row << 1) + col) & 0x7FFF


def spectrum_map(x, y):
    """Return (in_region, row, col, addr) exactly as the pixel shader."""
    inside = spectrum_in_region(x, y)
    if not inside:
        return False, None, None, None
    dx = x - X0
    dy = y - Y0
    row = spectrum_row(dy)
    col = spectrum_col(dx)
    return True, row, col, spectrum_addr(row, col)


def heat_colour(value):
    for limit, rgb in HEAT_MAP:
        if value < limit:
            return rgb
    raise AssertionError(value)


def test_spectrum_window_constants_match_rtl():
    text = (ROOT / 'src/ui/spectrum_disp.v').read_text(encoding='utf-8')
    assert 'localparam [10:0] X0 = 11\'d80;' in text
    assert 'localparam [10:0] Y0 = 11\'d80;' in text
    assert 'localparam [10:0] WD = 11\'d512;' in text
    assert 'localparam [10:0] HT = 11\'d256;' in text
    assert 'wire [17:0] col_p = dx * 11\'d258;' in text
    assert 'wire [10:0] col   = col_p[17:9];' in text
    assert 'wire [5:0] row = dy[7:2];' in text


def test_spectrum_mapping_corners():
    # top-left: first pixel of the window
    assert spectrum_map(X0, Y0) == (True, 0, 0, 0)
    # top-right: dx = 511 -> col 257, last column of the page
    assert spectrum_map(X0 + WD - 1, Y0) == (True, 0, 257, 257)
    # bottom-left: dy = 255 -> row 63
    assert spectrum_map(X0, Y0 + HT - 1) == (True, 63, 0, 63 * 258)
    # bottom-right: last byte of the 16512-byte page
    assert spectrum_map(X0 + WD - 1, Y0 + HT - 1) == (True, 63, 257, 16511)


def test_spectrum_mapping_monotonic():
    cols = [spectrum_col(dx) for dx in range(WD)]
    rows = [spectrum_row(dy) for dy in range(HT)]
    assert cols == sorted(cols), 'col must never decrease with dx'
    assert rows == sorted(rows), 'row must never decrease with dy'
    assert cols[0] == 0 and cols[-1] == PAGE_COLS - 1
    assert rows[0] == 0 and rows[-1] == PAGE_ROWS - 1
    # every page column is reachable: 512 pixels over 258 columns
    assert set(cols) == set(range(PAGE_COLS))
    assert set(rows) == set(range(PAGE_ROWS))


def test_spectrum_address_range_and_no_overlap():
    # addr_c is 15 bits and the page is 16512 bytes (spectrum_disp.v:24,50)
    seen = set()
    for dy in range(HT):
        for dx in range(WD):
            addr = spectrum_addr(spectrum_row(dy), spectrum_col(dx))
            assert 0 <= addr <= PAGE_DEPTH - 1
            seen.add(addr)
    # 258 cols x 64 rows are all addressable and the map is a bijection
    assert len(seen) == PAGE_DEPTH
    assert max(seen) == 16511


def test_spectrum_region_outside_does_not_hit():
    outside = [
        (X0 - 1, Y0), (X0 + WD, Y0),
        (X0, Y0 - 1), (X0, Y0 + HT),
        (0, 0), (1023, 767),
    ]
    for x, y in outside:
        assert spectrum_map(x, y) == (False, None, None, None)
    # both region edges are half-open: X0 .. X0+WD-1 and Y0 .. Y0+HT-1
    assert spectrum_in_region(X0, Y0)
    assert spectrum_in_region(X0 + WD - 1, Y0 + HT - 1)
    assert not spectrum_in_region(X0 + WD, Y0)
    assert not spectrum_in_region(X0, Y0 + HT)


def test_spectrum_heat_map_thresholds():
    # spectrum_disp.v:55-59, strict "<" comparisons
    assert [heat_colour(v) for v in (0, 31, 32, 95, 96, 159, 160, 223, 224, 255)] == [
        0x000020, 0x000020, 0x002080, 0x002080, 0x00A0C0, 0x00A0C0,
        0xE0C040, 0xE0C040, 0xFFFFE0, 0xFFFFE0,
    ]


def test_spectrum_read_pipeline_flags():
    # spectrum_disp.v:68-72: ram_addr is registered only inside the region,
    # spec_on is de && in_region && page_ready (one beat behind the address),
    # rgb is always the registered heat-map colour.
    ram_addr = 0
    spec_on = False
    rgb = 0
    history = []

    def beat(x, y, de, page_ready, ram_data):
        """Run one clock beat; return the registered outputs BEFORE the edge."""
        nonlocal ram_addr, spec_on, rgb
        inside = spectrum_in_region(x, y)
        _, row, col, addr = spectrum_map(x, y)
        colour = heat_colour(ram_data)
        out = (ram_addr, spec_on, rgb)
        next_addr = addr if (inside and de) else ram_addr
        next_on = bool(de and inside and page_ready)
        history.append(out)
        ram_addr, spec_on, rgb = next_addr, next_on, colour

    beat(X0 + 1, Y0 + 1, 1, 1, 200)          # address issued on this beat
    assert history[0] == (0, False, 0)
    assert ram_addr == spectrum_addr(0, 0)
    assert spec_on is True                    # spectrum_disp.v:71
    assert rgb == 0xE0C040                    # heat map of 200, same beat

    beat(X0 + 1, Y0 + 1, 1, 1, 200)          # data returns one beat later
    assert history[1][1] is True              # spec_on already aligned
    assert history[1][2] == 0xE0C040

    beat(X0 - 1, Y0 + 1, 1, 1, 200)          # outside: address frozen
    assert history[2][1] is True              # still the previous flag
    assert ram_addr == spectrum_addr(0, 0)
    assert spec_on is False                   # region test uses this beat's x

    beat(X0 + 1, Y0 + 1, 0, 1, 200)          # de low: no address, no spec_on
    assert ram_addr == spectrum_addr(0, 0)
    assert history[3][1] is False

    beat(X0 - 1, Y0 + 1, 1, 0, 10)            # page not ready: flag stays low
    assert history[4][1] is False
    assert rgb == 0x000020                    # rgb always registers colour


# ---------------------------------------------------------------------------
# ui_overlay.v
# ---------------------------------------------------------------------------
BLACK = 0x000000

BASE_RGB = 0x101010
SPEC_RGB = 0x202020
BARS_RGB = 0x303030


def overlay_mix(base_on, spec_on, bars_on):
    # ui_overlay.v:30-35  bars_on > spec_on > base_on > black
    if bars_on:
        return BARS_RGB
    if spec_on:
        return SPEC_RGB
    if base_on:
        return BASE_RGB
    return BLACK


def test_overlay_priority_all_combinations():
    expected = {
        (0, 0, 0): BLACK,
        (1, 0, 0): BASE_RGB,
        (0, 1, 0): SPEC_RGB,
        (1, 1, 0): SPEC_RGB,
        (0, 0, 1): BARS_RGB,
        (1, 0, 1): BARS_RGB,
        (0, 1, 1): BARS_RGB,
        (1, 1, 1): BARS_RGB,
    }
    assert len(expected) == 8
    for base_on, spec_on, bars_on in product((0, 1), repeat=3):
        assert overlay_mix(base_on, spec_on, bars_on) == expected[
            (base_on, spec_on, bars_on)]


def test_overlay_registers_one_beat():
    # ui_overlay.v:37-45: rgb <= mix and de_out <= de, one register stage
    rgb = 0
    de_out = False
    seen = []
    for de, spec_on in ((1, 1), (1, 0), (0, 1)):
        seen.append((rgb, de_out))
        rgb = overlay_mix(0, spec_on, 0)
        de_out = de
    assert seen == [(0, False), (SPEC_RGB, True), (BLACK, True)]
    assert rgb == SPEC_RGB and not de_out


# ---------------------------------------------------------------------------
# feat_copy_engine.v / feat_page_buf.v
# ---------------------------------------------------------------------------
DEPTH = 16512  # feat_copy_engine.v:32


class FeatCopySim:
    """Cycle-accurate model of feat_copy_engine (busy_in tied low).

    mel returns src_data one cycle after src_addr (feat_copy_engine.v:4-7),
    so the copy keeps one beat in flight: present address N, write data N-1.
    """

    def __init__(self, mem):
        self.mem = mem
        self.idx = 0
        self.idx_q = 0
        self.run = False
        self.src_addr = 0
        self.src_en = False
        self.dst_addr = 0
        self.dst_data = 0
        self.dst_we = False
        self.dst_page = 0
        self.done = False
        self.prev_src_addr = 0
        self.rd_pending = False
        self.fin = False

    def step(self, start=False):
        # value the mel port presents this beat (registered one beat earlier).
        # src_address can run one past DEPTH with src_en low (drain beat).
        src_data = self.mem[self.prev_src_addr] if self.prev_src_addr < DEPTH else 0
        obs = {
            'src_addr': self.src_addr,
            'src_en': self.src_en,
            'src_data': src_data,
            'dst_addr': self.dst_addr,
            'dst_data': self.dst_data,
            'dst_we': self.dst_we,
            'dst_page': self.dst_page,
            'done': self.done,
        }

        n_idx, n_idx_q, n_run = self.idx, self.idx_q, self.run
        n_pending = self.src_en
        n_fin = self.fin
        n_dst_addr, n_dst_data, n_dst_we = self.dst_addr, self.dst_data, False
        n_dst_page, n_done = self.dst_page, False

        if not self.run:
            if start:
                n_run = True
                n_idx = 0
                n_idx_q = 0
                n_fin = False
        else:
            if self.src_en:
                n_idx_q = self.idx
                n_idx = self.idx + 1
            if self.rd_pending:
                n_dst_addr = self.idx_q
                n_dst_data = src_data
                n_dst_we = True
                if self.idx_q == DEPTH - 1:
                    n_fin = True
            if self.fin:
                n_run = False
                n_fin = False
                n_dst_page = self.dst_page ^ 1
                n_done = True

        self.prev_src_addr = self.src_addr
        self.idx, self.idx_q, self.run = n_idx, n_idx_q, n_run
        self.src_addr = n_idx if n_idx < DEPTH else 0
        self.src_en = n_run and n_idx < DEPTH
        self.rd_pending, self.fin = n_pending, n_fin
        self.dst_addr, self.dst_data, self.dst_we = n_dst_addr, n_dst_data, n_dst_we
        self.dst_page, self.done = n_dst_page, n_done
        return obs


def run_copy(mem):
    sim = FeatCopySim(mem)
    beats = [sim.step(start=True)]
    while not beats[-1]['done']:
        beats.append(sim.step())
        assert len(beats) < 200000, 'copy engine failed to finish'
    beats.append(sim.step())
    return beats


def test_feat_copy_copies_every_byte_in_order():
    mem = [(i * 7 + 3) & 0xFF for i in range(DEPTH)]
    beats = run_copy(mem)
    writes = [b for b in beats if b['dst_we']]
    assert len(writes) == DEPTH
    assert [w['dst_addr'] for w in writes] == list(range(DEPTH))
    assert [w['dst_data'] for w in writes] == mem
    # source address stream covers 0..DEPTH-1 exactly once
    src = [b['src_addr'] for b in beats if b['src_en']]
    assert src == list(range(DEPTH))


def test_feat_copy_no_tail_byte_lost():
    mem = [0xA5] * (DEPTH - 1) + [0x5A]
    beats = run_copy(mem)
    writes = [b for b in beats if b['dst_we']]
    assert writes[-1]['dst_addr'] == DEPTH - 1
    assert writes[-1]['dst_data'] == 0x5A


def test_feat_copy_page_flip_at_end():
    mem = [0] * DEPTH
    beats = run_copy(mem)
    writes = [b for b in beats if b['dst_we']]
    done_beats = [b for b in beats if b['done']]
    assert len(done_beats) == 1
    assert all(w['dst_page'] == 0 for w in writes)
    assert done_beats[0]['dst_page'] == 1
    assert beats.index(done_beats[0]) > beats.index(writes[-1])


def test_feat_copy_last_byte_lands_before_page_flip():
    """The final byte must land in the same page as every preceding byte."""
    mem = list(range(DEPTH))
    beats = run_copy(mem)
    writes = [b for b in beats if b['dst_we']]
    last = writes[-1]
    assert last['dst_addr'] == 16511
    assert last['dst_page'] == 0
    page_of_byte = {w['dst_addr']: w['dst_page'] for w in writes}
    assert page_of_byte[16510] == 0
    assert page_of_byte[16511] == 0
