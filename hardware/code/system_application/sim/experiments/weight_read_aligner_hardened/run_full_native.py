"""Run the existing golden native chain with only its aligner substituted.

The baseline runner and baseline evidence are preserved. Generated assets and
logs use a separate case directory. WDMA has no read backpressure contract,
so the optional upstream readiness input is explicitly tied high here.
"""
import importlib.util
import sys
from dataclasses import replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'sim'))
import run_sim as sim

original_run_case = sim.run_case


def hardened_case(case, verilator, args):
    output = ROOT / 'build/sim/npu_full_native_hardened_assets'
    output.mkdir(parents=True, exist_ok=True)
    text = Path(case.tb).read_text(encoding='ascii')
    old = 'weight_read_aligner aligner('
    if text.count(old) != 1:
        raise RuntimeError('Baseline aligner instantiation changed; review adapter')
    text = text.replace(old, 'weight_read_aligner_hardened aligner(')
    old_tail = '.dn_done(aligned_done));'
    if text.count(old_tail) != 1:
        raise RuntimeError('Baseline aligner ports changed; review adapter')
    text = text.replace(old_tail, '.dn_done(aligned_done),.up_rd_ready(1\'b1),'
                        '.dn_abort(n_cmd_to_err[1] || n_addr_err[1]),'
                        '.protocol_error(aligner_error),.transaction_failed(aligner_failed));')
    text += '\nwire aligner_error,aligner_failed;\nalways @(posedge clk) if(rst_n && (aligner_error || aligner_failed)) $fatal(1,"hardened aligner fault");\n'
    # Extra declarations/assertion must be inside the existing TB module.
    trailer = text[text.rfind('\nwire aligner_error'):]
    text = text[:text.rfind('\nwire aligner_error')]
    position = text.rfind('endmodule')
    text = text[:position] + trailer + '\n' + text[position:]
    tb = output / 'tb_npu_full_native.sv'
    tb.write_text(text, encoding='ascii')
    rtl = [str(HERE / 'weight_read_aligner_hardened.v') if Path(p).name == 'weight_read_aligner.v' else p
           for p in case.rtl]
    return original_run_case(replace(case, name='npu_full_native_hardened', tb=str(tb), rtl=rtl), verilator, args)


if __name__ == '__main__':
    sim.run_case = hardened_case
    spec = importlib.util.spec_from_file_location('baseline_native_runner', HERE.parent / 'npu_full_native/run.py')
    baseline = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(baseline)
    raise SystemExit(baseline.main())
