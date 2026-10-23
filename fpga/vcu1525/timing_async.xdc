# =============================================================================
# HADES-SRAM VCU1525 — ASYNC build timing (CLK_MODE=ASYNC)
#
# port_clk comes from an independent source (second MMCM on the other onboard
# oscillator input in the default build; PCIe slot refclk variant prepared).
# Only the whitelist CDC cells in rtl/hades_sram_cdc.sv cross the domains.
#
# The domain-crossing constraints live in timing_async_cross.xdc and are read
# POST-PLACE: a user timing/path constraint referencing clocks in the
# pre-synth set trips the MIG's automatic pblock generation in the placer's
# "Constrain Clocks/Macros" phase (Place 30-881/30-99).
#
# Spec A1 acceptance for this build: report_cdc must show zero violations.
# =============================================================================

# fabric divider generated clock (analysis gear: div=200 -> 500 KHz from the
# 100 MHz MMCM2 source / 50 MHz PCIe ODIV2 source)
create_generated_clock -name hades_port_clk \
    -source [get_pins -hier -filter {NAME =~ *u_clkgen/u_bufgce/I}] \
    -divide_by 200 \
    [get_pins -hier -filter {NAME =~ *u_clkgen/u_bufgce/O}]
