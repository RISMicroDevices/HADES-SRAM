# =============================================================================
# HADES-SRAM — IP constraints, CLK_MODE=ASYNC variant.
# Loaded automatically by package_ip.tcl when the core is built with
# IS_SYNC=0.  All names reference only IP ports / internal cells — safe for
# any integrator.
#
# ui_clk (300 MHz MIG user clock) and port_clk (100-500 KHz, independent
# source) are asynchronous; only the whitelist cells of rtl/hades_sram_cdc.sv
# cross.  Acceptance (A1): report_cdc zero violations.
# =============================================================================

# cut the domains (references the IP's own port clocks, integrator-safe)
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports ui_clk]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports port_clk]]

# whitelist 2-flop synchronizers (hades_sram_sync2, hades_sram_rst_sync): bound the
# delay into the first (ASYNC_REG) stage; ui_clk is 300 MHz for this IP
set_max_delay -datapath_only 3.3 \
    -to [get_cells -hier -filter {NAME =~ */s1_reg && IS_SEQUENTIAL}] -quiet
set_max_delay -datapath_only 3.3 \
    -to [get_cells -hier -filter {NAME =~ */s_reg[*] && IS_SEQUENTIAL}] -quiet

# quasi-static crossings (qs_bus STAGES=0 hold slots; qs data/valid lines):
# protocol-guaranteed stable around sampling; bound the wire delay
set_max_delay -datapath_only 10.0 \
    -from [get_cells -hier -filter {NAME =~ *slot_data_u_reg*}] -quiet
set_max_delay -datapath_only 10.0 \
    -from [get_cells -hier -filter {NAME =~ *slot_vld_u_reg*}] -quiet
