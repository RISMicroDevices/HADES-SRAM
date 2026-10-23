# =============================================================================
# HADES-SRAM VCU1525 — A7: dual frequency gears (spec 6.2)
# Repeat the A4/A5 method at both gears: 500 KHz and 100 KHz, L=1 and L=2.
#   -tclargs <div500> <div100> [seconds] [n_ports]
#   SYNC: 600 3000 | ASYNC MMCM: 200 1000    (n default 56: re-scoped 2026-10-22)
# =============================================================================
set here [file dirname [file normalize [info script]]]
source $here/common.tcl

set d500 [lindex $argv 0]; if {$d500 eq ""} { set d500 600 }
set d100 [lindex $argv 1]; if {$d100 eq ""} { set d100 3000 }
set secs [lindex $argv 2]; if {$secs eq ""} { set secs 3 }
set n    [lindex $argv 3]; if {$n eq ""}    { set n 56 }

hw_open
reset_hw_axi [hw_axi]
hades_quiesce

foreach div [list $d500 $d100] {
  set_gear $div
  wait_meas [gear_ui_cycles $div]
  foreach L {2 1} {
    puts "--- A7: L=$L at div=$div n=$n ---"
    hades_enable $L $n
    selftest_run $secs $n
    hades_disable
  }
}

hades_summary "A7"
hw_close
exit [expr {$::g_fail_count != 0}]
