"""Prepare only: serial isolated original/narrow PDS RAM-inference probes."""
import hashlib
import json
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


PROBE = '''// Isolated resource probe; no production, timing or board claim.
module activation_store_map_probe(
 input wire clk,rst_n,start,read_mode,row_credit,
 input wire [1:0] cfg_layer,input wire [31:0] cfg_base,
 input wire in_valid,input wire [7:0] in_data,
 input wire cmd_ready,wr_ready,rd_valid,out_ready,
 input wire [31:0] payload,
 output wire [15:0] replay_row,
 output wire in_ready,cmd_valid,cmd_write,wr_valid,out_valid,
 output wire [31:0] cmd_addr,write_digest,
 output wire [7:0] out_data,
 output wire row_done,done,protocol_error
);
 reg [255:0] read_payload;
 wire [255:0] wr_data;
 always @(posedge clk) read_payload<={read_payload[223:0],payload};
 assign write_digest=wr_data[31:0]^wr_data[63:32]^wr_data[95:64]^wr_data[127:96]^
                     wr_data[159:128]^wr_data[191:160]^wr_data[223:192]^wr_data[255:224];
 activation_store_unit unit_under_test(
 .clk(clk),.rst_n(rst_n),.start(start),.read_mode(read_mode),.row_credit(row_credit),
 .cfg_layer(cfg_layer),.cfg_base(cfg_base),.replay_row(replay_row),
 .in_valid(in_valid),.in_data(in_data),.in_ready(in_ready),
 .cmd_valid(cmd_valid),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_ready(cmd_ready),
 .wr_valid(wr_valid),.wr_data(wr_data),.wr_ready(wr_ready),
 .rd_valid(rd_valid),.rd_data(read_payload),.out_valid(out_valid),.out_data(out_data),
 .out_ready(out_ready),.row_done(row_done),.done(done),.protocol_error(protocol_error));
endmodule
'''

LAUNCH = '''# Isolated map probe only; never run beside another PDS process.
if (Get-Process pds_shell -ErrorAction SilentlyContinue) { throw "PDS already running; wait" }
$probeRoot = $PSScriptRoot
$probeManifest = Get-Content -Raw -LiteralPath (Join-Path $probeRoot "manifest.json") | ConvertFrom-Json
foreach ($probeInput in $probeManifest.Files) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $probeInput.Path).Hash -ne $probeInput.Sha256) { throw "Probe input drift: $($probeInput.Path)" }
}
$probePdsRoot = [Environment]::GetEnvironmentVariable("PDS_ROOT", "User")
if (-not $probePdsRoot) { $probePdsRoot = $env:PDS_ROOT }
$probeArgs = @("-file", ('"' + (Join-Path $probeRoot "build.tcl") + '"'), "-work_dir", ('"' + $probeRoot + '"'), "-project_name", "activation_store_map_probe_pds")
$probeProc = Start-Process -FilePath (Join-Path $probePdsRoot "bin/pds_shell.exe") -ArgumentList $probeArgs -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $probeRoot "flow.log") -RedirectStandardError (Join-Path $probeRoot "stderr.log")
if ($probeProc.ExitCode -ne 0) { throw "Isolated map probe failed: $($probeProc.ExitCode)" }
'''


def main():
    out = ROOT / 'build/resource_gate' / ('activation-isolated-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    variants = []
    for variant, filename, module in [('original','activation_row_store_dynamic.v','activation_row_store_dynamic'),('narrow','activation_row_store_narrow.v','activation_row_store_narrow')]:
        dest = out / variant
        dest.mkdir(parents=True)
        original = HERE / filename
        rtl = dest / 'activation_store_unit.v'
        rtl.write_text(original.read_text(encoding='ascii').replace('module '+module+' (', 'module activation_store_unit ('),encoding='ascii')
        probe = dest / 'activation_store_map_probe.v'
        probe.write_text(PROBE,encoding='ascii')
        constraint = dest / 'probe.fdc'
        constraint.write_text('create_clock -name probe_clk -period 10.000 [get_ports {clk}]\n',encoding='ascii')
        tcl = dest / 'build.tcl'
        tcl.write_text('\n'.join([
            'add_design "'+rtl.as_posix()+'"','add_design "'+probe.as_posix()+'"',
            'add_constraint "'+constraint.as_posix()+'"',
            'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676',
            'compile -system_verilog -top_module activation_store_map_probe',
            'synthesize -ads -selected_syn_tool_opt 2','dev_map','exit','']),encoding='ascii')
        files = [{'Path':str(p),'Sha256':sha(p)} for p in (rtl,probe,constraint,tcl)]
        manifest={'Variant':variant,'OriginalSource':str(original),'OriginalSourceSha256':sha(original),
                  'Top':'activation_store_map_probe','StopAfter':'dev_map','NoBitstream':True,
                  'Files':files,'Limitations':'Isolated single store plus identical 256-bit input shift register and XOR output observation. No production functionality, timing closure, PnR or board result.'}
        (dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='ascii')
        (dest/'launch.ps1').write_text(LAUNCH,encoding='ascii')
        variants.append(str(dest))
    (out/'launch_compare.ps1').write_text('''# Serial only. Each child launch refuses an occupied PDS slot.
$ErrorActionPreference = "Stop"
& (Join-Path $PSScriptRoot "original/launch.ps1")
& (Join-Path $PSScriptRoot "narrow/launch.ps1")
''',encoding='ascii')
    (out/'comparison.json').write_text(json.dumps({'PreparedOnly':True,'Variants':variants,'StopAfter':'dev_map'},indent=2)+'\n',encoding='ascii')
    print('PREPARED_ONLY='+str(out))
    print('Not launched. Original and narrow must run serially after current PDS exits.')


if __name__=='__main__':
    main()
