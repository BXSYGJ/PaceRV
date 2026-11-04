`timescale 1ns / 1ps

`define UD #1
module ms72xx_ctl(
    input       clk,
    input       rst_n,

    output      init_over_rx,
    output      init_over,
    output      iic_scl,
    inout       iic_sda
);
    reg rstn_temp1,rstn_temp2;
    reg rstn;
    always @(posedge clk or negedge rst_n)
    begin
    	if(!rst_n)
    	    rstn_temp1 <= 1'b0;
    	else
    	    rstn_temp1 <= rst_n;
    end

    always @(posedge clk)
    begin
    	rstn_temp2 <= rstn_temp1;
    	rstn <= rstn_temp2;
    end

assign init_over_rx=1'b1;
    wire   [7:0] device_id_rx;
    wire         iic_trig_rx ;
    wire         w_r_rx      ;
    wire  [15:0] addr_rx     ;
    wire  [ 7:0] data_in_rx  ;
    wire         busy_rx     ;
    wire  [ 7:0] data_out_rx ;
    wire         byte_over_rx;

    wire   [7:0] device_id_tx;
    wire         iic_trig_tx ;
    wire         w_r_tx      ;
    wire  [15:0] addr_tx     ;
    wire  [ 7:0] data_in_tx  ;
    wire         busy_tx     ;
    wire  [ 7:0] data_out_tx ;
    wire         byte_over_tx;

    wire   [7:0] device_id   ;
    wire         iic_trig    ;
    wire         w_r         ;
    wire  [15:0] addr                                           ;
    wire  [ 7:0] data_in     ;
    wire         busy        ;
    wire  [ 7:0] data_out                                       ;
    wire         byte_over                                      ;

    ms7200_ctl U1_ms7200_ctl(
        .clk             (             ),
        .rstn            (  rstn          ),

        .init_over       (    ),
        .device_id       (                ),
        .iic_trig        (  iic_trig_rx   ),
        .w_r             (  w_r_rx        ),
        .addr            (  addr_rx       ),
        .data_in         (  data_in_rx    ),
        .busy            (  busy_rx       ),
        .data_out        (  data_out_rx   ),
        .byte_over       (  byte_over_rx  )
    );

    ms7210_ctl U2_ms7210_ctl(
        .clk             (  clk           ),
        .rstn            (  rstn  ),

        .init_over       (  init_over     ),
        .device_id       (                ),
        .iic_trig        (  iic_trig_tx   ),
        .w_r             (  w_r_tx        ),
        .addr            (  addr_tx       ),
        .data_in         (  data_in_tx    ),
        .busy            (  busy_tx       ),
        .data_out        (  data_out_tx   ),
        .byte_over       (  byte_over_tx  )
    );

    assign device_id = (init_over_rx == 1'b1 && init_over == 1'b0) ? 8'hB2 : 8'h56 ;
    assign iic_trig = (init_over_rx == 1'b1 && init_over == 1'b0) ? iic_trig_tx : iic_trig_rx;
    assign w_r = (init_over_rx == 1'b1 && init_over == 1'b0) ? w_r_tx : w_r_rx;
    assign addr = (init_over_rx == 1'b1 && init_over == 1'b0) ? addr_tx : addr_rx;
    assign data_in = (init_over_rx == 1'b1 && init_over == 1'b0) ? data_in_tx : data_in_rx;
    assign busy_tx = (init_over_rx == 1'b1 && init_over == 1'b0) ? busy : 0;
    assign data_out_tx = (init_over_rx == 1'b1 && init_over == 1'b0) ? data_out : 0;
    assign byte_over_tx = (init_over_rx == 1'b1 && init_over == 1'b0) ? byte_over : 0;

    assign busy_rx = (init_over_rx == 1'b0 || init_over == 1'b1) ? busy : 0;
    assign data_out_rx = (init_over_rx == 1'b0 || init_over == 1'b1) ? data_out : 0;
    assign byte_over_rx = (init_over_rx == 1'b0 || init_over == 1'b1) ? byte_over : 0;

    wire         sda_in                                   ;
    wire         sda_out                                   ;
    wire         sda_out_en                                   ;
    iic_dri #(
        .CLK_FRE        (  27'd10_000_000  ),
        .IIC_FREQ       (  20'd400_000     ),
        .T_WR           (  10'd1           ),
        .ADDR_BYTE      (  2'd2            ),
        .LEN_WIDTH      (  8'd3            ),
        .DATA_BYTE      (  2'd1            )
    )iic_dri(
        .clk            (  clk             ),
        .rstn           (  rstn            ),
        .device_id      (  device_id       ),
        .pluse          (  iic_trig        ),
        .w_r            (  w_r             ),
        .byte_len       (  4'd1            ),

        .addr           (  addr            ),
        .data_in        (  data_in         ),

        .busy           (  busy            ),

        .byte_over      (  byte_over       ),
        .data_out       (  data_out        ),

        .scl            (  iic_scl         ),
        .sda_in         (  sda_in          ),
        .sda_out        (  sda_out         ),
        .sda_out_en     (  sda_out_en      )
    );

    assign iic_sda = sda_out_en ? sda_out : 1'bz;
    assign sda_in = iic_sda;

endmodule
