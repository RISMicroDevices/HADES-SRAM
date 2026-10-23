# =============================================================================
# HADES-SRAM VCU1525 — A9: endurance run (spec 6.2)
# 56-port (DoD re-scope 2026-10-22) selftest at the 500 KHz gear for 8 h
# (default), error CSRs + die temperature logged every 10 min.  Duration is
# anchored on the Windows host clock (WSL2 wall clock drifts after crashes).
#   -tclargs [hours=8] [n_ports=56] [div=600]         ASYNC MMCM: 8 56 200
#   env HADES_SRC_UI_RATIO=3 for ASYNC MMCM bitstreams
# =============================================================================
set here [file dirname [file normalize [info script]]]
source $here/common.tcl

set hrs [lindex $argv 0]; if {$hrs eq ""} { set hrs 8 }
set n   [lindex $argv 1]; if {$n   eq ""} { set n 56 }
set div [lindex $argv 2]; if {$div eq ""} { set div 600 }

hw_open
reset_hw_axi [hw_axi]
hades_quiesce

set_gear $div
wait_meas [gear_ui_cycles $div]

hades_enable 2 $n
hades_clear_all_err
mwr $::REG_CTRL [expr {$::CTRL_ENABLE | $::CTRL_SELFTEST}]
puts "A9: endurance start n=$n L=2 div=$div target=${hrs}h (host-clock anchored)"

set t0 [host_now_s]
set target [expr {int($hrs * 3600)}]
set polls 0
set tmin ""; set tmax ""
while {1} {
  after 600000
  incr polls
  set el [expr {[host_now_s] - $t0}]
  set bad 0
  for {set p 0} {$p < $n} {incr p} {
    mwr $::REG_PORT_SEL $p
    if {[mrd_soak $::REG_PORT_STAT_ERR] != 0} { incr bad }
  }
  set es [mrd_soak $::REG_ERR_STATUS]
  set t [fpga_temp_c]
  if {$t ne "-1"} {
    if {$tmin eq "" || $t < $tmin} { set tmin $t }
    if {$tmax eq "" || $t > $tmax} { set tmax $t }
  }
  puts [format "A9: poll %d elapsed=%ds/%ds err_ports=%d ERR_STATUS=0x%02X temp=%sC" \
        $polls $el $target $bad [expr {$es & 0x3F}] $t]
  if {$bad || ($es & 0x3F)} { note_fail "errors during endurance (poll $polls)"; break }
  if {$el >= $target} break
}

mwr $::REG_CTRL $::CTRL_ENABLE
after 100
set el [expr {[host_now_s] - $t0}]
set rdr [rd64 $::REG_STAT_TOT_RD_HI $::REG_STAT_TOT_RD_LO]
set wrr [rd64 $::REG_STAT_TOT_WR_HI $::REG_STAT_TOT_WR_LO]
puts "A9: stopped after ${el}s; total reads=$rdr writes=$wrr; temp min=$tmin max=$tmax C"
check_range "endurance duration" $el $target 90000
if {$rdr == 0} { note_fail "no read traffic during endurance" }
if {$wrr == 0} { note_fail "no write traffic during endurance" }

hades_check_all_err_zero $n
hades_disable
hades_summary "A9"
hw_close
exit [expr {$::g_fail_count != 0}]
