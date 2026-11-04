#!/usr/bin/env python3
"""Parser and field decoder for the C-DIAG-UART@1 diagnostic frames.

The RTL producer is ``src/diag/diag_uart_report.v``.  Both sides agree on a
byte-exact, single-line, newline-terminated ASCII template of 91 bytes::

    DIAG <TAG8> A=<8 hex> B=<8 hex> C=<8 hex> D=<8 hex>
    E=<8 hex> F=<8 hex> G=<2 hex> H=<2 hex>\\n

(in the real frame those two template lines are one line; they are wrapped
here only for readability).

Byte accounting (91 bytes total; the plan text quotes 86 and is off by the
per-field trailing spaces, see the RTL header)::

    prefix DIAG plus space                     5
    tag field, always 8 bytes (space padded)   8
    separator space                            1
    six 32-bit fields  X=xxxxxxxx plus space   6 * 11 = 66
    two  8-bit  fields  X=xx plus space        2 *  5 = 10
    newline                                    1
    ----------------------------------------------------
    total                                     91

``<TAG8>`` is the tag name right padded with spaces to exactly 8 bytes, so
``DDR3DIAG`` fills the field and ``UIDEMO`` is followed by two spaces.  The
parser trims the padding of that field before matching, which means a log
line that lost the padding still decodes.

Hex digits are uppercase only, as produced by the RTL formatter; a lowercase
line is rejected instead of silently accepted, because the RTL side cannot
emit lowercase and a mixed-case capture would point at a different producer.

The ``E`` field of the DDR3 diagnostic frames is a bit pack.  ``DDR3_E_BITS``
holds the frozen slices of contract C-TOP-DDR3-DIAG@1 and
``DDR3_E_RESERVED_BITS`` names the slices the contract leaves unassigned, so
a reader can prove that the two sets together cover bit0..bit31 exactly once.
"""

from __future__ import annotations

import re

#: Bytes per frame, newline included.
FRAME_LEN = 91

#: Width of the space-padded tag field.
TAG_WIDTH = 8

#: Number of 32-bit value fields and 8-bit value fields in one frame.
FIELD32_COUNT = 6
FIELD8_COUNT = 2

#: ``frame_tag`` value to tag name (contract C-DIAG-UART@1).
TAG_NAMES = {
    0: 'DDR3DIAG',
    1: 'UIDEMO',
    2: 'DDR3SW',
    3: 'DDR3RS',
}

#: Tag name to ``frame_tag`` value.
TAG_CODES = {name: code for code, name in TAG_NAMES.items()}

#: Field names in wire order.
FIELD_NAMES = ('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h')

_TAG_ALTERNATION = '|'.join(TAG_NAMES[code] for code in sorted(TAG_NAMES))

#: Frame regex after the 8-byte tag field has had its padding trimmed.
FRAME_RE = re.compile(
    r'^DIAG (?P<tag>' + _TAG_ALTERNATION + r') '
    r'A=([0-9A-F]{8}) B=([0-9A-F]{8}) C=([0-9A-F]{8}) D=([0-9A-F]{8}) '
    r'E=([0-9A-F]{8}) F=([0-9A-F]{8}) G=([0-9A-F]{2}) H=([0-9A-F]{2}) ?$'
)

#: Bit slices of the ``E`` field, as (msb, lsb), contract C-DDR3-UART@1.
DDR3_E_BITS = {
    'to_err': (0, 0), 'cmd_to_err3': (1, 1), 'dbg_to_state': (4, 2),
    'addr_err3': (5, 5), 'st_done': (6, 6), 'st_fail': (7, 7),
    'result_a': (9, 8), 'result_b': (11, 10), 'round_cnt': (15, 12),
    'cfg_demo': (16, 16), 'cfg_stage': (18, 17), 'wlast_miss_cnt': (31, 24),
}

#: Slices of the ``E`` field the contract does not assign (documented zero).
#: Same (msb, lsb) order as DDR3_E_BITS: bits 23 down to 19 are reserved.
DDR3_E_RESERVED_BITS = ((23, 19),)

#: Decoding of the two 2-bit result slices of the ``E`` field.
RESULT_CODE = {0: 'NONE', 1: 'PASS', 2: 'FAIL', 3: 'TIMEOUT'}


def _decode(match: re.Match) -> dict:
    """Turn a FRAME_RE match into the public record dict."""
    values = [int(text, 16) for text in match.groups()[1:]]
    record = {'tag': match.group('tag')}
    record.update(zip(FIELD_NAMES, values))
    return record


def parse_frame(line: str) -> dict | None:
    """Decode one line into ``{'tag': str, 'a': int .. 'h': int}``.

    Returns ``None`` for any line that is not a diagnostic frame, including
    boot banners such as ``INSTREC BOOT`` and truncated captures.  The tag
    field is space padded to TAG_WIDTH on the wire; its padding is trimmed
    before the match so both padded and hand-cut lines decode the same way.
    """
    if not isinstance(line, str):
        return None
    text = line.rstrip('\r\n')
    match = FRAME_RE.match(text)
    if match is not None:
        return _decode(match)

    if len(text) < 5 + TAG_WIDTH or not text.startswith('DIAG '):
        return None
    tag_field = text[5:5 + TAG_WIDTH].rstrip(' ')
    if not tag_field:
        return None
    match = FRAME_RE.match('DIAG ' + tag_field + text[5 + TAG_WIDTH:])
    return None if match is None else _decode(match)


def parse_all(text: str) -> list[dict]:
    """Return every decodable frame of a captured UART dump, in order."""
    frames = []
    for line in text.splitlines():
        record = parse_frame(line)
        if record is not None:
            frames.append(record)
    return frames


def decode_e(value: int) -> dict[str, int]:
    """Split a 32-bit ``E`` field into the named slices of DDR3_E_BITS."""
    value = int(value) & 0xFFFFFFFF
    decoded = {}
    for name, (msb, lsb) in DDR3_E_BITS.items():
        decoded[name] = (value >> lsb) & ((1 << (msb - lsb + 1)) - 1)
    return decoded