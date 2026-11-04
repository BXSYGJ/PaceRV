"""Generate a separate no-inference top from the preserved full-system top."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]
s = (ROOT/'src/ctrl/instrec_top.v').read_text(encoding='utf-8')
s = s.replace('dashboard_renderer u_ui_renderer', 'demo_dashboard_renderer u_ui_renderer')
s = s.replace('module instrec_top #(', 'module top_emergency_demo #(', 1)
s = '// top_emergency_demo: DEMO ONLY: real audio and video, scripted results, no inference.\n' + s
start = s.index('    npu_top #(')
end = s.index('    // ---- Debug line formatter', start)
s = s[:start] + """    assign npu_busy_u = 1'b0;
    assign npu_done_raw = 1'b0;
    assign npu_timeout_raw = 1'b0;
    assign npu_cycles_u = 32'd0;
    assign npu_feat_rd_addr = 15'd0;
    assign npu_feat_rd_en_u = 1'b0;
    assign npu_rd_cmd_valid_u = 1'b0;
    assign npu_rd_cmd_u = 37'd0;
    assign act_cmd_valid = 1'b0;
    assign act_cmd_write = 1'b0;
    assign act_cmd_addr = 32'd0;
    assign act_wr_valid = 1'b0;
    assign act_wr_data = 256'd0;
    demo_confidence_player u_demo_player (
        .clk(core_clk), .rst_n(core_clk_rst_n), .key_n(key1_n),
        .probs_valid(npu_probs_valid_raw), .probs_pct(npu_probs_pct_u),
        .probs_idx(npu_probs_idx_u), .top1(npu_top1_u)
    );

""" + s[end:]
s = s.replace('wire npu_start = mel_npu_start && npu_launch_ready &&\n                     (NPU_ENABLE || cpu_npu_pending || cpu_npu_start);', "wire npu_start = 1'b0;")
s = s.replace('.weight_ok    (weight_ok),', ".weight_ok    (1'b1),", 1)
s = s.replace('.weight_err   (weight_err),', ".weight_err   (1'b0),", 1)
s = s.replace('.key1_n          (key1_n)', ".key1_n          (1'b1)")
(ROOT/'src/diag/top_emergency_demo.v').write_text(s, encoding='utf-8')
print('Generated top_emergency_demo; no NPU instance; KEY1 replay only.')

for name in ['dashboard_renderer', 'dashboard_text']:
    source = (ROOT/'src/ui'/f'{name}.v').read_text(encoding='utf-8')
    source = source.replace('dashboard_renderer', 'demo_dashboard_renderer').replace('dashboard_text', 'demo_dashboard_text')
    source = source.replace('src/ui/dashboard_', 'src/ui/demo_dashboard_')
    (ROOT/'src/ui'/f'demo_{name}.v').write_text(source, encoding='utf-8')
