// Frozen pre-split production bank, fc675565.
module reference_bank(input wire clk,input wire db_active,std_active,ex_active,run_active,mel_valid,db_wr_en,std_feat_wr_en,
input wire [14:0] db_spec_rd_addr,std_db_rd_addr,ex_rd_addr,db_wr_addr,std_feat_wr_addr,
input wire [13:0] feat_rd_addr,input wire [8:0] frm_out,input wire [5:0] mel_ch,
input wire [15:0] mel_q88,db_wr_data,input wire [7:0] std_feat_wr_data,output wire [15:0] result);
    reg [15:0] spec_bank [0:16575];
    reg [15:0] bank_q;        // port A synchronous read data (1 cycle)
    reg [14:0] bank_ra;       // port A address (state-muxed)

    always @* begin
        bank_ra = 15'd0;
        if (db_active)
            bank_ra = db_spec_rd_addr;      // db_norm log2 read
        else if (std_active)
            bank_ra = std_db_rd_addr;       // standardize dB read
        else if (ex_active)
            bank_ra = ex_rd_addr;           // export engine dB read
        else
            bank_ra = {1'b0, feat_rd_addr} + 15'd64; // NPU feat export
    end

    always @(posedge clk) begin
        bank_q <= spec_bank[bank_ra];
    end

    // Port B write mux: the three writers are state-exclusive (first
    // pass mel_filter / db_norm overwrite / standardize feat writeback
    // with the +64 physical offset, {8'h00, feat} low byte).
    always @(posedge clk) begin
        if (run_active && mel_valid)
            spec_bank[{frm_out, mel_ch}] <= mel_q88;
        else if (db_active && db_wr_en)
            spec_bank[db_wr_addr] <= db_wr_data;
        else if (std_active && std_feat_wr_en)
            spec_bank[{1'b0, std_feat_wr_addr} + 15'd64]
                <= {8'h00, std_feat_wr_data};
    end


assign result=bank_q;
endmodule
