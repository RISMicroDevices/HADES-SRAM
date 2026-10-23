# Debug: backdoor w/r with strict busy->done sequencing + neighbor reads.
set here [file dirname [file normalize [info script]]]
source $here/common.tcl

proc bkp_wait_done {} {
  # first wait busy=1 (engine picked it up), then done=1
  set saw_busy 0
  for {set t 0} {$t < 2000} {incr t} {
    set s [mrd 0x00A8]
    if {$s & 0x1} { set saw_busy 1 }
    if {$saw_busy && ($s & 0x3) == 0x2} { return $s }
  }
  puts "WARN: bkp_wait_done timeout (status=$s)"
  return $s
}

proc bkp_wr {port addr data} {
  mwr 0x0090 $port
  mwr 0x0094 $addr
  mwr 0x0098 0
  mwr 0x009C $data
  mwr 0x00A0 1
  bkp_wait_done
}

proc bkp_rd {port addr} {
  mwr 0x0090 $port
  mwr 0x0094 $addr
  mwr 0x0098 0
  mwr 0x00A0 2
  set s [bkp_wait_done]
  return [list $s [mrd 0x00A4]]
}

hw_open
reset_hw_axi [hw_axi]

foreach p {0 5} {
  set d [expr {0xC0FFEE00 + $p}]
  set s [bkp_wr $p 0 $d]
  lassign [bkp_rd $p 0] s1 r1
  lassign [bkp_rd $p 0] s2 r2
  lassign [bkp_rd $p 1] s3 r3
  puts [format "port %2d: w=0x%08X r1=0x%08X r2=0x%08X r\[1\]=0x%08X %s" \
        $p $d $r1 $r2 $r3 [expr {($r1 == $d && $r2 == $d) ? "MATCH" : "MISMATCH"}]]
}

hw_close
exit 0
