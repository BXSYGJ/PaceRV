"""Prepare an isolated bounded-address, canonical single-write RAM candidate."""
from pathlib import Path
HERE = Path(__file__).resolve().parent
text = (HERE / 'activation_row_store_dynamic.v').read_text(encoding='ascii')
text = text.replace('module activation_row_store_dynamic (', 'module activation_row_store_narrow (')
text = text.replace('reg [15:0] width, channels, height, row_bytes, stride, beats;', 'reg [7:0] width, channels, beats;\n    reg [5:0] height;\n    reg [12:0] row_bytes, stride;')
text = text.replace('assign replay_row=row[15:0];', "assign replay_row={10'd0,row};")
text = text.replace('integer row, grp, col, lane, count, beat;', 'reg [5:0] row;\n    reg [3:0] grp, lane;\n    reg [7:0] col, beat;\n    reg [12:0] count;')
text = text.replace('wire [31:0] scatter=', 'wire [12:0] scatter=')
text = text.replace('row_q[(count%32)*8 +:8]', "row_q[{count[4:0],3'b000} +:8]")
text = text.replace('wire [31:0] scan_next=', 'wire [12:0] scan_next=')
text = text.replace('wire [31:0] ram_ra=(state==WCMD || state==WDATA) ? beat : scan_next/32;', 'wire [7:0] ram_ra=(state==WCMD || state==WDATA) ? beat : scan_next[12:5];')
old = '''        always @(posedge clk) begin
            q<=mem[ram_ra<BEATS ? ram_ra : 0];
            if(accept_r) mem[beat]<=rd_data[g*8 +:8];
            else if(state==FILL && in_valid) begin
                if(scatter%32==g) mem[scatter/32]<=in_data;
                else if(row_bytes%32==16 && count==row_bytes-1 && g>=16)
                    mem[beats-1]<=8'd0;
            end
        end'''
new = '''        wire fill_lane=(state==FILL && in_valid && scatter[4:0]==g);
        wire fill_pad=(state==FILL && in_valid && !fill_lane && row_bytes[4:0]==16 && count==row_bytes-1 && g>=16);
        wire mem_we=accept_r || fill_lane || fill_pad;
        wire [7:0] mem_wa=accept_r ? beat : fill_lane ? scatter[12:5] : beats-8'd1;
        wire [7:0] mem_wd=accept_r ? rd_data[g*8 +:8] : fill_lane ? in_data : 8'd0;
        always @(posedge clk) begin
            q<=mem[ram_ra<BEATS ? ram_ra : 8'd0];
            if(mem_we) mem[mem_wa]<=mem_wd;
        end'''
if text.count(old) != 1:
    raise ValueError('original RAM template changed')
text = text.replace(old, new)
(HERE / 'activation_row_store_narrow.v').write_text(text, encoding='ascii')
