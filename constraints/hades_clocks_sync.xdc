# =============================================================================
# HADES-SRAM — IP constraints, CLK_MODE=SYNC variant (default).
# Loaded automatically by package_ip.tcl when the core is built with
# IS_SYNC=1.  All names reference only IP ports / internal cells — safe for
# any integrator.
#
# SYNC contract (spec 4.1): ui_clk and port_clk come from the SAME source
# (MMCM/PLL or integer fabric divider) with a static phase relation.  The
# integrator MUST declare port_clk as a generated clock of that divide so
# cross-domain paths are timed as ordinary paths, e.g. for a fabric divider:
#   create_generated_clock -name hades_port_clk \
#     -source [get_pins <divider_bufg>/I] -divide_by 600 [get_pins <divider_bufg>/O]
# Spread-spectrum or phase-drifting sources are FORBIDDEN in SYNC mode —
# rebuild with CLK_MODE=ASYNC if that cannot be guaranteed.
# =============================================================================

# quasi-static response-slot crossings (ui_clk -> port_clk, STAGES=0 wires):
# data is stable >= 1 target period before the shaper samples it; bound the
# wire delay so the router keeps the crossing short.  Sources are the hold
# registers inside each hades_port.
set_max_delay -datapath_only 10.0 \
    -from [get_cells -hier -filter {NAME =~ */u_port/slot_data_u_reg*}] -quiet
set_max_delay -datapath_only 10.0 \
    -from [get_cells -hier -filter {NAME =~ */u_port/slot_vld_u_reg*}] -quiet

# same-source sync2 stages are ordinary timed paths in SYNC; nothing further
# to relax.  Acceptance (A1): report_timing shows all cross-domain paths
# converged with WNS >= 0.
