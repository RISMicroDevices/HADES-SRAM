# =============================================================================
# HADES-SRAM HW spike - step B: build the MIG example design to bitstream
#
# Usage:  vivado -mode batch -source build_example.tcl
# Run from: fpga/vcu1525/spike/   (after mig_example_gen.tcl)
# Output:   ex_proj/mig_0_ex/mig_0_ex.runs/impl_1/example_top.bit
# =============================================================================
set xpr [file normalize ./ex_proj/mig_0_ex/mig_0_ex.xpr]
open_project $xpr

# Extra spike constraints: status LEDs (only if not already added)
set xdc [file normalize ./spike_pins.xdc]
if {[llength [get_files -quiet -of_objects [get_filesets constrs_1] spike_pins.xdc]] == 0} {
  add_files -fileset constrs_1 -norecurse $xdc
}

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  puts "SPIKE_BUILD_FAIL: synth_1 not complete"
  exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  puts "SPIKE_BUILD_FAIL: impl_1 not complete"
  exit 1
}

puts "SPIKE_WNS: [get_property STATS.WNS [get_runs impl_1]]"
puts "SPIKE_BIT: [glob [get_property DIRECTORY [get_runs impl_1]]/*.bit]"
puts "SPIKE_BUILD_DONE"
close_project
exit
