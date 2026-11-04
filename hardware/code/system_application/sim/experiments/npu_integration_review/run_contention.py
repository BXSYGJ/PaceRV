"""Independent four-native-master contention with the stable M1 owner."""
import argparse
from pathlib import Path
import run_loader_owner as owner
ROOT, HERE, sim = owner.ROOT, owner.HERE, owner.sim

source = (HERE.parent / 'npu_full_native/tb_npu_full_native.sv').read_text(encoding='ascii')
decls = source[source.index('    wire [255:0] n_mwdata;'):source.index('    npu_m1_bridge n_bridge(')]
hardware = source[source.index('    ddr3_ctrl_axi #'):source.index('\n\ninteger preload_i')]
decls = decls.replace("{2'b00,n_mcmdvalid,1'b0}", '{client_valid[3],client_valid[2],n_mcmdvalid,client_valid[0]}')
decls = decls.replace("{2'b00,n_mrdready,1'b0}", '{client_ready[3],client_ready[2],n_mrdready,client_ready[0]}')
for m in (0,2,3):
    hardware = hardware.replace('.m%d_cmd(37\'d0)' % m, '.m%d_cmd(client_cmd[%d])' % (m,m))
    hardware = hardware.replace('.m%d_wdata(256\'d0)' % m, '.m%d_wdata(client_wdata[%d])' % (m,m))
hardware = hardware.replace('.s_awvalid(n_awvalid)', '.s_awvalid(n_awvalid && !suppress_aw)')
hardware = hardware.replace('.s_awready(n_awready)', '.s_awready(model_awready)')
glue = '''
wire suppress_aw=inject_m1_aw_timeout && n_awid[1:0]==2'd1;
wire model_awready;
assign n_awready=model_awready && !suppress_aw;
assign client_rdata[0]=n_rd0;assign client_rdata[1]=n_rd1;
assign client_rdata[2]=n_rd2;assign client_rdata[3]=n_rd3;
assign client_wready[0]=n_wready_beat[0];assign client_wready[2]=n_wready_beat[2];assign client_wready[3]=n_wready_beat[3];
assign client_rvalid[0]=n_rd_valid_vec[0];assign client_rvalid[2]=n_rd_valid_vec[2];assign client_rvalid[3]=n_rd_valid_vec[3];
assign client_done[0]=n_done_vec[0];assign client_done[2]=n_done_vec[2];assign client_done[3]=n_done_vec[3];
npu_m1_owner owner_inst(.clk(clk),.rst_n(rst_n),.loader_allowed(1'b0),
 .l_valid(1'b0),.l_cmd(37'd0),.l_wdata(256'd0),.l_rd_ready(1'b0),.l_wready(),.l_rvalid(),.l_done(),
 .n_valid(client_valid[1]),.n_cmd(client_cmd[1]),.n_wdata(client_wdata[1]),.n_rd_ready(client_ready[1]),
 .n_wready(client_wready[1]),.n_rvalid(client_rvalid[1]),.n_done(client_done[1]),.n_abort(owner_abort),
 .m_valid(n_mcmdvalid),.m_cmd(n_mcmd),.m_wdata(n_mwdata),.m_rd_ready(n_mrdready),
 .m_wready(n_wready_beat[1]),.m_rvalid(n_rd_valid_vec[1]),.m_done(n_done_vec[1]),
 .m_abort(n_cmd_to_err[1] || n_addr_err[1]),.idle(owner_idle),.protocol_error(owner_error));
'''
text = (HERE / 'tb_native_contention.sv').read_text(encoding='ascii').replace('// NATIVE_HARDWARE', decls + hardware + glue)
assets = ROOT / 'build/sim/native_contention_assets'
assets.mkdir(parents=True, exist_ok=True)
tb = assets / 'tb_native_contention.sv'
tb.write_text(text, encoding='ascii')
rtl = [HERE / 'npu_m1_owner.v', ROOT / 'src/ddr3/ddr3_ctrl_axi.v', HERE.parent / 'npu_lifecycle/ddr3_arbiter.v', HERE.parent / 'npu_pingpong_native/ddr3_axi_model_full.sv']
verilator, _ = sim._toolchain()
case = sim.Case(name='native_contention', tb=str(tb), rtl=[str(p) for p in rtl], timeout=120)
result = sim.run_case(case, verilator, argparse.Namespace(clean=False, trace=False, verbose=True))
print(result.output)
print('ok=' + str(result.ok) + ' log=' + str(result.log_path) + ' detail=' + result.detail)
raise SystemExit(0 if result.ok else 1)
