"""Real UART loader + owner + production DDR controller at weight base 1 MiB."""
import argparse
from pathlib import Path
import run_loader_owner as owner

ROOT, HERE, sim = owner.ROOT, owner.HERE, owner.sim


def main():
    args = argparse.ArgumentParser()
    group = args.add_mutually_exclusive_group()
    group.add_argument('--timeout', action='store_true', help='Withhold native AW ready, expect fail-closed until reset')
    group.add_argument('--read-timeout', action='store_true', help='Upload succeeds, then native read data is withheld')
    mode = args.parse_args()
    fault_mode = mode.timeout or mode.read_timeout
    name = 'loader_native_read_timeout' if mode.read_timeout else ('loader_native_timeout' if mode.timeout else 'loader_native')
    text = owner.prepare_tb().replace('module tb_loader_owner;', 'module tb_' + name + ';')
    text = text.replace('weight_loader dut (', "weight_loader #(.BASE_ADDR(28'h100000)) dut (")
    text = text.replace(".m_abort(1'b0)", '.m_abort(n_cmd_to_err[1] || n_addr_err[1])')
    for before, after in (("reg         wready_beat = 1'b0;", 'wire        wready_beat;'),
                          ("reg         done        = 1'b0;", 'wire        done;'),
                          ("reg  [255:0] rd_data  = 256'd0;", 'wire [255:0] rd_data;'),
                          ("reg         rd_valid  = 1'b0;", 'wire        rd_valid;')):
        text = owner.replace_once(text, before, after)
    # Reuse the independently exercised production-controller wiring, while
    # excluding every NPU/aligner/bridge instance and its preload logic.
    source = (HERE.parent / 'npu_full_native/tb_npu_full_native.sv').read_text(encoding='ascii')
    declarations = source[source.index('    wire [255:0] n_mwdata;'):source.index('    npu_m1_bridge n_bridge(')]
    hardware = source[source.index('    ddr3_ctrl_axi #'):source.index('\n\ninteger preload_i')]
    hardware = hardware.replace('.MEM_BEATS(262144)', '.MEM_BEATS(65536)')
    if mode.timeout:
        hardware = hardware.replace('.MEM_BEATS(65536)', '.MEM_BEATS(65536),.AW_READY_AW_COUNT(0)')
    elif mode.read_timeout:
        hardware = hardware.replace('.MEM_BEATS(65536)', '.MEM_BEATS(65536),.R_MODE(2)')
    model = declarations + hardware + '''
    assign n_mcmdvalid=cmd_valid;
    assign n_mcmd=cmd;
    assign n_mwdata=wdata;
    assign n_mrdready=rd_ready;
    assign wready_beat=n_wready_beat[1];
    assign done=n_done_vec[1];
    assign rd_data=n_rd1;
    assign rd_valid=n_rd_valid_vec[1];
    integer wr_beats=0,rd_beats=0,wr_cmds=0,rd_cmds=0;
    integer early_done_count=0;
    reg [31:0] acc0=0,acc1=0,acc2=0,acc3=0;
    wire [31:0] digest_c=acc0^acc1^acc2^acc3;
    always @(posedge clk) if(rst_n)begin
        if(n_ctrl.grant[1])begin
            if(cmd[36])wr_cmds<=wr_cmds+1;else rd_cmds<=rd_cmds+1;
            if(cmd[35:8]<28'h100000 || cmd[35:8]>=28'h1b8000)$fatal(1,"weight address map");
        end
        if(l_wready)begin
            wr_beats<=wr_beats+1;
            acc0<=acc0+l_wdata[31:0]+l_wdata[159:128];
            acc1<=acc1+l_wdata[63:32]+l_wdata[191:160];
            acc2<=acc2+l_wdata[95:64]+l_wdata[223:192];
            acc3<=acc3+l_wdata[127:96]+l_wdata[255:224];
        end
        if(l_rd_valid && l_rd_ready)rd_beats<=rd_beats+1;
        if(done && !cmd[36] && !l_done)early_done_count<=early_done_count+1;
    end
'''
    start = text.index('    // DDR3 master-1 responder')
    end = text.index('    // uart_tx stand-in', start)
    text = text[:start] + model + '\n    // ' + text[end:]
    if fault_mode:
        text = text.replace('if(rst_n && owner_error)$fatal(1,"owner fault");', 'if(1\'b0)$fatal(1,"unused");')
        a = text.index('    initial begin\n        // -------------------------------------------------------------\n        // A:')
        b = text.index('    initial begin : watchdog', a)
        fault_test = '''
    initial begin
        reset_dut();send_frame(16'd0,1'b0);
        repeat(160)@(posedge clk);
        if(!n_cmd_to_err[1] || !owner_error || owner_idle || cmd_valid || l_rd_valid || l_done || weight_ok || frame_cnt!=0 || rx_len!=0)
            $fatal(1,"native timeout did not fail closed");
        repeat(32)begin @(posedge clk);if(cmd_valid || l_rd_valid || l_done || weight_ok)$fatal(1,"timeout leakage");end
        reset_dut();
        if(owner_error || !owner_idle || n_cmd_to_err[1])$fatal(1,"timeout reset recovery");
        $display("RESULT: PASS real loader + owner + native DDR AW-timeout fail-closed/reset");$finish;
    end
'''
        if mode.read_timeout:
            fault_test = fault_test.replace("reset_dut();send_frame(16'd0,1'b0);", "reset_dut();send_frame(16'd0,1'b0);wait_loader_idle();\n        if(rx_len!=1 || rx_text[0]!=8'h4b)$fatal(1,\"initial upload failed\");\n        send_end_frame();")
            fault_test = fault_test.replace('frame_cnt!=0 || rx_len!=0', 'frame_cnt!=1 || rx_len!=1')
            fault_test = fault_test.replace('native DDR AW-timeout', 'native DDR read-timeout')
        text = text[:a] + fault_test + text[b:]
    else:
        text = text.replace('if (errors == 0) begin', 'check("native done precedes loader FIFO completion",early_done_count==4);\n        if (errors == 0) begin')
        text = text.replace('RESULT: PASS real weight_loader + M1 owner early-native-done', 'RESULT: PASS real loader + owner + native DDR base100000 early-done/readback')
    assets = ROOT / ('build/sim/' + name + '_assets')
    assets.mkdir(parents=True, exist_ok=True)
    tb = assets / ('tb_' + name + '.sv')
    tb.write_text(text, encoding='ascii')
    rtl = [ROOT / 'src/ctrl/weight_loader.v', HERE / 'npu_m1_owner.v', ROOT / 'src/ddr3/ddr3_ctrl_axi.v',
           HERE.parent / 'npu_lifecycle/ddr3_arbiter.v', HERE.parent / 'npu_pingpong_native/ddr3_axi_model_full.sv']
    verilator, _ = sim._toolchain()
    case = sim.Case(name=name, tb=str(tb), rtl=[str(p) for p in rtl], timeout=120)
    result = sim.run_case(case, verilator, argparse.Namespace(clean=False, trace=False, verbose=True))
    print(result.output)
    print('ok=' + str(result.ok) + ' log=' + str(result.log_path) + ' detail=' + result.detail)
    return 0 if result.ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
