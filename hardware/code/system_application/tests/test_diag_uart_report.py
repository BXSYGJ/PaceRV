"""Conformance tests for the shared diagnostic UART frame (C-DIAG-UART@1).

The RTL producer is ``src/diag/diag_uart_report.v`` and the Python consumer is
``scripts/diag_frames.py``.  There is no Verilog simulator on this machine, so
the byte sequence is checked in three independent ways:

  * the ASCII tables are parsed straight out of the RTL source and compared
    with the contract template (this is what actually guards the RTL text);
  * a cycle model of the module, built on those parsed tables, is driven
    through ``fire`` and the handshake, and its output must equal a 91-byte
    template that this file builds from scratch;
  * static source checks (no string literal, reset branch, geometry
    constants, timing budget comment) and ``check_rtl.py``.

Contract note: plan section 2.2.3 says the frame is 86 bytes, but the
byte-exact template it prints totals 91 (the tag field is a fixed 8 bytes and
each of the eight value fields carries its own trailing space).  The 91-byte
count is implemented on both sides and pinned here; the mismatch is reported
to the team leader.
"""

from __future__ import annotations

import re
from functools import lru_cache
from pathlib import Path

import diag_frames

ROOT = Path(__file__).resolve().parents[1]
RTL_PATH = ROOT / 'src' / 'diag' / 'diag_uart_report.v'

BAUD_DIV_125M = 1085
BAUD_DIV_148M5 = 1289
CLK_125M = 125.0e6
CLK_148M5 = 148.5e6
FRAME_TICK_S = 25.0e-3

#: Sample field values: a mix of all-ones, all-zeros, leading zeros and
#: small values so zero padding and uppercase digits are both exercised.
VALUES = (0xDEADBEEF, 0x0000000A, 0x00000000, 0xFFFFFFFF,
          0x081FFCA0, 0x00300000, 0x05, 0xFF)

#: Expected tag field: always 8 bytes, space padded on the right.
EXPECTED_TAGS = {
    0: b'DDR3DIAG',
    1: b'UIDEMO  ',
    2: b'DDR3SW  ',
    3: b'DDR3RS  ',
}


# --------------------------------------------------------------------------- #
# RTL source helpers
# --------------------------------------------------------------------------- #

@lru_cache(maxsize=1)
def rtl_text() -> str:
    return RTL_PATH.read_text(encoding='utf-8')


_PREFIX_ITEM_RE = re.compile(r"8'd([0-4])\s*:\s*cur_char\s*=\s*8'h([0-9A-F]{2})\s*;")
_TAG_ITEM_RE = re.compile(r"5'd(\d{1,2})\s*:\s*tag_char\s*=\s*8'h([0-9A-F]{2})\s*;")


@lru_cache(maxsize=1)
def rtl_prefix() -> bytes:
    """The five prefix bytes parsed from the RTL ASCII case table."""
    items = {int(idx): int(code, 16) for idx, code in _PREFIX_ITEM_RE.findall(rtl_text())}
    assert set(items) == set(range(5)), f'prefix table incomplete: {sorted(items)}'
    return bytes(items[idx] for idx in range(5))


@lru_cache(maxsize=1)
def rtl_tag_table() -> dict[int, bytes]:
    """The four 8-byte tag fields parsed from the RTL ASCII case table."""
    items = {int(sel): int(code, 16) for sel, code in _TAG_ITEM_RE.findall(rtl_text())}
    assert set(items) == set(range(32)), f'tag table incomplete: {sorted(items)}'
    return {tag: bytes(items[tag * 8 + idx] for idx in range(8)) for tag in range(4)}


def rtl_frame_bytes(tag: int, values=VALUES) -> bytes:
    """Render one frame using the character tables parsed from the RTL."""
    a, b, c, d, e, f, g, h = values
    out = bytearray()
    out += rtl_prefix()
    out += rtl_tag_table()[tag]
    out.append(0x20)
    for letter, value in zip(b'ABCDEF', (a, b, c, d, e, f)):
        out.append(letter)
        out.append(0x3D)                       # '='
        out += f'{value:08X}'.encode('ascii')
        out.append(0x20)
    for letter, value in zip(b'GH', (g, h)):
        out.append(letter)
        out.append(0x3D)
        out += f'{value:02X}'.encode('ascii')
        out.append(0x20)
    out.append(0x0A)                           # newline
    return bytes(out)


def contract_frame_bytes(tag: int, values=VALUES) -> bytes:
    """The 91-byte template built independently of the RTL source."""
    a, b, c, d, e, f, g, h = values
    return (
        'DIAG '
        + EXPECTED_TAGS[tag].decode('ascii')
        + ' '
        + f'A={a:08X} B={b:08X} C={c:08X} D={d:08X} '
        + f'E={e:08X} F={f:08X} G={g:02X} H={h:02X} \n'
    ).encode('ascii')


# --------------------------------------------------------------------------- #
# Cycle models (RTL mirror)
# --------------------------------------------------------------------------- #

class UartTxModel:
    """Cycle model of src/ctrl/uart_tx.v.

    ``byte_wready <= ~busy`` is a register, so it stays high for one extra
    cycle after an accept; the model keeps that detail because it is exactly
    the hazard the producer handshake must survive.
    """

    def __init__(self, baud=4):
        self.baud = baud
        self.busy = 0
        self.wready = 0
        self.bit = 0
        self.div = 0
        self.out = bytearray()

    def step(self, wvalid, wdata):
        cur_busy = self.busy
        accepted = bool(wvalid and self.wready and not cur_busy)
        nxt_wready = 0 if cur_busy else 1
        if not cur_busy:
            if accepted:
                self.busy = 1
                self.bit = 0
                self.div = 0
                self.out.append(wdata)
        else:
            if self.div == self.baud - 1:
                self.div = 0
                if self.bit == 9:                # start + 8 data + stop
                    self.busy = 0
                else:
                    self.bit += 1
            else:
                self.div += 1
        self.wready = nxt_wready
        return accepted


class DiagUartReportModel:
    """Cycle model of the diag_uart_report frame engine.

    Mirrors the RTL register updates one for one: fire latch while idle, a
    level handshake while busy, one idle valid cycle after every accept, and
    busy released on the accepted newline byte.
    """

    def __init__(self, frame_builder=rtl_frame_bytes):
        self.frame_builder = frame_builder
        self.reset()

    def reset(self):
        self.busy = 0
        self.valid = 0
        self.data = 0
        self.pos = 0
        self.tag = 0
        self.values = (0,) * 8
        self.frame = b''
        self.accepted = bytearray()

    def step(self, fire=0, tag=0, values=None, ready=0):
        """Advance one clock; return the byte accepted in this cycle."""
        accepted = None
        if not self.busy:
            if fire:
                self.busy = 1
                self.pos = 0
                self.tag = tag
                self.values = tuple(VALUES if values is None else values)
                self.frame = self.frame_builder(tag, self.values)
                self.data = self.frame[0]        # prefix byte at pos 0
                self.valid = 1
        else:
            if self.valid:
                if ready:
                    accepted = self.data
                    self.accepted.append(self.data)
                    self.valid = 0
                    if self.pos == len(self.frame) - 1:
                        self.busy = 0
                        self.pos = 0
                    else:
                        self.pos += 1
            else:
                self.data = self.frame[self.pos]
                self.valid = 1
        return accepted


# --------------------------------------------------------------------------- #
# Acceptance 1: byte-exact sequence for frame_tag 0..3
# --------------------------------------------------------------------------- #

def test_frame_template_is_91_bytes():
    for tag in range(4):
        assert len(contract_frame_bytes(tag)) == diag_frames.FRAME_LEN == 91


def test_rtl_prefix_and_tag_tables_match_contract():
    assert rtl_prefix() == b'DIAG '
    table = rtl_tag_table()
    assert table == dict(EXPECTED_TAGS)
    # the two short names must be padded with spaces, not NUL or truncated
    assert table[1] == b'UIDEMO  '
    assert table[2] == b'DDR3SW  '
    assert table[3] == b'DDR3RS  '


def test_rtl_byte_sequence_equals_contract_for_each_tag():
    for tag in range(4):
        got = rtl_frame_bytes(tag)
        want = contract_frame_bytes(tag)
        assert len(got) == 91, f'tag {tag}: {len(got)} bytes'
        assert got == want, f'tag {tag}:\n got={got!r}\nwant={want!r}'
        # uppercase hex only, printable ASCII, newline terminated
        assert got.endswith(b'\n')
        assert b'abcdef' not in got
        assert all(0x20 <= byte <= 0x7E or byte == 0x0A for byte in got)
        assert got.count(b'=') == 8


def test_model_emits_exactly_one_frame_per_fire():
    # dummy cycle helper: three fires while idle -> three frames, one each
    dut = DiagUartReportModel()
    stream = bytearray()
    for _ in range(3):
        for cycle in range(400):
            accepted = dut.step(fire=1 if cycle == 0 else 0, tag=2,
                                values=VALUES, ready=1)
            if accepted is not None:
                stream.append(accepted)
            if cycle > 5 and not dut.busy:
                break
    assert bytes(stream) == contract_frame_bytes(2) * 3


# --------------------------------------------------------------------------- #
# Acceptance 2: no string literal anywhere in the RTL
# --------------------------------------------------------------------------- #

def test_rtl_source_contains_no_string_literal():
    text = rtl_text()
    assert '"' not in text, 'RTL must build text from an ASCII case table'
    # the tag/prefix tables must be ASCII byte constants
    assert re.search(r"5'd0:\s*tag_char\s*=\s*8'h44;", text)
    assert re.search(r"8'd0:\s*cur_char\s*=\s*8'h44;", text)


def test_rtl_hex_formatter_is_uppercase_ascii():
    body = re.search(r'function \[7:0\] hex_nib;(.*?)endfunction',
                     rtl_text(), re.S).group(1)
    assert "8'h41" in body          # 'A'
    assert "8'h30" in body          # '0'
    assert "4'hA" in body           # nibble threshold
    assert "8'h4A" not in body      # no lowercase path

    def hex_ascii(nibble):
        return chr(0x41 + nibble - 0x0A) if nibble >= 0x0A else chr(0x30 + nibble)

    assert ''.join(hex_ascii(n) for n in range(16)) == '0123456789ABCDEF'


# --------------------------------------------------------------------------- #
# Acceptance 3: level handshake (hold until ready, one byte per pulse)
# --------------------------------------------------------------------------- #

def test_valid_and_data_hold_while_ready_low():
    dut = DiagUartReportModel()
    dut.step(fire=1, tag=0, values=VALUES, ready=0)
    assert (dut.busy, dut.valid, dut.data) == (1, 1, ord('D'))
    snapshot = (dut.valid, dut.data)
    for _ in range(64):
        dut.step(ready=0)
        assert (dut.valid, dut.data) == snapshot
    assert dut.accepted == b''


def test_ready_pulse_advances_exactly_one_byte():
    dut = DiagUartReportModel()
    dut.step(fire=1, tag=0, values=VALUES, ready=0)
    assert dut.valid == 1 and dut.data == ord('D')

    dut.step(ready=0)
    assert dut.accepted == b'', 'ready low must not consume the byte'
    assert dut.valid == 1 and dut.data == ord('D')

    dut.step(ready=1)
    assert dut.accepted == b'D', 'one ready pulse takes one byte'
    assert dut.valid == 0, 'valid must drop for one cycle after the accept'

    dut.step(ready=0)
    assert dut.accepted == b'D', 'still exactly one byte advanced'
    assert dut.valid == 1 and dut.data == ord('I')


def test_full_frame_through_uart_tx_model():
    tx = UartTxModel(baud=4)
    dut = DiagUartReportModel()
    expected = contract_frame_bytes(0, VALUES)
    busy_at_accept = []
    for cycle in range(200000):
        ready = tx.wready
        valid_before, data_before = dut.valid, dut.data
        busy_before = dut.busy
        fire = 1 if cycle == 0 else 0
        accepted = dut.step(fire=fire, tag=0, values=VALUES, ready=ready)
        if accepted is not None:
            busy_at_accept.append(busy_before)
        tx.step(valid_before, data_before)
        if len(tx.out) == len(expected) and not dut.busy and not tx.busy:
            break
    assert bytes(tx.out) == expected
    assert dut.accepted == expected
    assert all(busy_at_accept), 'busy must be high for every byte accept'


def test_two_frames_on_a_tick_do_not_overlap():
    """Two fires one frame apart produce two complete frames, no truncation."""
    tx = UartTxModel(baud=4)
    dut = DiagUartReportModel()
    expected = contract_frame_bytes(0) + contract_frame_bytes(1)
    second_fire = 6000                    # well over one frame at baud 4
    for cycle in range(200000):
        ready = tx.wready
        valid_before, data_before = dut.valid, dut.data
        tag = 1 if cycle >= second_fire else 0
        dut.step(fire=1 if cycle in (0, second_fire) else 0, tag=tag,
                 values=VALUES, ready=ready)
        tx.step(valid_before, data_before)
        if len(tx.out) == len(expected) and not dut.busy and not tx.busy:
            break
    assert bytes(tx.out) == expected
    assert bytes(tx.out).count(b'\n') == 2


def test_back_to_back_fire_after_busy_drops():
    """A fire in the cycle busy releases must not steal or drop a byte.

    busy drops when uart_tx accepts the newline, so uart_tx is still busy
    for one more byte time; the producer must hold the new byte instead.
    """
    tx = UartTxModel(baud=4)
    dut = DiagUartReportModel()
    expected = contract_frame_bytes(2) * 2
    fired = 0
    for cycle in range(400000):
        ready = tx.wready
        valid_before, data_before = dut.valid, dut.data
        fire = 1 if (fired < 2 and not dut.busy) else 0
        if fire:
            fired += 1
        dut.step(fire=fire, tag=2, values=VALUES, ready=ready)
        tx.step(valid_before, data_before)
        if (fired == 2 and len(tx.out) == len(expected)
                and not dut.busy and not tx.busy):
            break
    assert fired == 2
    assert bytes(tx.out) == expected


# --------------------------------------------------------------------------- #
# Acceptance 4: fire while busy is dropped
# --------------------------------------------------------------------------- #

def test_fire_while_busy_is_dropped():
    dut = DiagUartReportModel()
    stream = bytearray()
    for cycle in range(500):
        fire = 1 if cycle in (0, 3, 7) else 0
        accepted = dut.step(fire=fire, tag=0, values=VALUES, ready=1)
        if accepted is not None:
            stream.append(accepted)
        if cycle > 20 and not dut.busy:
            break
    assert len(stream) == 91
    assert bytes(stream) == contract_frame_bytes(0)


def test_busy_is_low_again_after_the_frame():
    dut = DiagUartReportModel()
    for cycle in range(400):
        dut.step(fire=1 if cycle == 0 else 0, tag=1, values=VALUES, ready=1)
        if cycle > 5 and not dut.busy:
            break
    assert dut.busy == 0
    assert dut.valid == 0
    assert len(dut.accepted) == 91


# --------------------------------------------------------------------------- #
# Acceptance 5: no spontaneous frame after reset
# --------------------------------------------------------------------------- #

def test_no_spontaneous_frame_after_reset():
    dut = DiagUartReportModel()
    for _ in range(1000):
        dut.step(ready=1)
        assert dut.valid == 0
        assert dut.busy == 0
    assert dut.accepted == b''

    reset_block = re.search(r'if \(!rst_n\) begin(.*?)\n        end else if',
                            rtl_text(), re.S).group(1)
    assert re.search(r"busy_q\s*<=\s*1'b0;", reset_block)
    assert re.search(r"tx_byte_valid\s*<=\s*1'b0;", reset_block)


# --------------------------------------------------------------------------- #
# Acceptance 6: frame duration and duty cycle documented
# --------------------------------------------------------------------------- #

def test_timing_budget_documented_in_rtl():
    text = rtl_text()
    assert '987350' in text                     # 91 * 10 * 1085
    assert '1172990' in text                    # 91 * 10 * 1289
    assert '7.90 ms' in text
    assert '25 ms' in text
    assert '31.6' in text

    cycles_125m = diag_frames.FRAME_LEN * 10 * BAUD_DIV_125M
    cycles_148m5 = diag_frames.FRAME_LEN * 10 * BAUD_DIV_148M5
    assert cycles_125m == 987350
    assert cycles_148m5 == 1172990
    assert abs(cycles_125m / CLK_125M - 7.90e-3) < 5e-5
    assert abs(cycles_148m5 / CLK_148M5 - 7.90e-3) < 5e-5
    duty = (cycles_125m / CLK_125M) / FRAME_TICK_S
    assert abs(duty - 0.316) < 5e-3


def test_frame_geometry_constants_declared():
    text = rtl_text()
    assert re.search(r'localparam integer FRAME_LEN\s*=\s*91;', text)
    assert re.search(r'localparam integer FRAME_CYCLES\s*=\s*'
                     r'FRAME_LEN \* 10 \* BAUD_DIV;', text)
    assert re.search(r"localparam \[7:0\] POS_PREFIX_END\s*=\s*8'd5;", text)
    assert re.search(r"localparam \[7:0\] POS_TAG_END\s*=\s*8'd13;", text)
    assert re.search(r"localparam \[7:0\] POS_SEPARATOR\s*=\s*8'd13;", text)
    assert re.search(r"localparam \[7:0\] POS_F32_BASE\s*=\s*8'd14;", text)
    assert re.search(r"localparam \[7:0\] POS_F32_END\s*=\s*8'd80;", text)
    assert re.search(r"localparam \[7:0\] POS_F8_BASE\s*=\s*8'd80;", text)
    assert re.search(r"localparam \[7:0\] POS_F8_END\s*=\s*8'd90;", text)
    assert re.search(r"localparam \[7:0\] POS_NEWLINE\s*=\s*8'd90;", text)


def test_rtl_field_order_matches_contract():
    """A..F must be fed by f_a..f_f and G/H by f_g/f_h (wire order guard)."""
    text = rtl_text()
    for idx in range(5):
        port = 'abcdef'[idx] + '_q'
        assert re.search(rf"3'd{idx}:\s*field_word\s*=\s*{port};", text), port
    assert re.search(r"default:\s*field_word\s*=\s*f_q;", text)
    assert re.search(r"fld_idx = 3'd6;\s*\n\s*byte_val = g_q;", text)
    assert re.search(r"fld_idx = 3'd7;\s*\n\s*byte_val = h_q;", text)
    # nibble order inside a 32-bit field must be MSB first (31:28 .. 3:0)
    for off, hi in enumerate(range(31, 7, -4)):
        lo = hi - 3
        assert re.search(rf"8'd{off + 2}:\s*cur_char = hex_nib\(field_word\[{hi}:{lo}\]\);",
                         text), (off, hi, lo)


# --------------------------------------------------------------------------- #
# Acceptance 7: parser behaviour and E-field bit layout
# --------------------------------------------------------------------------- #

def test_parse_frame_decodes_all_fields():
    line = contract_frame_bytes(0).decode('ascii').rstrip('\n')
    record = diag_frames.parse_frame(line)
    assert record == {
        'tag': 'DDR3DIAG',
        'a': 0xDEADBEEF, 'b': 0x0000000A, 'c': 0x00000000, 'd': 0xFFFFFFFF,
        'e': 0x081FFCA0, 'f': 0x00300000, 'g': 0x05, 'h': 0xFF,
    }


def test_parse_frame_tolerates_padded_and_trimmed_tag_field():
    for tag in range(4):
        padded = contract_frame_bytes(tag).decode('ascii').rstrip('\n')
        trimmed = padded[:5] + EXPECTED_TAGS[tag].rstrip().decode('ascii') + padded[13:]
        assert diag_frames.parse_frame(padded)['tag'] == EXPECTED_TAGS[tag].rstrip().decode()
        assert diag_frames.parse_frame(trimmed)['tag'] == EXPECTED_TAGS[tag].rstrip().decode()
    # UIDEMO keeps 2 padding spaces on the wire and still decodes
    uidemo = contract_frame_bytes(1).decode('ascii').rstrip('\n')
    assert uidemo[5:13] == 'UIDEMO  '
    assert diag_frames.parse_frame(uidemo)['tag'] == 'UIDEMO'


def test_parse_frame_rejects_non_frame_lines():
    rejects = [
        '',
        'INSTREC BOOT',
        'DDR3 ERR @FFFFFFFF',
        'DIAG',
        'DIAG DDR3DIAG',
        'DIAG DDR3DIAG A=DEADBEEF B=0000000A',
        'diag DDR3DIAG A=DEADBEEF B=0000000A C=00000000 D=FFFFFFFF '
        'E=081FFCA0 F=00300000 G=05 H=FF',
        'DIAG BOGUS   A=DEADBEEF B=0000000A C=00000000 D=FFFFFFFF '
        'E=081FFCA0 F=00300000 G=05 H=FF',
        'DIAG DDR3DIAG A=deadbeef B=0000000A C=00000000 D=FFFFFFFF '
        'E=081FFCA0 F=00300000 G=05 H=FF',
    ]
    for line in rejects:
        assert diag_frames.parse_frame(line) is None, line
    assert diag_frames.parse_frame(None) is None
    assert diag_frames.parse_frame(1234) is None


def test_parse_all_keeps_arrival_order():
    text = '\n'.join([
        'INSTREC BOOT',
        contract_frame_bytes(0).decode('ascii').rstrip('\n'),
        'DDR3 SELFTEST...',
        contract_frame_bytes(2).decode('ascii').rstrip('\n'),
        '',
        contract_frame_bytes(1).decode('ascii').rstrip('\n'),
        'DDR3 ERR @FFFFFFFF',
    ]) + '\n'
    frames = diag_frames.parse_all(text)
    assert [frame['tag'] for frame in frames] == ['DDR3DIAG', 'DDR3SW', 'UIDEMO']
    assert frames[0]['e'] == 0x081FFCA0


def test_e_field_slices_cover_32_bits_without_overlap():
    covered = set()
    for name, (msb, lsb) in diag_frames.DDR3_E_BITS.items():
        assert 0 <= lsb <= msb <= 31, name
        span = set(range(lsb, msb + 1))
        assert not (covered & span), f'{name} overlaps {sorted(covered & span)}'
        covered |= span

    reserved = set()
    for msb, lsb in diag_frames.DDR3_E_RESERVED_BITS:
        span = set(range(lsb, msb + 1))
        assert not (covered & span), f'reserved slice overlaps {sorted(covered & span)}'
        reserved |= span

    assert not (reserved & covered)
    assert covered | reserved == set(range(32)), sorted(set(range(32)) - covered - reserved)


def test_decode_e_fields_roundtrip():
    value = (1 << 0) | (3 << 2) | (2 << 8) | (0xAB << 24) | (1 << 6)
    decoded = diag_frames.decode_e(value)
    assert decoded['to_err'] == 1
    assert decoded['dbg_to_state'] == 3
    assert decoded['result_a'] == 2
    assert decoded['result_b'] == 0
    assert decoded['st_done'] == 1
    assert decoded['wlast_miss_cnt'] == 0xAB
    assert diag_frames.RESULT_CODE[decoded['result_a']] == 'FAIL'
    assert diag_frames.RESULT_CODE[3] == 'TIMEOUT'


# --------------------------------------------------------------------------- #
# Acceptance 8: check_rtl clean, module name equals file name
# --------------------------------------------------------------------------- #

def test_check_rtl_reports_no_violations():
    import check_rtl

    assert RTL_PATH.is_file()
    assert RTL_PATH.stem == 'diag_uart_report'
    assert re.search(r'^\s*module diag_uart_report', rtl_text(), re.M)
    assert check_rtl.lint_file(RTL_PATH, 'diag/diag_uart_report.v') == []


def test_rtl_port_list_matches_contract():
    """T4 and T7 instantiate this module: the port set must not drift."""
    import check_rtl

    text = rtl_text()
    assert re.search(r'parameter integer BAUD_DIV = 1085', text)
    body = text.split('module diag_uart_report', 1)[1].split(');', 1)[0]
    names = set()
    for line in body.split('\n'):
        for match in check_rtl.PORT_DECL_RE.finditer(line):
            for part in match.group(1).split(','):
                ident = re.search(r'[A-Za-z_]\w*', part)
                if ident:
                    names.add(ident.group(0))
    expected = {
        'clk', 'rst_n', 'fire', 'frame_tag',
        'f_a', 'f_b', 'f_c', 'f_d', 'f_e', 'f_f', 'f_g', 'f_h',
        'busy', 'tx_byte_data', 'tx_byte_valid', 'tx_byte_ready',
    }
    assert names == expected, (sorted(names - expected), sorted(expected - names))


def test_check_rtl_scans_the_diag_directory():
    scanned = {path.name for path in (ROOT / 'src').rglob('*.v')
               if 'diag' in path.parts}
    assert 'diag_uart_report.v' in scanned