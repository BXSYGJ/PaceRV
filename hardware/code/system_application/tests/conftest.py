"""Pytest configuration: expose scripts/ modules to test modules."""

import sys
from pathlib import Path

# Put instrec_fpga/scripts on sys.path so tests can import generator modules
# (gen_mel_tables, golden_pipeline, ...) without package installation.
SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))