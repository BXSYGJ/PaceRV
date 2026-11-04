"""Pin the parameterised build pipeline (C-BUILD-TOKENS@1).

The full design needs ~1.5 h of place and route and the licence allows only one
``pds_shell.exe`` at a time, so debugging was blocked on routing time.  The fix
is a build-set manifest (``scripts/build_sets.json``) plus a tokenised
``scripts/build_full.tcl``: the same six-stage TCL builds

  ``full``       -> ``instrec_top``     the whole SoC
  ``ddr3_diag``  -> ``top_ddr3_diag``   DDR3 bring-up scope only
  ``ui_demo``    -> ``top_ui_demo``     HDMI + UI scope only

``run_pds_full.ps1 -BuildSet <set>`` expands the set's globs, substitutes the
eight tokens and (with ``-DryRun``) stops after writing ``build.tcl`` without
ever starting PDS.

Everything here is static or ``-DryRun`` based: no synthesis, no place and
route, no licence, no JTAG, no board.  The ``src/diag/top_*`` and
``constraints/top_*.fdc`` assets are delivered by parallel tasks, so the checks
tolerate files that do not exist yet (a glob over a missing directory expands
to nothing and an explicit missing path is kept as a path string only).
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
TCL_TEMPLATE = SCRIPTS / 'build_full.tcl'
PS_SCRIPT = SCRIPTS / 'run_pds_full.ps1'
SETS_PATH = SCRIPTS / 'build_sets.json'

TOKENS = (
    '__PROJECT_ROOT__',
    '__BUILD_ROOT__',
    '__TOP_MODULE__',
    '__PROJECT_NAME__',
    '__DESIGN_FILES__',
    '__IP_FILES__',
    '__CONSTRAINT_FILES__',
    '__HEX_COPY_BLOCK__',
)
SET_NAMES = ('full', 'ddr3_diag', 'ui_demo', 'conv1_test', 'mel_test', 'core_only', 'rv_core', 'pcm1808_diag', 'emergency_demo')
SET_KEYS = ('top_module', 'sources', 'ip_cores', 'constraints', 'hex_dirs')
TOP_MODULES = {
    'emergency_demo': 'top_emergency_demo',
    'pcm1808_diag': 'top_pcm1808_probe',
    'full': 'instrec_top',
    'ddr3_diag': 'top_ddr3_diag',
    'ui_demo': 'top_ui_demo',
    'conv1_test': 'top_npu_conv1_test',
    'mel_test': 'top_mel_test',
    'core_only': 'top_core_only',
    'rv_core': 'top_rv_core',
}
FULL_CONSTRAINTS = ('instrec_top.fdc', 'ddr3_100h.fdc', 'clock_groups_async.fdc')
DIAG_CONSTRAINTS = ('ddr3_100h.fdc', 'top_ddr3_diag.fdc')

SUMMARY_RE = re.compile(
    r'^DRYRUN top=(?P<top>\S+) set=(?P<set>\S+) design=(?P<design>\d+) '
    r'ip=(?P<ip>\d+) constraint=(?P<constraint>\d+) hex=(?P<hex>\d+)\s*$',
    re.M,
)
TCL_PATH_RE = re.compile(r'^DRYRUN build\.tcl:\s*(?P<path>.+?)\s*$', re.M)
ADD_DESIGN_RE = re.compile(r'^add_design "(?P<path>[^"]+)"$', re.M)
ADD_CONSTRAINT_RE = re.compile(r'^add_constraint "(?P<path>[^"]+)"$', re.M)
FILE_MKDIR_RE = re.compile(r'^file mkdir "(?P<path>[^"]+)"$', re.M)
FILE_COPY_RE = re.compile(r'^file copy -force "(?P<src>[^"]+)" "(?P<dst>[^"]+)"$', re.M)


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def load_sets():
    return json.loads(SETS_PATH.read_text(encoding='utf-8'))


def expected_files(patterns):
    """Mirror run_pds_full.ps1's Expand-BuildSetFiles in Python.

    Wildcard entries are globbed (missing directories yield nothing); plain
    entries are kept even when the file does not exist yet, because the build
    sets reference assets that parallel tasks deliver later.
    """
    ordered = []
    seen = set()
    for pattern in patterns:
        if '*' in pattern or '?' in pattern:
            for hit in sorted(ROOT.glob(pattern), key=lambda p: str(p).lower()):
                if not hit.is_file():
                    continue
                key = str(hit).lower()
                if key in seen:
                    continue
                seen.add(key)
                ordered.append(hit)
        else:
            candidate = ROOT / pattern
            key = str(candidate).lower()
            if key in seen:
                continue
            seen.add(key)
            ordered.append(candidate)
    return ordered


def as_posix_lower(paths):
    return {Path(str(p)).resolve().as_posix().lower() for p in paths}


def tcl_lines(tcl, pattern, group='path'):
    return [m.group(group) for m in pattern.finditer(tcl)]


def basenames(paths):
    return [Path(p).name for p in paths]


def code_only(text):
    """Drop comment lines so documentation may mention a token or a flag."""
    return '\n'.join(ln for ln in text.splitlines() if not ln.lstrip().startswith('#'))


@pytest.fixture(scope='session')
def powershell():
    exe = shutil.which('powershell')
    if exe is None:
        pytest.skip('Windows PowerShell is not available')
    return exe


def run_ps(exe, *args, timeout=240):
    return subprocess.run(
        [exe, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(PS_SCRIPT), *args],
        capture_output=True,
        text=True,
        encoding='utf-8',
        errors='replace',
        timeout=timeout,
    )


def _fail_hint(proc):
    return 'returncode={0}\nstdout:\n{1}\nstderr:\n{2}'.format(
        proc.returncode, proc.stdout, proc.stderr)


def dry_run(exe, set_name):
    """Run one -DryRun and return (summary dict, build.tcl text, tcl path)."""
    proc = run_ps(exe, '-BuildSet', set_name, '-DryRun')
    assert proc.returncode == 0, '-DryRun for {0} failed: {1}'.format(set_name, _fail_hint(proc))
    match = SUMMARY_RE.search(proc.stdout)
    assert match, 'missing DRYRUN summary line for {0}: {1}'.format(set_name, _fail_hint(proc))
    tcl_match = TCL_PATH_RE.search(proc.stdout)
    assert tcl_match, 'missing "DRYRUN build.tcl:" line: {0}'.format(_fail_hint(proc))
    tcl_path = Path(tcl_match.group('path'))
    assert tcl_path.is_file(), 'build.tcl was not written: {0}'.format(tcl_path)
    summary = {key: match.group(key) for key in ('top', 'set', 'design', 'ip', 'constraint', 'hex')}
    return summary, tcl_path.read_text(encoding='utf-8'), tcl_path, proc


@pytest.fixture(scope='session')
def dry_runs(powershell):
    runs = {}
    paths = []
    for name in SET_NAMES:
        summary, tcl, tcl_path, proc = dry_run(powershell, name)
        runs[name] = {'summary': summary, 'tcl': tcl, 'path': tcl_path, 'proc': proc}
        paths.append(tcl_path)
    yield runs
    # Remove only this session's dry-run directories, and only when the
    # directory holds nothing but the generated build.tcl (a real PDS run has
    # logs and stage directories, so it can never be matched).
    for tcl_path in paths:
        run_dir = tcl_path.parent
        try:
            entries = {entry.name for entry in run_dir.iterdir()}
        except OSError:
            continue
        if entries == {'build.tcl'} and run_dir.parent.name == 'pds':
            shutil.rmtree(run_dir, ignore_errors=True)


# --------------------------------------------------------------------------- #
# P1  eight tokens present, compile uses the injected top module
# --------------------------------------------------------------------------- #
def test_template_declares_all_eight_tokens():
    template = TCL_TEMPLATE.read_text(encoding='utf-8')
    missing = [token for token in TOKENS if token not in template]
    assert not missing, 'build_full.tcl is missing tokens: {0}'.format(missing)


def test_template_compiles_the_injected_top_module():
    template = TCL_TEMPLATE.read_text(encoding='utf-8')
    assert re.search(r'^compile -system_verilog -top_module __TOP_MODULE__$', template, re.M), \
        'compile must take the __TOP_MODULE__ token'
    assert '-top_module instrec_top' not in template, \
        'the top module must no longer be hard-coded inside build_full.tcl'


def test_template_uses_explicit_lists_instead_of_directory_globs():
    template = TCL_TEMPLATE.read_text(encoding='utf-8')
    for block in ('__DESIGN_FILES__', '__IP_FILES__', '__CONSTRAINT_FILES__', '__HEX_COPY_BLOCK__'):
        assert re.search(r'^{0}$'.format(re.escape(block)), template, re.M), \
            '{0} must stand alone on its own line'.format(block)
    assert 'foreach design [lsort [glob' not in template, \
        'PDS must never see a directory glob; the file list comes from build_sets.json'
    assert 'add_design "__PROJECT_ROOT__/' not in template, \
        'design/IP paths are generated as absolute paths by run_pds_full.ps1'


# --------------------------------------------------------------------------- #
# P2  build set schema
# --------------------------------------------------------------------------- #
def test_build_sets_schema_is_one():
    assert json.loads(SETS_PATH.read_text(encoding='utf-8'))['schema'] == 1


def test_build_sets_define_the_three_sets_with_five_keys():
    sets = load_sets()['sets']
    assert tuple(sets) == SET_NAMES, 'expected exactly the listed build sets, got {0}'.format(tuple(sets))
    for name, definition in sets.items():
        assert tuple(definition) == SET_KEYS, \
            'build set {0} must have exactly the keys {1}'.format(name, SET_KEYS)
        assert definition['top_module'] == TOP_MODULES[name]


def test_full_set_constraint_order_is_semantic():
    """clock_groups_async.fdc must load after ddr3_100h.fdc (SDC-2027)."""
    constraints = load_sets()['sets']['full']['constraints']
    assert basenames(constraints) == list(FULL_CONSTRAINTS), \
        'full constraint load order is semantic and must stay {0}'.format(FULL_CONSTRAINTS)
    assert constraints.index('constraints/ddr3_100h.fdc') < \
        constraints.index('constraints/clock_groups_async.fdc')


def test_diag_set_does_not_carry_the_alternative_top_levels():
    """Only the diag assets, otherwise PDS sees several top-level candidates."""
    sources = load_sets()['sets']['ddr3_diag']['sources']
    assert 'src/diag/top_ui_demo.v' not in sources
    ui_sources = load_sets()['sets']['ui_demo']['sources']
    assert 'src/diag/top_ddr3_diag.v' not in ui_sources


# --------------------------------------------------------------------------- #
# P3  full set: add_design count == glob expansion, constraint order
# --------------------------------------------------------------------------- #
def test_full_design_list_matches_glob_expansion(dry_runs):
    definition = load_sets()['sets']['full']
    expected_design = expected_files(definition['sources'])
    expected_ip = expected_files(definition['ip_cores'])
    tcl = dry_runs['full']['tcl']

    design_paths = tcl_lines(tcl, ADD_DESIGN_RE)
    design_verilog = [p for p in design_paths if Path(p).suffix in ('.v', '.sv')]
    ip_cores = [p for p in design_paths if Path(p).suffix == '.idf']

    assert as_posix_lower(design_verilog) == as_posix_lower(expected_design), \
        'add_design .v lines must equal the live glob expansion of full.sources'
    assert as_posix_lower(ip_cores) == as_posix_lower(expected_ip)
    assert len(design_paths) == len(expected_design) + len(expected_ip)
    assert int(dry_runs['full']['summary']['design']) == len(expected_design)
    assert int(dry_runs['full']['summary']['ip']) == len(expected_ip)


def test_full_dry_run_summary_and_constraint_order(dry_runs):
    summary = dry_runs['full']['summary']
    tcl = dry_runs['full']['tcl']
    assert summary['top'] == 'instrec_top'
    assert summary['set'] == 'full'
    assert int(summary['design']) == len(expected_files(load_sets()['sets']['full']['sources']))
    assert basenames(tcl_lines(tcl, ADD_CONSTRAINT_RE)) == list(FULL_CONSTRAINTS)
    assert 'compile -system_verilog -top_module instrec_top' in tcl


def test_full_hex_tables_are_copied_below_the_work_dir(dry_runs):
    definition = load_sets()['sets']['full']
    tcl = dry_runs['full']['tcl']
    expected_hex = []
    for hex_dir in definition['hex_dirs']:
        expected_hex.extend(sorted((ROOT / hex_dir).glob('*.hex')))

    mkdirs = tcl_lines(tcl, FILE_MKDIR_RE)
    copies = tcl_lines(tcl, FILE_COPY_RE, 'src')
    assert len(mkdirs) == len(definition['hex_dirs']), \
        'one file mkdir per hex_dir so $readmemh prefixes resolve'
    assert as_posix_lower(copies) == as_posix_lower(expected_hex)
    assert int(dry_runs['full']['summary']['hex']) == len(expected_hex)
    for mkdir in mkdirs:
        assert 'build/pds/' in mkdir, 'hex tables must be copied under -work_dir'


# --------------------------------------------------------------------------- #
# P4  ddr3_diag scope
# --------------------------------------------------------------------------- #
def test_ddr3_diag_scope(dry_runs):
    summary = dry_runs['ddr3_diag']['summary']
    tcl = dry_runs['ddr3_diag']['tcl']
    design_paths = tcl_lines(tcl, ADD_DESIGN_RE)

    assert summary['top'] == 'top_ddr3_diag'
    assert summary['set'] == 'ddr3_diag'
    assert 'compile -system_verilog -top_module top_ddr3_diag' in tcl
    for forbidden in ('src/npu/', 'src/mel/', 'src/hdmi/', 'ipcore/pll/', 'ipcore/pll_audio/'):
        assert not [p for p in design_paths if forbidden in p], \
            'ddr3_diag must not pull in {0}'.format(forbidden)
    assert as_posix_lower(design_paths) == \
        as_posix_lower(expected_files(load_sets()['sets']['ddr3_diag']['sources']) +
                       expected_files(load_sets()['sets']['ddr3_diag']['ip_cores']))
    assert basenames(tcl_lines(tcl, ADD_CONSTRAINT_RE)) == list(DIAG_CONSTRAINTS)
    assert int(summary['hex']) == 0
    assert not tcl_lines(tcl, FILE_COPY_RE), 'ddr3_diag has no $readmemh tables'


# --------------------------------------------------------------------------- #
# P5  ui_demo scope
# --------------------------------------------------------------------------- #
def test_ui_demo_scope(dry_runs):
    summary = dry_runs['ui_demo']['summary']
    tcl = dry_runs['ui_demo']['tcl']
    design_paths = tcl_lines(tcl, ADD_DESIGN_RE)

    assert summary['top'] == 'top_ui_demo'
    assert summary['set'] == 'ui_demo'
    assert 'compile -system_verilog -top_module top_ui_demo' in tcl
    assert not [p for p in design_paths if 'ddr3_test.idf' in p], \
        'ui_demo must not attach the DDR3 IP core'
    assert 'ddr3_100h.fdc' not in code_only(tcl), \
        'ui_demo must not load the DDR3 pin constraints'
    assert any('ipcore/pll/pll.idf' in p for p in design_paths)
    assert basenames(tcl_lines(tcl, ADD_CONSTRAINT_RE)) == ['top_ui_demo.fdc']
    assert any(p.endswith('src/diag/top_ui_demo.v') for p in design_paths)
    assert as_posix_lower(design_paths) == \
        as_posix_lower(expected_files(load_sets()['sets']['ui_demo']['sources']) +
                       expected_files(load_sets()['sets']['ui_demo']['ip_cores']))


def test_all_generated_paths_are_absolute_under_the_project(dry_runs):
    prefix = ROOT.as_posix().lower() + '/'
    repo_prefix = ROOT.parent.as_posix().lower() + '/'
    for name, run in dry_runs.items():
        for path in tcl_lines(run['tcl'], ADD_DESIGN_RE) + tcl_lines(run['tcl'], ADD_CONSTRAINT_RE):
            allowed = path.lower().startswith(prefix) or (name in ('rv_core', 'full', 'emergency_demo') and path.lower().startswith(repo_prefix + 'cpu/rtl/'))
            assert allowed, \
                '{0}: {1} is not under the project root'.format(name, path)
            assert '\\' not in path, 'build.tcl must use forward slashes'


def test_build_tcl_has_no_unexpanded_token(dry_runs):
    for name, run in dry_runs.items():
        assert '__' not in run['tcl'], '{0}: build.tcl still contains an unexpanded token'.format(name)


# --------------------------------------------------------------------------- #
# P6  artifact naming, P9 -DryRun never starts PDS
# --------------------------------------------------------------------------- #
def test_artifact_naming_rules():
    source = PS_SCRIPT.read_text(encoding='utf-8')
    assert re.search(
        r"if \(\$BuildSet -eq 'full'\) \{ \$latestBase = 'instrec-latest' \} "
        r"else \{ \$latestBase = \$topModule \+ '-latest' \}",
        source,
    ), 'full must keep instrec-latest.*; other sets use <TopModule>-latest.*'
    assert "($latestBase + '.sbit')" in source
    assert "($latestBase + '.json')" in source
    assert 'BuildSet = $BuildSet' in source, 'manifest.json must record the build set'
    assert "($topModule + '.sbit')" in source, 'the PDS bitstream name must follow the top module'
    assert "($topModule + '.rtr')" in source, 'the timing report name must follow the top module'


def test_dry_run_never_starts_pds(dry_runs):
    for name, run in dry_runs.items():
        stdout = run['proc'].stdout
        assert 'PDS PID:' not in stdout, '{0}: -DryRun started pds_shell.exe'.format(name)
        assert 'PDS ExitCode:' not in stdout
        assert 'Bitstream:' not in stdout
        assert 'SHA-256:' not in stdout
        assert 'DRYRUN top=' in stdout


# --------------------------------------------------------------------------- #
# P1  -TopModule conflict is rejected
# --------------------------------------------------------------------------- #
def test_top_module_override_must_match_the_set(powershell):
    proc = run_ps(powershell, '-BuildSet', 'ddr3_diag', '-TopModule', 'instrec_top', '-DryRun')
    assert proc.returncode != 0, 'a -TopModule that disagrees with the build set must throw'
    # PowerShell 5.1 truncates long Write-Error records at ~80 columns, so
    # assert the stable parts: the word conflict and the absence of a summary.
    combined = re.sub(r'\s+', ' ', proc.stdout + proc.stderr).lower()
    assert 'conflict' in combined
    assert 'DRYRUN top=' not in proc.stdout, 'the rejected run must not report a summary'
    assert not TCL_PATH_RE.search(proc.stdout), 'the rejected run must not write build.tcl'


def test_top_module_override_accepted_when_it_matches(powershell):
    proc = run_ps(powershell, '-BuildSet', 'full', '-TopModule', 'instrec_top', '-DryRun')
    assert proc.returncode == 0, _fail_hint(proc)
    assert 'DRYRUN top=instrec_top set=full' in proc.stdout
    tcl_match = TCL_PATH_RE.search(proc.stdout)
    assert tcl_match
    tcl_path = Path(tcl_match.group('path'))
    run_dir = tcl_path.parent
    try:
        entries = {entry.name for entry in run_dir.iterdir()}
    except OSError:
        entries = set()
    if entries == {'build.tcl'} and run_dir.parent.name == 'pds':
        shutil.rmtree(run_dir, ignore_errors=True)


# --------------------------------------------------------------------------- #
# P7/P8  the four rewritten blocks must stay untouched
# --------------------------------------------------------------------------- #
STAGE_COMMANDS = (
    r'^compile -system_verilog -top_module __TOP_MODULE__$',
    r'^synthesize -ads -selected_syn_tool_opt 2$',
    r'^dev_map$',
    r'^pnr$',
    r'^report_timing$',
    r'^gen_bit_stream$',
)


def test_six_stage_flow_is_preserved_and_pnr_stays_bare():
    template = TCL_TEMPLATE.read_text(encoding='utf-8')
    positions = []
    for pattern in STAGE_COMMANDS:
        match = re.search(pattern, template, re.M)
        assert match, 'six-stage flow lost: {0}'.format(pattern)
        positions.append(match.start())
    assert positions == sorted(positions), 'the six stages must keep their order'
    pnr_lines = [ln for ln in code_only(template).splitlines() if ln.startswith('pnr')]
    assert pnr_lines == ['pnr'], 'pnr must have no parameters (E-2 / L4)'


def test_pds_error_scan_is_preserved():
    source = PS_SCRIPT.read_text(encoding='utf-8')
    assert "if ($line -match '^E:')" in source
    assert "'SCBV has not been set'" in source
    assert "'Bitstream-2001'" in source
    assert 'if ($process.ExitCode -ne 0) { throw "PDS exited with code' in source
    assert '$errorLines | Select-Object -First 10' in source


def test_stage_check_timing_and_manifest_are_preserved():
    source = PS_SCRIPT.read_text(encoding='utf-8')
    assert ("$stages = @('compile', 'synthesize', 'dev_map', 'pnr', "
            "'report_timing', 'gen_bit_stream')") in source
    assert r"'Executing\s*:\s*'" in source
    assert '[System.Security.Cryptography.SHA256]::Create()' in source
    assert 'BitstreamSha256 = $sbitHash' in source
    assert 'StageStatus = $stageStatus' in source
    assert 'Device Utilization Summary' in source
    assert 'Setup Summary(Slow Corner):' in source
    assert 'Hold Summary(Slow Corner):' in source
    assert 'ConvertTo-Json -Depth 6' in source


# --------------------------------------------------------------------------- #
# P10  PowerShell 5.1 compatibility
# --------------------------------------------------------------------------- #
def test_ps51_static_constraints():
    # Comments may name the rule they forbid, so scan code lines only.
    source = code_only(PS_SCRIPT.read_text(encoding='utf-8'))
    assert 'Set-Content' not in source, \
        'Set-Content -Encoding UTF8 emits a BOM on PS 5.1'
    assert '??' not in source, 'PS7 null-coalescing operator used'
    assert '&&' not in source, 'PS7 chain operator used'
    start_process = [ln for ln in source.splitlines() if 'Start-Process' in ln]
    assert start_process, 'Start-Process call disappeared'
    for line in start_process:
        assert '-Wait' in line, 'Start-Process must be called with -Wait so ExitCode is reliable'
    assert source.count('[System.Text.UTF8Encoding]::new($false)') >= 2, \
        'generated text must be written as BOM-less UTF8'



def test_no_new_pnr_parameters_were_added():
    forbidden = ('-parallel', '-gplace_seed', '-plc_decongestion', '-dc_duplication',
                 '-fast_router', '-route_parallel')
    for path in (TCL_TEMPLATE, PS_SCRIPT):
        code = [ln for ln in path.read_text(encoding='utf-8').splitlines()
                if not ln.lstrip().startswith('#')]
        joined = '\n'.join(code)
        for flag in forbidden:
            assert flag not in joined, '{0}: forbidden PnR knob {1}'.format(path.name, flag)


def test_ps_script_parses():
    """A syntax error in the build script would only surface mid-build."""
    if shutil.which('powershell') is None:
        pytest.skip('Windows PowerShell is not available')
    command = (
        '$errs = $null; $tokens = $null; '
        '$null = [System.Management.Automation.Language.Parser]::ParseFile('
        '"{0}", [ref]$tokens, [ref]$errs); '
        'if ($errs.Count) {{ $errs | ForEach-Object {{ $_.Message }}; exit 1 }} else {{ "PARSE OK" }}'
    ).format(PS_SCRIPT)
    proc = subprocess.run(
        ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
        capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert 'PARSE OK' in proc.stdout


def test_resource_gate_exit_skips_preparser_but_stops_execution():
    """PDS parses Tcl before execution; exit must not kill its parser worker."""
    if shutil.which('powershell') is None:
        pytest.skip('Windows PowerShell is not available')
    import tkinter
    proc = subprocess.run(
        ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
         str(PS_SCRIPT), '-BuildSet', 'full', '-StopAfter', 'dev_map', '-DryRun'],
        capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    match = TCL_PATH_RE.search(proc.stdout)
    assert match, proc.stdout
    source = Path(match['path']).read_text(encoding='utf-8')
    # Execute the real generated flow with harmless Tcl stage stubs. In the
    # parser pass, all stages remain visible and exit must not be evaluated.
    for execution_pass in (False, True):
        interp = tkinter.Tcl()
        interp.eval('set reached {}; proc exit {} {error GATE_STOP}; proc unknown {args} {}')
        for command in ('compile', 'synthesize', 'dev_map', 'pnr', 'report_timing', 'gen_bit_stream'):
            interp.eval('proc %s {args} {global reached; lappend reached %s}' % (command, command))
        if execution_pass:
            interp.eval('proc open_project {args} {}')
            with pytest.raises(tkinter.TclError, match='GATE_STOP'):
                interp.eval(source)
            assert interp.eval('set reached') == 'compile synthesize dev_map'
        else:
            interp.eval(source)
            assert interp.eval('set reached') == 'compile synthesize dev_map pnr report_timing gen_bit_stream'
