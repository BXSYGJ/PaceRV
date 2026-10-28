`timescale 1ns/1ps
module core_token_tb #(
    parameter integer TOKEN_MODE=1,
    parameter integer EARLY_MODE=1
);
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    wire iv,ir,ov,dv,dw,dr,orr,mv,tv,tw,trap;
    wire [31:0] ia,ipa,da,dd,tpc,ti,td,trpc,tcause,tvalue;
    wire [3:0] ds;
    wire [4:0] trd,pvalid;
    wire [63:0] cycles,retired;
    reg i_valid=0,d_valid=0,d_error=0,irq=0;
    reg [31:0] i_data=0,i_pair=0,d_data=0;
    wire i_ready=!i_valid || ir;
    reg pending=0,held_write=0,irq_sent=0;
    reg [31:0] held_addr,held_data;
    reg [3:0] held_strobe;
    integer delay_count=0,scenario=-1,pp=0,ticks=0;
    reg [7:0] program_bytes[0:4095];
    reg [31:0] data_memory[0:127],reference_memory[0:127],reference_regs[0:31];
    integer requests=0,traps=0,arch_count=0,checks=0;
    integer grants=0,held_cycles=0,delayed_consumptions=0,consumptions=0,cancellations=0;
    integer owner_serial=0,token_serial=0,owner_age=0;
    reg done=0,shadow_token=0;
    reg [31:0] expected_pc=0,owner_pc=0,prepared_value=0,canceled_pc=0;
    reg [131:0] held_bank;
    wire [131:0] bank={dut.multiply_divide.unit.product_low_low,
        dut.multiply_divide.unit.product_low_high,dut.multiply_divide.unit.product_high_low,
        dut.multiply_divide.unit.product_high_high};

    rv32_core #(.ENABLE_M(1),.ENABLE_C(1),.ENABLE_PREDICTOR(0),
        .FETCH_OVERLAP(1),.LOAD_USE_BUBBLE(1),.EARLY_D_REQUEST(EARLY_MODE),
        .RETAIN_MUL_ELIGIBILITY(TOKEN_MODE)) dut(
        .clk(clk),.rst_n(rst_n),.i_req_valid(iv),.i_req_ready(i_ready),
        .i_req_address(ia),.i_req_pair_address(ipa),.i_rsp_valid(i_valid),.i_rsp_ready(ir),
        .i_rsp_data(i_data),.i_rsp_pair_data(i_pair),
        .i_rsp_is_c({i_data[17:16]!=2'b11,i_data[1:0]!=2'b11}),
        .i_rsp_pair_is_c({i_pair[17:16]!=2'b11,i_pair[1:0]!=2'b11}),
        .i_rsp_pair_valid(1'b1),.i_rsp_error(1'b0),
        .d_req_valid(dv),.d_req_ready(!pending && !d_valid),.d_req_address(da),
        .d_req_data(dd),.d_req_strobe(ds),.d_req_write(dw),
        .d_rsp_valid(d_valid),.d_rsp_ready(dr),.d_rsp_data(d_data),.d_rsp_error(d_error),
        .maintenance_valid(mv),.maintenance_ready(1'b1),.timer_value(64'b0),
        .irq_external(irq),.irq_software(1'b0),.irq_timer(1'b0),
        .trace_valid(tv),.trace_pc(tpc),.trace_instruction(ti),.trace_write(tw),
        .trace_rd(trd),.trace_data(td),.trap_valid(trap),.trap_pc(trpc),
        .trap_cause(tcause),.trap_value(tvalue),.pipeline_valid(pvalid),
        .cycle_count(cycles),.retired_count(retired));

    function automatic [31:0] word_at(input [31:0] address);
        begin
            if(address>4092) word_at=32'h00000013;
            else word_at={program_bytes[address+3],program_bytes[address+2],
                program_bytes[address+1],program_bytes[address]};
        end
    endfunction
    function automatic [31:0] ins_i(input integer opcode,rd,rs1,f3,imm);
        ins_i={imm[11:0],rs1[4:0],f3[2:0],rd[4:0],opcode[6:0]};
    endfunction
    function automatic [31:0] ins_m(input integer rd,rs1,rs2,f3);
        ins_m={7'b0000001,rs2[4:0],rs1[4:0],f3[2:0],rd[4:0],7'h33};
    endfunction
    function automatic [31:0] ins_s(input integer rs2,rs1,imm);
        ins_s={imm[11:5],rs2[4:0],rs1[4:0],3'b010,imm[4:0],7'h23};
    endfunction
    function automatic [31:0] ins_j(input integer offset);
        ins_j={offset[20],offset[10:1],offset[11],offset[19:12],5'b0,7'h6f};
    endfunction
    function automatic [31:0] ins_b(input integer rs1,rs2,offset);
        ins_b={offset[12],offset[10:5],rs2[4:0],rs1[4:0],3'b001,
            offset[4:1],offset[11],7'h63};
    endfunction
    function automatic [31:0] m_oracle(input [31:0] a,b,input [2:0] f3);
        reg signed [63:0] sp;
        reg signed [64:0] mp;
        reg [63:0] up;
        begin
            sp=$signed(a)*$signed(b); up={32'b0,a}*{32'b0,b};
            mp=$signed({a[31],a})*$signed({1'b0,b});
            case(f3)
                0: m_oracle=up[31:0];
                1: m_oracle=sp[63:32];
                2: m_oracle=mp[63:32];
                3: m_oracle=up[63:32];
                4: begin
                    if(b==0) m_oracle=32'hffffffff;
                    else if(a==32'h80000000 && b==32'hffffffff) m_oracle=a;
                    else m_oracle=$signed(a)/$signed(b);
                end
                5: begin if(b==0) m_oracle=32'hffffffff; else m_oracle=a/b; end
                6: begin
                    if(b==0) m_oracle=a;
                    else if(a==32'h80000000 && b==32'hffffffff) m_oracle=0;
                    else m_oracle=$signed(a)%$signed(b);
                end
                7: begin if(b==0) m_oracle=a; else m_oracle=a%b; end
            endcase
        end
    endfunction
    task automatic put32(input [31:0] instruction);
        begin
            program_bytes[pp]=instruction[7:0]; program_bytes[pp+1]=instruction[15:8];
            program_bytes[pp+2]=instruction[23:16]; program_bytes[pp+3]=instruction[31:24]; pp=pp+4;
        end
    endtask
    task automatic put16(input [15:0] instruction);
        begin program_bytes[pp]=instruction[7:0];program_bytes[pp+1]=instruction[15:8];pp=pp+2;end
    endtask
    task automatic finish_program;
        begin put32(ins_i('h13,31,0,0,1));put32(ins_j(0));end
    endtask
    task automatic make_program(input integer which);
        integer n,loop_pc;
        begin
            for(n=0;n<4096;n=n+4) begin
                program_bytes[n]=8'h13;program_bytes[n+1]=0;program_bytes[n+2]=0;program_bytes[n+3]=0;
            end
            pp=0;
            put32(ins_i('h13,1,0,0,(which==0 ? -7 : 7)));
            put32(ins_i('h13,2,0,0,11));put32(ins_i('h13,3,0,0,'h100));
            put32(ins_i('h13,4,0,0,'h200));put32(ins_i('h73,0,4,1,'h305));
            put16(16'h0001);put16(16'h0001);
            repeat(6) put32(ins_i('h13,0,0,0,0));
            case(which)
                0: begin put32(ins_s(2,3,0));put32(ins_m(5,1,2,0));end
                1: begin put32(ins_i('h03,8,3,2,0));put32(ins_m(5,1,2,0));end
                2: begin put32(ins_i('h03,1,3,2,0));put32(ins_m(5,1,2,0));end
                3: begin put32(ins_i('h13,1,0,0,19));put32(ins_m(5,1,2,0));end
                4: begin
                    canceled_pc=pp+4;put32(ins_i('h03,8,3,2,12));put32(ins_m(5,1,2,0));
                end
                5: begin canceled_pc=pp+4;put32(ins_s(2,3,12));put32(ins_m(5,1,2,0));end
                6: begin
                    put32(32'h000014b7);put32(ins_i('h13,9,9,0,-2048));
                    put32(ins_i('h73,0,9,1,'h304));put32(ins_i('h13,9,0,0,8));
                    put32(ins_i('h73,0,9,1,'h300));repeat(6) put32(ins_i('h13,0,0,0,0));
                    canceled_pc=pp+4;put32(ins_s(2,3,8));put32(ins_m(5,1,2,0));
                end
                7: begin put32(32'h0000100f);put32(ins_m(5,1,2,0));end
                8: begin put32(ins_j(8));put32(ins_m(5,1,2,0));put32(ins_m(6,1,2,0));end
                9: begin
                    put32(ins_m(5,0,2,0));put32(ins_i('h13,10,0,0,-7));
                    put32(ins_m(6,10,2,1));put32(ins_m(7,10,2,2));put32(ins_m(8,10,2,3));
                    put32(ins_m(12,10,2,4));put32(ins_m(13,10,2,5));
                    put32(ins_m(14,10,2,6));put32(ins_m(15,10,2,7));
                end
                10: begin
                    put32(ins_i('h13,11,0,0,3));loop_pc=pp;
                    put32(ins_s(2,3,0));put32(ins_m(5,1,2,0));
                    put32(ins_i('h13,11,11,0,-1));put32(ins_b(11,0,loop_pc-pp));
                end
            endcase
            finish_program();
            if(which>=4 && which<=6) begin
                pp='h200;put32(ins_i('h13,20,0,0,1));put32(ins_j('h300-pp));
                pp='h300;put32(ins_m(6,1,2,0));finish_program();
            end
        end
    endtask

    always @(posedge clk) begin
        if(!rst_n) begin
            i_valid<=0;d_valid<=0;d_error<=0;pending<=0;delay_count<=0;requests=0;
        end else begin
            if(i_valid && ir) i_valid<=0;
            if(iv && i_ready) begin
                i_valid<=1;i_data<=word_at(ia);i_pair<=word_at(ipa);
            end
            if(d_valid && dr) d_valid<=0;
            if(dv && !pending && !d_valid) begin
                if(da[1:0]!=0 || da>='h200) $fatal(1,"Unexpected data transaction");
                pending<=1;delay_count<=20;held_addr<=da;held_data<=dd;
                held_write<=dw;held_strobe<=ds;requests=requests+1;
            end
            if(pending) begin
                if(delay_count==0) begin
                    pending<=0;d_valid<=1;d_error<=held_addr=='h10c;
                    d_data<=data_memory[held_addr>>2];
                    if(held_write && held_addr!='h10c) begin
                        if(held_strobe!=4'b1111) $fatal(1,"Expected full-word store");
                        data_memory[held_addr>>2]<=held_data;
                    end
                end else delay_count<=delay_count-1;
            end
        end
    end
    always @(negedge clk) begin
        if(!rst_n) begin irq=0;irq_sent=0;end
        else if(traps!=0) irq=0;
        else if(scenario==6 && !irq_sent && pending && delay_count==12 &&
            dut.ex_valid && dut.ex_muldiv) begin irq=1;irq_sent=1;end
    end

    // A retirement-level oracle follows the fetched program, with independent
    // registers, memory, arithmetic and control flow. It never writes DUT state.
    always @(posedge clk) begin: architectural_oracle
        reg [31:0] a,b,value,next_pc,raw,imm,address;
        integer r1,r2,rd,n,length;
        reg writes;
        if(rst_n && !done) begin
            ticks=ticks+1;
            if(ticks>4000) $fatal(1,"Core history timeout scenario=%0d",scenario);
            if(tv) begin
                checks=checks+1;
                if(tpc!==expected_pc) $fatal(1,"Retirement PC mismatch scenario=%0d expected=%h actual=%h",scenario,expected_pc,tpc);
                raw=word_at(expected_pc);length=raw[1:0]==3 ? 4 : 2;
                if(length==2) begin
                    if(raw[15:0]!=16'h0001 || ti!=32'h00000013) $fatal(1,"Compressed NOP expansion differs");
                end else if(ti!==raw) $fatal(1,"Retired instruction differs from fetched bytes");
                r1=ti[19:15];r2=ti[24:20];rd=ti[11:7];a=reference_regs[r1];b=reference_regs[r2];
                next_pc=expected_pc+length;value=0;writes=0;
                case(ti[6:0])
                    'h13: begin value=a+{{20{ti[31]}},ti[31:20]};writes=1;end
                    'h37: begin value={ti[31:12],12'b0};writes=1;end
                    'h33: begin
                        if(ti[31:25]!=1) $fatal(1,"Unsupported oracle arithmetic");
                        value=m_oracle(a,b,ti[14:12]);writes=1;
                    end
                    'h03: begin
                        address=a+{{20{ti[31]}},ti[31:20]};value=reference_memory[address>>2];writes=1;
                        if(address=='h10c) $fatal(1,"Faulting load retired");
                    end
                    'h23: begin
                        imm={{20{ti[31]}},ti[31:25],ti[11:7]};address=a+imm;
                        if(address=='h10c) $fatal(1,"Faulting store retired");
                        reference_memory[address>>2]=b;
                    end
                    'h6f: begin
                        imm={{11{ti[31]}},ti[31],ti[19:12],ti[20],ti[30:21],1'b0};
                        next_pc=expected_pc+imm;value=expected_pc+length;writes=1;
                    end
                    'h63: begin
                        imm={{19{ti[31]}},ti[31],ti[7],ti[30:25],ti[11:8],1'b0};
                        if(a!=b) next_pc=expected_pc+imm;
                    end
                    'h73: begin if(rd!=0) $fatal(1,"Only write-only CSR setup expected");end
                    'h0f: begin end
                    default: $fatal(1,"Unsupported oracle instruction %h",ti);
                endcase
                if(tw!==(writes && rd!=0)) $fatal(1,"Architectural write qualification differs");
                if(tw) begin
                    if(trd!==rd || td!==value) $fatal(1,"Arithmetic/reference mismatch pc=%h rd=%0d expected=%h actual=%h",tpc,rd,value,td);
                    reference_regs[rd]=value;
                end
                reference_regs[0]=0;arch_count=arch_count+1;expected_pc=next_pc;
                $display("ARCH scenario=%0d index=%0d pc=%08h instruction=%08h write=%0d rd=%0d data=%08h",scenario,arch_count,tpc,ti,tw,tw ? trd : 0,tw ? td : 0);
                if(tw && trd==31) begin
                    if(td!=1) $fatal(1,"Incorrect completion marker");done=1;
                end
            end
            if(trap) begin
                if(scenario<4 || scenario>6) $fatal(1,"Unexpected trap");
                if(traps!=0) $fatal(1,"Duplicate trap");
                if(scenario==4 && (tcause!=5 || trpc!=canceled_pc-4)) $fatal(1,"Load fault identity differs");
                if(scenario==5 && (tcause!=7 || trpc!=canceled_pc-4)) $fatal(1,"Store fault identity differs");
                if(scenario==6 && (tcause!=32'h8000000b || trpc!=canceled_pc)) $fatal(1,"Interrupt owner differs");
                traps=traps+1;expected_pc='h200;
                $display("TRAP scenario=%0d pc=%08h cause=%08h value=%08h",scenario,trpc,tcause,tvalue);
            end
        end
    end

    // Shadow ownership comes from real ID admissions and accepted requests.
    // The held representation check detects a lost bank-enable hold even when
    // modulo-2^32 arithmetic happens to remain equal for that instruction.
    always @(posedge clk) begin: token_monitor
        reg grant_now,kill_now,accept_now,hold_now;
        reg [31:0] new_pc,new_product;
        reg [131:0] before_bank;
        if(!rst_n) begin shadow_token=0;owner_age=0;end
        else if(!done) begin
            grant_now=dut.mul_precompute;
            accept_now=dut.mul_request_accept;
            kill_now=dut.mem_flush || dut.frontend_barrier || dut.ex_fire ||
                !dut.ex_valid || !dut.ex_muldiv || dut.execute_common_exception || dut.muldiv_started;
            hold_now=TOKEN_MODE!=0 && dut.mul_precomputed &&
                dut.multiply_divide.unit.state==0 && !dut.muldiv_started;
            before_bank=bank;
            new_pc=dut.id_pc;
            new_product=m_oracle(dut.mul_id_operand_a,dut.mul_id_operand_b,0);
            if(dut.id_fire) owner_serial=owner_serial+1;
            if(dut.mul_precomputed && accept_now) begin
                checks=checks+1;
                if(dut.multiply_divide.unit.rsp_data!==prepared_value ||
                    !dut.multiply_divide.unit.immediate_product) $fatal(1,"Prepared owner/result mismatch");
                consumptions=consumptions+1;
                if(owner_age>0) delayed_consumptions=delayed_consumptions+1;
            end
            if(shadow_token && !grant_now && kill_now && !accept_now) cancellations=cancellations+1;
            if(shadow_token && !kill_now && !grant_now) begin held_cycles=held_cycles+1;owner_age=owner_age+1;end
            if(dut.mem_flush || dut.frontend_barrier) shadow_token=0;
            else if(grant_now) begin
                shadow_token=1;owner_pc=new_pc;token_serial=owner_serial;prepared_value=new_product;
                owner_age=0;grants=grants+1;
            end else if(kill_now) shadow_token=0;
            if(TOKEN_MODE==0 && !grant_now) shadow_token=0;
            #1;
            checks=checks+1;
            if(dut.mul_precomputed!==shadow_token) $fatal(1,"Token lifetime/expiry mismatch scenario=%0d expected=%b actual=%b",scenario,shadow_token,dut.mul_precomputed);
            if(shadow_token) begin
                if(!dut.ex_valid || !dut.ex_muldiv || dut.ex_instruction[14:12]!=0 || dut.ex_pc!==owner_pc || token_serial!=owner_serial)
                    $fatal(1,"Token crossed EX instruction ownership");
            end
            if(hold_now) begin
                checks=checks+1;
                if(bank!==before_bank) $fatal(1,"Prepared product bank overwritten during real EX ownership");
            end
        end
    end

    initial begin: execute_cases
        integer which,n;
        for(which=0;which<11;which=which+1) begin
            rst_n=0;scenario=which;done=0;expected_pc=0;ticks=0;
            traps=0;arch_count=0;checks=0;grants=0;held_cycles=0;delayed_consumptions=0;
            consumptions=0;cancellations=0;owner_serial=0;token_serial=0;owner_age=0;
            for(n=0;n<32;n=n+1) reference_regs[n]=0;
            for(n=0;n<128;n=n+1) begin data_memory[n]=13;reference_memory[n]=13;end
            make_program(which);
            repeat(4) @(negedge clk);rst_n=1;
            wait(done);@(negedge clk);
            if(which>=4 && which<=6 && traps!=1) $fatal(1,"Cancellation case did not trap");
            if(TOKEN_MODE!=0 && (which==0 || which==1 || which==10) && delayed_consumptions==0)
                $fatal(1,"No useful retained consumption under real memory wait");
            if(TOKEN_MODE==0 && delayed_consumptions!=0) $fatal(1,"Pulse mode retained eligibility");
            if((which==2 || which==3) && grants!=0) $fatal(1,"Operand hazard improperly admitted");
            if(TOKEN_MODE!=0 && which>=4 && which<=6 && cancellations==0)
                $fatal(1,"No canceled admitted owner observed");
            $display("CORE_CASE_PASS early=%0d mode=%0d scenario=%0d cycles=%0d retired=%0d grants=%0d held=%0d consumes=%0d delayed=%0d canceled=%0d requests=%0d traps=%0d checks=%0d",
                EARLY_MODE,TOKEN_MODE,which,ticks,arch_count,grants,held_cycles,consumptions,delayed_consumptions,cancellations,requests,traps,checks);
        end
        $display("CORE_TOKEN_PASS early=%0d mode=%0d scenarios=11",EARLY_MODE,TOKEN_MODE);
        $finish;
    end
endmodule
