`timescale 1ns/1ps
module mul_retention_tb;
    reg clk=0,rst_n=0,cancel=0,req_valid=0,req_precomputed=0,rsp_ready=0;
    reg [2:0] req_operation=0;
    reg [31:0] req_operand_a=0,req_operand_b=0;
    wire req_ready,rsp_valid,rsp_available;
    wire [31:0] rsp_data;
    integer checks=0,transactions=0,retained=0,canceled=0,step,n,op;
    reg [31:0] rng=32'h41c64e6d,a,b,want;
    reg [127:0] saved_products;
    rv32_muldiv #(.PRECOMPUTE(1),.RETAIN_PREPARATION(1)) dut(.*);

    function automatic [31:0] random_word(input [31:0] value);
        reg [31:0] x;
        begin x=value^(value<<13);x=x^(x>>17);random_word=x^(x<<5);end
    endfunction
    function automatic [31:0] oracle(input [2:0] kind,input [31:0] x,y);
        reg [63:0] uu;
        reg signed [63:0] ss;
        reg signed [64:0] su;
        begin
            uu={32'b0,x}*{32'b0,y};
            ss=$signed(x)*$signed(y);
            su=$signed({x[31],x})*$signed({1'b0,y});
            case(kind)
                0: oracle=uu[31:0];
                1: oracle=ss[63:32];
                2: oracle=su[63:32];
                3: oracle=uu[63:32];
                4: begin
                    if(y==0)oracle=32'hffffffff;
                    else if(x==32'h80000000 && y==32'hffffffff)oracle=x;
                    else begin ss=$signed(x)/$signed(y);oracle=ss[31:0];end
                end
                5: oracle=y==0 ? 32'hffffffff : x/y;
                6: begin
                    if(y==0)oracle=x;
                    else if(x==32'h80000000 && y==32'hffffffff)oracle=0;
                    else begin ss=$signed(x)%$signed(y);oracle=ss[31:0];end
                end
                7: oracle=y==0 ? x : x%y;
            endcase
        end
    endfunction
    task automatic tick;
        begin #5;clk=1;#1;clk=0;#4;end
    endtask
    task automatic check(input bit condition,input string message);
        begin checks=checks+1;if(!condition)$fatal(1,"%s transaction=%0d",message,transactions);end
    endtask
    task automatic prepare(input [31:0] x,y);
        begin
            req_valid=0;rsp_ready=0;req_precomputed=0;req_operation=0;
            req_operand_a=x;req_operand_b=y;cancel=0;
            #1;check(req_ready,"Preparation requires idle unit");tick();
            req_precomputed=1;#1;
            saved_products={dut.product_low_low,dut.product_high_high,dut.product_low_high[31:0],dut.product_high_low[31:0]};
        end
    endtask
    task automatic transact(input [2:0] kind,input [31:0] x,y,input bit retain,input integer wait_cycles);
        integer age,held;
        reg [31:0] expected;
        begin
            transactions=transactions+1;expected=oracle(kind,x,y);
            if(retain)begin
                prepare(x,y);retained=retained+1;
                for(held=0;held<wait_cycles;held=held+1)begin
                    rng=random_word(rng);req_operand_a=rng;req_operand_b=~rng;
                    #1;check(rsp_available && !rsp_valid,"Held eligibility exposes availability without accepting a request");
                    check({dut.product_low_low,dut.product_high_high,dut.product_low_high[31:0],dut.product_high_low[31:0]}===saved_products,"Prepared products changed during held ownership");
                    tick();
                end
                // Current bus values deliberately differ: consumption belongs to the saved owner.
                req_valid=1;rsp_ready=0;#1;
                check(req_ready && rsp_valid && rsp_data===expected,"Retained immediate result mismatch");
                tick();req_valid=0;req_precomputed=0;
            end else begin
                req_precomputed=0;req_operation=kind;req_operand_a=x;req_operand_b=y;req_valid=1;rsp_ready=0;
                #1;check(req_ready,"Arithmetic request was not accepted");tick();req_valid=0;
            end
            age=0;
            while(!rsp_valid && age<40)begin tick();age=age+1;end
            if(!(rsp_valid && rsp_data===expected))
                $display("M_ORACLE_DIAGNOSTIC operation=%0d a=%08x b=%08x expected=%08x actual=%08x age=%0d",kind,x,y,expected,rsp_data,age);
            check(rsp_valid && rsp_data===expected,"Architectural M operation mismatch");
            for(held=0;held<3;held=held+1)begin
                rng=random_word(rng);req_operand_a=rng;req_operand_b=~rng;
                tick();check(rsp_valid && rsp_data===expected,"Response changed under backpressure");
            end
            rsp_ready=1;tick();rsp_ready=0;req_precomputed=0;#1;
            check(req_ready && !rsp_valid,"Response was not consumed exactly once");
        end
    endtask
    initial begin
        tick();tick();rst_n=1;tick();
        transact(0,32'h80000000,32'hffffffff,1,17);
        transact(0,32'hffffffff,32'hffffffff,1,0);
        for(n=0;n<250;n=n+1)begin
            rng=random_word(rng);a=rng;rng=random_word(rng);b=rng;
            transact(0,a,b,1,n%29);
            for(op=0;op<8;op=op+1)transact(op[2:0],a,b,0,0);
        end
        for(op=0;op<8;op=op+1)begin
            transact(op[2:0],32'h80000000,32'hffffffff,0,0);
            transact(op[2:0],32'h12345678,0,0,0);
            transact(op[2:0],0,32'h80000000,0,0);
        end
        prepare(32'h12345678,32'h76543210);repeat(11)tick();cancel=1;req_valid=1;rsp_ready=1;
        #1;check(!req_ready && !rsp_valid,"Canceled owner remained consumable");tick();
        cancel=0;req_valid=0;rsp_ready=0;req_precomputed=0;canceled=canceled+1;
        transact(0,32'h44556677,32'h10203040,1,9);
        prepare(32'habcdef01,32'hfedcba98);repeat(7)tick();rst_n=0;req_precomputed=0;tick();
        check(!rsp_valid,"Reset retained a stale response");rst_n=1;tick();
        transact(0,32'h01234567,32'h89abcdef,1,6);
        $display("MUL_RETENTION_PASS checks=%0d transactions=%0d retained=%0d canceled=%0d",checks,transactions,retained,canceled);
        $finish;
    end
endmodule
