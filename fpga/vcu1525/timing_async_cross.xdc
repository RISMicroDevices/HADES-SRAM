# =============================================================================
# HADES-SRAM VCU1525 — ASYNC build, post-place timing (read between
# place_design and route_design; see timing_async.xdc for why).
#
# ui_clk tree (from the MIG XDC) vs the async-source tree (which already
# includes hades_port_clk through the divider's generated clock).  Only the
# whitelist CDC cells of rtl/hades_sram_cdc.sv cross: cut the domains, then bound
# the sync2 first stages and the quasi-static crossings.
# =============================================================================

# XDC files are NOT full Tcl: control flow (if/foreach/...) is rejected with
# Designutils 20-1307 and silently skipped, so the clock-source selection must
# be one pattern list — never a conditional (2026-10-22: the if/fallback here
# never ran, the async group came out empty, set_clock_groups was a no-op and
# ~17.5k inter-clock paths got timed: route WNS -3.114 / WHS -4.476).
set hades_ui_clks    [get_clocks -include_generated_clocks -of_objects [get_pins u_mig/c0_ddr4_ui_clk]]
set hades_async_clks [get_clocks -include_generated_clocks -of_objects [get_ports -quiet {pcie_refclk_p clk1_p}]]
set_clock_groups -asynchronous -group $hades_ui_clks -group $hades_async_clks

# whitelist sync2 first stages: bound the datapath delay into the ASYNC_REG
# pair (MTBF handled by the 2-flop structure; see integration guide)
set_max_delay -datapath_only 3.3 \
    -to [get_cells -hier -filter {NAME =~ */s1_reg && IS_SEQUENTIAL}] -quiet
set_max_delay -datapath_only 3.3 \
    -to [get_cells -hier -filter {NAME =~ */s_reg[*] && IS_SEQUENTIAL}] -quiet

# qs_bus quasi-static crossings (STAGES=0 hold slots etc.): protocol-guaranteed
# stable around sampling; bound the wire delay.  Generate scopes join with '.'
# (g_ports[i].u_port/...), so an anchored '*/u_port/' glob never matches —
# verified against post_synth.dcp: bare patterns hit 8192/256 cells exactly.
set_max_delay -datapath_only 10.0 \
    -from [get_cells -hier -filter {NAME =~ *slot_data_u_reg*}] -quiet
set_max_delay -datapath_only 10.0 \
    -from [get_cells -hier -filter {NAME =~ *slot_vld_u_reg*}] -quiet
