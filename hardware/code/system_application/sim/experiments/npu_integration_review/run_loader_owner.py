"""Real weight_loader plus owner: native done precedes read FIFO delivery."""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'sim'))
import run_sim as sim


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('Expected exactly one TB edit: ' + before)
    return text.replace(before, after)


def prepare_tb():
    assets = ROOT / 'build/sim/loader_owner_assets'
    assets.mkdir(parents=True, exist_ok=True)
    sim.prepare_weight_loader(assets)
    text = (ROOT / 'sim/tb_weight_loader.sv').read_text(encoding='ascii')
    text = text.replace('module tb_weight_loader;', 'module tb_loader_owner;')
    text = text.replace('build/sim/weight_loader/payload.hex', 'build/sim/loader_owner_assets/payload.hex')
    # Preserve the checked UART protocol and payload model; interpose owner
    # between the real loader and its original native responder.
    mappings = {
        '.cmd_valid   (cmd_valid)': '.cmd_valid   (l_cmd_valid)',
        '.cmd         (cmd)': '.cmd         (l_cmd)',
        '.wdata       (wdata)': '.wdata       (l_wdata)',
        '.wready_beat (wready_beat)': '.wready_beat (l_wready)',
        '.done        (done)': '.done        (l_done)',
        '.rd_ready    (rd_ready)': '.rd_ready    (l_rd_ready)',
        '.rd_valid    (rd_valid)': '.rd_valid    (l_rd_valid)',
    }
    for before, after in mappings.items():
        text = replace_once(text, before, after)
    block = '''
    wire l_cmd_valid,l_wready,l_done,l_rd_ready,l_rd_valid;
    wire [36:0] l_cmd;
    wire [255:0] l_wdata;
    wire owner_idle,owner_error;
    npu_m1_owner owner(
        .clk(clk),.rst_n(rst_n),.loader_allowed(1'b1),
        .l_valid(l_cmd_valid),.l_cmd(l_cmd),.l_wdata(l_wdata),.l_rd_ready(l_rd_ready),
        .l_wready(l_wready),.l_rvalid(l_rd_valid),.l_done(l_done),
        .n_valid(1'b0),.n_cmd(37'd0),.n_wdata(256'd0),.n_rd_ready(1'b0),
        .n_wready(),.n_rvalid(),.n_done(),.n_abort(),
        .m_valid(cmd_valid),.m_cmd(cmd),.m_wdata(wdata),.m_rd_ready(rd_ready),
        .m_wready(wready_beat),.m_rvalid(rd_valid),.m_done(done),.m_abort(1'b0),
        .idle(owner_idle),.protocol_error(owner_error));
    always @(posedge clk) if(rst_n && owner_error)$fatal(1,"owner fault");
'''
    text = replace_once(text, '    weight_loader dut (', block + '\n    weight_loader dut (')
    text = replace_once(text, "rd_data   <= mem_rd(c_addr, 5'd0);", "done      <= 1'b1; // Native done occurs before first FIFO delivery.\n                        rd_data   <= mem_rd(c_addr, 5'd0);")
    text = replace_once(text, "done      <= 1'b1;      // last beat and done, same cycle", "// Native done was already sent before FIFO delivery.")
    text = text.replace('RESULT: PASS tb_weight_loader', 'RESULT: PASS real weight_loader + M1 owner early-native-done')
    return text


def main():
    text = prepare_tb()
    tb = ROOT / 'build/sim/loader_owner_assets/tb_loader_owner.sv'
    tb.write_text(text, encoding='ascii')
    verilator, _ = sim._toolchain()
    case = sim.Case(name='loader_owner', tb=str(tb), rtl=[str(ROOT / 'src/ctrl/weight_loader.v'), str(HERE / 'npu_m1_owner.v')], timeout=120)
    result = sim.run_case(case, verilator, argparse.Namespace(clean=False, trace=False, verbose=True))
    print(result.output)
    print('ok=' + str(result.ok) + ' log=' + str(result.log_path) + ' detail=' + result.detail)
    return 0 if result.ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
