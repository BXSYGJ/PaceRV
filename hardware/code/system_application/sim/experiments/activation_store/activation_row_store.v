// Candidate only. Single-row reorder, serialized 32-byte DDR transfers.
// Native bridge must map addresses to byte-addressed len=0 commands.
module activation_row_store #(
    parameter WIDTH=3, CHANNELS=32, HEIGHT=2, BASE=0
) (
    input wire clk, rst_n, start, read_mode, row_credit,
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
    localparam ROW_BYTES=WIDTH*CHANNELS;
    localparam STRIDE=((ROW_BYTES+31)/32)*32;
    localparam BEATS=STRIDE/32;
    localparam IDLE=0, FILL=1, WCMD=2, WDATA=3, CREDIT=4,
               RCMD=5, RDATA=6, EMIT=7, PREFETCH=8;
    reg [3:0] state;
    wire [255:0] row_q;
    integer row, grp, col, lane, count, beat;
    wire [31:0] scatter=col*CHANNELS+grp*16+lane;
    assign in_ready=(state==FILL);
    assign cmd_valid=(state==WCMD)||(state==RCMD);
    assign cmd_write=(state==WCMD);
    assign cmd_addr=BASE+row*STRIDE+beat*32;
    assign wr_valid=(state==WDATA);
    assign wr_data=row_q;
    assign out_valid=(state==EMIT);
    assign out_data=row_q[(count%32)*8 +:8];
    wire accept_r=rd_valid && ((state==RDATA) || (state==RCMD && cmd_ready));
    wire [31:0] scan_next=(state==EMIT && out_ready) ? count+1 : count;
    wire [31:0] ram_ra=(state==WCMD || state==WDATA) ? beat : scan_next/32;
    genvar g;
    generate for(g=0;g<32;g=g+1) begin: lane_bank
        (* syn_ramstyle = "block_ram" *) reg [7:0] mem [0:BEATS-1];
        reg [7:0] q;
        assign row_q[g*8 +:8]=q;
        always @(posedge clk) begin
            q<=mem[ram_ra<BEATS ? ram_ra : 0];
            if(accept_r) mem[beat]<=rd_data[g*8 +:8];
            else if(state==FILL && in_valid) begin
                if(scatter%32==g) mem[scatter/32]<=in_data;
                else if(ROW_BYTES%32==16 && count==ROW_BYTES-1 && g>=16)
                    mem[BEATS-1]<=8'd0;
            end
        end
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; row<=0; grp<=0; col<=0; lane<=0;
            count<=0; beat<=0; row_done<=0; done<=0; protocol_error<=0;
        end else begin
            row_done<=0; done<=0;
            if(rd_valid && !accept_r) protocol_error<=1;
            case(state)
                IDLE: if(start) begin
                    row<=0; grp<=0; col<=0; lane<=0; count<=0; beat<=0;
                    protocol_error<=0;
                    state<=read_mode ? CREDIT : FILL;
                end
                FILL: if(in_valid) begin
                    if(count==ROW_BYTES-1) begin
                        // Only the final half beat can be partial (C multiple 16).
                        count<=0; beat<=0; state<=WCMD;
                    end else count<=count+1;
                    if(lane==15) begin
                        lane<=0;
                        if(col==WIDTH-1) begin col<=0; grp<=grp+1; end
                        else col<=col+1;
                    end else lane<=lane+1;
                end
                WCMD: if(cmd_ready) state<=WDATA;
                WDATA: if(wr_ready) begin
                    if(beat==BEATS-1) begin
                        row_done<=1; beat<=0; grp<=0; col<=0; lane<=0;
                        if(row==HEIGHT-1) begin done<=1; state<=IDLE; end
                        else begin row<=row+1; state<=FILL; end
                    end else begin beat<=beat+1; state<=WCMD; end
                end
                CREDIT: if(row_credit) begin beat<=0; state<=RCMD; end
                RCMD: if(cmd_ready) begin
                    // Zero-latency R response is accepted as well.
                    if(rd_valid) begin
                        if(beat==BEATS-1) begin count<=0; state<=PREFETCH; end
                        else begin beat<=beat+1; state<=RCMD; end
                    end else state<=RDATA;
                end
                RDATA: if(rd_valid) begin
                    if(beat==BEATS-1) begin count<=0; state<=PREFETCH; end
                    else begin beat<=beat+1; state<=RCMD; end
                end
                PREFETCH: state<=EMIT;
                EMIT: if(out_ready) begin
                    if(count==ROW_BYTES-1) begin
                        count<=0; row_done<=1;
                        if(row==HEIGHT-1) begin done<=1; state<=IDLE; end
                        else begin row<=row+1; state<=CREDIT; end
                    end else count<=count+1;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
