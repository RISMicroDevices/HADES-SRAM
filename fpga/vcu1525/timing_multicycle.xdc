# =============================================================================
# HADES-SRAM VCU1525 — SYNC build, post-place timing (read between
# place_design and route_design; see timing_sync.xdc for why the crossing
# constraints are not in the pre-synth set).
#
# The 600:1 integer divide makes naive same-cycle analysis meaningless at the
# domain boundary: launch/capture edge spacing collapses to 0..3.3 ns by
# phase, and hold is structurally violated.  (A full-ratio multicycle is NOT
# applicable here: -setup references destination-clock cycles while -hold
# references source-clock cycles, so at a 600:1 ratio the hold relaxation
# never compensates the setup shift — measured WHS was -1.19 ms.)
#
# The correct treatment is the same one used for the ASYNC whitelist (the
# CDC structure is identical by construction): nothing time-critical crosses,
# so bound every domain-crossing path with a generous -datapath_only max
# delay (setup checked, no hold analysis).  2000 ns = one 500 KHz target
# period; every crossing is quasi-static or synchronized far inside that.
# All functional timing then lives inside the two domains and closes
# normally.  A1 acceptance: report_timing_summary WNS >= 0 everywhere,
# cross-domain paths timed (not false-pathed) and converged.
# =============================================================================

set hades_ui_clk [get_clocks -of_objects [get_pins u_mig/c0_ddr4_ui_clk]]

set_max_delay 2000 -datapath_only -from $hades_ui_clk           -to [get_clocks hades_port_clk]
set_max_delay 2000 -datapath_only -from [get_clocks hades_port_clk] -to $hades_ui_clk

# "clock-as-data" samplers (freq_mon / refresh tick sample port_clk as data):
# their startpoint is the divider's BUFGCE pin, not a clocked FF, so the
# -from <clock> form above does not match them — bound by the pin instead
set_max_delay 2000 -datapath_only \
    -from [get_pins -hier -filter {NAME =~ *u_clkgen/u_bufgce/O}] -to $hades_ui_clk
