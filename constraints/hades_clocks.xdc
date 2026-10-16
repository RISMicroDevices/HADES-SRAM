# =============================================================================
# HADES-SRAM clock/CDC constraints — template (M1; completed in M2+)
# Two variants are provided; exactly one is loaded, matching the CLK_MODE
# the IP was built with (package_ip.tcl attaches the right file).
#
# Signal name assumptions (hades_sram_top):
#   ui_clk    - 300 MHz MIG user clock (created by the MIG/XDC outside this IP)
#   port_clk  - 100-500 KHz target-domain clock (created by integrator)
# =============================================================================

# -----------------------------------------------------------------------------
# Variant SYNC (default, CLK_MODE=1)
# port_clk and ui_clk come from the SAME MMCM/PLL (or BUFGCE_DIV integer
# divide); the phase relation is static and declared here, so cross-domain
# paths are ordinary timing paths analyzed by report_timing.
# Spread-spectrum or runtime-drifting sources are FORBIDDEN in SYNC mode —
# rebuild with CLK_MODE=ASYNC if the integrator cannot guarantee same-source.
#
# Example (port_clk = ui_clk / 600 via BUFGCE_DIV):
#   create_generated_clock -name hades_port_clk \
#       -source [get_pins <bufgce_div>/I] -divide_by 600 [get_pins <bufgce_div>/O]
#   # paths ui_clk -> port_clk are timed normally; nothing else required.
#   # Optionally relax port_clk -> ui_clk capture with a multicycle:
#   set_multicycle_path -setup 2 -from [get_clocks hades_port_clk] -to [get_clocks <ui_clk>]
#   set_multicycle_path -hold  1 -from [get_clocks hades_port_clk] -to [get_clocks <ui_clk>]
# Acceptance: report_timing shows all cross-domain paths converged (A1).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Variant ASYNC (CLK_MODE=0)
# Independent clock sources; only whitelist CDC (rtl/hades_cdc.sv) crosses.
#
#   set_clock_groups -asynchronous -group [get_clocks <ui_clk>] \
#                                  -group [get_clocks <port_clk>]
#
#   # hades_sync2 stages: control max delay on the first flop only
#   set_max_delay -datapath_only 3.3 \
#       -from [get_cells -hier -filter {NAME =~ *u_*sync*/s1_reg*}]   # placeholder pattern
#   # hades_qs_bus data: quasi-static; hold guaranteed by protocol, still bound:
#   set_max_delay -datapath_only 10.0 \
#       -from [get_cells -hier -filter {NAME =~ *qs*src*}]            # placeholder pattern
#
# Acceptance: report_cdc zero violations (A1).
# -----------------------------------------------------------------------------
