# -----------------------------------------------------------------------------
# program.tcl - load build/cmod_top.bit into the FPGA over JTAG (volatile)
#
#   vivado -mode batch -nojournal -source scripts/program.tcl
# -----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $root build cmod_top.bit]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices xc7a35t*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "PROGRAMMED: $bit"

close_hw_target
disconnect_hw_server
close_hw_manager
