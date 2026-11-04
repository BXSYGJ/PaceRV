// Candidate only. Single-row reorder, serialized 32-byte DDR transfers.
// Native bridge must map addresses to byte-addressed len=0 commands.
module activation_row_store_narrow (
    input wire clk, rst_n, start, read_mode, row_credit,
    input wire [1:0] cfg_layer, input wire [31:0] cfg_base,
    output wire [15:0] replay_row,
    input wire in_valid, input wire [7:0] in_data,
    output wire in_ready,
    output wire cmd_valid, output wire cmd_write,
    output wire [31:0] cmd_addr, input wire cmd_ready,
    output wire wr_valid, output wire [255:0] wr_data,
    input wire wr_ready,
    input wire rd_valid, input wire [255:0] rd_data,
    output wire out_valid, output wire [7:0] out_data,
    input wire out_ready,
    output reg row_done, done, protocol_error
);
    localparam BEATS=194;
    reg [7:0] width, channels, beats;
    reg [5:0] height;
    reg [12:0] row_bytes, stride;
    reg [1:0] geometry;
    reg [31:0] row_base;
    assign replay_row={10'd0,row};
    localparam IDLE=0, FILL=1, WCMD=2, WDATA=3, CREDIT=4,
               RCMD=5, RDATA=6, EMIT=7, PREFETCH=8;
    reg [3:0] state;
    wire [255:0] row_q;
    reg [5:0] row;
    reg [3:0] grp, lane;
    reg [7:0] col, beat;
    reg [12:0] count;
    wire [12:0] scatter=(geometry==0 ? col*48 : geometry==1 ? col*96 : col*192)+grp*16+lane;
    assign in_ready=(state==FILL);
    assign cmd_valid=(state==WCMD)||(state==RCMD);
    assign cmd_write=(state==WCMD);
    assign cmd_addr=row_base+beat*32;
    assign wr_valid=(state==WDATA);
    assign wr_data=row_q;
    assign out_valid=(state==EMIT);
    assign out_data=row_q[{count[4:0],3'b000} +:8];
    wire accept_r=rd_valid && ((state==RDATA) || (state==RCMD && cmd_ready));
    wire [12:0] scan_next=(state==EMIT && out_ready) ? count+1 : count;
    wire [7:0] ram_ra=(state==WCMD || state==WDATA) ? beat : scan_next[12:5];
    genvar g;
    generate for(g=0;g<32;g=g+1) begin: lane_bank
        (* syn_ramstyle = "block_ram" *) reg [7:0] mem [0:BEATS-1];
        reg [7:0] q;
        assign row_q[g*8 +:8]=q;
        wire fill_lane=(state==FILL && in_valid && scatter[4:0]==g);
        wire fill_pad=(state==FILL && in_valid && !fill_lane && row_bytes[4:0]==16 && count==row_bytes-1 && g>=16);
        wire mem_we=accept_r || fill_lane || fill_pad;
        wire [7:0] mem_wa=accept_r ? beat : fill_lane ? scatter[12:5] : beats-8'd1;
        wire [7:0] mem_wd=accept_r ? rd_data[g*8 +:8] : fill_lane ? in_data : 8'd0;
        always @(posedge clk) begin
            q<=mem[ram_ra<BEATS ? ram_ra : 8'd0];
            if(mem_we) mem[mem_wa]<=mem_wd;
        end
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; row<=0; grp<=0; col<=0; lane<=0;
            count<=0; beat<=0; row_done<=0; done<=0; protocol_error<=0;
            width<=129;channels<=48;height<=32;row_bytes<=6192;stride<=6208;beats<=194;geometry<=0;row_base<=0;
        end else begin
            row_done<=0; done<=0;
            if(rd_valid && !accept_r) protocol_error<=1;
            case(state)
                IDLE: if(start) begin
                    row<=0; grp<=0; col<=0; lane<=0; count<=0; beat<=0;
                    protocol_error<=0; geometry<=cfg_layer; row_base<=cfg_base;
                    case(cfg_layer)
                        0:begin width<=129;channels<=48;height<=32;row_bytes<=6192;stride<=6208;beats<=194;end
                        1:begin width<=64;channels<=96;height<=16;row_bytes<=6144;stride<=6144;beats<=192;end
                        2:begin width<=32;channels<=192;height<=8;row_bytes<=6144;stride<=6144;beats<=192;end
                        default:begin protocol_error<=1;end
                    endcase
                    if(cfg_layer!=3 && cfg_base[4:0]==0)
                        state<=read_mode ? CREDIT : FILL;
                    else begin state<=IDLE;protocol_error<=1;end
                end
                FILL: if(in_valid) begin
                    if(count==row_bytes-1) begin
                        // Only the final half beat can be partial (C multiple 16).
                        count<=0; beat<=0; state<=WCMD;
                    end else count<=count+1;
                    if(lane==15) begin
                        lane<=0;
                        if(col==width-1) begin col<=0; grp<=grp+1; end
                        else col<=col+1;
                    end else lane<=lane+1;
                end
                WCMD: if(cmd_ready) state<=WDATA;
                WDATA: if(wr_ready) begin
                    if(beat==beats-1) begin
                        row_done<=1; beat<=0; grp<=0; col<=0; lane<=0;
                        if(row==height-1) begin done<=1; state<=IDLE; end
                        else begin row<=row+1; row_base<=row_base+stride; state<=FILL; end
                    end else begin beat<=beat+1; state<=WCMD; end
                end
                CREDIT: if(row_credit) begin beat<=0; state<=RCMD; end
                RCMD: if(cmd_ready) begin
                    // Zero-latency R response is accepted as well.
                    if(rd_valid) begin
                        if(beat==beats-1) begin count<=0; state<=PREFETCH; end
                        else begin beat<=beat+1; state<=RCMD; end
                    end else state<=RDATA;
                end
                RDATA: if(rd_valid) begin
                    if(beat==beats-1) begin count<=0; state<=PREFETCH; end
                    else begin beat<=beat+1; state<=RCMD; end
                end
                PREFETCH: state<=EMIT;
                EMIT: if(out_ready) begin
                    if(count==row_bytes-1) begin
                        count<=0; row_done<=1;
                        if(row==height-1) begin done<=1; state<=IDLE; end
                        else begin row<=row+1; row_base<=row_base+stride; state<=CREDIT; end
                    end else count<=count+1;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
