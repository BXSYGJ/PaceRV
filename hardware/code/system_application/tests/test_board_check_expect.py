"""Offline tests for the C-BOARD-CHECK@1 contract (T6).

Nothing here touches hardware.  ``serial.Serial``, the PowerShell-backed
probes (``ftdi_present`` / ``jtag_procs`` / ``cfg_procs`` /
``port_listening``), ``ensure_server``, ``start_server`` and ``run_tcl`` are
all replaced, and the UART capture loop is driven by a fake clock, so every
test is deterministic and never sleeps.

Covered acceptance items:
  B1  --expect all seen -> exit 0 + "boot: PASS"; any miss -> exit 5 + FAIL
  B2  --json key set matches the contract exactly and the file has no BOM
  B3  build/uart_last.bin is still written and uart_file points at it
  B4  --diag-only keeps its behaviour and its 0/2 exit codes
  B5  exit 2/3/4 are never overwritten by 5
  (7) no real port / process is ever touched
"""

from __future__ import annotations

import codecs
import json
import sys
import types
from pathlib import Path

import pytest

import board_check

# Contract key set, in contract order (plan section 2.2.7 B2).
CONTRACT_KEYS = (
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

BOOT_OK = b'INSTREC BOOT\r\nDDR3 SELFTEST OK\r\nDDROK\r\n'


class FakeSerial:
    """Stand-in for pyserial: yields one payload, then reports EOF.

    The instance doubles as the ``serial.Serial`` factory (it is callable), so
    the script's ``serial.Serial(port, 115200, timeout=0.1)`` call returns this
    very object and can be inspected afterwards.
    """

    def __init__(self, harness):
        self.harness = harness
        self.port = None
        self.open_calls = 0
        self.reads = 0
        self.delivered = False
        self.closed = False

    def __call__(self, port, baud, timeout=None):
        self.open_calls += 1
        self.port = port
        return self

    def read(self, size):
        self.reads += 1
        # Mark delivery before returning so the fake clock stops the loop after
        # exactly one read, even when the payload is empty.
        self.delivered = True
        return self.harness.uart_payload if self.reads == 1 else b''

    def close(self):
        self.closed = True


class FakeClock:
    """Clock that jumps past the capture deadline once a read has happened."""

    def __init__(self, serial):
        self.serial = serial

    def time(self):
        return 1e6 if self.serial.delivered else 1e3

    def sleep(self, seconds):
        raise AssertionError('offline board tests must never sleep')


class Harness:
    """Everything a test needs to drive ``board_check.main()`` offline."""

    def __init__(self, tmp_path, monkeypatch):
        self.tmp = tmp_path
        self.monkeypatch = monkeypatch
        self.calls = {}
        self.uart_payload = b''
        self.program = ('PROGRAM FLOW DONE\nStatus Register: 0x081FFCA0\n', 0)
        self.ftdi_ok = True
        self.server = ('reused', 4242)
        self.jtag_pids = [4242]
        self.sbit = tmp_path / 'fake.sbit'
        self.sbit.write_bytes(b'SBIT-PLACEHOLDER')

        self.serial = FakeSerial(self)
        self.clock = FakeClock(self.serial)

        monkeypatch.setattr(board_check, 'LOG_DIR', tmp_path / 'build')
        monkeypatch.setitem(sys.modules, 'serial',
                            types.SimpleNamespace(Serial=self.serial))
        monkeypatch.setattr(board_check, 'time', self.clock)
        monkeypatch.setattr(board_check, 'port_listening',
                            self._counted('port_listening', lambda timeout=0.5: True))
        monkeypatch.setattr(board_check, 'ftdi_present',
                            self._counted('ftdi_present', lambda: self.ftdi_ok))
        monkeypatch.setattr(board_check, 'jtag_procs',
                            self._counted('jtag_procs', lambda: list(self.jtag_pids)))
        monkeypatch.setattr(board_check, 'cfg_procs',
                            self._counted('cfg_procs', lambda: []))
        monkeypatch.setattr(board_check, 'ensure_server',
                            self._counted('ensure_server',
                                          lambda wait_existing=30.0: self.server))
        monkeypatch.setattr(board_check, 'run_tcl',
                            self._counted('run_tcl',
                                          lambda name, body, timeout=180: self.program))
        # A second jtagserver must never be spawned (rule R3).
        monkeypatch.setattr(board_check, 'start_server',
                            self._counted('start_server', self._forbid_start))

    def _counted(self, name, func):
        def wrapper(*args, **kwargs):
            self.calls[name] = self.calls.get(name, 0) + 1
            return func(*args, **kwargs)
        return wrapper

    def _forbid_start(self, timeout=15.0):
        raise AssertionError('board_check must never start a second jtagserver')

    def run(self, *argv):
        self.monkeypatch.setattr(sys, 'argv', ['board_check.py', *argv])
        return board_check.main()

    def evidence(self, path):
        return json.loads(Path(path).read_text(encoding='utf-8'))


@pytest.fixture
def board(tmp_path, monkeypatch):
    return Harness(tmp_path, monkeypatch)


# --------------------------------------------------------------------------
# B1: exit code and stdout verdict
# --------------------------------------------------------------------------

def test_all_expected_tokens_exit_zero(board, capsys):
    board.uart_payload = BOOT_OK
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'INSTREC BOOT', 'DDROK')
    out = capsys.readouterr().out
    assert rc == 0
    assert 'boot: PASS (all 2 expected lines seen)' in out


def test_missing_token_exits_five(board, capsys):
    board.uart_payload = b'INSTREC BOOT\r\n'
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'INSTREC BOOT', 'DDROK')
    out = capsys.readouterr().out
    assert rc == 5
    assert 'boot: FAIL (missing DDROK)' in out


def test_empty_capture_with_expect_exits_five(board, capsys):
    """A silent board must never look like success."""
    board.uart_payload = b''
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'DDR3DIAG', 'DDR3RS')
    out = capsys.readouterr().out
    assert rc == 5
    assert 'uart: 0 bytes' in out
    assert 'boot: FAIL (missing DDR3DIAG, DDR3RS)' in out


def test_no_expect_keeps_zero(board, capsys):
    board.uart_payload = BOOT_OK
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12')
    out = capsys.readouterr().out
    assert rc == 0
    assert 'boot:' not in out


# --------------------------------------------------------------------------
# B2: JSON evidence file
# --------------------------------------------------------------------------

def test_json_key_set_matches_contract(board, tmp_path):
    board.uart_payload = BOOT_OK
    evidence_path = tmp_path / 'evidence.json'
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'INSTREC BOOT', 'DDROK', '--json', str(evidence_path))
    assert rc == 0
    record = board.evidence(evidence_path)
    # exactly the contract keys, in contract order, nothing added or dropped
    assert tuple(record) == CONTRACT_KEYS
    assert set(record) == set(CONTRACT_KEYS)


def test_json_values_are_typed_per_contract(board, tmp_path):
    board.uart_payload = BOOT_OK
    evidence_path = tmp_path / 'evidence.json'
    board.run('--sbit', str(board.sbit), '--seconds', '12',
              '--expect', 'INSTREC BOOT', 'DDROK', '--json', str(evidence_path))
    record = board.evidence(evidence_path)

    assert record['ftdi_present'] is True
    assert record['jtagserver_pids'] == [4242]
    assert record['cdt_cfg_pids'] == []
    assert record['program_ok'] is True
    assert record['status_raw'] == '0x081FFCA0'
    assert record['done'] == 1
    assert record['crc_err'] == 0
    assert record['uart_bytes'] == len(BOOT_OK)
    assert record['expect'] == ['INSTREC BOOT', 'DDROK']
    assert record['expect_missing'] == []
    assert record['verdict'] == 'PASS'
    assert isinstance(record['uart_file'], str) and record['uart_file']

    assert isinstance(record['ftdi_present'], bool)
    assert isinstance(record['program_ok'], bool)
    assert isinstance(record['uart_bytes'], int) and not isinstance(record['uart_bytes'], bool)
    assert isinstance(record['done'], int)
    assert isinstance(record['crc_err'], int)
    assert all(isinstance(pid, int) for pid in record['jtagserver_pids'])
    assert all(isinstance(pid, int) for pid in record['cdt_cfg_pids'])
    assert all(isinstance(token, str) for token in record['expect'])
    assert all(isinstance(token, str) for token in record['expect_missing'])
    assert record['verdict'] in ('PASS', 'FAIL')


def test_json_has_no_bom(board, tmp_path):
    board.uart_payload = BOOT_OK
    evidence_path = tmp_path / 'evidence.json'
    board.run('--sbit', str(board.sbit), '--seconds', '12',
              '--expect', 'INSTREC BOOT', '--json', str(evidence_path))
    raw = evidence_path.read_bytes()
    assert raw[:3] != codecs.BOM_UTF8
    assert raw[0:1] != b'\xef'
    raw.decode('utf-8')  # must be plain UTF-8


def test_json_records_missing_tokens_and_fail_verdict(board, tmp_path):
    board.uart_payload = b'INSTREC BOOT\r\n'
    evidence_path = tmp_path / 'evidence.json'
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'INSTREC BOOT', 'DDR3RS', '--json', str(evidence_path))
    assert rc == 5
    record = board.evidence(evidence_path)
    assert record['expect_missing'] == ['DDR3RS']
    assert record['verdict'] == 'FAIL'
    assert record['uart_bytes'] == len(b'INSTREC BOOT\r\n')


def test_json_written_on_early_hardware_exit(board, tmp_path):
    """The evidence file exists even when nothing was programmed."""
    board.ftdi_ok = False
    evidence_path = tmp_path / 'evidence.json'
    rc = board.run('--diag-only', '--json', str(evidence_path))
    assert rc == 2
    record = board.evidence(evidence_path)
    assert tuple(record) == CONTRACT_KEYS
    assert record['ftdi_present'] is False
    assert record['program_ok'] is False
    assert record['status_raw'] is None
    assert record['done'] is None
    assert record['crc_err'] is None
    assert record['uart_bytes'] == 0
    assert record['expect'] == []
    assert record['expect_missing'] == []
    assert record['verdict'] == 'FAIL'


def test_no_json_file_without_the_flag(board):
    board.uart_payload = BOOT_OK
    board.run('--sbit', str(board.sbit), '--seconds', '12')
    assert list(board.tmp.glob('*.json')) == []


def test_relative_json_path_resolves_below_project_root(board, tmp_path, monkeypatch):
    monkeypatch.setattr(board_check, 'ROOT', tmp_path)
    rc = board.run('--diag-only', '--json', 'reports/board_check.json')
    assert rc == 0
    assert (tmp_path / 'reports' / 'board_check.json').is_file()


def test_json_write_failure_keeps_the_board_exit_code(board, tmp_path, capsys):
    """An unwritable --json target must not mask the hardware verdict."""
    board.uart_payload = BOOT_OK
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'INSTREC BOOT', '--json', str(tmp_path))
    out = capsys.readouterr().out
    assert rc == 0
    assert '!! cannot write json evidence' in out


# --------------------------------------------------------------------------
# B3: uart_last.bin is still written and referenced
# --------------------------------------------------------------------------

def test_uart_last_bin_written_and_referenced(board, tmp_path):
    board.uart_payload = BOOT_OK
    evidence_path = tmp_path / 'evidence.json'
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'INSTREC BOOT', '--json', str(evidence_path))
    assert rc == 0

    uart_file = tmp_path / 'build' / 'uart_last.bin'
    assert uart_file.is_file()
    assert uart_file.read_bytes() == BOOT_OK

    record = board.evidence(evidence_path)
    pointer = Path(record['uart_file'])
    assert pointer.name == 'uart_last.bin'
    assert pointer.resolve() == uart_file.resolve()
    assert pointer.is_file()
    assert record['uart_bytes'] == len(BOOT_OK)


# --------------------------------------------------------------------------
# B4: --diag-only unchanged (exit 0 / 2, no programming, no UART)
# --------------------------------------------------------------------------

def test_diag_only_with_ftdi_exits_zero(board, capsys):
    rc = board.run('--diag-only')
    out = capsys.readouterr().out
    assert rc == 0
    assert 'ftdi: present' in out
    assert board.calls.get('run_tcl', 0) == 0
    assert board.calls.get('ensure_server', 0) == 0
    assert board.serial.open_calls == 0


def test_diag_only_without_ftdi_exits_two(board, capsys):
    board.ftdi_ok = False
    rc = board.run('--diag-only')
    out = capsys.readouterr().out
    assert rc == 2
    assert 'ftdi: ABSENT' in out
    assert board.calls.get('run_tcl', 0) == 0


# --------------------------------------------------------------------------
# B5: a missing token never overwrites 2/3/4
# --------------------------------------------------------------------------

def test_missing_token_does_not_override_rc_two(board):
    board.ftdi_ok = False
    board.uart_payload = b''
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'DDR3RS')
    assert rc == 2
    assert board.calls.get('run_tcl', 0) == 0


def test_missing_token_does_not_override_rc_three(board, capsys):
    board.program = ('Status Register: 0x081FFFF0\n', 1)
    board.uart_payload = b'INSTREC BOOT\r\n'
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'DDR3RS')
    out = capsys.readouterr().out
    assert rc == 3
    assert 'boot: FAIL (missing DDR3RS)' in out


def test_missing_token_does_not_override_rc_four(board, capsys):
    board.program = ('Status Register: 0x081FFFF0\n', None)
    board.uart_payload = b'INSTREC BOOT\r\n'
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'DDR3RS')
    out = capsys.readouterr().out
    assert rc == 4
    assert 'LEFT RUNNING on purpose' in out
    assert 'boot: FAIL (missing DDR3RS)' in out


def test_json_verdict_fail_when_rc_is_three(board, tmp_path):
    board.program = ('Status Register: 0x081FFFF0\n', 1)
    board.uart_payload = b'INSTREC BOOT\r\n'
    evidence_path = tmp_path / 'evidence.json'
    rc = board.run('--sbit', str(board.sbit), '--seconds', '12',
                   '--expect', 'INSTREC BOOT', '--json', str(evidence_path))
    assert rc == 3
    record = board.evidence(evidence_path)
    assert record['expect_missing'] == []
    assert record['verdict'] == 'FAIL'
    assert record['program_ok'] is False


# --------------------------------------------------------------------------
# (7) purely offline: one fake read, no process, no sleep
# --------------------------------------------------------------------------

def test_capture_loop_is_fully_faked(board):
    board.uart_payload = BOOT_OK
    rc = board.run('--sbit', str(board.sbit), '--seconds', '30',
                   '--expect', 'INSTREC BOOT')
    assert rc == 0
    assert board.serial.open_calls == 1
    assert board.serial.port == 'COM5'
    assert board.serial.reads == 1  # fake clock ends the loop after one read
    assert board.serial.closed is True
    assert board.calls['run_tcl'] == 1
    assert board.calls['ensure_server'] == 1
    assert board.calls.get('start_server', 0) == 0


def test_reused_server_path_is_kept(board, capsys):
    board.uart_payload = BOOT_OK
    board.run('--sbit', str(board.sbit), '--seconds', '12')
    out = capsys.readouterr().out
    assert 'reusing the running jtagserver (PID 4242' in out


def test_metadata_constants_are_exposed(board):
    """Static guard for downstream tasks that assert on the contract names."""
    assert board_check.EXIT_OK == 0
    assert board_check.EXIT_NO_HW == 2
    assert board_check.EXIT_PROGRAM_FAIL == 3
    assert board_check.EXIT_CFG_HUNG == 4
    assert board_check.EXIT_EXPECT_FAIL == 5
    assert board_check.EVIDENCE_KEYS == CONTRACT_KEYS