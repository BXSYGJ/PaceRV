# JTAG chain scan for InstRec-FPGA (USB Cable II -> J12).
# Run with jtagserver already listening on 127.0.0.1:65420:
#   cdt_js.exe -port 65420
#   cdt_cfg.exe -file jtag_scan.tcl
cfg_connect -ip 127.0.0.1 -port 65420
puts "== CONNECT DONE =="
cfg_scan_chain
puts "== SCAN DONE =="
cfg_disconnect
exit
