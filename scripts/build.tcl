# -----------------------------------------------------------------------------
# build.tcl - Vivado non-project batch build for the Cmod A7-35T
#
#   vivado -mode batch -nojournal -source scripts/build.tcl
#
# Outputs (build/):
#   cmod_top.bit / cmod_top.bin   bitstream (JTAG) / flash image
#   timing.rpt  util.rpt  drc.rpt  post_route.dcp
# The build fails (exit 1) if setup or hold timing is not met.
# -----------------------------------------------------------------------------
set part  xc7a35tcpg236-1
set top   cmod_top
set root  [file normalize [file join [file dirname [info script]] ..]]
set out   [file join $root build]
file mkdir $out

set_param general.maxThreads 8

# ---- sources ----------------------------------------------------------------
read_verilog [glob [file join $root rtl *.v]]
read_verilog [glob [file join $root rtl xilinx *.v]]
read_xdc     [file join $root constraints cmod_a7.xdc]

# ---- synthesis --------------------------------------------------------------
synth_design -top $top -part $part -flatten_hierarchy rebuilt
write_checkpoint -force [file join $out post_synth.dcp]
report_utilization -file [file join $out util_synth.rpt]

# ---- implementation ---------------------------------------------------------
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $out post_route.dcp]

report_timing_summary -max_paths 20 -file [file join $out timing.rpt]
report_utilization                  -file [file join $out util.rpt]
report_drc                          -file [file join $out drc.rpt]
report_clock_utilization            -file [file join $out clocks.rpt]

# ---- timing gate ------------------------------------------------------------
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "TIMING: WNS = $wns ns, WHS = $whs ns"
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met - see build/timing.rpt"
    exit 1
}

# ---- bitstream --------------------------------------------------------------
write_bitstream -force -bin_file [file join $out $top.bit]
puts "BUILD OK: [file join $out $top.bit]"
