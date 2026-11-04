"""Real firmware -> safe-window launch -> full golden native NPU -> CPU MMIO."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import numpy as np
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'sim'))
sys.path.insert(0,str(ROOT/'scripts'))
import run_sim as sim
import golden_pipeline as golden

def once(text,old,new):
    if text.count(old)!=1: raise RuntimeError('Review joint TB insertion: '+old[:80])
    return text.replace(old,new)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--top1-firmware',action='store_true')
    ap.add_argument('--run-label',default='',help='Separate evidence directory; preserve previous runs')
    ap.add_argument('--frame-major',action='store_true',help='Use real Mel frame-major bank layout')
    opts=ap.parse_args()
    name='cpu_native_joint_top1' if opts.top1_firmware else 'cpu_native_joint'
    if opts.run_label:
        if not opts.run_label.replace('-','').replace('_','').isalnum():
            raise ValueError('run-label must contain only letters, digits, hyphen or underscore')
        name+='_'+opts.run_label
    work=ROOT/'build/sim'/name
    assets=work/'assets';assets.mkdir(parents=True,exist_ok=True)
    feat=np.frombuffer((HERE.parent/'npu_conv1/feat_u8.bin').read_bytes(),dtype=np.uint8).reshape(64,258)
    result=golden.npu_forward(feat,golden.load_layer_contract(),golden.load_mel_tables()['exp_lut'])
    values={'weights':(ROOT/'scripts/outputs/weights_image.bin').read_bytes(),'feat':(feat.T if opts.frame_major else feat).reshape(-1),
            'gap':result['gap'],'fc1':result['fc1'],'fc2_logits':result['fc2'],'probs':result['probs_q16']}
    for layer_name in ('conv1','conv2','conv3','conv4','pool1','pool2','pool3','pool4'):
        a=result[layer_name];c,h,w=a.shape
        values[layer_name]=a.reshape(c//16,16,h,w).transpose(2,0,3,1).reshape(-1)
    for asset_name,data in values.items():
        (assets/(asset_name+'.hex')).write_text(''.join(f'{int(v):08x}\n' for v in data),encoding='ascii')
    text=(HERE.parent/'npu_full_native/tb_npu_full_native.sv').read_text(encoding='ascii')
    if opts.frame_major:
        text=once(text,'npu_top dut(', 'npu_top #(.FEATURE_FRAME_MAJOR(1)) dut(')
    text=text.replace('build/npu_full/',assets.relative_to(ROOT).as_posix()+'/')
    text=once(text,'reg rst_n=0,start=0;','reg rst_n=0;wire start=npu_start;')
    text=once(text,'weight_read_aligner aligner(','weight_read_aligner_hardened aligner(')
    text=once(text,'.dn_done(aligned_done));',".dn_done(aligned_done),.up_rd_ready(1'b1),.dn_abort(n_cmd_to_err[1] || n_addr_err[1]),.protocol_error(aligner_error),.transaction_failed(aligner_failed));")
    substitutions={
      "{2'b00,n_mcmdvalid,1'b0}":"{2'b00,owner_valid,1'b0}",
      "{2'b00,n_mrdready,1'b0}":"{2'b00,owner_ready,1'b0}",
      '.m1_wready(n_wready_beat[1])':'.m1_wready(owner_n_wready)',
      '.m1_rvalid(n_rd_valid_vec[1])':'.m1_rvalid(owner_n_rvalid)',
      '.m1_done(n_done_vec[1])':'.m1_done(owner_n_done)',
      '.m1_abort(n_cmd_to_err[1] || n_addr_err[1])':'.m1_abort(owner_n_abort)',
      ".m0_cmd(37'd0),.m1_cmd(n_mcmd)":".m0_cmd(37'd0),.m1_cmd(owner_cmd)",
      ".m0_wdata(256'd0),.m1_wdata(n_mwdata)":".m0_wdata(256'd0),.m1_wdata(owner_wdata)"}
    for old,new in substitutions.items(): text=once(text,old,new)
    text=once(text,' repeat(3) @(negedge clk); start=1; @(negedge clk);start=0;',""" wait(cpu_npu_pending);
 if(!cpu_alive || cpu_requests!=1 || busy || start) $fatal(1,"CPU request did not wait for safe window");
 repeat(11) @(negedge clk);
 if(busy || !cpu_npu_pending) $fatal(1,"pending lost or accelerator launched early");
 mel_npu_start=1;@(negedge clk);mel_npu_start=0;
 if(!busy || cpu_npu_pending || launches!=1) $fatal(1,"CPU pending request did not launch on Mel window");
 $display("CPU_NATIVE launched by real firmware CTRL[0]");""")
    text=once(text,'cycles);$finish;',"""cycles);
 expected_report=$sformatf("NPU top1=%0d last_class=%0d last_p=%0d c=%0d",top1,last_idx,last_pct,last_cycles);
 wait(report_seen);wait(cpu_acks==1);repeat(50) @(negedge clk);
 if(u_cpu.npu_probs_st || u_cpu.npu_done_st || u_cpu.npu_timeout_st) $fatal(1,"CPU did not clear result status");
 if(!log_has("RV32 BOOT") || !log_has("RV32 MMIO OK") || !log_has("RV32 ISA OK") || !log_has("NPU GO")) $fatal(1,"firmware boot/control transcript incomplete");
 if(launches!=1 || cpu_requests<1 || cpu_requests>2 || cpu_acks!=1) $fatal(1,"unexpected CPU control counts");
 if(u_cpu.result_cycles_q!==last_cycles || u_cpu.probs_pct_q!==last_pct || u_cpu.probs_idx_q!==last_idx) $fatal(1,"CPU MMIO payload differs from actual NPU event");
 $display("CPU_NATIVE expected report=%s",expected_report);
 $display("RESULT: PASS real CPU ROM MMIO launch, full native golden NPU, real result report and acknowledgement");
 $finish;""")
    top=(ROOT/'src/ctrl/top_rv_core.v').read_text(encoding='ascii')
    launch='    reg cpu_npu_pending;'+top.split('    reg cpu_npu_pending;',1)[1].split('    npu_top ',1)[0]
    extra=(HERE/'native_owner.vh').read_text(encoding='ascii')+'\nwire aligner_error,aligner_failed;\n'+(HERE/'cpu_joint.vh').read_text(encoding='ascii')+'\n'+launch
    if opts.top1_firmware:
        rom=ROOT/'build/sim/cpu_native_joint_top1/firmware/prog.hex'
        if not rom.is_file(): raise RuntimeError('Run build_firmware.py first')
        extra=extra.replace('src/cpu/prog.hex',rom.as_posix())
        text=text.replace('$sformatf("NPU t=%0d p=%0d c=%0d",last_idx,last_pct,last_cycles)',
                          '$sformatf("NPU top1=%0d last_class=%0d last_p=%0d c=%0d",top1,last_idx,last_pct,last_cycles)')
    pos=text.rfind('endmodule');text=text[:pos]+extra+text[pos:]
    tb=work/'tb_npu_full_native.sv';tb.write_text(text,encoding='ascii')
    rtl=list(sim.NPU_RTL)+['src/ddr3/ddr3_ctrl_axi.v','src/ddr3/ddr3_arbiter.v',
       'sim/experiments/npu_pingpong_native/ddr3_axi_model_full.sv','src/cpu/rv32_cpu_subsys.sv']
    rtl+=['../cpu/rtl/'+n+'.sv' for n in ('rv32_core','rv32_decode','rv32_alu','rv32_muldiv','rv32_btb','rv32_machine')]
    rows=[]
    for p in rtl+[(str(rom) if opts.top1_firmware else 'src/cpu/prog.hex'),'src/ctrl/top_rv_core.v']:
        path=(ROOT/p).resolve();rows.append(dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    (work/'inputs.json').write_text(json.dumps(rows,indent=2)+'\n',encoding='ascii')
    tool,_=sim._toolchain()
    case=sim.Case(name=name,tb=str(tb),rtl=rtl,timeout=480)
    r=sim.run_case(case,tool,argparse.Namespace(clean=False,trace=False,verbose=True))
    if r.ok:
        expected_top1=int(np.argmax(result['probs_q16']))
        if ('CPU_NATIVE expected report=NPU top1='+str(expected_top1)+' last_class=7 ') not in r.output:
            raise RuntimeError('CPU top1 report does not match independent golden argmax')
    print(r.output);print('ok='+str(r.ok)+' log='+str(r.log_path))
    return 0 if r.ok else 1
if __name__=='__main__':raise SystemExit(main())
