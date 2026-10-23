open_checkpoint [lindex [glob ./build/sync/post_synth.dcp] 0]
read_xdc ./timing_multicycle.xdc
set uiclk [get_clocks -of_objects [get_pins u_mig/c0_ddr4_ui_clk]]
puts "--- uiclk: $uiclk"
puts "--- max_delays from port_clk:"
foreach c [get_clocks] { puts "clk: $c" }
report_timing -from [get_clocks hades_port_clk] -to $uiclk -max_paths 3 -file /tmp/xpath.rpt
puts "PROBE_DONE"
exit
