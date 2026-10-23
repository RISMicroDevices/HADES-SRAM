# =============================================================================
# HADES-SRAM VCU1525 — reviewed report_cdc waivers (ASYNC build).
#
# Sourced by build.tcl after route_design, before report_cdc.  Every entry is
# a crossing structure report_cdc cannot recognize as safe but that IS safe
# by design + protocol.  The A1 gate then requires zero UNWAIVED
# Critical/Warning violations, so any new unreviewed CDC fails the build.
# Info-severity findings on our own logic (recognized ASYNC_REG
# synchronizers) are never waived — they are the evidence of correct CDC.
#
# Reviewed 2026-10-22 against build/async_MMCM/reports/cdc.rpt:
# 17772 raw findings -> 0 Critical / 0 Warning unwaived.
# =============================================================================

# -- qs_bus quasi-static CSR configuration, ui_clk -> port_clk -------------
# u_csr config (port_en, latency parameters, ...) is written only while the
# core is quiesced (hades_quiesce host discipline) and crosses through
# hades_qs_bus STAGES=0 (pure wires -> report_cdc sees "unknown circuitry").
# Wire delay bounded by set_max_delay -datapath_only 10 (timing_async_cross.xdc).
foreach id {CDC-1 CDC-13 CDC-15} {
  create_waiver -type CDC -id $id \
    -description "qs_bus quasi-static CSR config into port_clk domain (written only while quiesced; 10ns datapath bound)" \
    -from [get_pins -hier -filter {NAME =~ *g_csr.u_csr/*/C}]
}

# -- qs_bus hold slots, ui_clk -> port_clk ---------------------------------
# slot_data_u/slot_vld_u are held stable from slot hold until release (the A4
# determinism protocol); same 10ns bound.
foreach id {CDC-1 CDC-13 CDC-15} {
  create_waiver -type CDC -id $id \
    -description "qs_bus hold slots: slot data/valid stable from hold until release (A4 protocol; 10ns datapath bound)" \
    -from [get_pins -hier -filter {NAME =~ *u_port/slot_data_u_reg*/C || NAME =~ *u_port/slot_vld_u_reg*/C}]
}

# -- qs_bus release pointer, port_clk -> ui_clk ----------------------------
foreach id {CDC-1 CDC-15} {
  create_waiver -type CDC -id $id \
    -description "qs_bus release: rel_slot_p quasi-static around the ui_clk sampling that clears slot_vld_u" \
    -from [get_pins -hier -filter {NAME =~ *u_port/rel_slot_p_reg*/C}]
}

# -- per-port async FIFO storage (LUTRAM), port_clk write -> ui_clk read ----
# u_wr_fifo/u_rd_fifo are proper async FIFOs: the gray-pointer synchronizers
# are CDC-3-recognized; Vivado still flags the LUTRAM array's CE structure.
create_waiver -type CDC -id CDC-15 \
  -description "per-port async FIFO LUTRAM arrays; gray-pointer protocol recognized separately (CDC-3)" \
  -from [get_pins -hier -filter {NAME =~ *u_port/u_wr_fifo/* || NAME =~ *u_port/u_rd_fifo/*}]

# -- selftest run broadcast -------------------------------------------------
# One CSR bit fanned out to 64 independent per-port 2-flop synchronizers (each
# destination individually CDC-3 clean); port-to-port skew is irrelevant for a
# quasi-static run-control bit.
create_waiver -type CDC -id CDC-11 \
  -description "selftest_req broadcast to 64 per-port sync2 chains; cross-port alignment not required" \
  -from [get_pins -hier -filter {NAME =~ *g_csr.u_csr/selftest_req_reg*/C}]

# -- debug taps --------------------------------------------------------------
create_waiver -type CDC -id CDC-4 \
  -description "u_ila_pc PROBE_PIPE taps the quasi-static port_en CSR bus (debug-only)" \
  -from [get_pins -hier -filter {NAME =~ *g_csr.u_csr/port_en_reg*/C}]

# -- vendor IP internals ------------------------------------------------------
create_waiver -type CDC -id CDC-10 \
  -description "MIG infrastructure internal reset filter structure (vendor IP, False Path exception)" \
  -from [get_pins -hier -filter {NAME =~ *rst_filt_cnt_reg*/C}]
foreach id {CDC-1 CDC-3 CDC-6 CDC-9 CDC-13 CDC-15} {
  create_waiver -type CDC -id $id \
    -description "Xilinx debug hub internal CDC structure (vendor IP)" \
    -from [get_pins -hier -filter {NAME =~ *dbg_hub/*}]
}
foreach id {CDC-1 CDC-6 CDC-13 CDC-15} {
  create_waiver -type CDC -id $id \
    -description "Xilinx ILA / JTAG-AXI core internal CDC structure (vendor IP)" \
    -from [get_pins -hier -filter {NAME =~ *u_ila_ui/* || NAME =~ *u_ila_pc/* || NAME =~ *u_jtag_axi/*}]
}
