# =============================================================================
# HADES-SRAM VCU1525 — A10: clock stop/start + gear sweep dynamics (spec 6.2)
# Repeats a cycle for the given duration (default 30 min, host-clock anchored):
#   1. port_clk gated off (board_ctrl CLK_CTRL.bit0) -> selftest must produce
#      ZERO traffic while gated (proves the stop actually stopped the array)
#   2. gate back on -> gear re-measures -> traffic resumes, zero errors
#   3. gear sweep across the 100-500 KHz band, short selftest at each step
# Run once per bitstream (SYNC and ASYNC).  Port gear may only change while
# engines are off; the commit-into-wrap path is exercised at every step.
#   -tclargs [minutes=30] [div=600] [n_ports=56]      ASYNC MMCM: 30 200
#   env HADES_SRC_UI_RATIO=3 for ASYNC MMCM bitstreams
# =============================================================================
set here [file dirname [file normalize [info script]]]
source $here/common.tcl

set mins [lindex $argv 0]; if {$mins eq ""} { set mins 30 }
set div  [lindex $argv 1]; if {$div  eq ""} { set div 600 }
set n    [lindex $argv 2]; if {$n    eq ""} { set n 56 }

hw_open
reset_hw_axi [hw_axi]
hades_quiesce

set_gear $div
wait_meas [gear_ui_cycles $div]

set t0 [host_now_s]
set cycles 0
while {1} {
  incr cycles
  puts "--- A10: cycle $cycles (elapsed [expr {[host_now_s] - $t0}]s) ---"

  # ---- 1. stop: gate off, prove zero traffic -----------------------------
  hades_enable 2 $n
  hades_clear_all_err
  mwr $::BREG_CLK_CTRL 0                      ;# clk_gate=0 (no commit toggle)
  after 200
  # TOT_RD/TOT_WR are cumulative and only clear on SOFT_RESET — the gated
  # check must be a DELTA over the gated window, not an absolute zero
  # (2026-10-23: absolute check false-failed every cycle from cycle 2 on)
  set r0 [rd64 $::REG_STAT_TOT_RD_HI $::REG_STAT_TOT_RD_LO]
  set w0 [rd64 $::REG_STAT_TOT_WR_HI $::REG_STAT_TOT_WR_LO]
  mwr $::REG_CTRL [expr {$::CTRL_ENABLE | $::CTRL_SELFTEST}]
  after 2000
  set r1 [rd64 $::REG_STAT_TOT_RD_HI $::REG_STAT_TOT_RD_LO]
  set w1 [rd64 $::REG_STAT_TOT_WR_HI $::REG_STAT_TOT_WR_LO]
  if {$r1 != $r0 || $w1 != $w0} {
    note_fail "port traffic while clock gated (cycle $cycles, rd +[expr {$r1 - $r0}] wr +[expr {$w1 - $w0}])"
  }
  mwr $::REG_CTRL $::CTRL_ENABLE

  # ---- 2. start: gate on, gear settles, real traffic, zero errors --------
  mwr $::BREG_CLK_CTRL 1                      ;# clk_gate=1
  wait_meas [gear_ui_cycles $div]
  selftest_run 3 $n
  hades_disable

  # ---- 3. sweep the 100-500 KHz band (ui-cycle targets 3000/1500/1000/600)
  foreach tui {3000 1500 1000 600} {
    set d [expr {$tui / [src_ui_ratio]}]
    if {$d == $div} continue                  ;# the operating gear ran in step 2
    set_gear $d
    wait_meas [expr {$d * [src_ui_ratio]}]
    hades_enable 2 $n
    selftest_run 2 $n
    hades_disable
  }
  set_gear $div
  wait_meas [gear_ui_cycles $div]

  puts [format "A10: cycle %d clean, temp=%sC" $cycles [fpga_temp_c]]
  if {[host_now_s] - $t0 >= $mins * 60} break
}

set el [expr {[host_now_s] - $t0}]
puts "A10: $cycles stop/start+sweep cycles in ${el}s"
check_range "cycles completed" $cycles 10 100000
hades_summary "A10"
hw_close
exit [expr {$::g_fail_count != 0}]
