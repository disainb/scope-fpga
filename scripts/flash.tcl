# -----------------------------------------------------------------------------
# flash.tcl - write build/cmod_top.bin to the Cmod A7 Quad-SPI flash (persistent)
#
#   vivado -mode batch -nojournal -source scripts/flash.tcl -tclargs <cfgmem_part>
#
# The flash chip differs between Cmod A7 board revisions. If the default part
# fails, look at the chip marking / Digilent reference manual and pass the
# matching Vivado cfgmem part, e.g.
#   mx25l3273f-spi-x1_x2_x4      (Macronix, newer boards)
#   n25q32-3.3v-spi-x1_x2_x4     (Micron, older boards)
# -----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
set bin  [file join $root build cmod_top.bin]

set cfgmem_part "mx25l3273f-spi-x1_x2_x4"
if {$argc >= 1} { set cfgmem_part [lindex $argv 0] }

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices xc7a35t*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts $cfgmem_part] 0]
set mem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.ADDRESS_RANGE  {use_file} $mem
set_property PROGRAM.FILES          [list $bin] $mem
set_property PROGRAM.BLANK_CHECK    0 $mem
set_property PROGRAM.ERASE          1 $mem
set_property PROGRAM.CFG_PROGRAM    1 $mem
set_property PROGRAM.VERIFY         1 $mem
set_property PROGRAM.CHECKSUM       0 $mem

create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
program_hw_cfgmem -hw_cfgmem $mem
puts "FLASHED: $bin ($cfgmem_part) - power-cycle or press PROG to boot from flash"

close_hw_target
disconnect_hw_server
close_hw_manager
