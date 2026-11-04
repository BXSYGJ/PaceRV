"""Two CPU-requested A/B native inferences, isolated firmware and current RTL."""
import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import sys
from dataclasses import replace
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT/'sim'))
sys.path.insert(0, str(ROOT/'scripts'))
import run_sim as sim
import golden_pipeline as golden


def load(name, path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def once(text, old, new):
    if text.count(old)!=1:raise RuntimeError('Review repeat insertion: '+old[:80])
    return text.replace(old,new)


parser=argparse.ArgumentParser()
parser.add_argument('--run-label',default='narrow-repeat-ab-20261101')
parser.add_argument('--production-rom',action='store_true',help='Run checked-in continuous firmware without candidate edits')
parser.add_argument('--frame-major',action='store_true')
parser.add_argument('--report',type=Path,help='Unique evidence path, relative to instrec root')
args=parser.parse_args()
if not args.run_label.replace('-','').replace('_','').isalnum():raise ValueError('Invalid label')
name='cpu_native_joint_'+args.run_label
work=ROOT/'build/sim'/name
if work.exists():raise RuntimeError('Choose a new run-label to preserve evidence')
firmware=work/'firmware';firmware.mkdir(parents=True)
for file in ('start.S','link.ld'):shutil.copyfile(ROOT/'sw/rv32'/file,firmware/file)
if args.production_rom:
    shutil.copyfile(ROOT/'src/cpu/prog.hex',firmware/'prog.hex')
    shutil.copyfile(ROOT/'sw/rv32/main.c',firmware/'main.c')
else:
    source=(ROOT/'sw/rv32/main.c').read_text(encoding='ascii')
    source=source.replace('            NPU_CTRL = 0x1u;               /* request the next complete Mel window */\n','')
    source=once(source,'    NPU_CTRL = 0x1u;','    uint32_t requests_sent = 1u;\n    NPU_CTRL = 0x1u;')
    source=once(source,'            NPU_CTRL = 0x2u;               /* clear stickies */', '''            NPU_CTRL = 0x2u;               /* clear stickies */
                if (requests_sent < 2u) {
                    requests_sent++;
                    NPU_CTRL = 0x1u;
                    puts_("NPU GO AGAIN\\r\\n");
                }''')
    (firmware/'main.c').write_text(source,encoding='ascii')
    builder=load('repeat_firmware_builder',ROOT/'scripts/build_rv32_sw.py')
    builder.SW=firmware;builder.OUT=firmware;builder.HEX=firmware/'prog.hex'
    sys.argv=['build_rv32_sw.py','--no-m']
    if builder.main()!=0:raise RuntimeError('Firmware build failed')
feature_a=np.frombuffer((HERE.parent/'npu_conv1/feat_u8.bin').read_bytes(),dtype=np.uint8).reshape(64,258)
feature_b=(255-feature_a).astype(np.uint8)
result_b=golden.npu_forward(feature_b,golden.load_layer_contract(),golden.load_mel_tables()['exp_lut'])
values={'feat':(feature_b.T if args.frame_major else feature_b).reshape(-1),'gap':result_b['gap'],'fc1':result_b['fc1'],
        'fc2_logits':result_b['fc2'],'probs':result_b['probs_q16']}
for layer in ('conv1','conv2','conv3','conv4','pool1','pool2','pool3','pool4'):
    array=result_b[layer];c,h,w=array.shape
    values[layer]=array.reshape(c//16,16,h,w).transpose(2,0,3,1).reshape(-1)
assets=work/'frame_b';assets.mkdir()
for asset,array in values.items():
    (assets/(asset+'.hex')).write_text(''.join(f'{int(v):08x}\n' for v in array),encoding='ascii')

actual_run=sim.run_case


def repeat_case(case, tool, options):
    text=Path(case.tb).read_text(encoding='ascii')
    text=once(text,'module tb_npu_full_native;','module tb_repeat;')
    text=once(text,'.PROG_HEX("src/cpu/prog.hex")','.PROG_HEX("'+(firmware/'prog.hex').as_posix()+'")')
    reloads='\n'.join('   $readmemh("%s",%s);'%((assets/(a+'.hex')).as_posix(),'feat' if a=='feat' else 'exp_'+a) for a in values)
    text=once(text,' wait(cpu_npu_pending);', ''' for(inference=0;inference<2;inference=inference+1)begin
  if(inference==1)begin
%s
   $display("CPU_REPEAT distinct B feature/golden loaded without reset");
  end
  prob_count=0;count_conv1=0;count_conv2=0;count_conv3=0;count_conv4=0;
  count_pool1=0;count_pool2=0;count_pool3=0;count_pool4=0;
  count_gap=0;count_fc1=0;count_fc2_logits=0;replay0=0;replay1=0;prev=-1;
  report_seen=0;expected_report="";
  wait(cpu_npu_pending);'''%reloads)
    text=text.replace('cpu_requests!=1','cpu_requests!=inference+1')
    text=text.replace('launches!=1','launches!=inference+1')
    text=text.replace('wait(cpu_acks==1)','wait(cpu_acks==inference+1)')
    text=text.replace('cpu_acks!=1','cpu_acks!=inference+1')
    text=once(text,'if(launches!=inference+1 || cpu_requests<1 || cpu_requests>2 || cpu_acks!=inference+1)',
              'if(launches!=inference+1 || cpu_requests<inference+1 || cpu_requests>2 || cpu_acks!=inference+1)')
    text=once(text,' $finish;\nend\ninitial begin repeat(51000000)', ''' $display("CPU_REPEAT COMPLETE inference=%0d requests=%0d launches=%0d acks=%0d cycles=%0d",inference+1,cpu_requests,launches,cpu_acks,cycles);
 end
 if(!log_has("NPU GO AGAIN"))$fatal(1,"second request not issued by firmware");
 $display("RESULT: PASS two CPU-driven A/B native golden inferences with ACK and no reset");
 $finish;
end
integer inference=0;
initial begin repeat(110000000)''')
    if args.production_rom:
        text=text.replace('cpu_requests>2', 'cpu_requests>inference+2')
        text=text.replace(' if(!log_has("NPU GO AGAIN"))$fatal(1,"second request not issued by firmware");', '')
    tb=work/'tb_repeat.sv';tb.write_text(text,encoding='ascii')
    rows=json.loads((work/'inputs.json').read_text())
    rows=[row for row in rows if Path(row['path'])!=ROOT/'src/cpu/prog.hex']
    paths=[firmware/'prog.hex',firmware/'main.c',tb]+list(assets.glob('*.hex'))
    rows += [{'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths]
    (work/'repeat_inputs.json').write_text(json.dumps(rows,indent=2)+'\n',encoding='ascii')
    result=actual_run(replace(case,tb=str(tb),timeout=480),tool,options)
    if not result.ok:return result
    if not any('CPU_REPEAT COMPLETE inference=2 requests=%d launches=2 acks=2'%n in result.output for n in ((2,3) if args.production_rom else (2,))):
        raise RuntimeError('Missing second CPU lifecycle completion')
    expected_b=int(np.argmax(result_b['probs_q16']))
    if 'CPU_NATIVE expected report=NPU top1=%d last_class=7 '%expected_b not in result.output:
        raise RuntimeError('B top1 differs from independent argmax')
    for row in rows:
        if hashlib.sha256(Path(row['path']).read_bytes()).hexdigest()!=row['sha256']:
            raise RuntimeError('Source drift during simulation')
    completed_cycles=[int(v) for v in re.findall(r'CPU_REPEAT COMPLETE inference=\d+ requests=\d+ launches=\d+ acks=\d+ cycles=(\d+)',result.output)]
    if len(completed_cycles)!=2:raise RuntimeError('Missing measured cycle counts')
    report={'result':'PASS','label':args.run_label,'production_rtl':True,'production_rom_modified':False,
            'firmware_candidate':('none: checked-in continuous ROM' if args.production_rom else 'production main.c limited to two requests'),
            'production_rom':args.production_rom,
            'inferences':2,'dut_reset_between_inferences':False,'changed_feature_bytes':int(np.count_nonzero(feature_a!=feature_b)),
            'requests':('2 completed plus next queued' if args.production_rom else 2),'launches':2,'acks':2,'cycles_each':completed_cycles[0] if len(set(completed_cycles))==1 else completed_cycles,'measured_cycles':completed_cycles,'top1_b':expected_b,
            'inputs':rows,'log':str(result.log_path),'log_sha256':hashlib.sha256(Path(result.log_path).read_bytes()).hexdigest(),
            'limits':['modeled DDR AXI memory, Mel safe window and UART acceptance','physical DDR PHY, CDC, board and timing excluded','production ROM continues requesting at completion; model supplies two Mel windows' if args.production_rom else 'isolated firmware candidate limited to two requests']}
    (ROOT/(args.report or Path('reports/cpu_native_continuous_validation_20261102.json' if args.production_rom else 'reports/cpu_native_joint_repeat_ab_validation_20261101.json'))).write_text(json.dumps(report,indent=2)+'\n',encoding='ascii')
    return result


sim.run_case=repeat_case
base=load('cpu_joint_repeat_base',HERE/'run.py')
sys.argv=['run.py','--run-label',args.run_label]+(['--frame-major'] if args.frame_major else [])
raise SystemExit(base.main())
