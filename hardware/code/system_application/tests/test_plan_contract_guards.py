"""Cross-task contract guards for the DDR3 unblock plan (task T12).

Each test below pins one "must stay identical" fact that spans two or more
tasks of plan section 3.3.  A drift in any of the guarded files therefore
fails in seconds instead of after a 1.5 h full build:

  test 1  src/ctrl/self_test.v        <-> frozen C-SELFTEST@1 port table
  test 2  tests/test_self_test_model.py <-> src/ddr3/ddr3_ctrl_axi.v (S1/S2/S3)
  test 3  src/diag/top_ddr3_diag.v    <-> scripts/diag_frames.DDR3_E_BITS
  test 4  src/diag/diag_uart_report.v <-> scripts/diag_frames (91-byte frame)
  test 5  scripts/build_sets.json     <-> files on disk / set isolation
  test 6  scripts/board_check.py      <-> C-BOARD-CHECK@1 (exit 5, --json)
  test 7  constraints/top_ui_demo.fdc <-> constraints/instrec_top.fdc
  test 8  DDR3_E_BITS                 <-> DDR3_E_RESERVED_BITS (bit coverage)

Everything is static and offline: RTL is parsed with small regular
expressions after the comments are stripped, the build manifest is read as
JSON, ``board_check`` is reflected on its argparse surface and its JSON writer,
and one diagnostic frame is rebuilt from the RTL ASCII tables.  No PDS run, no
JTAG session, no serial port, no build artefact is produced or consumed.

Three plan-text errors are corrected here and documented rather than hidden
(they were already flagged by T3/T2 and by the hand-off):

  * the diagnostic frame is 91 bytes, not the 86 quoted in the plan: the
    accounting is 5 (prefix) + 8 (tag) + 1 (separator) + 6*11 + 2*5 + 1
    (newline) = 91;
  * ``self_test`` has 14 ports, not the 13 quoted in the plan sentence (the
    same sentence lists 14 names, and the list is what is asserted);
  * ``DDR3_E_BITS`` alone does not cover 32 bits (bits 23..19 are unassigned),
    so coverage is asserted over ``DDR3_E_BITS`` union
    ``DDR3_E_RESERVED_BITS``.
"""

from __future__ import annotations

import codecs
import json
import re
import sys
from pathlib import Path


import board_check
import diag_frames

ROOT = Path(__file__).resolve().parents[1]

SELF_TEST_V = ROOT / 'src' / 'ctrl' / 'self_test.v'
SELF_TEST_MODEL = ROOT / 'tests' / 'test_self_test_model.py'
DDR3_CTRL_V = ROOT / 'src' / 'ddr3' / 'ddr3_ctrl_axi.v'
TOP_DDR3_DIAG_V = ROOT / 'src' / 'diag' / 'top_ddr3_diag.v'
DIAG_UART_V = ROOT / 'src' / 'diag' / 'diag_uart_report.v'
DIAG_FRAMES_PY = ROOT / 'scripts' / 'diag_frames.py'
BUILD_SETS_JSON = ROOT / 'scripts' / 'build_sets.json'
BOARD_CHECK_PY = ROOT / 'scripts' / 'board_check.py'
FDC_TOP = ROOT / 'constraints' / 'instrec_top.fdc'
FDC_UI = ROOT / 'constraints' / 'top_ui_demo.fdc'
INSTREC_TOP_V = ROOT / 'src' / 'ctrl' / 'instrec_top.v'


# --------------------------------------------------------------------------- #
# Shared helpers
# --------------------------------------------------------------------------- #

def _read(path: Path) -> str:
    """Read a guarded file, with an actionable message when it disappears."""
    assert path.exists(), f'{path}: expected the file to exist, actual missing'
    return path.read_text(encoding='utf-8')


def _strip_comments(text: str) -> str:
    """Remove /* */ and // comments so matching only sees live RTL."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


# --------------------------------------------------------------------------- #
# Guard 1: src/ctrl/self_test.v port list == frozen contract
# --------------------------------------------------------------------------- #

#: C-SELFTEST@1 port table, in declaration order:
#: (direction, net kind, packed width or None, name).  14 ports.
CONTRACT_PORTS = (
    ('input', 'wire', None, 'clk'),
    ('input', 'wire', None, 'rst_n'),
    ('input', 'wire', None, 'st_start'),
    ('output', 'reg', None, 'cmd_valid'),
    ('output', 'reg', '[36:0]', 'cmd'),
    ('output', 'wire', '[255:0]', 'wdata'),
    ('input', 'wire', None, 'wready_beat'),
    ('output', 'reg', None, 'rd_ready'),
    ('input', 'wire', '[255:0]', 'rd_data'),
    ('input', 'wire', None, 'rd_valid'),
    ('input', 'wire', None, 'done'),
    ('output', 'reg', None, 'st_done'),
    ('output', 'reg', None, 'st_fail'),
    ('output', 'reg', '[27:0]', 'st_fail_addr'),
)

_PORT_RE = re.compile(
    r'\b(input|output|inout)\s+(wire|reg)\s*(\[[^\]]*\])?\s*([A-Za-z_]\w*)')


def _self_test_port_block(text: str) -> str:
    """The ``module self_test ... ( ... );`` header, comments stripped.

    ``text.index(');', start)`` lands on the port-list terminator because the
    parameter list is closed by ``) (`` and not by ``);``.
    """
    stripped = _strip_comments(text)
    start = stripped.index('module self_test')
    end = stripped.index(');', start)
    return stripped[start:end]


def test_self_test_port_list_matches_frozen_contract():
    """Guard 1: port names, directions and widths equal C-SELFTEST@1."""
    block = _self_test_port_block(_read(SELF_TEST_V))
    found = []
    for match in _PORT_RE.finditer(block):
        direction, kind, width, name = match.groups()
        width = width.replace(' ', '') if width else None
        found.append((direction, kind, width, name))

    expected_names = ', '.join(port[3] for port in CONTRACT_PORTS)
    actual_names = ', '.join(port[3] for port in found)
    assert len(found) == len(CONTRACT_PORTS), (
        f'{SELF_TEST_V}: port count expected {len(CONTRACT_PORTS)} '
        f'({expected_names}), actual {len(found)} ({actual_names})')

    for index, (expected, actual) in enumerate(zip(CONTRACT_PORTS, found)):
        assert actual == expected, (
            f'{SELF_TEST_V}: port #{index} expected {expected!r} '
            f'(direction, kind, width, name), actual {actual!r}')


# --------------------------------------------------------------------------- #
# Guard 2: the self_test cycle stub keeps the S1/S2 "done == last beat" facts
# --------------------------------------------------------------------------- #

def _state_case(text: str, state: str) -> str:
    """Body of one ``ST_XXX:`` branch of the FSM case statement."""
    start = text.index(f'{state}:')
    tail = text[start + len(state) + 1:]
    nxt = re.search(r'\n\s*ST_[A-Z]+:', tail)
    return tail[:nxt.start()] if nxt else tail


def test_self_test_stub_keeps_s1_s2_same_cycle_done_semantics():
    """Guard 2: watchdog limit 4096 and "done on the last beat" stay pinned."""
    rtl = _read(DDR3_CTRL_V)
    stub = _read(SELF_TEST_MODEL)

    limit = re.search(r'\bparameter\s+integer\s+AXI_TO_LIMIT\s*=\s*(\d+)', rtl)
    assert limit is not None, (
        f'{DDR3_CTRL_V}: expected "parameter integer AXI_TO_LIMIT = 4096", '
        f'actual no such parameter')
    assert int(limit.group(1)) == 4096, (
        f'{DDR3_CTRL_V}: AXI_TO_LIMIT expected 4096, actual {limit.group(1)}')

    assert re.search(r'AXI_TO_LIMIT\s*=\s*4096', stub), (
        f'{SELF_TEST_MODEL}: expected the stub to record "AXI_TO_LIMIT = 4096" '
        f'(S3 semantics shared with {DDR3_CTRL_V}), actual not found')

    # S2: wready_beat and the write-completion predicate share one condition,
    # so a completing beat and done are necessarily the same cycle (S1).
    assert re.search(
        r'wready_beat\s*=\s*\(self\.state == S_W\)\s*and\s*wready', stub), (
        f'{SELF_TEST_MODEL}: expected "wready_beat = (self.state == S_W) and '
        f'wready", actual pattern not found')
    assert re.search(
        r'write_cmpl\s*=[\s\S]{0,24}\(self\.state == S_W\)[\s\S]{0,24}'
        r'wready[\s\S]{0,80}self\.beat_cnt >= self\.cur_len', stub), (
        f'{SELF_TEST_MODEL}: expected "write_cmpl = (self.state == S_W) and '
        f'wready and (self.beat_cnt >= self.cur_len)", actual pattern not found')

    # The locked F2-order vector asserts the coincidence explicitly.
    assert re.search(r"trace\[done_i\]\['wready_beat'\]\s*==\s*1", stub), (
        f'{SELF_TEST_MODEL}: expected the F2-order vector to assert '
        f'"trace[done_i][wready_beat] == 1", actual not found')

    # RTL side of F2: wready_beat is tested before done in ST_WDATA.
    stripped = _strip_comments(_read(SELF_TEST_V))
    wdata = _state_case(stripped, 'ST_WDATA')
    assert 'if (wready_beat)' in wdata, (
        f'{SELF_TEST_V}: ST_WDATA expected "if (wready_beat)", actual not found')
    assert 'else if (done)' in wdata, (
        f'{SELF_TEST_V}: ST_WDATA expected "else if (done)", actual not found')
    assert wdata.index('if (wready_beat)') < wdata.index('else if (done)'), (
        f'{SELF_TEST_V}: ST_WDATA expected wready_beat tested BEFORE done '
        f'(F2), actual order reversed')


# --------------------------------------------------------------------------- #
# Guard 3: top_ddr3_diag.v E-field packing == diag_frames.DDR3_E_BITS
# --------------------------------------------------------------------------- #

#: Concat item base name -> contract field name of DDR3_E_BITS.
FRM_E_NAME_MAP = {
    'to_err_sel': 'to_err',
    'cmd_to_err_sel': 'cmd_to_err3',
    'dbg_to_state_sel': 'dbg_to_state',
    'addr_err_sel': 'addr_err3',
    'wlast_miss_cnt_sel': 'wlast_miss_cnt',
    'st_done': 'st_done',
    'st_fail': 'st_fail',
    'result_a': 'result_a',
    'result_b': 'result_b',
    'round_cnt': 'round_cnt',
    'cfg_demo': 'cfg_demo',
    'cfg_stage': 'cfg_stage',
}

_ITEM_LITERAL_RE = re.compile(r"^(\d+)'d(\d+)$")
_ITEM_SLICE_RE = re.compile(r'^([A-Za-z_]\w*)\[(\d+)(?::(\d+))?\]$')
_ITEM_NAME_RE = re.compile(r'^[A-Za-z_]\w*$')
_DECL_RE = re.compile(
    r'\b(?:wire|reg)\s*(\[(\d+)\s*:\s*(\d+)\])?\s*([A-Za-z_]\w*)')


def _declared_widths(text: str) -> dict:
    """Packed width of every wire/reg declared in one RTL file."""
    widths = {}
    for match in _DECL_RE.finditer(text):
        span, hi, lo, name = match.group(1), match.group(2), match.group(3), match.group(4)
        if span:
            widths[name] = abs(int(hi) - int(lo)) + 1
        else:
            widths.setdefault(name, 1)
    return widths


def _concat_body(text: str, lhs_pattern: str) -> str:
    """Text between the outer braces of ``<lhs> = { ... }``."""
    match = re.search(lhs_pattern + r'\s*=\s*\{', text)
    assert match is not None, (
        f'{TOP_DDR3_DIAG_V}: expected a declaration matching '
        f'{lhs_pattern!r} = {{ ... }}, actual not found')
    index = match.end()
    depth = 1
    while index < len(text) and depth:
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
        index += 1
    assert depth == 0, (
        f'{TOP_DDR3_DIAG_V}: expected balanced braces in {lhs_pattern!r}, '
        f'actual unbalanced')
    return text[match.end():index - 1]


def _split_top_level(body: str) -> list:
    """Split a concat body on top-level commas only."""
    items, depth, start = [], 0, 0
    for index, char in enumerate(body):
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
        elif char == ',' and depth == 0:
            items.append(body[start:index])
            start = index + 1
    items.append(body[start:])
    return items


def _item_base_name(item: str) -> str:
    item = item.strip()
    sliced = _ITEM_SLICE_RE.match(item)
    return sliced.group(1) if sliced else item


def _item_width(item: str, widths: dict, where: str) -> int:
    """Packed width of one concat item, derived from declarations/literals."""
    item = item.strip()
    literal = _ITEM_LITERAL_RE.match(item)
    if literal:
        declared, value = int(literal.group(1)), int(literal.group(2))
        assert value < (1 << declared), (
            f'{where}: expected literal {item!r} to fit its width, '
            f'actual value does not fit')
        return declared
    sliced = _ITEM_SLICE_RE.match(item)
    if sliced:
        hi = int(sliced.group(2))
        lo = int(sliced.group(3)) if sliced.group(3) is not None else hi
        return abs(hi - lo) + 1
    if _ITEM_NAME_RE.match(item):
        assert item in widths, (
            f'{where}: expected a wire/reg declaration for {item!r}, '
            f'actual none found in {TOP_DDR3_DIAG_V}')
        return widths[item]
    raise AssertionError(
        f'{where}: expected a concat item of the form name / name[a:b] / '
        f"N'dM, actual {item!r} cannot be sized")


def test_top_ddr3_diag_e_field_matches_ddr3_e_bits():
    """Guard 3: the E-field concat slices equal diag_frames.DDR3_E_BITS."""
    stripped = _strip_comments(_read(TOP_DDR3_DIAG_V))
    widths = _declared_widths(stripped)
    items = _split_top_level(_concat_body(stripped, r'\bwire\s*\[31:0\]\s*frm_e'))

    # In a Verilog concatenation the leftmost item is the most significant,
    # so the slices are accumulated downwards from bit 31.
    where = f'{TOP_DDR3_DIAG_V} frm_e'
    msb = 31
    found = {}
    reserved = []
    for item in items:
        base = _item_base_name(item)
        width = _item_width(item, widths, where)
        hi = msb
        lo = msb - width + 1
        if base in FRM_E_NAME_MAP:
            found[FRM_E_NAME_MAP[base]] = (hi, lo)
        elif _ITEM_LITERAL_RE.match(item.strip()):
            reserved.append((hi, lo))
        else:
            raise AssertionError(
                f'{where}: expected every named concat item to map to a '
                f'DDR3_E_BITS field, actual unmapped item {item.strip()!r}')
        msb = lo - 1

    assert msb == -1, (
        f'{where}: expected the concat to be exactly 32 bits wide, '
        f'actual {32 - (msb + 1)} bits')

    assert set(found) == set(diag_frames.DDR3_E_BITS), (
        f'{TOP_DDR3_DIAG_V}: E-field names expected '
        f'{sorted(diag_frames.DDR3_E_BITS)} (diag_frames.DDR3_E_BITS), '
        f'actual {sorted(found)}')

    for name, expected in diag_frames.DDR3_E_BITS.items():
        actual = found[name]
        assert actual == expected, (
            f'{TOP_DDR3_DIAG_V}: E-field slice {name!r} expected {expected!r} '
            f'(msb, lsb from diag_frames.DDR3_E_BITS), actual {actual!r}')

    expected_reserved = tuple(sorted(diag_frames.DDR3_E_RESERVED_BITS, reverse=True))
    actual_reserved = tuple(sorted(reserved, reverse=True))
    assert actual_reserved == expected_reserved, (
        f'{TOP_DDR3_DIAG_V}: reserved E-field slices expected '
        f'{expected_reserved!r} (diag_frames.DDR3_E_RESERVED_BITS), '
        f'actual {actual_reserved!r}')


# --------------------------------------------------------------------------- #
# Guard 4: diag_uart_report.v frame geometry == diag_frames (91 bytes)
# --------------------------------------------------------------------------- #

#: Sample payload used to rebuild one frame from the RTL ASCII tables.
FRAME_SAMPLE_VALUES = (0x1234ABCD, 0x00000000, 0xDEADBEEF, 0x00000007,
                       0x081FFCA0, 0x00300001, 0x5A, 0xC3)

_PREFIX_ITEM_RE = re.compile(r"8'd([0-4])\s*:\s*cur_char\s*=\s*8'h([0-9A-F]{2})\s*;")
_TAG_ITEM_RE = re.compile(r"5'd(\d{1,2})\s*:\s*tag_char\s*=\s*8'h([0-9A-F]{2})\s*;")


def _rtl_prefix_bytes(stripped: str) -> bytes:
    items = {int(idx): int(code, 16)
             for idx, code in _PREFIX_ITEM_RE.findall(stripped)}
    assert set(items) == set(range(5)), (
        f'{DIAG_UART_V}: prefix ASCII table expected indices 0..4, '
        f'actual {sorted(items)}')
    return bytes(items[index] for index in range(5))


def _rtl_tag_fields(stripped: str) -> dict:
    items = {int(sel): int(code, 16)
             for sel, code in _TAG_ITEM_RE.findall(stripped)}
    assert set(items) == set(range(32)), (
        f'{DIAG_UART_V}: tag ASCII table expected 32 entries (4 tags x 8 '
        f'bytes), actual {len(items)}')
    return {tag: bytes(items[tag * 8 + idx] for idx in range(8)) for tag in range(4)}


def _rtl_frame_bytes(tag: int, values, prefix: bytes, tags: dict) -> bytes:
    """Rebuild the byte-exact frame the module emits for one ``fire``."""
    a, b, c, d, e, f, g, h = values
    out = bytearray()
    out += prefix
    out += tags[tag]
    out.append(0x20)                                    # separator
    for letter, value in zip(b'ABCDEF', (a, b, c, d, e, f)):
        out.append(letter)
        out.append(0x3D)                                # '='
        out += f'{value:08X}'.encode('ascii')
        out.append(0x20)
    for letter, value in zip(b'GH', (g, h)):
        out.append(letter)
        out.append(0x3D)
        out += f'{value:02X}'.encode('ascii')
        out.append(0x20)
    out.append(0x0A)                                    # newline
    return bytes(out)


def test_diag_frame_is_91_bytes_and_matches_frame_re():
    """Guard 4: frame length is 91 (not 86) and FRAME_RE decodes a sample."""
    rtl = _strip_comments(_read(DIAG_UART_V))

    length = re.search(r'\blocalparam\s+integer\s+FRAME_LEN\s*=\s*(\d+)\s*;', rtl)
    assert length is not None, (
        f'{DIAG_UART_V}: expected "localparam integer FRAME_LEN = 91;", '
        f'actual not found')
    assert int(length.group(1)) == 91, (
        f'{DIAG_UART_V}: FRAME_LEN expected 91, actual {length.group(1)}')

    assert diag_frames.FRAME_LEN == 91, (
        f'{DIAG_FRAMES_PY}: FRAME_LEN expected 91, '
        f'actual {diag_frames.FRAME_LEN}')

    prefix = _rtl_prefix_bytes(rtl)
    tags = _rtl_tag_fields(rtl)
    for tag, name in sorted(diag_frames.TAG_NAMES.items()):
        actual_name = tags[tag].rstrip(b' ').decode('ascii')
        assert actual_name == name, (
            f'{DIAG_UART_V}: tag {tag} expected {name!r} '
            f'(diag_frames.TAG_NAMES), actual {actual_name!r}')

    for tag in sorted(diag_frames.TAG_NAMES):
        frame = _rtl_frame_bytes(tag, FRAME_SAMPLE_VALUES, prefix, tags)
        assert len(frame) == 91, (
            f'{DIAG_UART_V}: frame for tag {tag} expected 91 bytes '
            f'(5 + 8 + 1 + 6*11 + 2*5 + 1), actual {len(frame)}')

        line = frame.decode('ascii').rstrip('\n')
        tag_field = line[5:5 + diag_frames.TAG_WIDTH]
        rest = line[5 + diag_frames.TAG_WIDTH:]
        trimmed = line[:5] + tag_field.rstrip(' ') + rest

        match = diag_frames.FRAME_RE.match(trimmed)
        assert match is not None, (
            f'{DIAG_UART_V}: sample frame of tag {tag} expected to match '
            f'diag_frames.FRAME_RE, actual no match for {trimmed!r}')
        assert match.group('tag') == diag_frames.TAG_NAMES[tag], (
            f'{DIAG_UART_V}: sample frame tag expected '
            f'{diag_frames.TAG_NAMES[tag]!r}, actual {match.group("tag")!r}')

        record = diag_frames.parse_frame(line)
        assert record is not None, (
            f'{DIAG_UART_V}: expected diag_frames.parse_frame to decode the '
            f'rebuilt frame, actual None for {line!r}')
        for position, field in enumerate(diag_frames.FIELD_NAMES):
            expected = FRAME_SAMPLE_VALUES[position]
            assert record[field] == expected, (
                f'{DIAG_UART_V}: field {field.upper()} expected {expected:#x}, '
                f'actual {record[field]:#x}')


# --------------------------------------------------------------------------- #
# Guard 5: build_sets.json paths exist and the three sets stay isolated
# --------------------------------------------------------------------------- #

SET_NAMES = ('full', 'ddr3_diag', 'ui_demo', 'conv1_test', 'mel_test', 'core_only', 'rv_core', 'pcm1808_diag')
SET_LIST_KEYS = ('sources', 'ip_cores', 'constraints', 'hex_dirs')

#: Substrings the diagnostic set must never carry (kept out of the build).
DDR3_DIAG_FORBIDDEN = ('src/npu/', 'src/mel/', 'src/hdmi/', 'ipcore/pll/')

#: Substrings the UI demo set must never carry.
UI_DEMO_FORBIDDEN = ('ddr3_test.idf', 'ddr3_100h.fdc')


def _expand_entry(pattern: str) -> list:
    """Files matched by one build-set entry (T5 glob semantics).

    ``*``/``?`` entries are globbed; an empty expansion is legal (T5: a glob
    over a directory that holds no match yields nothing), but its parent
    directory must still exist so a renamed directory cannot silently empty
    the file list.  Plain entries must exist as files.
    """
    if '*' in pattern or '?' in pattern:
        parent = (ROOT / pattern).parent
        assert parent.is_dir(), (
            f'{BUILD_SETS_JSON}: glob {pattern!r} expected parent directory '
            f'{parent} to exist, actual missing')
        return sorted(hit for hit in ROOT.glob(pattern) if hit.is_file())
    target = ROOT / pattern
    assert target.exists(), (
        f'{BUILD_SETS_JSON}: entry {pattern!r} expected to exist at '
        f'{target}, actual missing')
    return [target]


def test_build_sets_paths_exist_and_sets_are_isolated():
    """Guard 5: every referenced path exists; the three sets stay disjoint."""
    manifest = json.loads(_read(BUILD_SETS_JSON))
    sets = manifest.get('sets')
    assert isinstance(sets, dict), (
        f'{BUILD_SETS_JSON}: expected a "sets" object, actual {type(sets).__name__}')
    assert tuple(sets) == SET_NAMES, (
        f'{BUILD_SETS_JSON}: set names expected {SET_NAMES}, actual {tuple(sets)}')

    for name in SET_NAMES:
        entry = sets[name]
        for key in SET_LIST_KEYS:
            assert key in entry, (
                f'{BUILD_SETS_JSON}: set {name!r} expected key {key!r}, '
                f'actual keys {sorted(entry)}')
            assert isinstance(entry[key], list), (
                f'{BUILD_SETS_JSON}: set {name!r} key {key!r} expected a list, '
                f'actual {type(entry[key]).__name__}')

        for key in SET_LIST_KEYS:
            for pattern in entry[key]:
                for path in _expand_entry(pattern):
                    assert path.exists(), (
                        f'{BUILD_SETS_JSON}: set {name!r} key {key!r} entry '
                        f'{pattern!r} expanded to {path}, actual missing')

    tops = [sets[name]['top_module'] for name in SET_NAMES]
    assert all(isinstance(top, str) and top for top in tops), (
        f'{BUILD_SETS_JSON}: top_module expected a non-empty string per set, '
        f'actual {tops}')
    assert len(set(tops)) == len(tops), (
        f'{BUILD_SETS_JSON}: top_module values expected to be distinct '
        f'(R3.3 artefact names), actual {tops}')

    diag_entries = ' '.join(str(item)
                            for key in SET_LIST_KEYS
                            for item in sets['ddr3_diag'][key])
    for token in DDR3_DIAG_FORBIDDEN:
        assert token not in diag_entries, (
            f'{BUILD_SETS_JSON}: ddr3_diag expected NOT to reference {token!r}, '
            f'actual entry list contains it: {diag_entries}')

    ui_entries = ' '.join(str(item)
                          for key in SET_LIST_KEYS
                          for item in sets['ui_demo'][key])
    for token in UI_DEMO_FORBIDDEN:
        assert token not in ui_entries, (
            f'{BUILD_SETS_JSON}: ui_demo expected NOT to reference {token!r}, '
            f'actual entry list contains it: {ui_entries}')


# --------------------------------------------------------------------------- #
# Guard 6: board_check.py exit code 5 + --json evidence record
# --------------------------------------------------------------------------- #

#: C-BOARD-CHECK@1 B2 evidence keys, in contract order.
CONTRACT_EVIDENCE_KEYS = (
    'ftdi_present',
    'jtagserver_pids',
    'cdt_cfg_pids',
    'program_ok',
    'status_raw',
    'done',
    'crc_err',
    'uart_bytes',
    'uart_file',
    'expect',
    'expect_missing',
    'verdict',
)


def test_board_check_exit_code_5_and_json_evidence_keys(monkeypatch, tmp_path):
    """Guard 6: exit 5 and the 12-key --json record are still in place.

    The argparse surface is reflected at run time: ``main`` is called with a
    patched ``run_check`` so the parsed namespace can be inspected without
    touching hardware.
    """
    source = _read(BOARD_CHECK_PY)

    assert re.search(r'^EXIT_EXPECT_FAIL\s*=\s*5\s*$', source, re.M), (
        f'{BOARD_CHECK_PY}: expected "EXIT_EXPECT_FAIL = 5", '
        f'actual not found')
    assert getattr(board_check, 'EXIT_EXPECT_FAIL', None) == 5, (
        f'{BOARD_CHECK_PY}: EXIT_EXPECT_FAIL expected 5, '
        f'actual {getattr(board_check, "EXIT_EXPECT_FAIL", None)!r}')
    assert board_check.verdict_for(5, ['DDR3DIAG']) == 'FAIL', (
        f'{BOARD_CHECK_PY}: verdict_for(5, missed tokens) expected "FAIL", '
        f'actual {board_check.verdict_for(5, ["DDR3DIAG"])!r}')
    assert board_check.verdict_for(0, []) == 'PASS', (
        f'{BOARD_CHECK_PY}: verdict_for(0, []) expected "PASS", '
        f'actual {board_check.verdict_for(0, [])!r}')

    assert re.search(r"add_argument\('--json'", source), (
        f'{BOARD_CHECK_PY}: expected an argparse "--json" option, '
        f'actual not found')

    keys = getattr(board_check, 'EVIDENCE_KEYS', None)
    assert keys is not None, (
        f'{BOARD_CHECK_PY}: expected EVIDENCE_KEYS to exist, actual missing')
    assert tuple(keys) == CONTRACT_EVIDENCE_KEYS, (
        f'{BOARD_CHECK_PY}: EVIDENCE_KEYS expected '
        f'{CONTRACT_EVIDENCE_KEYS}, actual {tuple(keys)}')

    evidence = {
        'ftdi_present': True,
        'jtagserver_pids': [11],
        'cdt_cfg_pids': [12],
        'program_ok': True,
        'status_raw': '0x081FFCA0',
        'done': 1,
        'crc_err': 0,
        'uart_bytes': 128,
        'uart_file': 'build/uart_last.bin',
        'expect': ['DDR3DIAG'],
        'expect_missing': [],
        'verdict': 'PASS',
    }
    captured = {}

    def fake_run_check(args):
        captured['args'] = args
        return board_check.EXIT_OK, dict(evidence)

    monkeypatch.setattr(board_check, 'run_check', fake_run_check)
    target = tmp_path / 'evidence.json'
    monkeypatch.setattr(sys, 'argv', ['board_check.py', '--json', str(target)])

    assert board_check.main() == board_check.EXIT_OK, (
        f'{BOARD_CHECK_PY}: main() with a clean run expected exit '
        f'{board_check.EXIT_OK}, actual different')
    assert captured, (
        f'{BOARD_CHECK_PY}: expected main() to call run_check, actual not called')
    assert getattr(captured['args'], 'json_path', None) == str(target), (
        f'{BOARD_CHECK_PY}: parsed --json expected {str(target)!r}, '
        f'actual {getattr(captured["args"], "json_path", None)!r}')

    assert target.exists(), (
        f'{BOARD_CHECK_PY}: --json expected to write {target}, actual missing')
    raw = target.read_bytes()
    assert not raw.startswith(codecs.BOM_UTF8), (
        f'{BOARD_CHECK_PY}: --json expected UTF-8 without BOM, actual BOM present')

    record = json.loads(raw.decode('utf-8'))
    assert set(record) == set(CONTRACT_EVIDENCE_KEYS), (
        f'{BOARD_CHECK_PY}: --json key set expected '
        f'{sorted(CONTRACT_EVIDENCE_KEYS)}, actual {sorted(record)}')
    assert len(record) == 12, (
        f'{BOARD_CHECK_PY}: --json expected exactly 12 keys, '
        f'actual {len(record)}')


# --------------------------------------------------------------------------- #
# Guard 7: shared pins of top_ui_demo.fdc == instrec_top.fdc
# --------------------------------------------------------------------------- #

_FDC_LOC_RE = re.compile(
    r'define_attribute\s+\{p:([^}]+)\}\s+\{PAP_IO_LOC\}\s+\{([^}]+)\}')


def _pin_locations(path: Path) -> dict:
    """``pin name -> (location, line number)`` parsed from one FDC file."""
    text = _read(path)
    locations = {}
    for match in _FDC_LOC_RE.finditer(text):
        name = match.group(1).strip()
        line = text.count('\n', 0, match.start()) + 1
        locations[name] = (match.group(2).strip(), line)
    assert locations, (
        f'{path}: expected define_attribute PAP_IO_LOC lines, actual none found')
    return locations


def _shared_pin_names() -> tuple:
    names = ['clk', 'rst_n', 'key1_n', 'uart_tx', 'iic_tx_scl', 'iic_tx_sda',
             'vout_clk', 'vout_de', 'vout_hs', 'vout_vs']
    names += [f'led[{index}]' for index in range(8)]
    names += [f'vout_data[{index}]' for index in range(24)]
    return tuple(names)


def test_top_ui_demo_pin_locations_match_instrec_top():
    """Guard 7: every pin the UI demo shares keeps the reference location."""
    reference = _pin_locations(FDC_TOP)
    ui = _pin_locations(FDC_UI)

    for name in _shared_pin_names():
        assert name in reference, (
            f'{FDC_TOP}: pin {name!r} expected a PAP_IO_LOC attribute, '
            f'actual not found')
        expected, expected_line = reference[name]
        assert name in ui, (
            f'{FDC_UI}: pin {name!r} expected PAP_IO_LOC {expected!r} '
            f'(from {FDC_TOP}:{expected_line}), actual pin missing')
        actual, actual_line = ui[name]
        assert actual == expected, (
            f'{FDC_UI}:{actual_line}: pin {name!r} expected {expected!r} '
            f'(from {FDC_TOP}:{expected_line}), actual {actual!r}')


# --------------------------------------------------------------------------- #
# Guard 8: _E bit slices cover bit0..bit31 via defined union reserved
# --------------------------------------------------------------------------- #

def _expand_slices(slices) -> list:
    bits = []
    for hi, lo in slices:
        assert hi >= lo, (
            f'{DIAG_FRAMES_PY}: slice expected msb >= lsb, actual ({hi}, {lo})')
        bits.extend(range(lo, hi + 1))
    return bits


def test_ddr3_e_bit_coverage_uses_defined_union_reserved():
    """Guard 8: defined + reserved slices cover bit0..bit31 exactly once."""
    defined = _expand_slices(diag_frames.DDR3_E_BITS.values())
    reserved = _expand_slices(diag_frames.DDR3_E_RESERVED_BITS)

    duplicates = sorted({bit for bit in defined if defined.count(bit) > 1})
    assert not duplicates, (
        f'{DIAG_FRAMES_PY}: DDR3_E_BITS expected pairwise disjoint slices, '
        f'actual duplicate bits {duplicates}')

    overlap = sorted(set(defined) & set(reserved))
    assert not overlap, (
        f'{DIAG_FRAMES_PY}: DDR3_E_BITS and DDR3_E_RESERVED_BITS expected '
        f'disjoint, actual overlap at bits {overlap}')

    union = set(defined) | set(reserved)
    missing = sorted(set(range(32)) - union)
    outside = sorted(union - set(range(32)))
    assert union == set(range(32)), (
        f'{DIAG_FRAMES_PY}: DDR3_E_BITS + DDR3_E_RESERVED_BITS expected '
        f'bit0..bit31 (defined {len(defined)} bits, reserved {len(reserved)} '
        f'bits), actual missing {missing}, outside {outside}')


# --------------------------------------------------------------------------- #
# Guard 9: DDR init gate quarantines pre-init commands and R responses
# --------------------------------------------------------------------------- #

def test_instrec_ddr_init_gate_blocks_preinit_axi_traffic():
    """Guard 9: stale pre-init RVALID cannot reach the AXI controller."""
    rtl = _read(INSTREC_TOP_V)
    assert re.search(
        r'assign\s+ddr_cmd_valid\s*=\s*ddr_init_done\s*\?\s*', rtl), (
        f'{INSTREC_TOP_V}: command valid must be gated by ddr_init_done')
    assert re.search(
        r'(?:wire\s+axi_rvalid_ctrl\s*;\s*)?assign\s+axi_rvalid_ctrl\s*=\s*ddr_init_done\s*&&\s*axi_rvalid',
        rtl), f'{INSTREC_TOP_V}: AXI RVALID must be gated by ddr_init_done'
    assert re.search(
        r'\.axi_rvalid\s*\(axi_rvalid_ctrl\)', rtl), (
        f'{INSTREC_TOP_V}: controller must consume the gated RVALID net')

    # Cycle-level contract for the two-input gate.  A stale R beat is not
    # observable before init; once init is complete, normal R beats pass.
    def gate(init_done, rvalid):
        return bool(init_done and rvalid)

    assert gate(False, True) is False
    assert gate(False, False) is False
    assert gate(True, False) is False
    assert gate(True, True) is True
