`timescale 1ns / 1ps

module ddr3_arbiter #(

    parameter integer P3_QUOTA_TIMEOUT = 125000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        arb_en,

    input  wire [3:0]  cmd_valid,
    input  wire [36:0] m0_cmd,
    input  wire [36:0] m1_cmd,
    input  wire [36:0] m2_cmd,
    input  wire [36:0] m3_cmd,

    output wire [3:0]  grant,
    output wire        grant_wr,
    output wire [27:0] grant_addr,
    output wire [7:0]  grant_len,

    output reg  [31:0] wait_cnt_0,
    output reg  [31:0] wait_cnt_1,
    output reg  [31:0] wait_cnt_2,
    output reg  [31:0] wait_cnt_3,
    output reg  [3:0]  addr_err
);

    wire        m0_wr   = m0_cmd[36];
    wire [27:0] m0_addr = m0_cmd[35:8];
    wire [7:0]  m0_len  = m0_cmd[7:0];
    wire        m1_wr   = m1_cmd[36];
    wire [27:0] m1_addr = m1_cmd[35:8];
    wire [7:0]  m1_len  = m1_cmd[7:0];
    wire        m2_wr   = m2_cmd[36];
    wire [27:0] m2_addr = m2_cmd[35:8];
    wire [7:0]  m2_len  = m2_cmd[7:0];
    wire        m3_wr   = m3_cmd[36];
    wire [27:0] m3_addr = m3_cmd[35:8];
    wire [7:0]  m3_len  = m3_cmd[7:0];

    reg [16:0] p3_starve_cnt;
    wire       p3_override;

    assign p3_override = (p3_starve_cnt >= P3_QUOTA_TIMEOUT[16:0]);

    reg [3:0] sel_onehot;
    always @* begin
        if (p3_override && cmd_valid[3]) begin

            sel_onehot = 4'b1000;
        end else if (cmd_valid[0]) begin
            sel_onehot = 4'b0001;
        end else if (cmd_valid[1]) begin
            sel_onehot = 4'b0010;
        end else if (cmd_valid[2]) begin
            sel_onehot = 4'b0100;
        end else if (cmd_valid[3]) begin
            sel_onehot = 4'b1000;
        end else begin
            sel_onehot = 4'b0000;
        end
    end

    assign grant = arb_en ? sel_onehot : 4'b0000;

    assign grant_wr   = (sel_onehot == 4'b0001) ? m0_wr   :
                        (sel_onehot == 4'b0010) ? m1_wr   :
                        (sel_onehot == 4'b0100) ? m2_wr   : m3_wr;
    assign grant_addr = (sel_onehot == 4'b0001) ? m0_addr :
                        (sel_onehot == 4'b0010) ? m1_addr :
                        (sel_onehot == 4'b0100) ? m2_addr : m3_addr;
    assign grant_len  = (sel_onehot == 4'b0001) ? m0_len  :
                        (sel_onehot == 4'b0010) ? m1_len  :
                        (sel_onehot == 4'b0100) ? m2_len  : m3_len;

    wire [27:0] check_addr = grant_addr;

    wire region_pcm_l = (check_addr >= 28'h000000) && (check_addr <= 28'h083FFF);
    wire region_pcm_r = (check_addr >= 28'h084000) && (check_addr <= 28'h0C5FFF);
    wire region_wgt   = (check_addr >= 28'h100000) && (check_addr <= 28'h1B7FFF);
    wire region_spec  = (check_addr >= 28'h200000) && (check_addr <= 28'h20FFFF);
    wire region_self  = (check_addr >= 28'h300000) && (check_addr <= 28'h30FFFF);

    wire region_act_a = (check_addr >= 28'h0400000) && (check_addr <= 28'h043FFE0);
    wire region_act_b = (check_addr >= 28'h0440000) && (check_addr <= 28'h045FFE0);
    wire activation_legal = (sel_onehot == 4'b0010) && (grant_len == 8'd0) &&
                            (region_act_a || region_act_b);
    wire addr_aligned = (check_addr[4:0] == 5'b00000);
    wire len_legal    = (grant_len <= 8'd15);
    wire addr_legal   = addr_aligned && len_legal &&
                         (region_pcm_l || region_pcm_r ||
                          region_wgt || region_spec || region_self || activation_legal);

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wait_cnt_0    <= 32'd0;
            wait_cnt_1    <= 32'd0;
            wait_cnt_2    <= 32'd0;
            wait_cnt_3    <= 32'd0;
            p3_starve_cnt <= 17'd0;
            addr_err      <= 4'b0000;
        end else begin

            if (cmd_valid[0] && !grant[0]) begin
                wait_cnt_0 <= wait_cnt_0 + 32'd1;
            end else begin
                wait_cnt_0 <= 32'd0;
            end
            if (cmd_valid[1] && !grant[1]) begin
                wait_cnt_1 <= wait_cnt_1 + 32'd1;
            end else begin
                wait_cnt_1 <= 32'd0;
            end
            if (cmd_valid[2] && !grant[2]) begin
                wait_cnt_2 <= wait_cnt_2 + 32'd1;
            end else begin
                wait_cnt_2 <= 32'd0;
            end
            if (cmd_valid[3] && !grant[3]) begin
                wait_cnt_3 <= wait_cnt_3 + 32'd1;
            end else begin
                wait_cnt_3 <= 32'd0;
            end

            if (cmd_valid[3] && !grant[3]) begin
                if (p3_starve_cnt < P3_QUOTA_TIMEOUT[16:0]) begin
                    p3_starve_cnt <= p3_starve_cnt + 17'd1;
                end
            end else begin
                p3_starve_cnt <= 17'd0;
            end

            if ((grant != 4'b0000) && !addr_legal) begin
                for (i = 0; i < 4; i = i + 1) begin
                    if (grant[i]) begin
                        addr_err[i] <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
