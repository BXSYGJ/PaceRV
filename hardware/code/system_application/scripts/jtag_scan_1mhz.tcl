# JTAG chain scan at 1 MHz (more tolerant of cable/link quality).
# Run with jtagserver already listening on 127.0.0.1:65420.
cfg_set_tcl_break -flag false
cfg_connect -ip 127.0.0.1 -port 65420
puts "== CONNECT DONE =="
cfg_set_cable_property -index 0 -freq 1Mhz
puts "== CABLE PROPERTY SET =="
cfg_scan_chain
puts "== SCAN DONE =="
cfg_disconnect
exit
