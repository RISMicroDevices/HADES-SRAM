# =============================================================================
# HADES-SRAM VCU1525 — A4: latency accuracy, hardware (spec 6.2)
# On-chip selftest per-cycle phase check is the criterion (PORT_STAT_ERR=0
# on all enabled ports, ERR_STATUS.bit5=0, at L=1 and L=2); the port_clk ILA
# re-witnesses the req->rvalid spacing on ports 0..3 (>= 1e4 port periods of
# selftest traffic pass while the captures are taken).
#   -tclargs <div> [seconds] [n_ports]   default: div=600 (500 KHz SYNC), 3 s,
#                                        n_ports=64
#   Load re-scope (2026-10-22, user decision): the verified full-load figure
#   on this platform is n_ports=56 — the fitted x4-class RDIMM has no DM pins
#   (VCU1525 part0_pins.xml: none routed), every 32-bit partial write is a
#   MIG-internal RMW, and the measured write supply (~28M ops/s, knee between
#   56 and 64) is below the 64-port demand (32M/s).  Run as: 600 3 56
# =============================================================================
set here [file dirname [file normalize [info script]]]
source $here/common.tcl
source $here/ila_common.tcl

set div [lindex $argv 0];  if {$div eq ""} { set div 600 }
set secs [lindex $argv 1]; if {$secs eq ""} { set secs 3 }
set n   [lindex $argv 2];  if {$n eq ""}   { set n 64 }

hw_open
reset_hw_axi [hw_axi]
hades_quiesce

set_gear $div
after 100
check_meas [gear_ui_cycles $div]

foreach L {2 1} {
  puts "--- A4: L=$L at div=$div n=$n ---"
  hades_enable $L $n

  # >= 1e4 periods of traffic with per-cycle checking (0.5s @500KHz = 25e4)
  # split into two runs; ILA capture taken during the second
  selftest_run $secs $n

  hades_clear_all_err
  mwr $::REG_CTRL [expr {$::CTRL_ENABLE | $::CTRL_SELFTEST}]
  after 500                                    ;# engines settle into RD bursts
  set ila [ila_find *u_ila_pc*]
  ila_arm $ila {u_hades/g_ports[0].u_port/rd_req_p} eq1'b1 1024
  set cap [ila_capture_csv $ila $here/cap_a4_L${L}_div${div}.csv]
  mwr $::REG_CTRL $::CTRL_ENABLE
  after 100
  hades_check_all_err_zero $n

  # witness: per-response req->rvalid spacing.  Wire-level expectation is a
  # constant L+1 port_clk samples (the +1 = registered release visibility at
  # the sampling edge; the authoritative ==L instrument is the on-chip
  # per-cycle phase checker, PORT_STAT_ERR above).  The first pair is
  # dropped — it can answer a pre-window request.  2026-10-22: parser fixed
  # (0b-bareword bug read every cell as 0) + taps DONT_TOUCHed.
  set rows [ila_csv_rows $cap]
  set gaps [ila_req_rv_gaps $rows {u_hades/g_ports[0].u_port/rd_req_p} \
                                 {u_hades/g_ports[0].u_port/rvalid}]
  puts "ok:   ILA req->rvalid gaps (L=$L): $gaps"
  if {[llength $gaps] < 2} {
    note_fail "ILA capture has no req/rvalid pairs (L=$L)"
  } else {
    set bad 0
    foreach g [lrange $gaps 1 end] {
      if {$g != $L + 1} { incr bad }
    }
    check_eq "ILA req->rvalid spacing constant L+1 (L=$L)" $bad 0
  }
  set nr [ila_count_rises $rows {u_hades/g_ports[0].u_port/rvalid}]
  check_range "ILA rvalid edges in window" $nr 1 4096
}

hades_disable
hades_summary "A4"
hw_close
exit [expr {$::g_fail_count != 0}]
