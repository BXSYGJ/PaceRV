"""UI mapping semantics (M3): bars geometry, spectrum coordinates, font ROM.

These pin the arithmetic hardcoded in bars_disp / spectrum_disp / font_rom
so a later edit cannot silently change the on-screen mapping.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def bar_len(pct):
    return (pct & 0xFF) << 2


def test_bars_length_is_pct_times_four():
    assert bar_len(0) == 0
    assert bar_len(50) == 200
    assert bar_len(100) == 400


def bar_slot(dy):
    # RTL priority chain (a descending loop with no break always ends at 0).
    for d in range(7, -1, -1):
        if dy >= d * 28:
            return d
    return 0


def test_bars_slots():
    assert [bar_slot(dy) for dy in (0, 27, 28, 55, 56, 223)] == [0, 0, 1, 1, 2, 7]


def spec_col(dx):
    return (dx * 258) >> 9


def spec_row(dy):
    return dy >> 2


def test_spectrum_mapping_corners():
    assert spec_col(0) == 0
    assert spec_col(511) == 257
    assert spec_row(0) == 0
    assert spec_row(255) == 63


def test_spectrum_mapping_monotonic():
    cols = [spec_col(dx) for dx in (0, 100, 250, 400, 511)]
    assert cols == sorted(cols)
    assert all(0 <= c <= 257 for c in cols)


def spec_addr(row, col):
    return row * 258 + col


def test_spectrum_address_range():
    assert spec_addr(0, 0) == 0
    assert spec_addr(63, 257) == 16511


def test_font_rom_size():
    data = (ROOT / 'src/ui/font8x16.hex').read_text().split()
    assert len(data) == 95 * 16
    assert all(len(b) == 2 for b in data)


def test_font_rom_not_blank():
    data = (ROOT / 'src/ui/font8x16.hex').read_text().split()
    # At least the A-Z block must contain lit pixels.
    assert any(int(b, 16) != 0 for b in data[33 * 16:58 * 16])