// Experimental transaction-level bridge; native command is held until done.
module npu_m1_bridge (
    input wire clk, rst_n,
    input wire wgt_cmd_valid,
    input wire [36:0] wgt_cmd,
    input wire wgt_rd_ready,
    output wire [255:0] wgt_rd_data,
    output wire wgt_rd_valid, wgt_done,
    input wire act_cmd_valid, act_cmd_write,
    input wire [31:0] act_cmd_addr,
    output wire act_cmd_ready,
    input wire act_wr_valid,
    input wire [255:0] act_wr_data,
    output wire act_wr_ready,
    output wire act_rd_valid,
    output wire [255:0] act_rd_data,
    output wire m1_cmd_valid,
    output wire [36:0] m1_cmd,
    output wire [255:0] m1_wdata,
    output wire m1_rd_ready,
    input wire m1_wready,
    input wire [255:0] m1_rdata,
    input wire m1_rvalid, m1_done, m1_abort,
    output reg protocol_error,
    output reg transaction_failed
);
    localparam [2:0] IDLE=3'd0, WEIGHT=3'd1, WEIGHT_GAP=3'd2,
                     ACT_DATA=3'd3, ACTIVATION=3'd4, FAULT=3'd5;
    reg [2:0] state;
    reg [36:0] cmd_q;
    reg [255:0] write_q;
    reg prefer_act;
    reg native_done_seen;
    reg [8:0] reads_left;
    wire read_accept = m1_rvalid && m1_rd_ready;
    wire read_complete = (native_done_seen || m1_done) &&
                         (reads_left==9'd0 || (reads_left==9'd1 && read_accept));
    wire act_addr_ok = (act_cmd_addr[31:28]==4'd0 && act_cmd_addr[4:0]==5'd0);
    assign act_cmd_ready = state==IDLE && (!wgt_cmd_valid || prefer_act) && act_addr_ok;
    assign m1_cmd_valid = (state==WEIGHT || state==ACTIVATION) && !native_done_seen;
    assign m1_cmd = cmd_q;
    assign m1_wdata = write_q;
    assign m1_rd_ready = state==WEIGHT ? wgt_rd_ready : 1'b1;
    assign wgt_rd_data = m1_rdata;
    assign wgt_rd_valid = state==WEIGHT && m1_rvalid && !m1_abort;
    assign wgt_done = state==WEIGHT && read_complete && !m1_abort;
    assign act_rd_data = m1_rdata;
    assign act_rd_valid = state==ACTIVATION && !cmd_q[36] && m1_rvalid && !m1_abort;
    // The client data beat is accepted before the native command is issued.
    // ACT_DATA is the bridge's one-beat staging buffer; waiting for native
    // m1_wready here deadlocks because the controller cannot assert wready
    // until it has first seen the activation command.
    assign act_wr_ready = state==ACT_DATA && !m1_abort;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;cmd_q<=37'd0;write_q<=256'd0;protocol_error<=1'b0;prefer_act<=1'b0;
            native_done_seen<=1'b0;reads_left<=9'd0;transaction_failed<=1'b0;
        end else begin
            transaction_failed<=1'b0;
            if(state==WEIGHT || state==ACTIVATION) begin
                if(m1_done) native_done_seen<=1'b1;
                if(!cmd_q[36] && read_accept && reads_left!=9'd0)
                    reads_left<=reads_left-9'd1;
            end
            if(state==IDLE && act_cmd_valid && !act_addr_ok) protocol_error<=1'b1;
            if(m1_abort && (state==WEIGHT || state==ACTIVATION || state==ACT_DATA)) begin
                state<=FAULT;protocol_error<=1'b1;transaction_failed<=1'b1;
            end else case(state)
                IDLE: begin
                    if(wgt_cmd_valid && !(act_cmd_valid && act_addr_ok && prefer_act)) begin
                        cmd_q<=wgt_cmd;write_q<=256'd0;state<=WEIGHT;
                        native_done_seen<=1'b0;reads_left<={1'b0,wgt_cmd[7:0]}+9'd1;
                        if(wgt_cmd[36]) protocol_error<=1'b1;
                    end else if(act_cmd_valid && act_cmd_ready) begin
                        cmd_q<={act_cmd_write,act_cmd_addr[27:0],8'd0};
                        native_done_seen<=1'b0;reads_left<=act_cmd_write ? 9'd0 : 9'd1;
                        state<=act_cmd_write ? ACT_DATA : ACTIVATION;
                    end
                end
                WEIGHT: if(read_complete) begin state<=WEIGHT_GAP;prefer_act<=1'b1;end
                WEIGHT_GAP: if(!wgt_cmd_valid) state<=IDLE;
                ACT_DATA: if(act_wr_valid) begin
                    write_q<=act_wr_data;state<=ACTIVATION;
                end
                ACTIVATION: if(cmd_q[36] ? m1_done : read_complete) begin state<=IDLE;prefer_act<=1'b0;end
                FAULT: state<=FAULT;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
