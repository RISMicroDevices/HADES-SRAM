# Debug: capture one AXI read transaction (AR->R) on u_ila_ui, engines on.
set here [file dirname [file normalize [info script]]]
source $here/common.tcl
source $here/ila_common.tcl

hw_open
set_property PROBES.FILE $here/../build/sync/hades_sram_vcu1525_sync.ltx [current_hw_device]
refresh_hw_device [current_hw_device]
reset_hw_axi [hw_axi]

hades_enable 2 64
mwr $::REG_CTRL [expr {$::CTRL_ENABLE | $::CTRL_SELFTEST}]
after 300

set ila [ila_find *u_ila_ui*]
# trigger on arvalid rising (any read issue)
set_property CONTROL.TRIGGER_POSITION 64 $ila
set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.DATA_DEPTH 4096 $ila
set pr [get_hw_probes axi_arvalid -of_objects $ila]
set_property TRIGGER_COMPARE_VALUE eq1'b1 $pr
set cap [ila_capture_csv $ila $here/cap_axi_dbg.csv]

mwr $::REG_CTRL $::CTRL_ENABLE
after 50
hades_disable

set rows [ila_csv_rows $cap]
puts "sample  arv arr rv rr"
set n 0
set printed 0
foreach r $rows {
  set arv [dict get $r axi_arvalid]
  set arr [dict get $r axi_arready]
  set rv  [dict get $r axi_rvalid]
  set rr  [dict get $r axi_rready]
  if {$printed < 90 && $n >= 40} {
    puts [format "%4d   %s   %s   %s   %s" $n $arv $arr $rv $rr]
    incr printed
  }
  incr n
}
hw_close
exit 0
