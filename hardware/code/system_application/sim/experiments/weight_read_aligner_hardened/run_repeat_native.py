"""Two complete golden native inferences without resetting the design.

Only testbench counters restart; native DDR memory and all DUT state remain
live between starts. The single-inference source and case are preserved.
"""
import importlib.util
import sys
from dataclasses import replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'sim'))
import run_sim as sim

real_run_case = sim.run_case


def repeat_case(case, verilator, args):
    output = ROOT / 'build/sim/npu_repeat_native_hardened_assets'
    output.mkdir(parents=True, exist_ok=True)
    text = Path(case.tb).read_text(encoding='ascii')
    start_marker = ' repeat(3) @(negedge clk); start=1; @(negedge clk);start=0;'
    end_marker = '$finish;\nend\ninitial begin repeat(51000000)'
    if text.count(start_marker) != 1 or text.count(end_marker) != 1:
        raise RuntimeError('Baseline completion block changed; review repeat TB')
    text = text.replace(start_marker, ''' repeat(3) @(negedge clk);
 for(inference=0;inference<2;inference=inference+1) begin
  if(busy || done) $fatal(1,"design not idle before repeated start");
  prob_count=0;count_conv1=0;count_conv2=0;count_conv3=0;count_conv4=0;
  count_pool1=0;count_pool2=0;count_pool3=0;count_pool4=0;
  count_gap=0;count_fc1=0;count_fc2_logits=0;replay0=0;replay1=0;prev=-1;
  start=1;@(negedge clk);start=0;
  if(!busy || cycles>1) $fatal(1,"new start did not restart busy/cycle counter");
  $display("REPEAT BEGIN inference=%0d",inference+1);
''')
    text = text.replace(end_marker, '''
 $display("REPEAT COMPLETE inference=%0d cycles=%0d conv1=%0d conv2=%0d conv3=%0d conv4=%0d pool1=%0d pool2=%0d pool3=%0d pool4=%0d gap=%0d fc1=%0d fc2=%0d probs=%0d",inference+1,cycles,count_conv1,count_conv2,count_conv3,count_conv4,count_pool1,count_pool2,count_pool3,count_pool4,count_gap,count_fc1,count_fc2_logits,prob_count);
 repeat(12) @(negedge clk);
 if(busy || done || probs_valid || cmd_v || acv) $fatal(1,"inference did not return to quiescent idle");
 end
 $display("RESULT: PASS two complete native-controller golden inferences without reset");
 $finish;
end
integer inference=0;
initial begin repeat(110000000)''')
    text = text.replace('integer inference=0;', """integer inference=0;
always @(posedge clk) if(rst_n) begin
 if(dut.u_fc1.w_valid && dut.layer != dut.L_FC1) $fatal(1,"inactive FC1 sees weights");
 if(dut.u_fc2.w_valid && dut.layer != dut.L_FC2) $fatal(1,"inactive FC2 sees weights");
 if(dut.u_fc1.w_valid && dut.u_fc1.w_ready &&
    (dut.u_fc1.b_cnt!=128 || dut.u_fc1.m_cnt!=128 || dut.u_fc1.s_cnt!=128))
  $fatal(1,"FC1 MAC before current contracts complete");
 if(dut.u_fc2.w_valid && dut.u_fc2.w_ready &&
    (dut.u_fc2.b_cnt!=8 || dut.u_fc2.m_cnt!=8 || dut.u_fc2.s_cnt!=8))
  $fatal(1,"FC2 MAC before current contracts complete");
end""")
    tb = output / 'tb_npu_full_native.sv' 
    tb.write_text(text, encoding='ascii')
    rtl = [str(HERE / 'npu_top_repeat_candidate.v')
           if Path(p).name == 'npu_top_candidate.v' else
           str(HERE / 'fc_engine_repeat_candidate.v')
           if Path(p).name == 'fc_engine.v' else p for p in case.rtl]
    return real_run_case(replace(case, name='npu_repeat_native_hardened',
                                 tb=str(tb), rtl=rtl, timeout=420), verilator, args)


if __name__ == '__main__':
    spec = importlib.util.spec_from_file_location('hardened_runner', HERE / 'run_full_native.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    helper.original_run_case = repeat_case
    sim.run_case = helper.hardened_case
    spec = importlib.util.spec_from_file_location('baseline_native_runner', HERE.parent / 'npu_full_native/run.py')
    baseline = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(baseline)
    raise SystemExit(baseline.main())
