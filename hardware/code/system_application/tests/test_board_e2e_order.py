"""Ordering and short-circuit behaviour of the board bring-up chain.

``board_e2e.py`` runs four stages in a fixed order and must stop at the first
failure -- otherwise a board that never booted could be reported as "layers
compared".  Hardware is stubbed out: only the orchestration is under test.
"""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

import board_e2e                      # noqa: E402


class Recorder:
    def __init__(self, fail_on=None):
        self.calls = []
        self.fail_on = fail_on

    def __call__(self, argv, **kwargs):
        script = Path(argv[1]).name
        self.calls.append(script)
        rc = 1 if script == self.fail_on else 0
        return SimpleNamespace(returncode=rc, stdout='', stderr='')


def test_all_stages_run_in_order(monkeypatch):
    rec = Recorder()
    monkeypatch.setattr(board_e2e.subprocess, 'run', rec)
    rc = board_e2e.main(['--stage', 'all'])
    assert rc == 0
    assert rec.calls == ['board_check.py', 'weight_upload.py',
                         'uart_capture.py', 'compare_layers.py']


def test_stops_at_first_failure(monkeypatch):
    rec = Recorder(fail_on='weight_upload.py')
    monkeypatch.setattr(board_e2e.subprocess, 'run', rec)
    rc = board_e2e.main(['--stage', 'all'])
    assert rc == 1
    assert rec.calls == ['board_check.py', 'weight_upload.py']


def test_boot_stage_alone(monkeypatch):
    rec = Recorder()
    monkeypatch.setattr(board_e2e.subprocess, 'run', rec)
    assert board_e2e.main(['--stage', 'boot']) == 0
    assert rec.calls == ['board_check.py']


def test_layers_stage_skips_programming(monkeypatch):
    rec = Recorder()
    monkeypatch.setattr(board_e2e.subprocess, 'run', rec)
    assert board_e2e.main(['--stage', 'layers']) == 0
    assert rec.calls == ['uart_capture.py', 'compare_layers.py']


def test_boot_expectations_cover_the_status_lines():
    """The boot stage must demand the same lines sys_ctrl emits."""
    assert board_e2e.BOOT_EXPECT == ['INSTREC BOOT', 'DDR3 SELFTEST', 'DDROK']