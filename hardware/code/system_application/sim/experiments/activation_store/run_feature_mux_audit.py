"""Production UI feature-copy regression with synchronous shared RAM."""
import argparse
from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
sys.path.insert(0,str(ROOT/'sim'))
import run_sim as sim
work=ROOT/'build/sim/feature_copy_mux_audit';work.mkdir(parents=True,exist_ok=True)
text=r'''module tb_feature_copy_mux_audit;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,start=0,busy_in=0;
wire [14:0] src_addr,dst_addr;wire src_en,dst_we,dst_page,done;
wire [7:0] dst_data;
wire [14:0] mux_addr=busy_in ? 15'd3000 : src_addr;
reg [7:0] src_data;
function automatic [7:0] pattern(input [14:0] a);pattern=(a*7+3)%251;endfunction
always @(posedge clk)src_data<=pattern(mux_addr);
feat_copy_engine dut(.core_clk(clk),.core_rst_n(rst_n),.start(start),.busy_in(busy_in),
 .src_addr(src_addr),.src_en(src_en),.src_data(src_data),.dst_addr(dst_addr),.dst_data(dst_data),
 .dst_we(dst_we),.dst_page(dst_page),.done(done));
integer errors=0,bytes=0,scenario=0,ticks=0;
reg [15:0] rng=16'hace1;
reg testing=0,expected_page=0;
always @(negedge clk)begin
 ticks=ticks+1;rng={rng[14:0],rng[15]^rng[13]^rng[12]^rng[10]};
 if(testing && scenario==2)busy_in=(rng[3:0]<10);
 if(testing && scenario==3)busy_in=(dut.idx>=16508 && ticks%5!=0);
end
always @(posedge clk)if(rst_n && dst_we)begin
 if(dst_addr!==15'(bytes))$fatal(1,"wrong/duplicate destination address %0d expected %0d",dst_addr,bytes);
 if(dst_page!==expected_page)$fatal(1,"page flipped before last write");
 bytes=bytes+1;
 if(dst_data!==pattern(dst_addr))begin
  errors=errors+1;
  if(errors<5)$display("COPY_MISMATCH addr=%0d expected=%0d actual=%0d busy=%0d",dst_addr,pattern(dst_addr),dst_data,busy_in);
 end
end
initial begin
 #21;rst_n=1;
 for(scenario=0;scenario<4;scenario=scenario+1)begin
  bytes=0;errors=0;busy_in=0;testing=0;
  @(negedge clk);start=1;@(negedge clk);start=0;testing=1;
  if(scenario==1)begin
   wait(dut.idx==10);@(negedge clk);busy_in=1;
   repeat(7)@(negedge clk);busy_in=0;
  end
  wait(done);testing=0;busy_in=0;repeat(3)@(negedge clk);
  if(errors || bytes!=16512)$fatal(1,"copy mismatch scenario=%0d bytes=%0d errors=%0d",scenario,bytes,errors);
  expected_page=~expected_page;
  if(dst_page!==expected_page)$fatal(1,"missing completed page flip");
  $display("COPY_PASS scenario=%0d bytes=%0d errors=%0d page=%0d",scenario,bytes,errors,dst_page);
 end
 $display("RESULT: PASS continuous, NPU pause/resume, random pauses and final-beat pauses; exact 16512 writes per page");$finish;
end
initial begin repeat(200000)@(posedge clk);$fatal(1,"timeout");end
endmodule
'''
tb=work/'tb_feature_copy_mux_audit.sv';tb.write_text(text,encoding='ascii')
tool,_=sim._toolchain()
r=sim.run_case(sim.Case(name=work.name,tb=str(tb),rtl=['src/ui/feat_copy_engine.v'],timeout=60),tool,
               argparse.Namespace(clean=False,trace=False,verbose=True))
print(r.output);print('ok='+str(r.ok)+' log='+str(r.log_path))
raise SystemExit(0 if r.ok else 1)
