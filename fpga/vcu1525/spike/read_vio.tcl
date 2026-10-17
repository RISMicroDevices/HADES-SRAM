# Read VIO on the already-programmed spike_top (no reprogramming)
# Probes (named by net): calib, cmperr, hb[31:0], rst_pin; output: rst_drv
if {[info exists ::env(HADES_HW_URL)]} { set hw_url $::env(HADES_HW_URL) } else { set hw_url localhost }
set rundir [file normalize [file join [file dirname [info script]] ex_proj mig_0_ex mig_0_ex.runs impl_1]]
set ltx [file join $rundir spike_top.ltx]

open_hw_manager
connect_hw_server -url $hw_url -allow_non_jtag
open_hw_target [lindex [get_hw_targets] 0]
current_hw_device [lindex [get_hw_devices xcvu9p*] 0]
if {[file exists $ltx]} { set_property PROBES.FILE $ltx [current_hw_device] }
refresh_hw_device [current_hw_device]

set vio [lindex [get_hw_vios] 0]
refresh_hw_vio $vio
set c0 [get_property INPUT_VALUE [get_hw_probes calib   -of_objects $vio]]
set e0 [get_property INPUT_VALUE [get_hw_probes cmperr  -of_objects $vio]]
set h0 [get_property INPUT_VALUE [get_hw_probes hb      -of_objects $vio]]
set r0 [get_property INPUT_VALUE [get_hw_probes rst_pin -of_objects $vio]]
after 500
refresh_hw_vio $vio
set c1 [get_property INPUT_VALUE [get_hw_probes calib   -of_objects $vio]]
set e1 [get_property INPUT_VALUE [get_hw_probes cmperr  -of_objects $vio]]
set h1 [get_property INPUT_VALUE [get_hw_probes hb      -of_objects $vio]]

puts "SPIKE_VIO calib=$c0,$c1 compare_err=$e0,$e1 heartbeat=$h0->$h1 rst_pin=$r0"
if {$c0 == 1 && $c1 == 1 && $e0 == 0 && $e1 == 0 && $h0 != $h1} {
  puts "SPIKE_VIO_PASS: calibration complete, TG clean, ui_clk alive"
} else {
  puts "SPIKE_VIO_CHECK: unexpected values - inspect"
}
close_hw_target
disconnect_hw_server
close_hw_manager
exit
