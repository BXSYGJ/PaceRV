#!/usr/bin/env python3
"""Generate an 8x16 ASCII font ROM for the InstRec UI (M3).

Renders printable ASCII (0x20..0x7E) with a monospace system font and
writes one hex byte per scanline, MSB = leftmost pixel, 16 lines per
character (95 * 16 = 1520 bytes). Output: src/ui/font8x16.hex.

Usage: python scripts/gen_font_hex.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'src/ui/font8x16.hex'
FONT_CANDIDATES = [
    r'C:/Windows/Fonts/consola.ttf',
    r'C:/Windows/Fonts/cour.ttf',
    r'C:/Windows/Fonts/lucon.ttf',
]


def load_font():
    for path in FONT_CANDIDATES:
        if Path(path).is_file():
            return ImageFont.truetype(path, 13)
    return ImageFont.load_default()


def render(ch, font):
    img = Image.new('1', (8, 16), 0)
    draw = ImageDraw.Draw(img)
    # Center the glyph in the 8x16 cell.
    bbox = draw.textbbox((0, 0), ch, font=font)
    w = bbox[2] - bbox[0]
    h = bbox[3] - bbox[1]
    draw.text(((8 - w) // 2 - bbox[0], (16 - h) // 2 - bbox[1]), ch, font=font, fill=1)
    rows = []
    for y in range(16):
        byte = 0
        for x in range(8):
            if img.getpixel((x, y)):
                byte |= 1 << (7 - x)
        rows.append(byte)
    return rows


def main():
    font = load_font()
    lines = []
    for code in range(0x20, 0x7F):
        for byte in render(chr(code), font):
            lines.append(f'{byte:02x}')
    OUT.write_text('\n'.join(lines) + '\n', encoding='ascii', newline='\n')
    print(f'wrote {OUT} ({len(lines)} bytes, 95 chars x 16 rows)')


if __name__ == '__main__':
    main()