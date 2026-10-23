# =============================================================================
# HADES-SRAM VCU1525 — A8: software configuration loop (spec 6.2)
# Host-driven: change L, change active port count (N->16->N), change
# CFG_MIN_PERIOD — each followed by a selftest run; behavior must match the
# new configuration with zero errors.  Also checks the over-frequency
# interlock (min_period below the actual period => ENABLE rejected, bit4).
#   -tclargs <div> [seconds] [n_ports]   (n default 56: re-scoped 2026-10-22)
# =============================================================================
set here [file dirname [file normalize [info script]]]
source $here/common.tcl

set div [lindex $argv 0]; if {$div eq ""} { set div 600 }
set secs [lindex $argv 1]; if {$secs eq ""} { set secs 2 }
set nmax [lindex $argv 2]; if {$nmax eq ""} { set nmax 56 }

hw_open
reset_hw_axi [hw_axi]
hades_quiesce

set_gear $div
after 100
check_meas [gear_ui_cycles $div]

# ---- (1) latency reconfiguration: L=2 then L=1
foreach L {2 1} {
  puts "--- A8: L=$L ---"
  hades_enable $L $nmax
  selftest_run $secs $nmax
  hades_disable
}

# ---- (2) active port count: N -> 16 -> N
foreach n [list 16 $nmax] {
  puts "--- A8: $n active ports ---"
  hades_enable 2 $n
  selftest_run $secs $n
  hades_disable
}

# ---- (3) CFG_MIN_PERIOD interlock: min_period ABOVE the actual period plus
# the +-4-cycle sampling margin => over-frequency => ENABLE rejected (bit4).
# (Fixed 2026-10-22: the RTL rejects when meas_period+4 < min_period, so the
# trip point is div+5; the old div-1 could never fire.)
puts "--- A8: CFG_MIN_PERIOD over-freq interlock ---"
mwr $::REG_CTRL 0
mwr $::REG_CFG_MIN_PERIOD [expr {$div + 5}]    ;# 604 < 605 => over-freq
mwr $::REG_ERR_STATUS 0x3F
after 50
mwr $::REG_CTRL $::CTRL_ENABLE
after 100
set es [mrd $::REG_ERR_STATUS]
check_eq "ERR_STATUS.bit4 (enable rejected)" [expr {($es >> 4) & 1}] 1
set s [mrd $::REG_STATUS]
check_eq "READY stays 0" [expr {($s >> 1) & 1}] 0
# restore and recover
mwr $::REG_CFG_MIN_PERIOD $div
mwr $::REG_ERR_STATUS 0x3F
hades_enable 2 $nmax
selftest_run $secs $nmax
hades_disable

hades_summary "A8"
hw_close
exit [expr {$::g_fail_count != 0}]
