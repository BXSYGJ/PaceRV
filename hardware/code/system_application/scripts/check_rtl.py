#!/usr/bin/env python3
"""check_rtl.py - SV-2005 static lint for the InstRec-FPGA RTL sources.

Implements the REQ-BLD-003 lint checklist (task T-GP-06, design doc
section 12.1):

  1. SV-2012 syntax blacklist (project style is SV-2005, PREFERENCE):
       always_ff / always_comb / always_latch
       'logic' type declarations (use wire / reg explicitly)
       empty instance connections like '.port()'
       interface / modport constructs
       unique / priority prefixes
  2. Identifier naming: module names and signal names must be snake_case,
     parameter names must be UPPER_SNAKE_CASE.
  3. Comments must be pure ASCII (English-only comments).
  4. Combinational always blocks must use '@*' sensitivity; an explicit
     signal list without posedge/negedge edges is a violation.
  5. File header must carry the module name in a comment block, the module
     name must equal the file name, and one file holds exactly one module.

Scans src/**/*.v recursively. The src/hdmi/ demo files are copied
third-party code kept verbatim (see reports/asset_trace.md) and are
excluded from the scan by default.

Usage:
    python scripts/check_rtl.py [--src <dir>] [--exclude <name> ...]

Exit codes: 0 = no violations, 1 = violations found, 2 = usage error.
Output format: <file>:<line>:<rule>:<description> per violation.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# --------------------------------------------------------------------------- #
# Constants and rule definitions
# --------------------------------------------------------------------------- #

DEFAULT_SRC = Path(__file__).resolve().parents[1] / 'src'
DEFAULT_EXCLUDES = ('hdmi',)
HEADER_SCAN_LINES = 30  # comment block considered as the "file header"

# SV-2012 blacklist keywords: (rule code, regex, message).
SV2012_BLACKLIST = (
    ('SV2012_ALWAYS_FF', re.compile(r'\balways_ff\b'),
     "SV-2012 keyword 'always_ff' is blacklisted (use 'always @(posedge ...)')"),
    ('SV2012_ALWAYS_COMB', re.compile(r'\balways_comb\b'),
     "SV-2012 keyword 'always_comb' is blacklisted (use 'always @*')"),
    ('SV2012_ALWAYS_LATCH', re.compile(r'\balways_latch\b'),
     "SV-2012 keyword 'always_latch' is blacklisted (use 'always @*')"),
    ('SV2012_LOGIC', re.compile(r'\blogic\b'),
     "'logic' type declaration is blacklisted (declare wire/reg explicitly)"),
    ('SV2012_EMPTY_PORT', re.compile(r'\.\s*[A-Za-z_]\w*\s*\(\s*\)'),
     "empty instance connection '.port()' is blacklisted (SV-2012 shortcut)"),
    ('SV2012_INTERFACE', re.compile(r'\binterface\b'),
     "SV-2012 'interface' construct is blacklisted"),
    ('SV2012_MODPORT', re.compile(r'\bmodport\b'),
     "SV-2012 'modport' construct is blacklisted"),
    ('SV2012_UNIQUE', re.compile(r'\bunique\b'),
     "'unique' prefix is blacklisted (SV-2012 case priority hint)"),
    ('SV2012_PRIORITY', re.compile(r'\bpriority\b'),
     "'priority' prefix is blacklisted (SV-2012 case priority hint)"),
)

SNAKE_RE = re.compile(r'^[a-z](?:[a-z0-9_]*[a-z0-9])?$')
UPPER_RE = re.compile(r'^[A-Z](?:[A-Z0-9_]*[A-Z0-9])?$')
IDENT_RE = re.compile(r'[A-Za-z_]\w*')

MODULE_RE = re.compile(r'(?m)^\s*module\s+([A-Za-z_]\w*)')
PORT_DECL_RE = re.compile(
    r'\b(?:input|output|inout)\s+(?:(?:wire|reg)\s+)?(?:signed\s+)?'
    r'(?:\[[^\]]*\]\s*)?([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*(?:\s*\[[^\]]*\])?)*)'
)
NET_DECL_RE = re.compile(
    r'(?m)^\s*(?:wire|reg)\s+(?:signed\s+)?(?:\[[^\]]*\]\s*)?([^;]+);'
)
PARAM_DECL_RE = re.compile(r'\b(?:parameter|localparam)\b')
GENVAR_DECL_RE = re.compile(r'\bgenvar\s+([A-Za-z_]\w*)')
ALWAYS_RE = re.compile(r'\balways\s*@\s*(\*|\(\s*\*\s*\)|\(([^)]*)\))')


@dataclass(frozen=True)
class Violation:
    """One lint finding, rendered as file:line:rule:description."""

    file: str
    line: int
    rule: str
    message: str

    def format(self) -> str:
        return f'{self.file}:{self.line}:{self.rule}:{self.message}'


# --------------------------------------------------------------------------- #
# Comment / string masking
# --------------------------------------------------------------------------- #

def mask_source(text: str) -> tuple[str, list[tuple[int, str]]]:
    """Blank out comments and string literals, preserving line structure.

    Returns (masked_code, comments) where masked_code has the same number
    of newlines as the original text (so line numbers stay valid) and
    comments is a list of (start_line, comment_text) for every comment.
    String literal contents are blanked so that keywords inside strings
    cannot trigger false positives.
    """
    out: list[str] = []
    comments: list[tuple[int, str]] = []
    state = 'code'
    comment_start_line = 0
    comment_chars: list[str] = []
    line = 1
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ''
        if state == 'code':
            if ch == '/' and nxt == '/':
                state = 'line_comment'
                comment_start_line = line
                comment_chars = []
                out.append('  ')
                i += 2
                continue
            if ch == '/' and nxt == '*':
                state = 'block_comment'
                comment_start_line = line
                comment_chars = []
                out.append('  ')
                i += 2
                continue
            if ch == '"':
                state = 'string'
                # Keep the quote itself: a string-literal argument such as
                # .TW_FILE("path.hex") must NOT collapse into an empty
                # parenthesized connection ".TW_FILE(   )" after masking,
                # which would falsely trip SV2012_EMPTY_PORT.
                out.append('"')
                i += 1
                continue
            if ch == '\n':
                line += 1
            out.append(ch)
        elif state == 'line_comment':
            if ch == '\n':
                comments.append((comment_start_line, ''.join(comment_chars)))
                state = 'code'
                line += 1
                out.append(ch)
            else:
                comment_chars.append(ch)
                out.append(' ')
        elif state == 'block_comment':
            if ch == '*' and nxt == '/':
                comments.append((comment_start_line, ''.join(comment_chars)))
                state = 'code'
                out.append('  ')
                i += 2
                continue
            if ch == '\n':
                line += 1
                comment_chars.append(ch)
                out.append(ch)
            else:
                comment_chars.append(ch)
                out.append(' ')
        else:  # string literal
            if ch == '\\' and nxt:
                out.append('  ')
                i += 2
                continue
            if ch == '"':
                state = 'code'
                # Keep the closing quote (see the opening-quote note above).
                out.append('"')
            else:
                if ch == '\n':
                    line += 1
                out.append(' ')
        i += 1
    if state in ('line_comment', 'block_comment'):
        comments.append((comment_start_line, ''.join(comment_chars)))
    return ''.join(out), comments


def line_of_offset(masked: str, offset: int) -> int:
    """1-based line number of a character offset inside masked text."""
    return masked.count('\n', 0, offset) + 1


# --------------------------------------------------------------------------- #
# Per-rule check helpers
# --------------------------------------------------------------------------- #

def check_blacklist(masked: str, rel: str) -> list[Violation]:
    """Rule 1: SV-2012 keyword / construct blacklist."""
    found: list[Violation] = []
    for rule, regex, message in SV2012_BLACKLIST:
        for m in regex.finditer(masked):
            found.append(Violation(rel, line_of_offset(masked, m.start()), rule, message))
    return found


def check_always_sensitivity(masked: str, rel: str) -> list[Violation]:
    """Rule 4: combinational always blocks must use '@*' sensitivity.

    A sensitivity list that mentions signals but contains no posedge /
    negedge edge describes combinational logic and must be written as
    'always @*' (or 'always @(*)').
    """
    found: list[Violation] = []
    for m in ALWAYS_RE.finditer(masked):
        signals = m.group(2)
        if signals is None:
            continue  # '@*' or @(*)' form is the accepted style
        if 'posedge' in signals or 'negedge' in signals:
            continue  # sequential block, edge-driven
        found.append(Violation(
            rel, line_of_offset(masked, m.start()), 'ALWAYS_SENSITIVITY',
            "combinational always block must use '@*' sensitivity, not an "
            "explicit signal list",
        ))
    return found


def check_comments_ascii(comments: list[tuple[int, str]], rel: str) -> list[Violation]:
    """Rule 3: comments must be pure ASCII (English comments only)."""
    found: list[Violation] = []
    for line_no, ctext in comments:
        for ch in ctext:
            if ord(ch) > 127:
                found.append(Violation(
                    rel, line_no, 'NON_ASCII_COMMENT',
                    f'comment contains non-ASCII character U+{ord(ch):04X} '
                    '(comments must be English/ASCII only)',
                ))
                break
    return found


def _split_declarator_list(chunk: str) -> list[str]:
    """Extract declared identifiers from 'a, b[3:0], c = ...' style chunks."""
    names: list[str] = []
    for part in chunk.split(','):
        part = part.split('=')[0]
        m = IDENT_RE.search(part)
        if m:
            names.append(m.group(0))
    return names


def _check_name(name: str, pattern: re.Pattern, no_double_underscore: bool) -> bool:
    if not pattern.match(name):
        return False
    if no_double_underscore and '__' in name:
        return False
    return True


def check_naming_and_header(masked: str, comments: list[tuple[int, str]],
                            rel: str, stem: str) -> list[Violation]:
    """Rules 2 and 5: identifier naming, file header, module/file identity."""
    found: list[Violation] = []

    # ---- module declarations ----
    modules = [(m.group(1), line_of_offset(masked, m.start()))
               for m in MODULE_RE.finditer(masked)]
    if not modules:
        found.append(Violation(
            rel, 1, 'MODULE_MISSING',
            'no module declaration found in a .v source file',
        ))
        return found
    if len(modules) > 1:
        found.append(Violation(
            rel, modules[0][1], 'MODULE_COUNT',
            f'{len(modules)} module declarations in one file '
            '(expected exactly one module per file)',
        ))
    for name, line_no in modules:
        if not _check_name(name, SNAKE_RE, True):
            found.append(Violation(
                rel, line_no, 'NAMING_MODULE',
                f"module name '{name}' is not snake_case",
            ))
        if name != stem:
            found.append(Violation(
                rel, line_no, 'MODULE_FILE_MISMATCH',
                f"module name '{name}' does not match file name '{stem}.v'",
            ))

    # ---- rule 5: header comment must mention the module name ----
    header_text = ' '.join(ctext for line_no, ctext in comments
                           if line_no <= HEADER_SCAN_LINES)
    if not any(re.search(r'\b' + re.escape(name) + r'\b', header_text)
               for name, _ in modules):
        found.append(Violation(
            rel, 1, 'HEADER_COMMENT_MISSING',
            "file header (first "
            f'{HEADER_SCAN_LINES} lines) has no comment mentioning the '
            f"module name '{modules[0][0]}'",
        ))

    # ---- rule 2: signal identifiers (ports, nets, registers, genvars) ----
    # Port / net / parameter declarations are matched line by line so that a
    # trailing comma in an ANSI port list cannot swallow the next line.
    for line_no, line in enumerate(masked.split('\n'), start=1):
        for m in PORT_DECL_RE.finditer(line):
            for name in _split_declarator_list(m.group(1)):
                if not _check_name(name, SNAKE_RE, True):
                    found.append(Violation(
                        rel, line_no, 'NAMING_SIGNAL',
                        f"signal name '{name}' is not snake_case",
                    ))
    for m in NET_DECL_RE.finditer(masked):
        line_no = line_of_offset(masked, m.start())
        # Net declarations may carry an initializer ("wire [2:0] a = b + C;").
        # Only the declarator list (left of '=') holds declared names; the
        # initializer expression may legitimately reference UPPER_CASE
        # parameters, so cut it off before splitting.
        decl_list = m.group(1).split('=', 1)[0]
        for name in _split_declarator_list(decl_list):
            if not _check_name(name, SNAKE_RE, True):
                found.append(Violation(
                    rel, line_no, 'NAMING_SIGNAL',
                    f"signal name '{name}' is not snake_case",
                ))
    for m in GENVAR_DECL_RE.finditer(masked):
        line_no = line_of_offset(masked, m.start())
        if not _check_name(m.group(1), SNAKE_RE, True):
            found.append(Violation(
                rel, line_no, 'NAMING_SIGNAL',
                f"genvar name '{m.group(1)}' is not snake_case",
            ))

    # ---- rule 2: parameter identifiers (UPPER_SNAKE_CASE) ----
    for line_no, line in enumerate(masked.split('\n'), start=1):
        m = PARAM_DECL_RE.search(line)
        if not m:
            continue
        chunk = line[m.end():]
        if ';' in chunk:
            chunk = chunk.split(';', 1)[0]
        for name in _split_declarator_list(chunk):
            if name in ('wire', 'reg', 'signed', 'integer',
                        'input', 'output', 'inout'):
                continue  # type/direction keywords, not the parameter name
            if not _check_name(name, UPPER_RE, True):
                found.append(Violation(
                    rel, line_no, 'NAMING_PARAM',
                    f"parameter name '{name}' is not UPPER_SNAKE_CASE",
                ))
    return found


# --------------------------------------------------------------------------- #
# File / tree scanning
# --------------------------------------------------------------------------- #

def lint_file(path: Path, rel: str) -> list[Violation]:
    """Run all lint rules over one Verilog source file."""
    try:
        text = path.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        # Non-UTF-8 files are themselves suspect; decode leniently so the
        # comment rule can still flag the non-ASCII content.
        text = path.read_text(encoding='utf-8', errors='replace')
    masked, comments = mask_source(text)
    violations: list[Violation] = []
    violations += check_blacklist(masked, rel)
    violations += check_always_sensitivity(masked, rel)
    violations += check_comments_ascii(comments, rel)
    violations += check_naming_and_header(masked, comments, rel, path.stem)
    return sorted(violations, key=lambda v: (v.line, v.rule))


def lint_tree(src_root: Path, excludes: tuple[str, ...] = DEFAULT_EXCLUDES) -> list[Violation]:
    """Lint every .v file under src_root, skipping excluded directories."""
    if not src_root.is_dir():
        raise FileNotFoundError(f'source directory not found: {src_root}')
    violations: list[Violation] = []
    for path in sorted(src_root.rglob('*.v')):
        rel = path.relative_to(src_root).as_posix()
        if any(part in excludes for part in path.relative_to(src_root).parts):
            continue
        violations += lint_file(path, rel)
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='SV-2005 static lint for InstRec-FPGA RTL sources '
                    '(REQ-BLD-003).')
    parser.add_argument('--src', default=str(DEFAULT_SRC),
                        help='RTL source root to scan (default: %(default)s)')
    parser.add_argument('--exclude', nargs='+', default=list(DEFAULT_EXCLUDES),
                        help='directory names to skip (default: %(default)s); '
                             'src/hdmi demo files are third-party code')
    args = parser.parse_args(argv)

    src_root = Path(args.src)
    try:
        violations = lint_tree(src_root, tuple(args.exclude))
    except FileNotFoundError as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 2

    for v in violations:
        print(v.format())
    scanned = [p for p in sorted(src_root.rglob('*.v'))
               if not any(part in tuple(args.exclude)
                          for part in p.relative_to(src_root).parts)]
    dirty = {v.file for v in violations}
    print(f'checked {len(scanned)} .v file(s) under {src_root}: '
          f'{len(violations)} violation(s) in {len(dirty)} file(s)')
    return 0 if not violations else 1


if __name__ == '__main__':
    sys.exit(main())