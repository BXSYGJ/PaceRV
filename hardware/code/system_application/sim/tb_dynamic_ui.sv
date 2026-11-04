`timescale 1ns/1ps
module tb_dynamic_ui;
    reg core_clk=0, pix_clk=0;
    always #4 core_clk=~core_clk;
    always #7 pix_clk=~pix_clk;
    reg rst_n=0, frame_start=0;
    reg pv=0; reg [7:0] pp=0; reg [3:0] pi=0, top1=0;
    wire [7:0] b0,b1,b2,b3,b4,b5,b6,b7;
    wire [3:0] frame_class;
    wire frame_ready;
    bars_data bars(.core_clk(core_clk),.core_rst_n(rst_n),.probs_valid(pv),
        .probs_pct(pp),.probs_idx(pi),.top1(top1),.pix_clk(pix_clk),
        .pix_rst_n(rst_n),.frame_start(frame_start),.pct0(b0),.pct1(b1),
        .pct2(b2),.pct3(b3),.pct4(b4),.pct5(b5),.pct6(b6),.pct7(b7),
        .frame_class(frame_class),.frame_ready(frame_ready));
    reg copy_start=0, busy=0;
    wire [14:0] src_addr,dst_addr; wire src_en,dst_we,wr_page,copy_done;
    reg [7:0] src_data=0; wire [7:0] dst_data;
    feat_copy_engine #(.SOURCE_FRAME_MAJOR(1)) copy_dut(
        .core_clk(core_clk),.core_rst_n(rst_n),.start(copy_start),.busy_in(busy),
        .src_addr(src_addr),.src_en(src_en),.src_data(src_data),
        .dst_addr(dst_addr),.dst_data(dst_data),.dst_we(dst_we),
        .dst_page(wr_page),.done(copy_done));
    reg [14:0] manual_addr=0;
    wire [14:0] shader_addr;
    reg shader_active=0;
    wire [7:0] page_data; wire page_ready;
    feat_page_buf pages(.core_clk(core_clk),.core_rst_n(rst_n),.wr_en(dst_we),
        .wr_addr(dst_addr),.wr_data(dst_data),.wr_page(wr_page),.copy_done(copy_done),
        .pix_clk(pix_clk),.pix_rst_n(rst_n),.frame_start(frame_start),
        .rd_addr(shader_active ? shader_addr : manual_addr),.rd_data(page_data),.page_ready(page_ready));
    reg [10:0] x=0,y=0; reg de=0;
    wire [23:0] spec_rgb,bar_rgb; wire spec_on,bar_on;
    spectrum_disp shader(.pix_clk(pix_clk),.rst_pix_n(rst_n),.x(x),.y(y),.de(de),
        .ram_addr(shader_addr),.ram_data(page_data),.page_ready(page_ready),
        .rgb(spec_rgb),.spec_on(spec_on));
    wire [10:0] bx,by; wire bd;
    ui_coord_delay #(.DELAY(2)) delay_bars(.pix_clk(pix_clk),.rst_pix_n(rst_n),
        .x(x),.y(y),.de(de),.x_d(bx),.y_d(by),.de_d(bd));
    bars_disp draw_bars(.pix_clk(pix_clk),.rst_pix_n(rst_n),.x(bx),.y(by),.de(bd),
        .pct0(b0),.pct1(b1),.pct2(b2),.pct3(b3),.pct4(b4),.pct5(b5),.pct6(b6),.pct7(b7),
        .rgb(bar_rgb),.bars_on(bar_on));
    function [7:0] source_byte(input integer addr,input integer window_id);
        source_byte=(addr*13+window_id*51)^(addr>>8);
    endfunction
    function [7:0] display_byte(input integer addr,input integer window_id);
        display_byte=source_byte((addr%258)*64+addr/258,window_id);
    endfunction
    function [23:0] heat(input [7:0] value);
        if(value<32) heat=24'h000020;
        else if(value<96) heat=24'h002080;
        else if(value<160) heat=24'h00a0c0;
        else if(value<224) heat=24'he0c040;
        else heat=24'hffffe0;
    endfunction
    function [23:0] bar_colour(input integer number);
        case(number)
            0:bar_colour=24'h3080ff;1:bar_colour=24'h30c060;
            2:bar_colour=24'hffc030;3:bar_colour=24'hff6030;
            4:bar_colour=24'hc060ff;5:bar_colour=24'h60e0e0;
            6:bar_colour=24'he0e060;default:bar_colour=24'hff80c0;
        endcase
    endfunction
    integer window_id=0,writes=0;
    reg seen[0:16511];
    always @(posedge core_clk) begin
        if(src_en) src_data<=source_byte(src_addr,window_id);
        if(rst_n && dst_we) begin
            if(dst_addr>=16512 || seen[dst_addr] || dst_data!==display_byte(dst_addr,window_id))
                $fatal(1,"copy transpose/data mismatch addr=%0d win=%0d",dst_addr,window_id);
            seen[dst_addr]=1;
            writes=writes+1;
        end
    end
    reg [67:0] old_bars=0;
    reg frame_at_edge;
    reg old_ready=0;
    always @(posedge pix_clk) begin
        frame_at_edge=frame_start;
        #1;
        if(rst_n && frame_ready && !frame_at_edge && !old_ready) $fatal(1,"ready changed inside frame");
        old_ready=frame_ready;
        if(rst_n && {frame_class,b7,b6,b5,b4,b3,b2,b1,b0}!==old_bars && !frame_at_edge)
            $fatal(1,"probability snapshot changed inside frame");
        old_bars={frame_class,b7,b6,b5,b4,b3,b2,b1,b0};
    end
    task commit_frame;
        @(negedge pix_clk);frame_start=1;
        @(negedge pix_clk);frame_start=0;
    endtask
    integer i,j,c;
    reg [2:0] spec_valid_pipe=0,bar_valid_pipe=0;
    reg [23:0] spec_expect[0:2];
    reg [23:0] bar_expect[0:2];
    integer a,slot,pct_now;
    reg check_pixels=0;
    always @(posedge pix_clk) begin
        if(check_pixels) begin
            spec_valid_pipe={spec_valid_pipe[1:0],de && x>=80 && x<592 && y>=80 && y<336};
            spec_expect[2]=spec_expect[1];spec_expect[1]=spec_expect[0];
            a=((y-80)/4)*258+((x-80)*258)/512;
            spec_expect[0]=heat(display_byte(a,window_id));
            slot=(y-700)/28;
            pct_now=(slot>=0 && slot<8) ? (10+slot) : 0;
            bar_expect[2]=bar_expect[1];bar_expect[1]=bar_expect[0];
            bar_expect[0]=bar_colour(slot);
            bar_valid_pipe={bar_valid_pipe[1:0],de && x>=1200 && x<1600 && y>=700 && y<924 && ((y-700)%28)<20 && (x-1200)<pct_now*4};
            #2;
            if(spec_on!==spec_valid_pipe[2] || (spec_on && spec_rgb!==spec_expect[2]))
                $fatal(1,"spectrum pixel/latency mismatch x=%0d y=%0d",x,y);
            if(bar_on!==bar_valid_pipe[2] || (bar_on && bar_rgb!==bar_expect[2])) $fatal(1,"bar pixel/latency mismatch x=%0d y=%0d",x,y);
        end
    end
    initial begin
        repeat(5) @(negedge core_clk);rst_n=1;
        for(i=0;i<8;i=i+1) begin
            @(negedge core_clk);pv=1;pi=i;pp=10+i;top1=7;
        end
        @(negedge core_clk);pv=0;
        repeat(20) @(negedge pix_clk);
        if(frame_ready || {b7,b6,b5,b4,b3,b2,b1,b0}!==64'd0) $fatal(1,"early snapshot");
        commit_frame();
        if(!frame_ready || b0!=10 || b7!=17 || frame_class!=7) $fatal(1,"snapshot commit");
        for(i=0;i<8;i=i+1) begin
            @(negedge core_clk);pv=1;pi=i;pp=200+i;top1=2;
        end
        @(negedge core_clk);pv=0;
        repeat(20) @(negedge pix_clk);
        if(b0!=10 || b7!=17 || frame_class!=7) $fatal(1,"snapshot tore before commit");
        commit_frame();
        if({b7,b6,b5,b4,b3,b2,b1,b0}!==64'h6464646464646464 || frame_class!=2)
            $fatal(1,"clamped snapshot");
        for(i=0;i<4;i=i+1) begin
            @(negedge core_clk);pv=1;pi=i;pp=0;
        end
        @(negedge core_clk);pv=0;
        repeat(20) @(negedge pix_clk);commit_frame();
        if(b0!=100 || b7!=100) $fatal(1,"incomplete snapshot escaped");
        rst_n=0;
        repeat(5) @(negedge core_clk);rst_n=1;
        for(i=0;i<8;i=i+1) begin
            @(negedge core_clk);pv=1;pi=i;pp=10+i;top1=7;
        end
        @(negedge core_clk);pv=0;
        repeat(20) @(negedge pix_clk);commit_frame();
        for(window_id=1;window_id<=2;window_id=window_id+1) begin
            for(i=0;i<16512;i=i+1) seen[i]=0;
            writes=0;busy=0;
            @(negedge core_clk);copy_start=1;
            @(negedge core_clk);copy_start=0;
            c=0;
            while(!copy_done && c<40000) begin
                @(negedge core_clk);busy=(c%7<2);c=c+1;
            end
            busy=0;
            if(!copy_done || writes!=16512) $fatal(1,"copy completion");
            repeat(20) @(negedge pix_clk);
            if(window_id==1 && page_ready) $fatal(1,"uncommitted initial page visible");
            if(window_id==2) begin
                manual_addr=1000;
                repeat(3) @(negedge pix_clk);
                if(page_data!==display_byte(1000,1)) $fatal(1,"page tore before frame boundary");
            end
            commit_frame();
            if(!page_ready) $fatal(1,"page not ready after commit");
            for(i=0;i<16512;i=i+1) begin
                manual_addr=i;
                @(negedge pix_clk);
                if(page_data!==display_byte(i,window_id)) $fatal(1,"page mismatch addr=%0d win=%0d",i,window_id);
            end
        end
        window_id=2;shader_active=1;
        repeat(5) @(negedge pix_clk);
        check_pixels=1;
        for(j=0;j<2;j=j+1)
            for(i=0;i<8000;i=i+1) begin
                @(negedge pix_clk);
                x=j ? (1190+i%430) : (70+i%535);
                y=j ? (690+(i/430)*13) : (70+(i/535)*19);
                de=(i%11!=0);
            end
        check_pixels=0;
        $display("RESULT: PASS dynamic_ui: coherent probabilities, two transposed stalled copies, atomic pages, pixel alignment");
        $finish;
    end
    initial begin #20000000;$fatal(1,"timeout");end
endmodule
