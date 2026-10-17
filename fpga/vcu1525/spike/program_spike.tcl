# =============================================================================
# HADES-SRAM HW spike - step C: program the VCU1525 and check calibration
#
# Connects to a hw_server (default: localhost), programs example_top.bit on the
# VU9P, and reports device status. Calibration success is observed on the board:
#   GPIO_LED_0 (BC21) = c0_init_calib_complete  (ON = calibration passed)
#   GPIO_LED_1 (BB21) = c0_data_compare_error   (OFF = traffic generator clean)
# sys_rst is the CPU_RESET button (AL20); release = run.
#
# Usage (WSL2):  vivado -mode batch -source program_spike.tcl
#                HADES_HW_URL=<win-host-ip>:3121 vivado -mode batch -source ...
# Requires: hw_server running on the Windows host (C:\Xilinx\Vivado\2024.1\bin)
# =============================================================================
if {[info exists ::env(HADES_HW_URL)]} { set hw_url $::env(HADES_HW_URL) } else { set hw_url localhost }
set bit [file normalize [file join [file dirname [info script]] ex_proj mig_0_ex mig_0_ex.runs impl_1 example_top.bit]]
if {![file exists $bit]} { puts "SPIKE_PROGRAM_FAIL: bitstream not found: $bit"; exit 1 }

open_hw_manager
connect_hw_server -url $hw_url -allow_non_jtag
set t [lindex [get_hw_targets] 0]
puts "SPIKE_TARGET: $t"
open_hw_target $t
current_hw_device [lindex [get_hw_devices xcvu9p*] 0]
puts "SPIKE_DEVICE: [current_hw_device]"
set_property PROGRAM.FILE $bit [current_hw_device]
program_hw_devices [current_hw_device]
refresh_hw_device -update_hw_probes false [current_hw_device]
puts "SPIKE_PROGRAM_DONE - check GPIO_LED_0 (calib complete) / GPIO_LED_1 (compare error)"
close_hw_target
disconnect_hw_server
close_hw_manager
exit
