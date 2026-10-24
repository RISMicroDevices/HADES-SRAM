# =============================================================================
# HADES-SRAM VCU1525 — host common (M5-hw).  Sourced by every host script.
# Connection: Vivado hw_server (Windows side) reached from WSL2 at
# localhost:3121 (mirrored networking); FTDI target xilinx_tcf.
# Register access: JTAG-AXI master (hw_axi) at 0x0000_0000 (HADES IP CSR)
# and 0x0001_0000 (board_ctrl).  See csr/csr_regmap.md.
# =============================================================================

if {[info exists ::env(HADES_HW_URL)]} { set ::HADES_HW_URL $::env(HADES_HW_URL) } \
else                                     { set ::HADES_HW_URL localhost:3121 }

set ::HADES_HOST_DIR [file dirname [file normalize [info script]]]

# ---- HADES IP CSR offsets (0x0000_0000 base)
set ::REG_CTRL            0x0000
set ::REG_STATUS          0x0004
set ::REG_CFG_LATENCY     0x0008
set ::REG_CFG_PORTS       0x000C
set ::REG_MEAS_PERIOD     0x0010
set ::REG_PORT_EN_LO      0x0014
set ::REG_PORT_EN_HI      0x0018
set ::REG_CFG_MIN_PERIOD  0x001C
set ::REG_PORT_SEL        0x0020
set ::REG_PORT_BASE       0x0024
set ::REG_PORT_BASE_HI    0x0028
set ::REG_PORT_SIZE       0x002C
set ::REG_PORT_STAT_RD    0x0030
set ::REG_PORT_STAT_WR    0x0034
set ::REG_PORT_STAT_ERR   0x0038
set ::REG_PORT_WIDTH      0x003C
set ::REG_CFG_REFRESH_DIV 0x0040
set ::REG_CFG_ZQ_DIV      0x0044
set ::REG_ERR_STATUS      0x0050
set ::REG_ERR_ADDR        0x0054
set ::REG_STAT_MAXLAT     0x0058
set ::REG_STAT_REFCNT     0x005C
set ::REG_STAT_TOT_RD_LO  0x0060
set ::REG_STAT_TOT_WR_LO  0x0064
set ::REG_STAT_TOT_RD_HI  0x0068
set ::REG_STAT_TOT_WR_HI  0x006C
set ::REG_ID              0x0080
set ::REG_PARAMS          0x0084
# ---- board_ctrl offsets (0x0001_0000 base)
set ::BREG_BASE    0x10000
set ::BREG_ID      0x10000
set ::BREG_SCRATCH 0x10004
set ::BREG_CLK_DIV 0x10008
set ::BREG_CLK_CTRL 0x1000C

# CTRL bits
set ::CTRL_ENABLE    0x1
set ::CTRL_SOFTRESET 0x2
set ::CTRL_SELFTEST  0x4

set ::g_fail_count 0

proc note_fail {msg} {
  puts "FAIL: $msg"
  incr ::g_fail_count
}

proc check_eq {what got exp} {
  if {[expr {$got == $exp}]} { puts [format "ok:   %s = 0x%08X" $what $got] } \
  else { note_fail [format "%s = 0x%08X, expected 0x%08X" $what $got $exp] }
}

proc check_range {what got lo hi} {
  if {[expr {$got >= $lo && $got <= $hi}]} {
    puts [format "ok:   %s = %d in \[%d,%d\]" $what $got $lo $hi]
  } else {
    note_fail [format "%s = %d, expected \[%d,%d\]" $what $got $lo $hi]
  }
}

proc hades_summary {tag} {
  if {$::g_fail_count == 0} { puts "HADES_${tag}_PASS" } \
  else                      { puts "HADES_${tag}_FAIL ($::g_fail_count failures)" }
}

# ------------------------------------------------------------------ connect
proc hw_open {{url ""}} {
  if {$url eq ""} { set url $::HADES_HW_URL }
  open_hw_manager
  connect_hw_server -url $url -allow_non_jtag
  set t [open_hw_target [lindex [get_hw_targets] 0]]
  # 6 MHz TCK: the dbg_hub + long chain goes marginal at the 15 MHz default
  # after long hot selftest sessions (2026-10-20 chain-wedge incident)
  catch {set_property PARAM.FREQUENCY 6000000 $t}
  current_hw_device [lindex [get_hw_devices xcvu9p*] 0]
  # associate the probes file explicitly — without it the ILA cores enumerate
  # with generic names and ila_find's CELL_NAME match fails (2026-10-22: the
  # mapping had been served by a lingering program-session cs_server cache)
  if {[info exists ::env(HADES_LTX)]} { set ltx $::env(HADES_LTX) } \
  else { set ltx [file join $::HADES_HOST_DIR .. build sync hades_sram_vcu1525_sync.ltx] }
  if {[file exists $ltx]} {
    catch {set_property PROBES.FILE [file normalize $ltx] [current_hw_device]}
  }
  refresh_hw_device [current_hw_device]
}

proc hw_close {} {
  catch {close_hw_target}
  catch {disconnect_hw_server}
  catch {close_hw_manager}
}

proc hw_axi {} {
  set a [get_hw_axis -quiet]
  if {![llength $a]} { error "no hw_axi (jtag_axi) found — bitstream loaded?" }
  return [lindex $a 0]
}

# ------------------------------------------------------------- AXI accesses
proc mwr {addr data} {
  set a [hw_axi]
  set tx [create_hw_axi_txn wr_$addr $a -address [format 0x%08X $addr] \
          -data [format %08X $data] -type write -force]
  run_hw_axi $tx
}

proc mrd {addr} {
  set a [hw_axi]
  set tx [create_hw_axi_txn rd_$addr $a -address [format 0x%08X $addr] \
          -type read -force]
  run_hw_axi $tx
  return [expr "0x[get_property DATA $tx]"]
}

proc rd64 {hi lo} {
  return [expr {([mrd $hi] << 32) | ([mrd $lo] & 0xFFFFFFFF)}]
}

# ------------------------------------------------------------ HADES helpers
proc hades_poll_ready {{timeout_ms 3000}} {
  set t0 [clock milliseconds]
  while {1} {
    set s [mrd $::REG_STATUS]
    if {($s & 0x3) == 0x3} { return $s }
    if {[clock milliseconds] - $t0 > $timeout_ms} {
      note_fail "STATUS.READY timeout (STATUS=$s)"
      return $s
    }
    after 10
  }
}

proc hades_default_map {} {
  # 64 ports x 16 MiB map, bank-staggered (2026-10-20 hardware finding):
  # flat bases (i*2^18 beats) put every stream on the same DRAM bank phase
  # (2^18 mod 16 banks = 0) — all 64 ports walk the 16 banks in lockstep and
  # thrash (~tRC per 1-beat command, backend ~3M ops/s vs 32M/s demand).
  # base_i = i*(2^18 + 1) keeps windows disjoint (1-beat holes) and starts
  # stream i on bank i%16 — banks interleave across ports.
  for {set p 0} {$p < 64} {incr p} {
    mwr $::REG_PORT_SEL $p
    mwr $::REG_PORT_BASE [expr {$p * (0x40000 + 1)}]
    mwr $::REG_PORT_BASE_HI 0
    mwr $::REG_PORT_SIZE 0x00400000
  }
}

proc hades_enable {lat {n_ports 64}} {
  mwr $::REG_CTRL 0
  mwr $::REG_CFG_LATENCY $lat
  if {$n_ports >= 64} {
    mwr $::REG_PORT_EN_LO 0xFFFFFFFF
    mwr $::REG_PORT_EN_HI 0xFFFFFFFF
  } elseif {$n_ports > 32} {
    mwr $::REG_PORT_EN_LO 0xFFFFFFFF
    mwr $::REG_PORT_EN_HI [expr {(1 << ($n_ports - 32)) - 1}]
  } else {
    mwr $::REG_PORT_EN_LO [expr {(1 << $n_ports) - 1}]
    mwr $::REG_PORT_EN_HI 0
  }
  mwr $::REG_CFG_PORTS $n_ports
  hades_default_map
  after 50                       ;# let freq_mon measure port_clk
  mwr $::REG_CTRL $::CTRL_ENABLE
  hades_poll_ready
}

proc hades_disable {} {
  mwr $::REG_CTRL 0
  after 50
}

# protocol-correct quiesce (regmap "host protocol"): clear SELFTEST first and
# wait >= 16 port periods, then SOFT_RESET — clears ENABLE + all error/stat
# accumulation, keeps config.  Absorbs any dirty leftover state from an
# errored previous session (2026-10-22: stale CTRL_SELFTEST + an abrupt
# enable drop set a transient overflow record at the next run's start).
proc hades_quiesce {} {
  catch {mwr $::REG_CTRL $::CTRL_ENABLE}          ;# SELFTEST off, keep ENABLE
  after 100                                        ;# >> 16 port periods
  catch {mwr $::REG_CTRL $::CTRL_SOFTRESET}        ;# clears ENABLE + errors
  after 100
}

proc hades_clear_all_err {} {
  for {set p 0} {$p < 64} {incr p} {
    mwr $::REG_PORT_SEL $p
    mwr $::REG_PORT_STAT_ERR 1      ;# any write = W1C clear
  }
  mwr $::REG_ERR_STATUS 0x3F
}

proc hades_read_stat_err {p} {
  mwr $::REG_PORT_SEL $p
  return [mrd $::REG_PORT_STAT_ERR]
}

proc hades_check_all_err_zero {{n_ports 64}} {
  set bad 0
  for {set p 0} {$p < $n_ports} {incr p} {
    set e [hades_read_stat_err $p]
    if {$e != 0} { note_fail "PORT_STAT_ERR\[$p\] = $e"; incr bad }
  }
  if {!$bad} { puts "ok:   all $n_ports PORT_STAT_ERR = 0" }
  set es [mrd $::REG_ERR_STATUS]
  check_eq "ERR_STATUS & 0x3F" [expr {$es & 0x3F}] 0
}

# selftest: clear counters, run engines for $seconds, stop, drain, verify
proc selftest_run {seconds {n_ports 64}} {
  hades_clear_all_err
  mwr $::REG_CTRL [expr {$::CTRL_ENABLE | $::CTRL_SELFTEST}]
  after [expr {int($seconds * 1000)}]
  mwr $::REG_CTRL $::CTRL_ENABLE        ;# engines off, still enabled
  after 100                             ;# drain (>= 16 port periods)
  hades_check_all_err_zero $n_ports
}

# board clock gear: program div (src cycles / port period) + commit
proc set_gear {div} {
  mwr $::BREG_CLK_DIV $div
  mwr $::BREG_CLK_CTRL 0x101            ;# COMMIT | GATE
  after 20
}

proc meas_period {} {
  return [mrd $::REG_MEAS_PERIOD]
}

# expected MEAS_PERIOD tolerance check (spec A2: +-0.1%)
# gear divider -> expected MEAS_PERIOD.  The on-chip frequency monitor counts
# ui_clk (300 MHz) cycles per port_clk period, but the divider works in
# src_clk cycles: SYNC src=ui_clk (ratio 1); ASYNC MMCM src=100 MHz (ratio 3:
# div 200 = 500 KHz measures 600); ASYNC PCIE src=50 MHz (ratio 6).
# Set env HADES_SRC_UI_RATIO=3 when testing an ASYNC MMCM bitstream.
proc src_ui_ratio {} {
  if {[info exists ::env(HADES_SRC_UI_RATIO)]} { return $::env(HADES_SRC_UI_RATIO) }
  return 1
}
proc gear_ui_cycles {div} { return [expr {$div * [src_ui_ratio]}] }

proc check_meas {exp_ui_cycles} {
  set m [meas_period]
  set tol [expr {max(1.0, $exp_ui_cycles * 0.001)}]
  check_range "MEAS_PERIOD ($m vs $exp_ui_cycles)" $m \
    [expr {int($exp_ui_cycles - $tol)}] [expr {int($exp_ui_cycles + $tol + 1)}]
}

# poll MEAS_PERIOD until it settles at the expected gear (post-commit), or
# fail after timeout.  Use after every set_gear — the commit lands at the
# next divider wrap and the 4-period measurement window must rebuild.
proc wait_meas {exp_ui_cycles {timeout_ms 4000}} {
  set t0 [clock milliseconds]
  while {1} {
    set m [meas_period]
    if {$m >= $exp_ui_cycles - 3 && $m <= $exp_ui_cycles + 4} {
      puts [format "ok:   MEAS_PERIOD settled = %d (exp %d)" $m $exp_ui_cycles]
      return $m
    }
    if {[clock milliseconds] - $t0 > $timeout_ms} {
      note_fail "MEAS_PERIOD settle to $exp_ui_cycles (stuck at $m)"
      return $m
    }
    after 100
  }
}

# anchor long durations on the Windows host clock: the WSL2 wall clock can
# drift after a crash (2026-10-22: a 10s sleep measured 13.56s real)
proc host_now_s {} {
  if {![catch {exec powershell.exe -NoProfile -Command "Get-Date -UFormat %s"} r]} {
    return [expr {int($r)}]
  }
  return [clock seconds]
}

# die temperature via the device SYSMON over JTAG; -1 if not exposed
proc fpga_temp_c {} {
  if {[catch {
    set sm [lindex [get_hw_sysmons -quiet [current_hw_device]] 0]
    if {$sm eq ""} { set sm [lindex [get_hw_sysmons -quiet] 0] }
    if {$sm eq ""} { return -1 }
    refresh_hw_sysmon $sm
    get_property TEMPERATURE $sm
  } r]} { return -1 }
  return $r
}

# soak-grade register read: a JTAG-chain glitch must not kill an 8h run —
# retry, then reconnect the hw_server session once, before giving up.
proc mrd_soak {addr} {
  for {set i 0} {$i < 3} {incr i} {
    if {![catch {mrd $addr} r]} { return $r }
    after 2000
  }
  puts "soak: hw read failing, reconnecting hw_server session"
  catch {hw_close}
  hw_open
  return [mrd $addr]
}
