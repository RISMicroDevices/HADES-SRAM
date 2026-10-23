# =============================================================================
# HADES-SRAM VCU1525 — ILA helpers (M5-hw), sourced after common.tcl.
# Cores: u_ila_ui (ui_clk: probe0={ref,ref_ack,zq,zq_ack}, probe1=AXI hs,
# probe2={calib,rst,rlast}); u_ila_pc (port_clk: probe0=rd_req[3:0],
# probe1=rvalid[3:0]).
# =============================================================================

proc ila_find {pat} {
  # A core on a slow debug clock (u_ila_pc @500 KHz) intermittently fails hub
  # enumeration after a fresh connect — refresh and retry before giving up.
  for {set t 0} {$t < 4} {incr t} {
    foreach i [get_hw_ilas] {
      if {[string match $pat [get_property CELL_NAME $i]]} { return $i }
    }
    catch {refresh_hw_device [lindex [get_hw_devices] 0]}
    after 2000
  }
  error "ILA core $pat not found"
}

# arm with a single compare-value trigger on one probe, mid-window position
proc ila_arm {ila probe_name cmpval {trigpos 2048}} {
  set_property CONTROL.TRIGGER_POSITION $trigpos $ila
  set_property CONTROL.WINDOW_COUNT 1 $ila
  set_property CONTROL.DATA_DEPTH 4096 $ila
  set pr [get_hw_probes $probe_name -of_objects $ila]
  # the arm-time clock-alive check is flaky on the 500 KHz debug clock over
  # the WSL2->Windows JTAG hop ("clock has stopped" while MEAS_PERIOD=600) —
  # retry before giving up (2026-10-22)
  set err "arm failed"
  for {set t 0} {$t < 5} {incr t} {
    if {![catch {set_property TRIGGER_COMPARE_VALUE $cmpval $pr} err]} { return }
    after 1000
  }
  error $err
}

# run -> wait -> upload -> write CSV; returns the csv path
proc ila_capture_csv {ila file} {
  # every ILA interaction re-runs the (flaky @500 KHz) clock-alive check —
  # retry the whole sequence, not just the run (2026-10-22)
  set err "capture failed"
  for {set t 0} {$t < 6} {incr t} {
    set ok [catch {
      run_hw_ila $ila
      wait_on_hw_ila $ila
      set d [upload_hw_ila_data $ila]
      write_hw_ila_data -csv_file -force $file $d
    } err]
    if {!$ok} { display_hw_ila_data $d; return $file }
    after 1500
  }
  error $err
}

# parse an ILA CSV: return list of {sample probename...} rows as dicts
# (Vivado CSV header carries probe names; values are binary strings)
proc ila_csv_rows {file} {
  set fh [open $file r]
  set hdr [split [string trim [gets $fh]] ","]
  set rows [list]
  while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq ""} continue
    set cols [split $line ","]
    set row [dict create]
    foreach h $hdr c $cols {
      dict set row [string trim $h "\" "] [string trim $c "\" "]
    }
    lappend rows $row
  }
  close $fh
  return $rows
}

# rising-edge index list of (value & mask); CSV cells are radix-HEX strings
proc ila_rise_list {rows col {mask -1}} {
  set out [list]
  set prev 0
  set n 0
  foreach r $rows {
    set v 0
    catch {scan [dict get $r $col] %x v; set v [expr {$v & $mask}]}
    if {$prev == 0 && $v != 0} { lappend out $n }
    set prev $v
    incr n
  }
  return $out
}

# req->rvalid gaps: each rvalid rise paired with the latest preceding req
# rise.  CALLER drops the first pair — it can answer a pre-window request.
proc ila_req_rv_gaps {rows reqcol rvcol} {
  set rq [ila_rise_list $rows $reqcol]
  set rv [ila_rise_list $rows $rvcol]
  set gaps [list]
  foreach r $rv {
    set best -1
    foreach q $rq { if {$q <= $r} { set best $q } }
    if {$best >= 0} { lappend gaps [expr {$r - $best}] }
  }
  return $gaps
}

# first sample index where (value & mask) rises 0->nonzero
proc ila_first_rise {rows col {from 0} {mask -1}} {
  set rl [ila_rise_list $rows $col $mask]
  foreach i $rl { if {$i >= $from} { return $i } }
  return -1
}

# count rising edges of (value & mask)
proc ila_count_rises {rows col {mask -1}} {
  set prev 0
  set cnt 0
  foreach r $rows {
    set v 0
    catch {scan [dict get $r $col] %x v; set v [expr {$v & $mask}]}
    if {$prev == 0 && $v != 0} { incr cnt }
    set prev $v
  }
  return $cnt
}
