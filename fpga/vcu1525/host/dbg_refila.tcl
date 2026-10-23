# Debug: capture the app_ref_req/app_ref_ack handshake shape on u_ila_ui.
set here [file dirname [file normalize [info script]]]
source $here/common.tcl
source $here/ila_common.tcl

hw_open
set_property PROBES.FILE $here/../build/sync/hades_vcu1525_sync.ltx [current_hw_device]
refresh_hw_device [current_hw_device]
reset_hw_axi [hw_axi]

puts [format "STATUS=0x%08X REFCNT=%d" [mrd $::REG_STATUS] [mrd $::REG_STAT_REFCNT]]

set ila [ila_find *u_ila_ui*]
ila_arm $ila ref_req eq1'b1 512
set cap [ila_capture_csv $ila $here/cap_ref_dbg.csv]
puts "captured $cap"

set rows [ila_csv_rows $cap]
set i [ila_first_rise $rows ref_req]
puts "first ref_req at sample $i"
set n 0
foreach r $rows {
  if {$n >= $i - 2 && $n <= $i + 40} {
    puts [format "%4d req=%s ack=%s zq=%s zqa=%s" $n \
          [dict get $r ref_req] [dict get $r ref_ack] \
          [dict get $r zq_req] [dict get $r zq_ack]]
  }
  incr n
}
hw_close
exit 0
