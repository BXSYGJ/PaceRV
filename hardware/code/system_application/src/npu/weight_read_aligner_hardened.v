module weight_read_aligner_hardened (
    input wire clk, rst_n,
    input wire up_valid,
    input wire [36:0] up_cmd,
    output wire [255:0] up_data,
    output wire up_rd_valid, up_done,
    input wire up_rd_ready,
    output wire dn_valid,
    output wire [36:0] dn_cmd,
    input wire [255:0] dn_data,
    input wire dn_rd_valid, dn_done, dn_abort,
    output reg protocol_error, transaction_failed
);
    localparam [2:0] IDLE=3'd0, ISSUE=3'd1, GAP=3'd2,
                     EMIT=3'd3, WAIT_LOW=3'd4, FAULT=3'd5;
    localparam [28:0] REGION_BYTES=29'h00b8000;
    reg [2:0] state;
    reg [4:0] offset, wanted, total, received, emitted, chunk, chunk_received;
    reg [27:0] addr;
    reg native_done_seen;
    reg [255:0] beats [0:16];
    wire [4:0] request_beats={1'b0,up_cmd[3:0]}+5'd1;
    wire [4:0] physical_beats=request_beats+(up_cmd[12:8]!=5'd0);
    wire [28:0] request_end={1'b0,up_cmd[35:8]}+{19'd0,request_beats,5'd0};
    wire command_ok=!up_cmd[36] && up_cmd[7:4]==4'd0 && request_end<=REGION_BYTES;
    wire [5:0] received_now={1'b0,chunk_received}+(dn_rd_valid?6'd1:6'd0);
    wire [511:0] pair={beats[emitted+5'd1],beats[emitted]};
    assign up_data=(offset==5'd0)?beats[emitted]:(pair >> {offset,3'd0});
    assign up_rd_valid=state==EMIT && !dn_abort;
    assign up_done=up_rd_valid && up_rd_ready && emitted==wanted-5'd1;
    assign dn_valid=state==ISSUE && !native_done_seen && !dn_abort;
    assign dn_cmd={1'b0,addr,3'd0,(chunk-5'd1)};

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;offset<=5'd0;wanted<=5'd0;total<=5'd0;
            received<=5'd0;emitted<=5'd0;chunk<=5'd0;chunk_received<=5'd0;
            addr<=28'd0;native_done_seen<=1'b0;
            protocol_error<=1'b0;transaction_failed<=1'b0;
        end else begin
            transaction_failed<=1'b0;
            if(dn_abort && (state==ISSUE || state==GAP || state==EMIT)) begin
                state<=FAULT;protocol_error<=1'b1;transaction_failed<=1'b1;
            end else case(state)
                IDLE: if(up_valid) begin
                    if(!command_ok) begin
                        state<=FAULT;protocol_error<=1'b1;transaction_failed<=1'b1;
                    end else begin
                        offset<=up_cmd[12:8];wanted<=request_beats;total<=physical_beats;
                        received<=5'd0;emitted<=5'd0;chunk_received<=5'd0;
                        chunk<=(physical_beats>5'd16)?5'd16:physical_beats;
                        addr<={up_cmd[35:13],5'd0}+28'h100000;
                        native_done_seen<=1'b0;state<=ISSUE;
                    end
                end
                ISSUE: begin
                    if(dn_done) native_done_seen<=1'b1;
                    if(dn_rd_valid && (chunk_received>=chunk || received>=total)) begin
                        state<=FAULT;protocol_error<=1'b1;transaction_failed<=1'b1;
                    end else begin
                        if(dn_rd_valid) begin
                            beats[received]<=dn_data;received<=received+5'd1;
                            chunk_received<=chunk_received+5'd1;
                        end
                        if((native_done_seen || dn_done) && received_now=={1'b0,chunk}) begin
                            addr<=addr+{18'd0,chunk,5'd0};state<=GAP;
                        end
                    end
                end
                GAP: begin
                    if(received==total) state<=EMIT;
                    else begin
                        chunk<=total-received;chunk_received<=5'd0;
                        native_done_seen<=1'b0;state<=ISSUE;
                    end
                end
                EMIT: if(up_rd_ready) begin
                    if(emitted==wanted-5'd1) state<=WAIT_LOW;
                    else emitted<=emitted+5'd1;
                end
                WAIT_LOW: if(!up_valid) state<=IDLE;
                FAULT: state<=FAULT;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
