# =============================================================================
# HADES-SRAM VCU1525 — SYNC build timing (CLK_MODE=SYNC)
#
# ui_clk (300 MHz) comes from the MIG XDC.  port_clk is the fabric-divided
# square wave from board_clk_gen's BUFGCE: same-source with ui_clk.
#
# The 600:1 integer divide makes naive same-cycle analysis meaningless at the
# domain boundary (edge spacing collapses to 0..3.3 ns by phase; hold is
# structurally violated).  The domain-crossing constraints therefore live in
# timing_multicycle.xdc (generous -datapath_only max_delay on every
# ui_clk<->port_clk path — the same treatment as the ASYNC whitelist CDC,
# which is identical by construction), and are applied POST-PLACE: a user
# timing constraint referencing the generated clock in the pre-synth set
# trips the MIG's automatic pblock generation in the placer's "Constrain
# Clocks/Macros" phase.
# =============================================================================

# fabric divider: port_clk = ui_clk / 600 (worst-case gear for analysis)
create_generated_clock -name hades_port_clk \
    -source [get_pins -hier -filter {NAME =~ *u_clkgen/u_bufgce/I}] \
    -divide_by 600 \
    [get_pins -hier -filter {NAME =~ *u_clkgen/u_bufgce/O}]
