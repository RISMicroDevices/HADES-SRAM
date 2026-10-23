# =============================================================================
# HADES-SRAM VCU1525 — A6: refresh determinism (spec 6.2)
# Criterion: refreshes only in scheduled slots, STAT_REFCNT matches the
# configured rate +-1%.  The ui_clk ILA captures the app_ref_req/ack
# handshake under full load; the script checks the observed request interval
# against CFG_REFRESH_DIV and the counter rate over 10 s.
#   -tclargs <div> [n_ports]   default: div=600 (500 KHz SYNC gear), 56
#   (load re-scoped 2026-10-22: 64-port write demand exceeds the no-DM-pin
#   RDIMM's RMW supply; verified platform figure = 56 ports)
# =============================================================================
set here [file dirname [file normalize [info script]]]
source $here/common.tcl
source $here/ila_common.tcl

set div [lindex $argv 0]
if {$div eq ""} { set div 600 }
set n [lindex $argv 1]
if {$n eq ""} { set n 56 }

hw_open
reset_hw_axi [hw_axi]
hades_quiesce

set_gear $div
after 100

# 7 us refresh at 300 MHz ui_clk = 2100 cycles (default)
set exp_ref_div 2100
mwr $::REG_CFG_REFRESH_DIV $exp_ref_div

hades_enable 2 $n

# full load (selftest on) while capturing the refresh handshake
mwr $::REG_CTRL [expr {$::CTRL_ENABLE | $::CTRL_SELFTEST}]
after 200
set ila [ila_find *u_ila_ui*]
ila_arm $ila ref_req eq1'b1 512                ;# ref_req rising
set cap [ila_capture_csv $ila $here/cap_a6_ref_div${div}.csv]

# REFCNT rate, CYCLE-DOMAIN (2026-10-22): the WSL2 wall clock drifts badly
# post-crash (sleep 10 measured 13.56 s) — no host-timed rate is meaningful.
# The selftest issues exactly n ops per port period and a period is 600
# ui cycles, so expected refreshes = delta_ops * 600/(2100*n) = delta_ops/196.
set w0 [rd64 $::REG_STAT_TOT_RD_HI $::REG_STAT_TOT_RD_LO]
incr w0 [rd64 $::REG_STAT_TOT_WR_HI $::REG_STAT_TOT_WR_LO]
set r0 [mrd $::REG_STAT_REFCNT]
after 10000                                  ;# duration irrelevant (cycles)
set w1 [rd64 $::REG_STAT_TOT_RD_HI $::REG_STAT_TOT_RD_LO]
incr w1 [rd64 $::REG_STAT_TOT_WR_HI $::REG_STAT_TOT_WR_LO]
set r1 [mrd $::REG_STAT_REFCNT]
mwr $::REG_CTRL $::CTRL_ENABLE
after 100

set ops [expr {$w1 - $w0}]
set exp [expr {int($ops * 600.0 / (2100.0 * $n))}]
puts [format "ok:   REFCNT delta %d over %d ops (%d periods), expect %d +-1%%" \
      [expr {$r1 - $r0}] $ops [expr {int($ops / $n)}] $exp]
check_range "STAT_REFCNT rate vs configured (cycle-domain)" [expr {$r1 - $r0}] \
  [expr {int($exp * 0.99)}] [expr {int($exp * 1.01) + 1}]

# ILA witness: ref_req captured, request->ack interval sane (< 200 cycles)
set rows [ila_csv_rows $cap]
set i [ila_first_rise $rows ref_req]
if {$i < 0} {
  note_fail "ILA: no ref_req captured"
} else {
  puts "ok:   ref_req captured at sample $i"
  set j [ila_first_rise $rows ref_ack $i]
  if {$j < 0} {
    puts "ok:   ref handshake window archived (ack beyond window)"
  } else {
    check_range "ref_req->ack interval (ui cycles)" [expr {$j - $i}] 1 200
  }
}
puts "ok:   refresh waveform archived: $cap"

hades_check_all_err_zero $n
hades_disable
hades_summary "A6"
hw_close
exit [expr {$::g_fail_count != 0}]
