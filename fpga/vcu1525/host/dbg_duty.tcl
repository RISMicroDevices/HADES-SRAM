# Debug: AXI channel duty-cycle measurement under full selftest load.
# Answers: is the backend throttled on issue (arready gaps), on return
# (rready gaps), or neither (engine-limited)?
#   vivado -mode batch -source host/dbg_duty.tcl -tclargs [div] [bitdir]
set here [file dirname [file normalize [info script]]]
source $here/common.tcl
source $here/ila_common.tcl

set div [lindex $argv 0]; if {$div eq ""} { set div 600 }
set bdir [lindex $argv 1]; if {$bdir eq ""} { set bdir "$here/../build/sync_lastmile" }

hw_open
set_property PROBES.FILE $bdir/hades_sram_vcu1525_sync.ltx [current_hw_device]
refresh_hw_device [current_hw_device]
reset_hw_axi [hw_axi]

set_gear $div
after 100
hades_enable 2 64
mwr $::REG_CTRL [expr {$::CTRL_ENABLE | $::CTRL_SELFTEST}]
after 1000                         ;# full-load steady state

set ila [ila_find *u_ila_ui*]
ila_arm $ila {calib} eq1'b1 64     ;# always-true trigger: capture "now"
set cap [ila_capture_csv $ila $here/cap_duty.csv]

mwr $::REG_CTRL $::CTRL_ENABLE
hades_disable

set rows [ila_csv_rows $cap]
set n 0
set ar_v 0; set ar_a 0; set r_v 0; set r_a 0
set aw_v 0; set aw_a 0; set w_v 0; set w_a 0
foreach r $rows {
  set arv [dict get $r axi_arvalid]; set arr [dict get $r axi_arready]
  set rv  [dict get $r axi_rvalid];  set rr  [dict get $r axi_rready]
  set awv [dict get $r axi_awvalid]; set awr [dict get $r axi_awready]
  set wv  [dict get $r axi_wvalid];  set wr  [dict get $r axi_wready]
  if {$arv == 1} { incr ar_v; if {$arr == 1} { incr ar_a } }
  if {$rv == 1}  { incr r_v;  if {$rr == 1}  { incr r_a } }
  if {$awv == 1} { incr aw_v; if {$awr == 1} { incr aw_a } }
  if {$wv == 1}  { incr w_v;  if {$wr == 1}  { incr w_a } }
  incr n
}
puts "DUTY window=$n ui_clk cycles"
puts [format "DUTY AR: valid=%d accept=%d (%.1f%% of cycles; stall %.1f%%)" \
  $ar_v $ar_a [expr {100.0*$ar_v/$n}] [expr {$ar_v ? 100.0*($ar_v-$ar_a)/$ar_v : 0}]]
puts [format "DUTY R : valid=%d accept=%d (%.1f%% of cycles; stall %.1f%%)" \
  $r_v $r_a [expr {100.0*$r_v/$n}] [expr {$r_v ? 100.0*($r_v-$r_a)/$r_v : 0}]]
puts [format "DUTY AW: valid=%d accept=%d   W: valid=%d accept=%d" $aw_v $aw_a $w_v $w_a]
puts [format "DUTY rd throughput = %.1f Mops/s ; wr = %.1f Mops/s" \
  [expr {$ar_a/($n/300.0)}] [expr {$w_a/($n/300.0)}]]
hw_close
exit 0
