"""Unit tests for scripts/check_rtl.py (task T-GP-06, REQ-BLD-003).

Covers each of the five lint categories with at least one deliberate
violation sample plus one fully clean sample, the src/hdmi demo exclusion,
and the CLI exit codes.
"""

import importlib.util
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / 'scripts'
_spec = importlib.util.spec_from_file_location('check_rtl', SCRIPTS_DIR / 'check_rtl.py')
check_rtl = importlib.util.module_from_spec(_spec)
sys.modules['check_rtl'] = check_rtl  # required for dataclass resolution
_spec.loader.exec_module(check_rtl)


def write_file(root: Path, relpath: str, content: str) -> Path:
    """Create <root>/<relpath> with the given text and return its path."""
    path = root / relpath
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8')
    return path


def rules_of(violations):
    return {v.rule for v in violations}


# --------------------------------------------------------------------------- #
# Sample sources
# --------------------------------------------------------------------------- #

CLEAN_SAMPLE = """\
// -----------------------------------------------------------------------------
// File    : good_sample.v
// Module  : good_sample
// A fully compliant sample: SV-2005 style, snake_case identifiers,
// UPPER_SNAKE_CASE parameters, ASCII comments, @* combinational blocks.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module good_sample (
    input  wire       clk,
    input  wire       rst_n,
    output reg  [3:0] data_out
);

    localparam [3:0] RESET_VALUE = 4'd0;
    localparam [23:0] COUNT_HALF = 24'd100;

    reg [3:0] cnt_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_reg <= RESET_VALUE;
        end else begin
            cnt_reg <= cnt_reg + 4'd1;
        end
    end

    always @* begin
        data_out = cnt_reg;
    end

endmodule
"""

SV2012_SAMPLE = """\
// bad_sv2012 sample file (deliberate SV-2012 violations).
module bad_sv2012 (
    input  wire clk,
    input  logic data_in,
    output wire flag_out
);

    sub_cell u_sub (
        .clk(clk),
        .data_in(),
        .flag_out(flag_out)
    );

    always_ff @(posedge clk) begin
        flag_reg <= data_in;
    end

    always_comb begin
        flag_out = flag_reg;
    end

    unique case (data_in)
        1'b0: flag_out = 1'b0;
        1'b1: flag_out = 1'b1;
    endcase

endmodule

interface sample_if (input wire clk);
    logic data_in;
    modport consumer(input data_in);
endinterface
"""

NAMING_SAMPLE = """\
// bad_naming sample file (identifier naming violations).
module BadNaming (
    input  wire clk,
    input  wire dataIn,
    output reg  [3:0] outBus
);

    parameter width = 4;

    reg [3:0] valueCnt;

    always @(posedge clk) begin
        valueCnt <= valueCnt + 1'b1;
    end

    always @* begin
        outBus = valueCnt;
    end

endmodule
"""

# Note: the header comment deliberately does NOT mention 'orphan_mod', and
# the module name differs from the file name used below.
HEADER_SAMPLE = """\
// Some generic header comment without the module name.
module orphan_mod (
    input wire clk
);

    reg state_reg;

    always @(posedge clk) begin
        state_reg <= 1'b0;
    end

endmodule
"""

ASCII_COMMENT_SAMPLE = """\
// bad_comment sample: 这一行包含非 ASCII 的中文注释，必须被检出。
module bad_comment (
    input wire clk
);

    reg state_reg;

    always @(posedge clk) begin
        state_reg <= 1'b0;
    end

endmodule
"""

ALWAYS_SAMPLE = """\
// bad_always sample: explicit combinational sensitivity list.
module bad_always (
    input  wire a,
    input  wire b,
    output reg  y
);

    always @(a or b) begin
        y = a & b;
    end

endmodule
"""

# Blacklist words inside comments and strings must NOT be flagged.
MASK_SAMPLE = """\
// mask_sample: the comment mentions always_ff, always_comb, logic and
// interface keywords, which must not be flagged inside a comment.
module mask_sample (
    input  wire       clk,
    output wire [7:0] ascii_out
);

    assign ascii_out = "always_ff";

endmodule
"""


# --------------------------------------------------------------------------- #
# Rule category tests (five violation categories, one each minimum)
# --------------------------------------------------------------------------- #

def test_clean_sample_has_no_violations(tmp_path):
    path = write_file(tmp_path, 'good_sample.v', CLEAN_SAMPLE)
    assert check_rtl.lint_file(path, 'good_sample.v') == []


def test_sv2012_blacklist_rules(tmp_path):
    path = write_file(tmp_path, 'bad_sv2012.v', SV2012_SAMPLE)
    rules = rules_of(check_rtl.lint_file(path, 'bad_sv2012.v'))
    assert {'SV2012_ALWAYS_FF', 'SV2012_ALWAYS_COMB', 'SV2012_LOGIC',
            'SV2012_EMPTY_PORT', 'SV2012_INTERFACE', 'SV2012_MODPORT',
            'SV2012_UNIQUE'} <= rules


def test_string_argument_is_not_empty_port(tmp_path):
    # Regression: a string-literal argument such as .TW_FILE("path.hex")
    # must not be reported as an empty instance connection after the
    # string mask (historical bug: quotes were blanked, collapsing the
    # connection into ".TW_FILE(   )" and tripping SV2012_EMPTY_PORT).
    sample = (
        '// regression sample: string parameter connection\n'
        '// module string_arg\n'
        'module string_arg (\n'
        '    input  wire clk,\n'
        '    output reg  q\n'
        ');\n'
        '    rom_file #(.MEM_FILE("src/mel/table.hex")) u_rom (\n'
        '        .clk(clk),\n'
        '        .q(q)\n'
        '    );\n'
        'endmodule\n'
    )
    path = write_file(tmp_path, 'string_arg.v', sample)
    violations = check_rtl.lint_file(path, 'string_arg.v')
    assert rules_of(violations) == set()


def test_naming_rules(tmp_path):
    path = write_file(tmp_path, 'bad_naming.v', NAMING_SAMPLE)
    rules = rules_of(check_rtl.lint_file(path, 'bad_naming.v'))
    assert {'NAMING_MODULE', 'NAMING_SIGNAL', 'NAMING_PARAM'} <= rules
    # module 'BadNaming' does not match file name 'bad_naming.v'
    assert 'MODULE_FILE_MISMATCH' in rules


def test_non_ascii_comment_rule(tmp_path):
    path = write_file(tmp_path, 'bad_comment.v', ASCII_COMMENT_SAMPLE)
    rules = rules_of(check_rtl.lint_file(path, 'bad_comment.v'))
    assert 'NON_ASCII_COMMENT' in rules


def test_always_sensitivity_rule(tmp_path):
    path = write_file(tmp_path, 'bad_always.v', ALWAYS_SAMPLE)
    violations = check_rtl.lint_file(path, 'bad_always.v')
    assert rules_of(violations) == {'ALWAYS_SENSITIVITY'}


def test_header_and_module_file_rules(tmp_path):
    # file name intentionally different from the module name
    path = write_file(tmp_path, 'other_name.v', HEADER_SAMPLE)
    rules = rules_of(check_rtl.lint_file(path, 'other_name.v'))
    assert 'HEADER_COMMENT_MISSING' in rules
    assert 'MODULE_FILE_MISMATCH' in rules


# --------------------------------------------------------------------------- #
# Masking, exclusion and CLI behavior
# --------------------------------------------------------------------------- #

def test_blacklist_words_in_comments_and_strings_are_ignored(tmp_path):
    path = write_file(tmp_path, 'mask_sample.v', MASK_SAMPLE)
    assert check_rtl.lint_file(path, 'mask_sample.v') == []


def test_violation_output_format(tmp_path):
    path = write_file(tmp_path, 'bad_always.v', ALWAYS_SAMPLE)
    violation = check_rtl.lint_file(path, 'bad_always.v')[0]
    text = violation.format()
    # file:line:rule:description
    parts = text.split(':', 3)
    assert parts[0] == 'bad_always.v'
    assert parts[1].isdigit()
    assert parts[2] == 'ALWAYS_SENSITIVITY'
    assert parts[3]


def test_hdmi_directory_is_excluded(tmp_path):
    write_file(tmp_path, 'hdmi/demo_copy.v', ALWAYS_SAMPLE)
    write_file(tmp_path, 'ctrl/good_sample.v', CLEAN_SAMPLE)
    violations = check_rtl.lint_tree(tmp_path, excludes=('hdmi',))
    assert violations == []

    # without the exclusion the demo file is scanned and flagged
    violations = check_rtl.lint_tree(tmp_path, excludes=())
    assert 'ALWAYS_SENSITIVITY' in rules_of(violations)


def test_main_exit_codes(tmp_path, capsys):
    clean_root = tmp_path / 'clean_src'
    write_file(clean_root, 'good_sample.v', CLEAN_SAMPLE)
    assert check_rtl.main(['--src', str(clean_root)]) == 0

    dirty_root = tmp_path / 'dirty_src'
    write_file(dirty_root, 'bad_always.v', ALWAYS_SAMPLE)
    assert check_rtl.main(['--src', str(dirty_root)]) == 1
    out = capsys.readouterr().out
    assert 'bad_always.v:' in out
    assert 'ALWAYS_SENSITIVITY' in out


def test_main_missing_source_dir(tmp_path, capsys):
    missing = tmp_path / 'no_such_dir'
    assert check_rtl.main(['--src', str(missing)]) == 2
    assert 'error:' in capsys.readouterr().err