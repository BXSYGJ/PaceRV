
import re
repo = open('../cpu/constraints/ddr3.fdc', encoding='utf-8').read()
m = re.search(r'###=== BEGIN IO Table(.*)', repo, re.S)
io_table = m.group(1) if m else ''
io_lines = [l.rstrip() for l in io_table.splitlines() if l.strip().startswith('define_attribute')]
print('repo IO attribute lines:', len(io_lines))
hdr = '''### DDR3 constraints for the PG2L100H CPU SoC (pds_cpu_top_100h).
### Pin table: cpu/constraints/ddr3.fdc (verified 2026-10-24 identical to the
### official 100Pro+ demo 2_9_ddr3_test active pin table for all 73 DDR3 pins).
### Clock section rebased to this project's hierarchy:
###   ddr3_wrapper.I_ips_ddr_top = rv32_ddr3_ip_wrapper.ddr3_test
### The DDR3 memory pins MUST be constrained here: with the IP idf alone the
### command/address group keeps placeholder pads and the CA OSERDES cannot be
### placed on the device (Place-0006).

# ---- Clocks: differential 125 MHz reference -> DDR controller core clocks ----
create_clock -name {ref_clk} [get_ports {ref_clk_p}] -period {8.000} -waveform {0.000 4.000}
create_generated_clock -name {rst_clk} -source [get_ports {ref_clk_p}] [get_pins {ddr3_wrapper.I_ips_ddr_top.u_ddrphy_top.rst_clk_gpll/clkout0}] -master_clock [get_clocks {ref_clk}] -multiply_by {16} -divide_by {16}
create_generated_clock -name {ddrphy_sysclk} -source [get_ports {ref_clk_p}] [get_pins {ddr3_wrapper.I_ips_ddr_top.u_ddrphy_top.ddrphy_gpll/clkout0}] -master_clock [get_clocks {ref_clk}] -multiply_by {16} -divide_by {16}
create_generated_clock -name {phy_dq_clk_0} -source [get_ports {ref_clk_p}] [get_pins {ddr3_wrapper.I_ips_ddr_top.u_ddrphy_top.ddrphy_slice_top.i_dqs_bank[0].ddrphy_ppll/clkoutphy}] -master_clock [get_clocks {ref_clk}] -multiply_by {16} -divide_by {2}
create_generated_clock -name {phy_dq_sysclk_0} -source [get_pins {ddr3_wrapper.I_ips_ddr_top.u_ddrphy_top.ddrphy_slice_top.i_dqs_bank[0].ddrphy_ppll/clkoutphy}] [get_pins {ddr3_wrapper.I_ips_ddr_top.u_ddrphy_top.ddrphy_slice_top.i_dqs_bank[0].u_ddrphy_ioclkdiv/CLKDIVOUT}] -master_clock [get_clocks {phy_dq_clk_0}] -edges {5 13 21} -edge_shift {0 0 0}
set_multicycle_path 2 -from [get_clocks ddrphy_sysclk] -to [get_clocks phy_dq_sysclk_0]
create_generated_clock -name {phy_dq_clk_1} -source [get_ports {ref_clk_p}] [get_pins {ddr3_wrapper.I_ips_ddr_top.u_ddrphy_top.ddrphy_slice_top.i_dqs_bank[1].ddrphy_ppll/clkoutphy}] -master_clock [get_clocks {ref_clk}] -multiply_by {16} -divide_by {2}
create_generated_clock -name {phy_dq_sysclk_1} -source [get_pins {ddr3_wrapper.I_ips_ddr_top.u_ddrphy_top.ddrphy_slice_top.i_dqs_bank[1].ddrphy_ppll/clkoutphy}] [get_pins {ddr3_wrapper.I_ips_ddr_top.u_ddrphy_top.ddrphy_slice_top.i_dqs_bank[1].u_ddrphy_ioclkdiv/CLKDIVOUT}] -master_clock [get_clocks {phy_dq_clk_1}] -edges {5 13 21} -edge_shift {0 0 0}
set_multicycle_path 2 -from [get_clocks ddrphy_sysclk] -to [get_clocks phy_dq_sysclk_1]
set_clock_uncertainty {0.4} -from [get_clocks {ddrphy_sysclk}] -to [get_clocks {phy_dq_sysclk_0}] -setup -hold
set_clock_uncertainty {0.4} -from [get_clocks {phy_dq_sysclk_0}] -to [get_clocks {ddrphy_sysclk}] -setup -hold
set_clock_uncertainty {0.4} -from [get_clocks {ddrphy_sysclk}] -to [get_clocks {phy_dq_sysclk_1}] -setup -hold
set_clock_uncertainty {0.4} -from [get_clocks {phy_dq_sysclk_1}] -to [get_clocks {ddrphy_sysclk}] -setup -hold

# ---- CPU clock (clk, cpu_top_100h.fdc) is asynchronous to all DDR clocks ----
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {ref_clk}] -group [get_clocks {rst_clk}] -group [get_clocks {ddrphy_sysclk}] -group [get_clocks {phy_dq_clk_0}] -group [get_clocks {phy_dq_sysclk_0}] -group [get_clocks {phy_dq_clk_1}] -group [get_clocks {phy_dq_sysclk_1}]

###=== BEGIN IO Table (73 DDR3 pins; identical to the 100Pro+ demo active table)
'''
open('constraints/ddr3_100h.fdc','w',encoding='utf-8').write(hdr + '\n'.join(io_lines) + '\n')
print('written with', len(io_lines), 'IO attribute lines')
