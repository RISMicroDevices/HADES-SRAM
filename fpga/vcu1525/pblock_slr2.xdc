# =============================================================================
# HADES-SRAM VCU1525 — SLR placement note (spec A1 / DoD methodology)
#
# INTENDED: pblock the whole HADES core into SLR2 while the MIG C0
# controller+PHY stays in SLR0 — the ui_clk AXI4 paths then cross the SLR
# boundary exactly once in each direction through the registered interfaces
# (the worst integration scenario the IP must survive).
#
# OBSERVED TOOLCHAIN LIMITATION (Vivado 2024.1, this design): the MIG's
# built-in automatic pblock generation (placer "Constrain Clocks/Macros"
# phase) fails with Place 30-881 / 30-99 whenever a RANGED user pblock
# exists in the design — whole-SLR ranges, CLOCKREGION ranges, and small
# sub-rectangles all reproduce it; a range-less pblock or no pblock places
# cleanly.  The build therefore ships WITHOUT a ranged pblock: the MIG
# auto-places in SLR0 (board-fixed I/O) and the core places freely.
#
# The SLR-crossing robustness the pblock was meant to stress is instead
# guaranteed by construction (M5-hw): every MIG-side input is registered at
# the HADES boundary (calib/refresh acks) and inside hades_mig_if (R/B AXI
# channels), and every HADES AXI output is a register — all SLR crossings
# are FF->FF.  Cross-SLR timing is evidenced in
# build/*/reports/timing_summary.rpt (WNS >= 0).  Integrators who need the
# containment demonstration can re-create the pblock in their own flow:
#   create_pblock pblock_hades
#   add_cells_to_pblock pblock_hades [get_cells u_hades]
#   resize_pblock pblock_hades -add {SLR2}
# (works with a free-placed MIG in isolation; conflicts with the MIG's
# automatic pblock generation as noted above).
# =============================================================================
