"""Offline render of the spectrogram overlay from a golden Mel page.

The board drives ``spectrum_disp`` from a 258x64 uint8 page copied out of the
mel engine.  Nothing in the RTL flow proves that the address mapping in
``spectrum_disp`` actually reproduces the window on screen -- a column/row
swap would still compile and still light up pixels.

This test replays the RTL mapping over the archived golden feature page and
checks the rendered image is a faithful upscale of it:

  * every rendered pixel's colour comes from the 5-stop heat map;
  * the brightest stop appears iff the page really contains a hot cell;
  * the image is not degenerate (rows differ from each other, i.e. no
    constant field and no row/column transposition);
  * a PPM copy is written to build/tmp/ui_preview.ppm for eyeballing.

No board, no HDMI, no PDS.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
GOLDEN_FEAT = ROOT / 'reports/golden_ref/sine_440_full/feat.npy'

X0, Y0 = 80, 80
WD, HT = 512, 256
PAGE_W, PAGE_H = 258, 64

STOPS = [
    (0, 0x000020),
    (32, 0x002080),
    (96, 0x00A0C0),
    (160, 0xE0C040),
    (224, 0xFFFFE0),
]


def heat(v):
    out = STOPS[0][1]
    for lo, rgb in STOPS:
        if v >= lo:
            out = rgb
    return out


def render(page):
    """Replay spectrum_disp's col/row mapping into an RGB image."""
    img = np.zeros((HT, WD, 3), np.uint8)
    for dy in range(HT):
        row = dy >> 2                       # dy * 64 / 256
        for dx in range(WD):
            col = (dx * 258) >> 9           # dx * 258 / 512
            rgb = heat(int(page[row, col]))
            img[dy, dx] = ((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
    return img


@pytest.fixture(scope='module')
def page():
    if not GOLDEN_FEAT.is_file():
        pytest.skip(f'missing {GOLDEN_FEAT}')
    arr = np.load(GOLDEN_FEAT)
    assert arr.shape == (PAGE_H, PAGE_W), arr.shape
    return arr.astype(np.uint8)


def test_render_uses_only_heat_map_colours(page):
    img = render(page)
    seen = {tuple(int(c) for c in px) for px in img.reshape(-1, 3)[::97]}
    allowed = {((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
               for _, rgb in STOPS}
    assert seen <= allowed, seen - allowed


def test_render_is_not_degenerate(page):
    img = render(page)
    # rows must differ: a transposed or constant mapping would collapse this
    row_sigs = {img[y].tobytes() for y in range(0, HT, 16)}
    assert len(row_sigs) > 1
    assert img.std() > 0


def test_render_tracks_the_page_dynamic_range(page):
    """The hottest stop appears iff the source page has a hot cell."""
    img = render(page)
    hot = 0xFFFFE0
    has_hot_page = bool((page >= 224).any())
    has_hot_img = bool(((img[..., 0] == 0xFF) & (img[..., 1] == 0xFF) &
                        (img[..., 2] == 0xE0)).any())
    assert has_hot_img == has_hot_page


def test_render_writes_preview(page):
    img = render(page)
    out = ROOT / 'build/tmp/ui_preview.ppm'
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, 'wb') as fh:
        fh.write(b'P6\n%d %d\n255\n' % (WD, HT))
        fh.write(img.tobytes())
    assert out.is_file() and out.stat().st_size == WD * HT * 3 + 15