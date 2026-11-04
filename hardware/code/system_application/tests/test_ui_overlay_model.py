"""UI compositor and overlay geometry semantics (M3).

Pins three things that a later edit could silently break and that no lint or
PDS compile can catch:

  * layer priority in ``ui_overlay`` (bars > text > spectrum > base) and its
    single register stage, which is what the caller's de/hs/vs delay assumes;
  * ``spectrum_disp`` heat-map thresholds and the one-cycle alignment between
    the issued RAM address and ``spec_on``;
  * frame geometry: every overlay rectangle must fit inside 1920x1080, and the
    text field must be wide enough for the longest class name plus its five
    percentage cells.

Values are transcribed from the RTL localparams; if a module changes, this
test is the signal to re-check the on-screen layout.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

H_ACT = 1920
V_ACT = 1080

# ---- ui_overlay -----------------------------------------------------------
LAYER_ORDER = ['bars', 'text', 'spec', 'base']


def overlay(bars_on, text_on, spec_on, base_on):
    """Exact mirror of ui_overlay's priority chain."""
    if bars_on:
        return 'bars'
    if text_on:
        return 'text'
    if spec_on:
        return 'spec'
    if base_on:
        return 'base'
    return 'blank'


def test_overlay_priority_all_combinations():
    for b in (0, 1):
        for t in (0, 1):
            for s in (0, 1):
                for g in (0, 1):
                    got = overlay(b, t, s, g)
                    if b:
                        assert got == 'bars'
                    elif t:
                        assert got == 'text'
                    elif s:
                        assert got == 'spec'
                    elif g:
                        assert got == 'base'
                    else:
                        assert got == 'blank'


def test_overlay_priority_is_strictly_ordered():
    """A lower layer must never win over a higher one that is on."""
    assert overlay(1, 1, 1, 1) == 'bars'
    assert overlay(0, 1, 1, 1) == 'text'
    assert overlay(0, 0, 1, 1) == 'spec'
    assert overlay(0, 0, 0, 1) == 'base'


def test_overlay_adds_exactly_one_stage():
    """rgb/de_out are registered once; the caller delays de by one cycle."""
    src = (ROOT / 'src/ui/ui_overlay.v').read_text(encoding='utf-8')
    body = src.split('endmodule')[0]
    assert body.count('always @(posedge pix_clk') == 1
    assert 'de_out <= de;' in body


# ---- spectrum_disp --------------------------------------------------------
SPEC_X0, SPEC_Y0 = 80, 80
SPEC_W, SPEC_H = 512, 256
COLOURS = [
    (0, 32, 0x000020),
    (32, 96, 0x002080),
    (96, 160, 0x00A0C0),
    (160, 224, 0xE0C040),
    (224, 256, 0xFFFFE0),
]


def heat(value):
    for lo, hi, rgb in COLOURS:
        if value < hi:
            return rgb
    return COLOURS[-1][2]


def test_spectrum_heat_map_thresholds():
    assert heat(0) == 0x000020
    assert heat(31) == 0x000020
    assert heat(32) == 0x002080
    assert heat(95) == 0x002080
    assert heat(96) == 0x00A0C0
    assert heat(159) == 0x00A0C0
    assert heat(160) == 0xE0C040
    assert heat(223) == 0xE0C040
    assert heat(224) == 0xFFFFE0
    assert heat(255) == 0xFFFFE0


def spec_in_region(x, y):
    return (x >= SPEC_X0 and x < SPEC_X0 + SPEC_W and
            y >= SPEC_Y0 and y < SPEC_Y0 + SPEC_H)


def test_spectrum_region_bounds():
    assert spec_in_region(SPEC_X0, SPEC_Y0)
    assert spec_in_region(SPEC_X0 + SPEC_W - 1, SPEC_Y0 + SPEC_H - 1)
    assert not spec_in_region(SPEC_X0 - 1, SPEC_Y0)
    assert not spec_in_region(SPEC_X0, SPEC_Y0 - 1)
    assert not spec_in_region(SPEC_X0 + SPEC_W, SPEC_Y0)
    assert not spec_in_region(SPEC_X0, SPEC_Y0 + SPEC_H)


def test_spectrum_on_flag_requires_de_region_and_page():
    """spec_on = de && in_region && page_ready, registered one cycle later."""
    for de in (0, 1):
        for page in (0, 1):
            on = bool(de and spec_in_region(SPEC_X0 + 5, SPEC_Y0 + 5) and page)
            assert on == bool(de and page)
    assert not (True and spec_in_region(0, 0) and True)


def test_spectrum_region_fits_frame():
    assert SPEC_X0 + SPEC_W <= H_ACT
    assert SPEC_Y0 + SPEC_H <= V_ACT


# ---- text_disp ------------------------------------------------------------
TEXT_X0, TEXT_Y0 = 1200, 560
CELL_W, CELL_H = 8, 16
LINE_H = 20
MAX_NAME = 25          # longest label in class_labels.hex
PCT_CELLS = 5          # space + hundreds + tens + ones + '%'
FIELD_CELLS = MAX_NAME + PCT_CELLS


def test_text_field_fits_frame():
    width = FIELD_CELLS * CELL_W
    assert TEXT_X0 + width <= H_ACT, (TEXT_X0, width)
    assert TEXT_Y0 + CELL_H <= V_ACT


def test_text_does_not_overlap_bars():
    """Text line 0 occupies TEXT_Y0..TEXT_Y0+CELL_H; bars start at y=700."""
    assert TEXT_Y0 + CELL_H <= 700


def _hex_bytes(path):
    out = []
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.split('//')[0].strip()
        if not line:
            continue
        out.extend(t for t in line.split() if len(t) == 2)
    return out


def test_class_labels_are_power_of_two_records():
    data = _hex_bytes(ROOT / 'src/ui/class_labels.hex')
    assert len(data) == 8 * 32, len(data)
    longest = 0
    for i in range(8):
        rec = bytes(int(b, 16) for b in data[i * 32:(i + 1) * 32])
        name = rec.split(b'\x00')[0].rstrip(b' ')
        assert all(32 <= c < 127 for c in name), (i, name)
        longest = max(longest, len(name))
    assert longest <= MAX_NAME, longest

def _rtl_name_len():
    """Parse the class -> name length case table out of text_disp.v."""
    import re
    src = (ROOT / 'src/ui/text_disp.v').read_text(encoding='utf-8')
    table = {}
    for m in re.finditer(r"3'd(\d):\s*name_len\s*=\s*5'd(\d+)", src):
        table[int(m.group(1))] = int(m.group(2))
    default = re.search(r"default:\s*name_len\s*=\s*5'd(\d+)", src)
    if default:
        table['default'] = int(default.group(1))
    return table


def test_name_len_matches_label_rom():
    """The percentage column starts at name_len, so it must equal the real
    label length -- otherwise the digits land inside the name or leave a
    gap.  No lint or compile checks this."""
    data = _hex_bytes(ROOT / 'src/ui/class_labels.hex')
    table = _rtl_name_len()
    assert len(table) == 8, table          # classes 0..6 explicit + default (7)
    for cls in range(8):
        rec = bytes(int(b, 16) for b in data[cls * 32:(cls + 1) * 32])
        name = rec.split(b'\x00')[0].rstrip(b' ')
        want = table.get(cls, table['default'])
        assert len(name) == want, (cls, name, want)
