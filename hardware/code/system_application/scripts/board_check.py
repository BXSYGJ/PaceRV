#!/usr/bin/env python3
"""One-shot board check: FTDI present -> program -> read status -> capture UART.

The script automates the sequence that was previously done by hand:
  1. confirm the FTDI downloader (VID_0403) is present;
  2. reuse an already-listening jtagserver, or start one and keep it;
  3. open the UART *before* programming so the boot banner is not missed;
  4. program the given .sbit through cdt_cfg and let it exit on its own;
  5. scan the chain and read the device status register (mode 3);
  6. capture N seconds of UART and print a compact report.

FTDI drop protection (2026-10-29, root cause confirmed)
------------------------------------------------------
Every previous run of this script killed cdt_cfg with a ``Popen`` terminate
call as soon as "PROGRAM FLOW DONE" appeared in the log.  That banner is
printed
*before* the TCL interpreter reaches ``cfg_disconnect``/``exit``, so the
terminate always landed while the D2XX handle was still open.  A killed
D2XX process never releases the handle, the FT2232H stops responding on the
USB bus and disappears from PnP (``CM_PROB_PHANTOM``) until the cable is
physically re-plugged.  That is the "it drops the moment you touch the
board" behaviour.

Therefore this script now enforces three rules:
  R1. the generated TCL always ends with ``exit`` so cdt_cfg finishes by
      itself (a normal run is over in a few seconds);
  R2. no code path terminates or kills cdt_cfg / cdt_js -- a stuck
      cdt_cfg is reported with its PID and left alone;
  R3. an already-open 127.0.0.1:65420 is reused instead of starting a
      second jtagserver (restarting the server also desynchronises USB).

It also records the FTDI device count before and after each step, so if the
downloader ever disappears again the exact step is named in the report.

Usage:
  python scripts/board_check.py --sbit build/instrec-latest.sbit --port COM5 --seconds 12
  python scripts/board_check.py --sbit releases/m1-20261027/instrec_top.sbit --status-only
  python scripts/board_check.py --diag-only
  python scripts/board_check.py --sbit build/top_ddr3_diag-latest.sbit --seconds 12
      --expect "DDR3DIAG" "DDR3SW" "DDR3RS" --json reports/board_check.json

Exit codes: 0 ok, 2 no downloader / port, 3 program failed, 4 cdt_cfg hung,
            5 one or more --expect tokens were not seen in the UART capture.
            A code of 2/3/4 is never downgraded to 5: the more severe state
            wins, so a missing token cannot hide a programming failure.

The --json record is UTF-8 without a BOM and always uses the same twelve keys
(see EVIDENCE_KEYS), so downstream build and board tasks can decide pass/fail
from the file alone instead of parsing stdout (C-BOARD-CHECK@1).
"""

import argparse
import os
import json
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

PDS = Path(os.environ.get('PDS_ROOT', 'C:/PDS_2022.2-SP6.4')) / 'bin'
ROOT = Path(__file__).resolve().parents[1]
LOG_DIR = ROOT / 'build'

# C-BOARD-CHECK@1 exit codes.  EXIT_EXPECT_FAIL (5) is only reported from a
# clean run; 2/3/4 already describe a more severe failure (see run_check).
EXIT_OK = 0
EXIT_NO_HW = 2
EXIT_PROGRAM_FAIL = 3
EXIT_CFG_HUNG = 4
EXIT_EXPECT_FAIL = 5

# Exact key set of the --json evidence record (C-BOARD-CHECK@1 B2).  The tuple
# order is the contract order; write_evidence_json never adds or drops a key.
EVIDENCE_KEYS = (
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

# Fallback values used when a key is absent from an evidence record.
EVIDENCE_DEFAULTS = {
    'ftdi_present': False,
    'jtagserver_pids': [],
    'cdt_cfg_pids': [],
    'program_ok': False,
    'status_raw': None,
    'done': None,
    'crc_err': None,
    'uart_bytes': 0,
    'uart_file': '',
    'expect': [],
    'expect_missing': [],
    'verdict': 'FAIL',
}


def run_ps(cmd):
    return subprocess.run(['powershell', '-NoProfile', '-Command', cmd],
                          capture_output=True, text=True)


def jtag_procs():
    """PIDs of every running jtagserver (cdt_js)."""
    out = run_ps("Get-Process cdt_js -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }")
    pids = []
    for line in out.stdout.splitlines():
        line = line.strip().lstrip('\ufeff')
        if line.isdigit():
            pids.append(int(line))
    return sorted(pids)


def cfg_procs():
    """PIDs of every running cdt_cfg (programmer UI/console)."""
    out = run_ps("Get-Process cdt_cfg -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }")
    pids = []
    for line in out.stdout.splitlines():
        line = line.strip().lstrip('\ufeff')
        if line.isdigit():
            pids.append(int(line))
    return sorted(pids)


def tools_running():
    return bool(jtag_procs())


def ftdi_present():
    out = run_ps("(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_0403' } | Measure-Object).Count")
    try:
        return int(out.stdout.strip().splitlines()[-1]) > 0
    except Exception:
        return False


def port_listening(timeout=0.5):
    try:
        with socket.create_connection(('127.0.0.1', 65420), timeout=timeout):
            return True
    except OSError:
        return False


def start_server(timeout=15.0):
    """Start the ONE jtagserver instance and wait for its TCP port.

    Callers must have already verified that no cdt_js is running; opening a
    second server means two processes race for the same FTDI handle, which is
    the second half of the "downloader drops" bug (the first half was killing
    the process).  The PID is recorded so later runs can prove they reused it.
    """
    flags = 0
    if hasattr(subprocess, 'DETACHED_PROCESS'):
        flags = subprocess.DETACHED_PROCESS
    proc = subprocess.Popen([str(PDS / 'cdt_js.exe'), '-port', '65420'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            creationflags=flags, close_fds=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    (LOG_DIR / 'jtagserver.pid').write_text(str(proc.pid), encoding='ascii')
    deadline = time.time() + timeout
    while time.time() < deadline:
        if port_listening():
            return proc.pid
        time.sleep(0.5)
    return None


def ensure_server(wait_existing=30.0):
    """Return ('reused'|'started'|'broken', pid).

    Never starts a second instance: if a cdt_js already exists it is reused
    even when its port is not up yet (it is given time to come up).  Starting
    a second server is reported as a defect, not "fixed" by spawning another.
    """
    pids = jtag_procs()
    if len(pids) > 1:
        print(f'!! {len(pids)} jtagserver instances are running {pids}; '
              f'not starting another (multiple UIs fight over the FTDI handle)')
    if pids:
        deadline = time.time() + wait_existing
        while time.time() < deadline:
            if port_listening():
                return 'reused', pids[0]
            time.sleep(0.5)
        return 'broken', pids[0]
    pid = start_server()
    if pid is None:
        return 'broken', None
    return 'started', pid


def run_tcl(name, body, timeout=180):
    """Run a TCL file through cdt_cfg and wait for it to exit on its own.

    Returns (log_text, returncode).  A returncode of None means cdt_cfg did
    not exit within the timeout; it is then left running on purpose (rule R2)
    and the caller reports it instead of killing it.
    """
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    tcl = LOG_DIR / f'board_check_{name}.tcl'
    log = LOG_DIR / f'board_check_{name}.log'
    tcl.write_text(body, encoding='utf-8', newline='\n')
    with open(log, 'w') as fh:
        proc = subprocess.Popen([str(PDS / 'cdt_cfg.exe'), '-file', str(tcl)],
                                stdout=fh, stderr=subprocess.STDOUT)
    try:
        rc = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        rc = None
    return log.read_text(errors='replace'), rc


def status_body(sbit=None, freq='10Mhz'):
    lines = [
        'cfg_set_tcl_break -flag false',
        'cfg_connect -ip 127.0.0.1 -port 65420',
        f'cfg_set_cable_property -index 0 -freq {freq}',
        'cfg_scan_chain',
    ]
    if sbit:
        lines += [
            f'cfg_assign_file -file {sbit} -device_index 0',
            'cfg_program -device_index 0',
            'after 1000',
            'cfg_scan_chain',
        ]
    lines += [
        'puts "== STATUS DONE =="',
        'catch {cfg_read_device_property -device_index 0 -mode 3}',
        'cfg_disconnect',
        # R1: cdt_cfg must terminate itself; the previous flow relied on
        # terminate() here, which is exactly what dropped the FTDI device.
        'exit',
    ]
    return '\n'.join(lines) + '\n'


def parse_done(text):
    m = re.search(r'Status Register: (0x[0-9A-Fa-f]+)', text)
    if not m:
        return None
    val = int(m.group(1), 16)
    return {'raw': m.group(1), 'done': (val >> 12) & 1, 'crc_err': (val >> 1) & 1}


def uart_file_path():
    """Absolute POSIX path of the UART capture this script writes.

    Resolved at call time (not at import time) so the path follows LOG_DIR
    when a caller or a test redirects it.
    """
    return (LOG_DIR / 'uart_last.bin').resolve().as_posix()


def initial_evidence(args):
    """Baseline evidence record holding every C-BOARD-CHECK@1 key."""
    record = {}
    for key in EVIDENCE_KEYS:
        value = EVIDENCE_DEFAULTS[key]
        record[key] = list(value) if isinstance(value, list) else value
    record['uart_file'] = uart_file_path()
    record['expect'] = list(args.expect or [])
    return record


def verdict_for(rc, missing):
    """Machine-readable verdict: PASS only for a clean run with no misses."""
    return 'PASS' if rc == EXIT_OK and not missing else 'FAIL'


def write_evidence_json(path, evidence):
    """Write the evidence record as UTF-8 JSON without a BOM.

    Relative paths are resolved against the project root (same convention as
    --sbit).  Missing keys fall back to EVIDENCE_DEFAULTS and unknown keys are
    dropped, so the written file always matches the contract key set exactly.
    """
    target = Path(path)
    if not target.is_absolute():
        target = ROOT / target
    target.parent.mkdir(parents=True, exist_ok=True)
    record = {}
    for key in EVIDENCE_KEYS:
        value = EVIDENCE_DEFAULTS[key]
        record[key] = evidence.get(key, list(value) if isinstance(value, list) else value)
    # encoding='utf-8' writes no BOM; newline='\n' keeps the file diffable.
    with open(target, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(json.dumps(record, indent=2) + '\n')
    return target


def run_check(args):
    """Run the FTDI -> program -> status -> UART sequence.

    Returns ``(exit_code, evidence)``.  The evidence record is updated on every
    exit path, including the early hardware checks, so --json can always be
    written even when nothing was programmed.
    """
    evidence = initial_evidence(args)

    present = ftdi_present()
    js = jtag_procs()
    cfg = cfg_procs()
    evidence['ftdi_present'] = present
    evidence['jtagserver_pids'] = js
    evidence['cdt_cfg_pids'] = cfg
    multi = ' (!! MULTIPLE UIs)' if len(js) > 1 or len(cfg) > 1 else ''
    print(f'ftdi: {"present" if present else "ABSENT"}  '
          f'jtagserver: {js if js else "none"}{multi}  '
          f'cdt_cfg: {cfg if cfg else "none"}  port65420: '
          f'{"open" if port_listening() else "closed"}')
    if args.diag_only:
        return (EXIT_OK if present else EXIT_NO_HW), evidence

    if not present:
        print('FTDI downloader (VID_0403) is not present in PnP; programming is impossible.')
        return EXIT_NO_HW, evidence

    if not args.status_only and not args.sbit:
        print('--sbit is required unless --status-only is used')
        return EXIT_NO_HW, evidence

    sbit = (ROOT / args.sbit).resolve().as_posix() if args.sbit else None
    if sbit and not Path(sbit).is_file():
        print(f'sbit not found: {sbit}')
        return EXIT_NO_HW, evidence

    ser = None
    chunks = []
    if not args.status_only:
        try:
            import serial
            ser = serial.Serial(args.port, 115200, timeout=0.1)
            print(f'UART {args.port} opened before programming')
        except Exception as exc:
            print(f'cannot open {args.port}: {exc}')
            return EXIT_NO_HW, evidence

    # R3: exactly ONE jtagserver. Reuse whatever is already running (it owns
    # the FTDI handle); start a server only when no cdt_js exists at all.
    procs_before = jtag_procs()
    cfg_before = cfg_procs()
    state, pid = ensure_server()
    if state == 'broken':
        print(f'existing jtagserver (PID {pid}) did not open port 65420; '
              f'NOT starting a second instance (that is what breaks the FTDI link)')
        return EXIT_NO_HW, evidence
    if state == 'started':
        print(f'jtagserver started once (PID {pid}) and kept; it is never killed by this script')
    else:
        print(f'reusing the running jtagserver (PID {pid}, not restarted)')

    rc = EXIT_OK
    try:
        body = status_body(sbit, args.freq) if sbit else status_body(None, args.freq)
        text, code = run_tcl('program', body)
        if code is None:
            print('cdt_cfg did not exit within the timeout; it was LEFT RUNNING on purpose '
                  '(killing it is what drops the FTDI device).')
            rc = EXIT_CFG_HUNG
        else:
            print(f'cdt_cfg exit code: {code}')
            if code != 0:
                rc = EXIT_PROGRAM_FAIL

        prog_ok = ('PROGRAM FLOW DONE' in text or
                   'COMMAND[Program] execute successfully' in text or
                   'The done bit is 1' in text)
        evidence['program_ok'] = prog_ok
        print(f'program: {prog_ok}')
        done = parse_done(text)
        if done:
            print(f'status: {done["raw"]} done={done["done"]} crc_err={done["crc_err"]}')
            evidence['status_raw'] = done['raw']
            evidence['done'] = done['done']
            evidence['crc_err'] = done['crc_err']
        else:
            print('status: not available')

        if ser is not None:
            deadline = time.time() + args.seconds
            while time.time() < deadline:
                data = ser.read(4096)
                if data:
                    chunks.append(data)
    finally:
        if ser is not None:
            ser.close()

    # R2 evidence: name the step if the downloader vanished during the run.
    present_after = ftdi_present()
    evidence['ftdi_present'] = present_after
    if not present_after:
        print('!! FTDI disappeared during this run (device no longer in PnP).')
        rc = EXIT_NO_HW

    # Instance hygiene: this run must not have added a second UI/server.
    procs_after = jtag_procs()
    cfg_after = cfg_procs()
    evidence['jtagserver_pids'] = procs_after
    evidence['cdt_cfg_pids'] = cfg_after
    if len(procs_after) > len(procs_before):
        print(f'!! jtagserver instances grew {procs_before} -> {procs_after} '
              f'(multiple UIs fight over one FTDI handle)')
    elif procs_after:
        print(f'jtagserver instances stable at {procs_after} (single UI, reused)')
    if len(cfg_after) > len(cfg_before):
        print(f'note: cdt_cfg instances grew {cfg_before} -> {cfg_after} '
              f'(leftovers are left running on purpose, never killed)')

    raw = b''.join(chunks)
    evidence['uart_bytes'] = len(raw)
    if raw:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        (LOG_DIR / 'uart_last.bin').write_bytes(raw)
        evidence['uart_file'] = uart_file_path()
        print(f'uart: {len(raw)} bytes (saved build/uart_last.bin)')
        expect = [x.encode() for x in (args.expect or [])]
        for line in raw.split(b'\n'):
            line = line.rstrip(b'\r')
            if not line:
                continue
            mark = ''
            if expect:
                mark = '  <-- MISSING' if not any(e in line for e in expect) else '  OK'
            printable = ''.join(chr(b) if 32 <= b < 127 else f'\\x{b:02x}' for b in line)
            print(f'  line: {printable}{mark}')
    else:
        print('uart: 0 bytes')

    # B1/B5: a missing token reports 5 only from an otherwise clean run.  An
    # expected token that is absent from a zero-byte capture counts as missing,
    # so "the board printed nothing" can never look like success.
    expect_tokens = list(args.expect or [])
    evidence['expect'] = expect_tokens
    evidence['expect_missing'] = []
    if expect_tokens:
        missing = [token for token in expect_tokens if token.encode() not in raw]
        evidence['expect_missing'] = missing
        if missing:
            print('boot: FAIL (missing ' + ', '.join(missing) + ')')
            if rc == EXIT_OK:
                rc = EXIT_EXPECT_FAIL
        else:
            print(f'boot: PASS (all {len(expect_tokens)} expected lines seen)')

    return rc, evidence


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sbit')
    ap.add_argument('--port', default='COM5')
    ap.add_argument('--seconds', type=float, default=12.0)
    ap.add_argument('--status-only', action='store_true')
    ap.add_argument('--diag-only', action='store_true',
                    help='report FTDI / jtagserver / UART state and exit')
    ap.add_argument('--freq', default='10Mhz')
    ap.add_argument('--expect', nargs='*', default=None,
                    help='substrings that must appear in the UART capture, '
                         'e.g. --expect "INSTREC BOOT" "DDR3 SELFTEST" "DDROK"')
    ap.add_argument('--json', dest='json_path', default=None,
                    help='write a UTF-8 (no BOM) evidence file with the fixed '
                         'C-BOARD-CHECK@1 key set')
    args = ap.parse_args()

    rc, evidence = run_check(args)
    evidence['verdict'] = verdict_for(rc, evidence['expect_missing'])
    if args.json_path:
        # A bad --json target must not hide the hardware result: report the
        # write failure and keep the exit code that the board state produced.
        try:
            target = write_evidence_json(args.json_path, evidence)
        except OSError as exc:
            print(f'!! cannot write json evidence: {exc}')
        else:
            print(f'json: {target.as_posix()} verdict={evidence["verdict"]}')
    return rc


if __name__ == '__main__':
    sys.exit(main())