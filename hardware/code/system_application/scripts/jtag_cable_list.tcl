# List JTAG cables seen by jtagserver (fast sanity check).
cfg_connect -ip 127.0.0.1 -port 65420
cfg_get_cable_paras
cfg_disconnect
puts "== CABLE LIST DONE =="
exit
