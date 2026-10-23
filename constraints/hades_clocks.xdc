# =============================================================================
# HADES-SRAM clock/CDC constraints — VARIANT INDEX.
#
# The constraints are split per CLK_MODE (spec DoD); exactly one file is
# loaded, matching the IS_SYNC parameter the IP was built with
# (ip/package_ip.tcl attaches it; the FPGA reference build in fpga/vcu1525
# uses its own timing_sync.xdc / timing_async.xdc):
#
#   hades_clocks_sync.xdc   — CLK_MODE=SYNC (default): same-source clocks,
#                             integrator declares the port_clk generated clock
#   hades_clocks_async.xdc  — CLK_MODE=ASYNC: independent clocks, whitelist
#                             CDC bounds; acceptance = report_cdc 0 violations
#
# Signal names referenced (IP ports): ui_clk (300 MHz MIG user clock),
# port_clk (100-500 KHz target-domain clock).
# =============================================================================
