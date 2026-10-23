# =============================================================================
# HADES-SRAM VCU1525 — program the FPGA with a build bitstream (M5-hw).
#   vivado -mode batch -source host/program.tcl -tclargs <bitfile> [ltxfile]
# =============================================================================
set here [file dirname [file normalize [info script]]]
source $here/common.tcl

set bit [lindex $argv 0]
set ltx [lindex $argv 1]
if {$bit eq ""} { puts "usage: program.tcl <bitfile> [ltxfile]"; exit 1 }
if {$ltx eq ""} { set ltx [file rootname $bit].ltx }

hw_open
set_property PROGRAM.FILE $bit [current_hw_device]
if {[file exists $ltx]} { set_property PROBES.FILE $ltx [current_hw_device] }
program_hw_devices [current_hw_device]
refresh_hw_device [current_hw_device]
puts "HADES_PROGRAM_DONE: $bit"
hw_close
exit 0
