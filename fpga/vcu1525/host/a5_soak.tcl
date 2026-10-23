# =============================================================================
# HADES-SRAM VCU1525 — A5: sustained full-load soak (spec 6.2)
# 56-port (DoD re-scope 2026-10-22) selftest at the 500 KHz gear for >= 10 min
# (default 12), error CSRs polled live once a minute; duration anchored on the
# Windows host clock (WSL2 wall clock drifts after crashes — 2026-10-22).
#   -tclargs [minutes=12] [n_ports=56] [div=600]      ASYNC MMCM: 12 56 200
#   env HADES_SRC_UI_RATIO=3 for ASYNC MMCM bitstreams
# =============================================================================
set here [file dirname [file normalize [info script]]]
source $here/common.tcl

set mins [lindex $argv 0]; if {$mins eq ""} { set mins 12 }
set n    [lindex $argv 1]; if {$n    eq ""} { set n 56 }
set div  [lindex $argv 2]; if {$div  eq ""} { set div 600 }

hw_open
reset_hw_axi [hw_axi]
hades_quiesce

set_gear $div
wait_meas [gear_ui_cycles $div]

hades_enable 2 $n
hades_clear_all_err
mwr $::REG_CTRL [expr {$::CTRL_ENABLE | $::CTRL_SELFTEST}]
puts "A5: soak start n=$n L=2 div=$div target=${mins}min (host-clock anchored)"

set t0 [host_now_s]
set polls 0
while {1} {
  after 60000
  incr polls
  set el [expr {[host_now_s] - $t0}]
  set bad 0
  for {set p 0} {$p < $n} {incr p} {
    mwr $::REG_PORT_SEL $p
    if {[mrd_soak $::REG_PORT_STAT_ERR] != 0} { incr bad }
  }
  set es [mrd_soak $::REG_ERR_STATUS]
  puts [format "A5: poll %d elapsed=%ds err_ports=%d ERR_STATUS=0x%02X temp=%sC" \
        $polls $el $bad [expr {$es & 0x3F}] [fpga_temp_c]]
  if {$bad || ($es & 0x3F)} { note_fail "errors during soak (poll $polls)"; break }
  if {$el >= $mins * 60} break
}

mwr $::REG_CTRL $::CTRL_ENABLE
after 100
set el [expr {[host_now_s] - $t0}]
set rdr [rd64 $::REG_STAT_TOT_RD_HI $::REG_STAT_TOT_RD_LO]
set wrr [rd64 $::REG_STAT_TOT_WR_HI $::REG_STAT_TOT_WR_LO]
puts "A5: stopped after ${el}s; total reads=$rdr writes=$wrr"
check_range "soak duration >= 600s" $el 600 86400
if {$rdr == 0} { note_fail "no read traffic during soak" }
if {$wrr == 0} { note_fail "no write traffic during soak" }

hades_check_all_err_zero $n
hades_disable
hades_summary "A5"
hw_close
exit [expr {$::g_fail_count != 0}]
