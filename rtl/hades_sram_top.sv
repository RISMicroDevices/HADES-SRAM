//-----------------------------------------------------------------------------
// HADES-SRAM — top level (spec 3.x).  N emulated SRAM ports (port_clk
// domain) backed by one MIG AXI4 channel (ui_clk domain).
//
// Build-time variants:
//   IS_SYNC:  1=SYNC (default; same-source clocks, XDC-declared phase)
//             0=ASYNC (independent clocks; whitelist CDC)
//   CSR_EN:   1 = AXI4-Lite CSR-configurable (default, spec 3.3)
//             0 = static hard-wired; configuration from parameters
//                 (P_L, P_PORT_EN, P_MIN_PERIOD, P_REFRESH_DIV, P_ZQ_DIV and
//                 the per-port flat vectors P_PORT_BASE / P_PORT_SIZE, fully
//                 user-overridable), auto-enable, pin-level status/backdoor.
//
// M2: full single/multi-port datapath — hades_sram_port (CDC + shaper) array ->
// hades_sram_mig_if (FCFS engine, AXI4, outstanding).  M3: hades_sram_refresh_sched
// (user refresh/ZQCS, maintenance window at the slot-table head).
// M4: hades_sram_arbiter (TDMA static slot gating in front of mig_if) +
// hades_sram_backdoor (CSR/pin host channel, lowest-priority requester).
//-----------------------------------------------------------------------------
`default_nettype none

module hades_sram_top
  import hades_sram_pkg::*;
#(
  // NOTE: defaults are plain literals (not hades_sram_pkg constants) because the
  // Vivado IP packager cannot resolve package references in parameter
  // defaults; values must match hades_sram_pkg (N_MAX=64, DW=32, AW=22, 500 KHz
  // target = 600 ui_clk cycles)
  parameter int  N                    = 1,       // active ports (<= N_MAX)
  parameter int  AW                   = 22,
  parameter bit  IS_SYNC              = 1'b1,    // CLK_MODE: 1=SYNC, 0=ASYNC
  parameter bit  CSR_EN               = 1'b1,
  parameter bit  SELFTEST_EN          = 1'b0,
  parameter int  SELFTEST_BLK         = 256,   // selftest words per pass
  parameter int  TARGET_PERIOD_CYCLES = 600,
  // static-variant (CSR_EN=0) configuration — all user-overridable
  parameter logic [1:0]  P_L              = 2'd2,
  parameter logic [N_MAX-1:0] P_PORT_EN   = {64{1'b1}},
  parameter logic [31:0] P_MIN_PERIOD     = 32'd600,
  parameter logic [31:0] P_REFRESH_DIV    = 32'd2100,
  parameter logic [31:0] P_ZQ_DIV         = 32'd32000,
  parameter logic [N_MAX*BASE_W-1:0] P_PORT_BASE =
      2176'h3F0000000F80000003D0000000F00000003B0000000E8000000390000000E0000000370000000D8000000350000000D0000000330000000C8000000310000000C00000002F0000000B80000002D0000000B00000002B0000000A8000000290000000A0000000270000000980000002500000009000000023000000088000000210000000800000001F0000000780000001D0000000700000001B00000006800000019000000060000000170000000580000001500000005000000013000000048000000110000000400000000F0000000380000000D0000000300000000B00000002800000009000000020000000070000000180000000500000001000000003000000008000000010000000000000,
  parameter logic [N_MAX*32-1:0]     P_PORT_SIZE =
      2048'h400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000004000000040000000400000
,
  parameter int  W0   = 32,
  parameter int  W1   = 32,
  parameter int  W2   = 32,
  parameter int  W3   = 32,
  parameter int  W4   = 32,
  parameter int  W5   = 32,
  parameter int  W6   = 32,
  parameter int  W7   = 32,
  parameter int  W8   = 32,
  parameter int  W9   = 32,
  parameter int  W10  = 32,
  parameter int  W11  = 32,
  parameter int  W12  = 32,
  parameter int  W13  = 32,
  parameter int  W14  = 32,
  parameter int  W15  = 32,
  parameter int  W16  = 32,
  parameter int  W17  = 32,
  parameter int  W18  = 32,
  parameter int  W19  = 32,
  parameter int  W20  = 32,
  parameter int  W21  = 32,
  parameter int  W22  = 32,
  parameter int  W23  = 32,
  parameter int  W24  = 32,
  parameter int  W25  = 32,
  parameter int  W26  = 32,
  parameter int  W27  = 32,
  parameter int  W28  = 32,
  parameter int  W29  = 32,
  parameter int  W30  = 32,
  parameter int  W31  = 32,
  parameter int  W32  = 32,
  parameter int  W33  = 32,
  parameter int  W34  = 32,
  parameter int  W35  = 32,
  parameter int  W36  = 32,
  parameter int  W37  = 32,
  parameter int  W38  = 32,
  parameter int  W39  = 32,
  parameter int  W40  = 32,
  parameter int  W41  = 32,
  parameter int  W42  = 32,
  parameter int  W43  = 32,
  parameter int  W44  = 32,
  parameter int  W45  = 32,
  parameter int  W46  = 32,
  parameter int  W47  = 32,
  parameter int  W48  = 32,
  parameter int  W49  = 32,
  parameter int  W50  = 32,
  parameter int  W51  = 32,
  parameter int  W52  = 32,
  parameter int  W53  = 32,
  parameter int  W54  = 32,
  parameter int  W55  = 32,
  parameter int  W56  = 32,
  parameter int  W57  = 32,
  parameter int  W58  = 32,
  parameter int  W59  = 32,
  parameter int  W60  = 32,
  parameter int  W61  = 32,
  parameter int  W62  = 32,
  parameter int  W63  = 32,
  parameter bit  BE0_EN = 1'b0,
  parameter bit  BE1_EN = 1'b0,
  parameter bit  BE2_EN = 1'b0,
  parameter bit  BE3_EN = 1'b0,
  parameter bit  BE4_EN = 1'b0,
  parameter bit  BE5_EN = 1'b0,
  parameter bit  BE6_EN = 1'b0,
  parameter bit  BE7_EN = 1'b0,
  parameter bit  BE8_EN = 1'b0,
  parameter bit  BE9_EN = 1'b0,
  parameter bit  BE10_EN = 1'b0,
  parameter bit  BE11_EN = 1'b0,
  parameter bit  BE12_EN = 1'b0,
  parameter bit  BE13_EN = 1'b0,
  parameter bit  BE14_EN = 1'b0,
  parameter bit  BE15_EN = 1'b0,
  parameter bit  BE16_EN = 1'b0,
  parameter bit  BE17_EN = 1'b0,
  parameter bit  BE18_EN = 1'b0,
  parameter bit  BE19_EN = 1'b0,
  parameter bit  BE20_EN = 1'b0,
  parameter bit  BE21_EN = 1'b0,
  parameter bit  BE22_EN = 1'b0,
  parameter bit  BE23_EN = 1'b0,
  parameter bit  BE24_EN = 1'b0,
  parameter bit  BE25_EN = 1'b0,
  parameter bit  BE26_EN = 1'b0,
  parameter bit  BE27_EN = 1'b0,
  parameter bit  BE28_EN = 1'b0,
  parameter bit  BE29_EN = 1'b0,
  parameter bit  BE30_EN = 1'b0,
  parameter bit  BE31_EN = 1'b0,
  parameter bit  BE32_EN = 1'b0,
  parameter bit  BE33_EN = 1'b0,
  parameter bit  BE34_EN = 1'b0,
  parameter bit  BE35_EN = 1'b0,
  parameter bit  BE36_EN = 1'b0,
  parameter bit  BE37_EN = 1'b0,
  parameter bit  BE38_EN = 1'b0,
  parameter bit  BE39_EN = 1'b0,
  parameter bit  BE40_EN = 1'b0,
  parameter bit  BE41_EN = 1'b0,
  parameter bit  BE42_EN = 1'b0,
  parameter bit  BE43_EN = 1'b0,
  parameter bit  BE44_EN = 1'b0,
  parameter bit  BE45_EN = 1'b0,
  parameter bit  BE46_EN = 1'b0,
  parameter bit  BE47_EN = 1'b0,
  parameter bit  BE48_EN = 1'b0,
  parameter bit  BE49_EN = 1'b0,
  parameter bit  BE50_EN = 1'b0,
  parameter bit  BE51_EN = 1'b0,
  parameter bit  BE52_EN = 1'b0,
  parameter bit  BE53_EN = 1'b0,
  parameter bit  BE54_EN = 1'b0,
  parameter bit  BE55_EN = 1'b0,
  parameter bit  BE56_EN = 1'b0,
  parameter bit  BE57_EN = 1'b0,
  parameter bit  BE58_EN = 1'b0,
  parameter bit  BE59_EN = 1'b0,
  parameter bit  BE60_EN = 1'b0,
  parameter bit  BE61_EN = 1'b0,
  parameter bit  BE62_EN = 1'b0,
  parameter bit  BE63_EN = 1'b0
) (
  input  wire ui_clk,
  input  wire ui_rst_n,
  input  wire port_clk,
  input  wire port_rst_n,
  input  wire calib_done,      // MIG init_calib_complete

  // ---- emulated SRAM ports (port_clk domain), separated per port
  // (v1.1.0): own width W<i> (1..512) and byte-enable input (BE<i>_EN)
  input  wire                 sram0_en,
  input  wire                 sram0_we,
  input  wire       [AW-1:0]  sram0_addr,
  input  wire       [W0-1:0]   sram0_wdata,
  input  wire       [63:0]   sram0_be,
  output          logic [W0-1:0]   sram0_rdata,
  output          logic          sram0_rvalid,
  input  wire                 sram1_en,
  input  wire                 sram1_we,
  input  wire       [AW-1:0]  sram1_addr,
  input  wire       [W1-1:0]   sram1_wdata,
  input  wire       [63:0]   sram1_be,
  output          logic [W1-1:0]   sram1_rdata,
  output          logic          sram1_rvalid,
  input  wire                 sram2_en,
  input  wire                 sram2_we,
  input  wire       [AW-1:0]  sram2_addr,
  input  wire       [W2-1:0]   sram2_wdata,
  input  wire       [63:0]   sram2_be,
  output          logic [W2-1:0]   sram2_rdata,
  output          logic          sram2_rvalid,
  input  wire                 sram3_en,
  input  wire                 sram3_we,
  input  wire       [AW-1:0]  sram3_addr,
  input  wire       [W3-1:0]   sram3_wdata,
  input  wire       [63:0]   sram3_be,
  output          logic [W3-1:0]   sram3_rdata,
  output          logic          sram3_rvalid,
  input  wire                 sram4_en,
  input  wire                 sram4_we,
  input  wire       [AW-1:0]  sram4_addr,
  input  wire       [W4-1:0]   sram4_wdata,
  input  wire       [63:0]   sram4_be,
  output          logic [W4-1:0]   sram4_rdata,
  output          logic          sram4_rvalid,
  input  wire                 sram5_en,
  input  wire                 sram5_we,
  input  wire       [AW-1:0]  sram5_addr,
  input  wire       [W5-1:0]   sram5_wdata,
  input  wire       [63:0]   sram5_be,
  output          logic [W5-1:0]   sram5_rdata,
  output          logic          sram5_rvalid,
  input  wire                 sram6_en,
  input  wire                 sram6_we,
  input  wire       [AW-1:0]  sram6_addr,
  input  wire       [W6-1:0]   sram6_wdata,
  input  wire       [63:0]   sram6_be,
  output          logic [W6-1:0]   sram6_rdata,
  output          logic          sram6_rvalid,
  input  wire                 sram7_en,
  input  wire                 sram7_we,
  input  wire       [AW-1:0]  sram7_addr,
  input  wire       [W7-1:0]   sram7_wdata,
  input  wire       [63:0]   sram7_be,
  output          logic [W7-1:0]   sram7_rdata,
  output          logic          sram7_rvalid,
  input  wire                 sram8_en,
  input  wire                 sram8_we,
  input  wire       [AW-1:0]  sram8_addr,
  input  wire       [W8-1:0]   sram8_wdata,
  input  wire       [63:0]   sram8_be,
  output          logic [W8-1:0]   sram8_rdata,
  output          logic          sram8_rvalid,
  input  wire                 sram9_en,
  input  wire                 sram9_we,
  input  wire       [AW-1:0]  sram9_addr,
  input  wire       [W9-1:0]   sram9_wdata,
  input  wire       [63:0]   sram9_be,
  output          logic [W9-1:0]   sram9_rdata,
  output          logic          sram9_rvalid,
  input  wire                 sram10_en,
  input  wire                 sram10_we,
  input  wire       [AW-1:0]  sram10_addr,
  input  wire       [W10-1:0]   sram10_wdata,
  input  wire       [63:0]   sram10_be,
  output          logic [W10-1:0]   sram10_rdata,
  output          logic          sram10_rvalid,
  input  wire                 sram11_en,
  input  wire                 sram11_we,
  input  wire       [AW-1:0]  sram11_addr,
  input  wire       [W11-1:0]   sram11_wdata,
  input  wire       [63:0]   sram11_be,
  output          logic [W11-1:0]   sram11_rdata,
  output          logic          sram11_rvalid,
  input  wire                 sram12_en,
  input  wire                 sram12_we,
  input  wire       [AW-1:0]  sram12_addr,
  input  wire       [W12-1:0]   sram12_wdata,
  input  wire       [63:0]   sram12_be,
  output          logic [W12-1:0]   sram12_rdata,
  output          logic          sram12_rvalid,
  input  wire                 sram13_en,
  input  wire                 sram13_we,
  input  wire       [AW-1:0]  sram13_addr,
  input  wire       [W13-1:0]   sram13_wdata,
  input  wire       [63:0]   sram13_be,
  output          logic [W13-1:0]   sram13_rdata,
  output          logic          sram13_rvalid,
  input  wire                 sram14_en,
  input  wire                 sram14_we,
  input  wire       [AW-1:0]  sram14_addr,
  input  wire       [W14-1:0]   sram14_wdata,
  input  wire       [63:0]   sram14_be,
  output          logic [W14-1:0]   sram14_rdata,
  output          logic          sram14_rvalid,
  input  wire                 sram15_en,
  input  wire                 sram15_we,
  input  wire       [AW-1:0]  sram15_addr,
  input  wire       [W15-1:0]   sram15_wdata,
  input  wire       [63:0]   sram15_be,
  output          logic [W15-1:0]   sram15_rdata,
  output          logic          sram15_rvalid,
  input  wire                 sram16_en,
  input  wire                 sram16_we,
  input  wire       [AW-1:0]  sram16_addr,
  input  wire       [W16-1:0]   sram16_wdata,
  input  wire       [63:0]   sram16_be,
  output          logic [W16-1:0]   sram16_rdata,
  output          logic          sram16_rvalid,
  input  wire                 sram17_en,
  input  wire                 sram17_we,
  input  wire       [AW-1:0]  sram17_addr,
  input  wire       [W17-1:0]   sram17_wdata,
  input  wire       [63:0]   sram17_be,
  output          logic [W17-1:0]   sram17_rdata,
  output          logic          sram17_rvalid,
  input  wire                 sram18_en,
  input  wire                 sram18_we,
  input  wire       [AW-1:0]  sram18_addr,
  input  wire       [W18-1:0]   sram18_wdata,
  input  wire       [63:0]   sram18_be,
  output          logic [W18-1:0]   sram18_rdata,
  output          logic          sram18_rvalid,
  input  wire                 sram19_en,
  input  wire                 sram19_we,
  input  wire       [AW-1:0]  sram19_addr,
  input  wire       [W19-1:0]   sram19_wdata,
  input  wire       [63:0]   sram19_be,
  output          logic [W19-1:0]   sram19_rdata,
  output          logic          sram19_rvalid,
  input  wire                 sram20_en,
  input  wire                 sram20_we,
  input  wire       [AW-1:0]  sram20_addr,
  input  wire       [W20-1:0]   sram20_wdata,
  input  wire       [63:0]   sram20_be,
  output          logic [W20-1:0]   sram20_rdata,
  output          logic          sram20_rvalid,
  input  wire                 sram21_en,
  input  wire                 sram21_we,
  input  wire       [AW-1:0]  sram21_addr,
  input  wire       [W21-1:0]   sram21_wdata,
  input  wire       [63:0]   sram21_be,
  output          logic [W21-1:0]   sram21_rdata,
  output          logic          sram21_rvalid,
  input  wire                 sram22_en,
  input  wire                 sram22_we,
  input  wire       [AW-1:0]  sram22_addr,
  input  wire       [W22-1:0]   sram22_wdata,
  input  wire       [63:0]   sram22_be,
  output          logic [W22-1:0]   sram22_rdata,
  output          logic          sram22_rvalid,
  input  wire                 sram23_en,
  input  wire                 sram23_we,
  input  wire       [AW-1:0]  sram23_addr,
  input  wire       [W23-1:0]   sram23_wdata,
  input  wire       [63:0]   sram23_be,
  output          logic [W23-1:0]   sram23_rdata,
  output          logic          sram23_rvalid,
  input  wire                 sram24_en,
  input  wire                 sram24_we,
  input  wire       [AW-1:0]  sram24_addr,
  input  wire       [W24-1:0]   sram24_wdata,
  input  wire       [63:0]   sram24_be,
  output          logic [W24-1:0]   sram24_rdata,
  output          logic          sram24_rvalid,
  input  wire                 sram25_en,
  input  wire                 sram25_we,
  input  wire       [AW-1:0]  sram25_addr,
  input  wire       [W25-1:0]   sram25_wdata,
  input  wire       [63:0]   sram25_be,
  output          logic [W25-1:0]   sram25_rdata,
  output          logic          sram25_rvalid,
  input  wire                 sram26_en,
  input  wire                 sram26_we,
  input  wire       [AW-1:0]  sram26_addr,
  input  wire       [W26-1:0]   sram26_wdata,
  input  wire       [63:0]   sram26_be,
  output          logic [W26-1:0]   sram26_rdata,
  output          logic          sram26_rvalid,
  input  wire                 sram27_en,
  input  wire                 sram27_we,
  input  wire       [AW-1:0]  sram27_addr,
  input  wire       [W27-1:0]   sram27_wdata,
  input  wire       [63:0]   sram27_be,
  output          logic [W27-1:0]   sram27_rdata,
  output          logic          sram27_rvalid,
  input  wire                 sram28_en,
  input  wire                 sram28_we,
  input  wire       [AW-1:0]  sram28_addr,
  input  wire       [W28-1:0]   sram28_wdata,
  input  wire       [63:0]   sram28_be,
  output          logic [W28-1:0]   sram28_rdata,
  output          logic          sram28_rvalid,
  input  wire                 sram29_en,
  input  wire                 sram29_we,
  input  wire       [AW-1:0]  sram29_addr,
  input  wire       [W29-1:0]   sram29_wdata,
  input  wire       [63:0]   sram29_be,
  output          logic [W29-1:0]   sram29_rdata,
  output          logic          sram29_rvalid,
  input  wire                 sram30_en,
  input  wire                 sram30_we,
  input  wire       [AW-1:0]  sram30_addr,
  input  wire       [W30-1:0]   sram30_wdata,
  input  wire       [63:0]   sram30_be,
  output          logic [W30-1:0]   sram30_rdata,
  output          logic          sram30_rvalid,
  input  wire                 sram31_en,
  input  wire                 sram31_we,
  input  wire       [AW-1:0]  sram31_addr,
  input  wire       [W31-1:0]   sram31_wdata,
  input  wire       [63:0]   sram31_be,
  output          logic [W31-1:0]   sram31_rdata,
  output          logic          sram31_rvalid,
  input  wire                 sram32_en,
  input  wire                 sram32_we,
  input  wire       [AW-1:0]  sram32_addr,
  input  wire       [W32-1:0]   sram32_wdata,
  input  wire       [63:0]   sram32_be,
  output          logic [W32-1:0]   sram32_rdata,
  output          logic          sram32_rvalid,
  input  wire                 sram33_en,
  input  wire                 sram33_we,
  input  wire       [AW-1:0]  sram33_addr,
  input  wire       [W33-1:0]   sram33_wdata,
  input  wire       [63:0]   sram33_be,
  output          logic [W33-1:0]   sram33_rdata,
  output          logic          sram33_rvalid,
  input  wire                 sram34_en,
  input  wire                 sram34_we,
  input  wire       [AW-1:0]  sram34_addr,
  input  wire       [W34-1:0]   sram34_wdata,
  input  wire       [63:0]   sram34_be,
  output          logic [W34-1:0]   sram34_rdata,
  output          logic          sram34_rvalid,
  input  wire                 sram35_en,
  input  wire                 sram35_we,
  input  wire       [AW-1:0]  sram35_addr,
  input  wire       [W35-1:0]   sram35_wdata,
  input  wire       [63:0]   sram35_be,
  output          logic [W35-1:0]   sram35_rdata,
  output          logic          sram35_rvalid,
  input  wire                 sram36_en,
  input  wire                 sram36_we,
  input  wire       [AW-1:0]  sram36_addr,
  input  wire       [W36-1:0]   sram36_wdata,
  input  wire       [63:0]   sram36_be,
  output          logic [W36-1:0]   sram36_rdata,
  output          logic          sram36_rvalid,
  input  wire                 sram37_en,
  input  wire                 sram37_we,
  input  wire       [AW-1:0]  sram37_addr,
  input  wire       [W37-1:0]   sram37_wdata,
  input  wire       [63:0]   sram37_be,
  output          logic [W37-1:0]   sram37_rdata,
  output          logic          sram37_rvalid,
  input  wire                 sram38_en,
  input  wire                 sram38_we,
  input  wire       [AW-1:0]  sram38_addr,
  input  wire       [W38-1:0]   sram38_wdata,
  input  wire       [63:0]   sram38_be,
  output          logic [W38-1:0]   sram38_rdata,
  output          logic          sram38_rvalid,
  input  wire                 sram39_en,
  input  wire                 sram39_we,
  input  wire       [AW-1:0]  sram39_addr,
  input  wire       [W39-1:0]   sram39_wdata,
  input  wire       [63:0]   sram39_be,
  output          logic [W39-1:0]   sram39_rdata,
  output          logic          sram39_rvalid,
  input  wire                 sram40_en,
  input  wire                 sram40_we,
  input  wire       [AW-1:0]  sram40_addr,
  input  wire       [W40-1:0]   sram40_wdata,
  input  wire       [63:0]   sram40_be,
  output          logic [W40-1:0]   sram40_rdata,
  output          logic          sram40_rvalid,
  input  wire                 sram41_en,
  input  wire                 sram41_we,
  input  wire       [AW-1:0]  sram41_addr,
  input  wire       [W41-1:0]   sram41_wdata,
  input  wire       [63:0]   sram41_be,
  output          logic [W41-1:0]   sram41_rdata,
  output          logic          sram41_rvalid,
  input  wire                 sram42_en,
  input  wire                 sram42_we,
  input  wire       [AW-1:0]  sram42_addr,
  input  wire       [W42-1:0]   sram42_wdata,
  input  wire       [63:0]   sram42_be,
  output          logic [W42-1:0]   sram42_rdata,
  output          logic          sram42_rvalid,
  input  wire                 sram43_en,
  input  wire                 sram43_we,
  input  wire       [AW-1:0]  sram43_addr,
  input  wire       [W43-1:0]   sram43_wdata,
  input  wire       [63:0]   sram43_be,
  output          logic [W43-1:0]   sram43_rdata,
  output          logic          sram43_rvalid,
  input  wire                 sram44_en,
  input  wire                 sram44_we,
  input  wire       [AW-1:0]  sram44_addr,
  input  wire       [W44-1:0]   sram44_wdata,
  input  wire       [63:0]   sram44_be,
  output          logic [W44-1:0]   sram44_rdata,
  output          logic          sram44_rvalid,
  input  wire                 sram45_en,
  input  wire                 sram45_we,
  input  wire       [AW-1:0]  sram45_addr,
  input  wire       [W45-1:0]   sram45_wdata,
  input  wire       [63:0]   sram45_be,
  output          logic [W45-1:0]   sram45_rdata,
  output          logic          sram45_rvalid,
  input  wire                 sram46_en,
  input  wire                 sram46_we,
  input  wire       [AW-1:0]  sram46_addr,
  input  wire       [W46-1:0]   sram46_wdata,
  input  wire       [63:0]   sram46_be,
  output          logic [W46-1:0]   sram46_rdata,
  output          logic          sram46_rvalid,
  input  wire                 sram47_en,
  input  wire                 sram47_we,
  input  wire       [AW-1:0]  sram47_addr,
  input  wire       [W47-1:0]   sram47_wdata,
  input  wire       [63:0]   sram47_be,
  output          logic [W47-1:0]   sram47_rdata,
  output          logic          sram47_rvalid,
  input  wire                 sram48_en,
  input  wire                 sram48_we,
  input  wire       [AW-1:0]  sram48_addr,
  input  wire       [W48-1:0]   sram48_wdata,
  input  wire       [63:0]   sram48_be,
  output          logic [W48-1:0]   sram48_rdata,
  output          logic          sram48_rvalid,
  input  wire                 sram49_en,
  input  wire                 sram49_we,
  input  wire       [AW-1:0]  sram49_addr,
  input  wire       [W49-1:0]   sram49_wdata,
  input  wire       [63:0]   sram49_be,
  output          logic [W49-1:0]   sram49_rdata,
  output          logic          sram49_rvalid,
  input  wire                 sram50_en,
  input  wire                 sram50_we,
  input  wire       [AW-1:0]  sram50_addr,
  input  wire       [W50-1:0]   sram50_wdata,
  input  wire       [63:0]   sram50_be,
  output          logic [W50-1:0]   sram50_rdata,
  output          logic          sram50_rvalid,
  input  wire                 sram51_en,
  input  wire                 sram51_we,
  input  wire       [AW-1:0]  sram51_addr,
  input  wire       [W51-1:0]   sram51_wdata,
  input  wire       [63:0]   sram51_be,
  output          logic [W51-1:0]   sram51_rdata,
  output          logic          sram51_rvalid,
  input  wire                 sram52_en,
  input  wire                 sram52_we,
  input  wire       [AW-1:0]  sram52_addr,
  input  wire       [W52-1:0]   sram52_wdata,
  input  wire       [63:0]   sram52_be,
  output          logic [W52-1:0]   sram52_rdata,
  output          logic          sram52_rvalid,
  input  wire                 sram53_en,
  input  wire                 sram53_we,
  input  wire       [AW-1:0]  sram53_addr,
  input  wire       [W53-1:0]   sram53_wdata,
  input  wire       [63:0]   sram53_be,
  output          logic [W53-1:0]   sram53_rdata,
  output          logic          sram53_rvalid,
  input  wire                 sram54_en,
  input  wire                 sram54_we,
  input  wire       [AW-1:0]  sram54_addr,
  input  wire       [W54-1:0]   sram54_wdata,
  input  wire       [63:0]   sram54_be,
  output          logic [W54-1:0]   sram54_rdata,
  output          logic          sram54_rvalid,
  input  wire                 sram55_en,
  input  wire                 sram55_we,
  input  wire       [AW-1:0]  sram55_addr,
  input  wire       [W55-1:0]   sram55_wdata,
  input  wire       [63:0]   sram55_be,
  output          logic [W55-1:0]   sram55_rdata,
  output          logic          sram55_rvalid,
  input  wire                 sram56_en,
  input  wire                 sram56_we,
  input  wire       [AW-1:0]  sram56_addr,
  input  wire       [W56-1:0]   sram56_wdata,
  input  wire       [63:0]   sram56_be,
  output          logic [W56-1:0]   sram56_rdata,
  output          logic          sram56_rvalid,
  input  wire                 sram57_en,
  input  wire                 sram57_we,
  input  wire       [AW-1:0]  sram57_addr,
  input  wire       [W57-1:0]   sram57_wdata,
  input  wire       [63:0]   sram57_be,
  output          logic [W57-1:0]   sram57_rdata,
  output          logic          sram57_rvalid,
  input  wire                 sram58_en,
  input  wire                 sram58_we,
  input  wire       [AW-1:0]  sram58_addr,
  input  wire       [W58-1:0]   sram58_wdata,
  input  wire       [63:0]   sram58_be,
  output          logic [W58-1:0]   sram58_rdata,
  output          logic          sram58_rvalid,
  input  wire                 sram59_en,
  input  wire                 sram59_we,
  input  wire       [AW-1:0]  sram59_addr,
  input  wire       [W59-1:0]   sram59_wdata,
  input  wire       [63:0]   sram59_be,
  output          logic [W59-1:0]   sram59_rdata,
  output          logic          sram59_rvalid,
  input  wire                 sram60_en,
  input  wire                 sram60_we,
  input  wire       [AW-1:0]  sram60_addr,
  input  wire       [W60-1:0]   sram60_wdata,
  input  wire       [63:0]   sram60_be,
  output          logic [W60-1:0]   sram60_rdata,
  output          logic          sram60_rvalid,
  input  wire                 sram61_en,
  input  wire                 sram61_we,
  input  wire       [AW-1:0]  sram61_addr,
  input  wire       [W61-1:0]   sram61_wdata,
  input  wire       [63:0]   sram61_be,
  output          logic [W61-1:0]   sram61_rdata,
  output          logic          sram61_rvalid,
  input  wire                 sram62_en,
  input  wire                 sram62_we,
  input  wire       [AW-1:0]  sram62_addr,
  input  wire       [W62-1:0]   sram62_wdata,
  input  wire       [63:0]   sram62_be,
  output          logic [W62-1:0]   sram62_rdata,
  output          logic          sram62_rvalid,
  input  wire                 sram63_en,
  input  wire                 sram63_we,
  input  wire       [AW-1:0]  sram63_addr,
  input  wire       [W63-1:0]   sram63_wdata,
  input  wire       [63:0]   sram63_be,
  output          logic [W63-1:0]   sram63_rdata,
  output          logic          sram63_rvalid,

  // ---- AXI4 master to MIG (512-bit data, 4-bit ID, 40-bit byte address) ----
  output          logic [3:0]         m_axi_awid,
  output          logic [39:0] m_axi_awaddr,
  output          logic [7:0]         m_axi_awlen,
  output          logic [2:0]         m_axi_awsize,
  output          logic [1:0]         m_axi_awburst,
  output          logic               m_axi_awvalid,
  input  wire                   m_axi_awready,
  output          logic [511:0]       m_axi_wdata,
  output          logic [63:0]        m_axi_wstrb,
  output          logic               m_axi_wlast,
  output          logic               m_axi_wvalid,
  input  wire                   m_axi_wready,
  input  wire [3:0]             m_axi_bid,
  input  wire [1:0]             m_axi_bresp,
  input  wire                   m_axi_bvalid,
  output          logic               m_axi_bready,
  output          logic [3:0]         m_axi_arid,
  output          logic [39:0] m_axi_araddr,
  output          logic [7:0]         m_axi_arlen,
  output          logic [2:0]         m_axi_arsize,
  output          logic [1:0]         m_axi_arburst,
  output          logic               m_axi_arvalid,
  input  wire                   m_axi_arready,
  input  wire [3:0]             m_axi_rid,
  input  wire [511:0]           m_axi_rdata,
  input  wire [1:0]             m_axi_rresp,
  input  wire                   m_axi_rlast,
  input  wire                   m_axi_rvalid,
  output          logic               m_axi_rready,

  // ---- MIG user refresh / ZQCS (spec 3.2) — driven by hades_sram_refresh_sched ----
  output          logic               app_ref_req,
  input  wire                   app_ref_ack,
  output          logic               app_zq_req,
  input  wire                   app_zq_ack,

  // ---- CSR AXI4-Lite slave (CSR_EN=1) ----
  input  wire [15:0]            s_axil_awaddr,
  input  wire                   s_axil_awvalid,
  output          logic               s_axil_awready,
  input  wire [31:0]            s_axil_wdata,
  input  wire [3:0]             s_axil_wstrb,
  input  wire                   s_axil_wvalid,
  output          logic               s_axil_wready,
  output          logic [1:0]         s_axil_bresp,
  output          logic               s_axil_bvalid,
  input  wire                   s_axil_bready,
  input  wire [15:0]            s_axil_araddr,
  input  wire                   s_axil_arvalid,
  output          logic               s_axil_arready,
  output          logic [31:0]        s_axil_rdata,
  output          logic [1:0]         s_axil_rresp,
  output          logic               s_axil_rvalid,
  input  wire                   s_axil_rready,

  // ---- static-variant pins (CSR_EN=0) ----
  output          logic               stat_calib_done,
  output          logic               stat_ready,
  output          logic               stat_refresh_active,
  output          logic               stat_zq_active,
  output          logic [7:0]         stat_err,      // mirrors ERR_STATUS[5:0]

  // ---- pin-level backdoor (CSR_EN=0; CSR_EN=1 uses the BKP_* registers) ----
  input  wire                   bkp_req,
  input  wire                   bkp_we,
  input  wire [7:0]             bkp_port,
  input  wire [33:0]      bkp_addr,
  input  wire [31:0]            bkp_wdata,
  output          logic [31:0]        bkp_rdata,
  output          logic               bkp_ack
);

  // ------------------------------------------------------------------
  // Spec 4.3 static slot-budget assertion (T11 guard)
  // ------------------------------------------------------------------
  if (!budget_ok(N, TARGET_PERIOD_CYCLES, IS_SYNC ? CLK_MODE_SYNC : CLK_MODE_ASYNC))
  begin : g_budget_violation
    HADES_SRAM_SLOT_BUDGET_EXCEEDED__reduce_N_or_lower_target_frequency u_forced_error();
`ifndef SYNTHESIS
    initial $error("HADES-SRAM: slot budget exceeded (N=%0d, target=%0d ui_clk cycles)",
                   N, TARGET_PERIOD_CYCLES);
`endif
  end

  // ------------------------------------------------------------------
  // Resets
  // ------------------------------------------------------------------
  logic ui_rst, port_rst;
  hades_sram_rst_sync u_rst_ui   (.clk(ui_clk),   .arst_n(ui_rst_n),   .srst(ui_rst));
  hades_sram_rst_sync u_rst_port (.clk(port_clk), .arst_n(port_rst_n), .srst(port_rst));

  // ------------------------------------------------------------------
  // Boundary input registering (300 MHz closure, M5-hw): calib_done and the
  // MIG maintenance acks cross from the MIG side before use — every input
  // sees a single FF.  calib_done is sticky and the acks are 1-cycle pulses
  // whose exact cycle is internal to the MIG, so +1 ui_clk is invisible.
  // ------------------------------------------------------------------
  logic calib_q, ref_ack_q, zq_ack_q;
  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      calib_q   <= 1'b0;
      ref_ack_q <= 1'b0;
      zq_ack_q  <= 1'b0;
    end else begin
      calib_q   <= calib_done;
      ref_ack_q <= app_ref_ack;
      zq_ack_q  <= app_zq_ack;
    end
  end

  // ------------------------------------------------------------------
  // Frequency monitor
  // ------------------------------------------------------------------
  logic [31:0] meas_period;
  logic        clk_running, over_freq;

  cfg_t        cfg_eff;
  logic        enable_eff;

  hades_sram_freq_mon #(
    .CLK_MODE_SYNC (IS_SYNC)
  ) u_freq_mon (
    .ui_clk      (ui_clk),
    .ui_rst      (ui_rst),
    .port_clk    (port_clk),
    .min_period  (cfg_eff.min_period),
    .meas_period (meas_period),
    .clk_running (clk_running),
    .over_freq   (over_freq)
  );

  // ------------------------------------------------------------------
  // Configuration producer: CSR registers, or static parameters
  // ------------------------------------------------------------------
  logic       soft_reset_stb;
  logic       port_err_clr;
  logic [7:0] port_sel;

  // shared signals used inside the generate branches and below
  logic [4:0]  err_in;
  logic [7:0]  err_in_port;
  logic [31:0] err_in_addr;
  logic [63:0] stat_tot_rd, stat_tot_wr;
  logic [31:0] stat_maxlat;
  logic [N_MAX-1:0][31:0] port_stat_rd, port_stat_wr, port_stat_err;
  logic        win_stky_any, ovf_stky_any;
  logic        refresh_active, zq_active;
  logic [31:0] stat_refcnt;
  logic        period_tick;              // maintenance-window head
  logic        backend_idle;             // mig_if quiescent (refresh gate)
  logic        slots_done;               // all of the period's slots released
  logic        maint_fire_ok;            // refresh block still fits the gap
  logic        tmo_stky_u, slv_stky_u, ill_stky_u;  // static-mirror stickies
  logic        mig_err_illegal, mig_err_timeout, mig_err_slverr;
  logic [7:0]  mig_err_port;
  logic [31:0] mig_err_addr;
  logic        soft_port;                // stretched soft reset, port_clk dom.
  logic        clr_tog_u;                // ui_clk: toggles per err_clr pulse
  logic [7:0]  clr_port_u;
  logic        clr_tog_p, clr_tog_pd;    // port_clk domain
  wire  logic  clr_edge_p = clr_tog_p ^ clr_tog_pd;

  // post-soft-reset event blanking (declarations hoisted: st_evt_u feeds the
  // mig_if instance above the always_ff that drives evt_blk)
  logic [13:0] evt_blk;
  wire  logic  evt_en = (evt_blk == 14'd0);

  // on-chip selftest (M5-hw): per-port error toggles cross to ui_clk as
  // 1-cycle pulses into the mig_if PORT_STAT_ERR counters; evt_en blanks
  // stale pre-soft-reset toggles exactly like the window/overflow events
  logic        selftest_run;             // broadcast run level (ui_clk)
  logic [N-1:0] st_tog_p;                // port_clk error toggles (from ports)
  logic [N-1:0] st_lvl_u, st_dl_u;       // ui_clk sync + edge detect
  wire  logic [N-1:0] st_evt_u = (st_lvl_u ^ st_dl_u) & {N{evt_en}};

  // backdoor command interface (from CSR registers or static pins) + engine
  logic                  bkp_cmd_rd, bkp_cmd_wr;
  logic [7:0]            bkp_cmd_port;
  logic [39:0]           bkp_cmd_addr;
  logic [31:0]           bkp_cmd_wdata;
  logic                  bkp_busy, bkp_done, bkp_err;
  logic [31:0]           bkp_rdata_eng;

  // per-port elaboration constants packed for the CSR / static config
  // (v1.1.0): 10-bit width fields, MSB = port 63
  wire logic [N_MAX*10-1:0] widths_flat = { 10'(W63), 10'(W62), 10'(W61), 10'(W60), 10'(W59), 10'(W58), 10'(W57), 10'(W56), 10'(W55), 10'(W54), 10'(W53), 10'(W52), 10'(W51), 10'(W50), 10'(W49), 10'(W48), 10'(W47), 10'(W46), 10'(W45), 10'(W44), 10'(W43), 10'(W42), 10'(W41), 10'(W40), 10'(W39), 10'(W38), 10'(W37), 10'(W36), 10'(W35), 10'(W34), 10'(W33), 10'(W32), 10'(W31), 10'(W30), 10'(W29), 10'(W28), 10'(W27), 10'(W26), 10'(W25), 10'(W24), 10'(W23), 10'(W22), 10'(W21), 10'(W20), 10'(W19), 10'(W18), 10'(W17), 10'(W16), 10'(W15), 10'(W14), 10'(W13), 10'(W12), 10'(W11), 10'(W10), 10'(W9), 10'(W8), 10'(W7), 10'(W6), 10'(W5), 10'(W4), 10'(W3), 10'(W2), 10'(W1), 10'(W0) };
  wire logic [N_MAX-1:0]    be_flat     = { BE63_EN, BE62_EN, BE61_EN, BE60_EN, BE59_EN, BE58_EN, BE57_EN, BE56_EN, BE55_EN, BE54_EN, BE53_EN, BE52_EN, BE51_EN, BE50_EN, BE49_EN, BE48_EN, BE47_EN, BE46_EN, BE45_EN, BE44_EN, BE43_EN, BE42_EN, BE41_EN, BE40_EN, BE39_EN, BE38_EN, BE37_EN, BE36_EN, BE35_EN, BE34_EN, BE33_EN, BE32_EN, BE31_EN, BE30_EN, BE29_EN, BE28_EN, BE27_EN, BE26_EN, BE25_EN, BE24_EN, BE23_EN, BE22_EN, BE21_EN, BE20_EN, BE19_EN, BE18_EN, BE17_EN, BE16_EN, BE15_EN, BE14_EN, BE13_EN, BE12_EN, BE11_EN, BE10_EN, BE9_EN, BE8_EN, BE7_EN, BE6_EN, BE5_EN, BE4_EN, BE3_EN, BE2_EN, BE1_EN, BE0_EN };

  generate
    if (CSR_EN) begin : g_csr
      // CSR-side backdoor register channel
      logic        c_bkp_go_rd, c_bkp_go_wr;
      logic [7:0]  c_bkp_port;
      logic [39:0] c_bkp_addr;
      logic [31:0] c_bkp_wdata;

      // return path for the soft-reset stretch: the CSR gates ENABLE
      // (READY reads 0) until the port domain has truly exited reset
      logic soft_port_u;
      hades_sram_sync2 u_soft_back (.clk(ui_clk), .rst(ui_rst),
                               .d(soft_port), .q(soft_port_u));

      hades_sram_csr #(
        .IS_SYNC     (IS_SYNC),
        .DW          (32),
        .SELFTEST_EN (SELFTEST_EN)
      ) u_csr (
        .widths_i        (widths_flat),
        .be_en_i         (be_flat),
        .ui_clk          (ui_clk),
        .ui_rst          (ui_rst),
        .s_axil_awaddr   (s_axil_awaddr),
        .s_axil_awvalid  (s_axil_awvalid),
        .s_axil_awready  (s_axil_awready),
        .s_axil_wdata    (s_axil_wdata),
        .s_axil_wstrb    (s_axil_wstrb),
        .s_axil_wvalid   (s_axil_wvalid),
        .s_axil_wready   (s_axil_wready),
        .s_axil_bresp    (s_axil_bresp),
        .s_axil_bvalid   (s_axil_bvalid),
        .s_axil_bready   (s_axil_bready),
        .s_axil_araddr   (s_axil_araddr),
        .s_axil_arvalid  (s_axil_arvalid),
        .s_axil_arready  (s_axil_arready),
        .s_axil_rdata    (s_axil_rdata),
        .s_axil_rresp    (s_axil_rresp),
        .s_axil_rvalid   (s_axil_rvalid),
        .s_axil_rready   (s_axil_rready),
        .calib_done      (calib_q),
        .clk_running     (clk_running),
        .over_freq       (over_freq),
        .meas_period     (meas_period),
        .refresh_active  (refresh_active),
        .zq_active       (zq_active),
        .port_rst_busy   (soft_port_u),
        .err_in          (err_in),
        .err_in_port     (err_in_port),
        .err_in_addr     (err_in_addr),
        .stat_maxlat     (stat_maxlat),
        .stat_refcnt     (stat_refcnt),
        .stat_tot_rd     (stat_tot_rd),
        .stat_tot_wr     (stat_tot_wr),
        .port_stat_rd    (port_stat_rd),
        .port_stat_wr    (port_stat_wr),
        .port_stat_err   (port_stat_err),
        .cfg             (cfg_eff),
        .enable          (enable_eff),
        .soft_reset_stb  (soft_reset_stb),
        .port_err_clr    (port_err_clr),
        .port_sel_o      (port_sel),
        .selftest_run    (selftest_run),
        .bkp_go_rd       (c_bkp_go_rd),
        .bkp_go_wr       (c_bkp_go_wr),
        .bkp_port_o      (c_bkp_port),
        .bkp_addr_o      (c_bkp_addr),
        .bkp_wdata_o     (c_bkp_wdata),
        .bkp_busy        (bkp_busy),
        .bkp_done        (bkp_done),
        .bkp_err         (bkp_err),
        .bkp_rdata_i     (bkp_rdata_eng[31:0])
      );

      assign bkp_cmd_rd    = c_bkp_go_rd;
      assign bkp_cmd_wr    = c_bkp_go_wr;
      assign bkp_cmd_port  = c_bkp_port;
      assign bkp_cmd_addr  = c_bkp_addr;
      assign bkp_cmd_wdata = 32'(c_bkp_wdata);   // 32-bit backdoor data

      // the pin-level backdoor inputs are unused in the CSR variant
      logic unused_bkp_pins;
      assign unused_bkp_pins = &{1'b0, bkp_req, bkp_we, bkp_port, bkp_addr,
                               bkp_wdata};

      assign stat_calib_done     = 1'b0;
      assign stat_ready          = 1'b0;
      assign stat_refresh_active = refresh_active;
      assign stat_zq_active      = zq_active;
      assign stat_err            = 8'd0;

    end else begin : g_static
      assign cfg_eff    = static_cfg(P_L, P_PORT_EN, P_MIN_PERIOD,
                                     P_REFRESH_DIV, P_ZQ_DIV,
                                     P_PORT_BASE, P_PORT_SIZE,
                                     widths_flat, be_flat);
      assign enable_eff = calib_q & clk_running & ~over_freq;

      // no CSR in the static variant: when the engines are built in they
      // auto-run whenever the port is live
      assign selftest_run = SELFTEST_EN;

      assign soft_reset_stb = 1'b0;
      assign port_err_clr   = 1'b0;
      assign port_sel       = 8'd0;

      // pin-level backdoor drive: req synced; the integrator holds the
      // fields stable while req is high; ack = done pulse (above)
      logic bkp_req_u, bkp_req_d;
      hades_sram_sync2 u_bkp_req_sync (.clk(ui_clk), .rst(ui_rst),
                                  .d(bkp_req), .q(bkp_req_u));
      always_ff @(posedge ui_clk) begin
        if (ui_rst) bkp_req_d <= 1'b0;
        else        bkp_req_d <= bkp_req_u;
      end
      wire logic bkp_start = bkp_req_u & ~bkp_req_d & ~bkp_busy;
      assign bkp_cmd_rd    = bkp_start & ~bkp_we;
      assign bkp_cmd_wr    = bkp_start &  bkp_we;
      assign bkp_cmd_port  = bkp_port;
      assign bkp_cmd_addr  = {6'b0, bkp_addr};
      assign bkp_cmd_wdata = bkp_wdata;

      assign stat_calib_done     = calib_q;
      assign stat_ready          = enable_eff;
      assign stat_refresh_active = refresh_active;
      assign stat_zq_active      = zq_active;
      // level-style mirror of ERR_STATUS: bit4 = enable withheld (clock
      // unhealthy); bits 1-3/5 sticky-since-reset error accumulation
      assign stat_err = {2'b00,
                         win_stky_any,              // bit5
                         ~(clk_running & ~over_freq), // bit4
                         slv_stky_u,                 // bit3
                         ovf_stky_any,               // bit2
                         tmo_stky_u,                 // bit1
                         ill_stky_u};                // bit0
    end
  endgenerate

  // sticky backend-error flags for the static stat_err mirror
  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      tmo_stky_u <= 1'b0;
      slv_stky_u <= 1'b0;
      ill_stky_u <= 1'b0;
    end else begin
      if (mig_err_timeout) tmo_stky_u <= 1'b1;
      if (mig_err_slverr)  slv_stky_u <= 1'b1;
      if (mig_err_illegal) ill_stky_u <= 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // Soft reset: 1-cycle ui strobe; stretched + synced into port_clk domain
  // (a 3.3 ns pulse would be invisible to a 100-500 KHz clock)
  // ------------------------------------------------------------------
  logic [13:0] sr_cnt;
  logic        soft_lvl;

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      sr_cnt   <= 14'd0;
      soft_lvl <= 1'b0;
    end else if (soft_reset_stb) begin
      sr_cnt   <= 14'd8191;          // 8192 ui cycles > 2 slowest port periods
      soft_lvl <= 1'b1;
    end else if (sr_cnt != 14'd0) begin
      sr_cnt   <= sr_cnt - 14'd1;
      if (sr_cnt == 14'd1) soft_lvl <= 1'b0;
    end
  end

  hades_sram_sync2 u_soft_sync (.clk(port_clk), .rst(port_rst), .d(soft_lvl), .q(soft_port));
  wire logic port_rst_eff = port_rst | soft_port;
  wire logic ui_rst_soft  = ui_rst | soft_reset_stb;

  // ------------------------------------------------------------------
  // Backend engine: TDMA slot gating (M4: hades_sram_arbiter) in front of the
  // FCFS engine; backdoor enters mig_if as the lowest-priority requester.
  // ------------------------------------------------------------------
  logic [N-1:0]          pr_rd_vld;  // port FIFO heads (raw)
  logic [N-1:0][AW-1:0]  p_rd_addr;
  logic [N-1:0]          pr_wr_vld;
  logic [N-1:0][AW-1:0]  p_wr_addr;
  logic [N-1:0][511:0]   p_wr_data;   // LSB-justified per port (v1.1.0)
  logic [N-1:0][63:0]    p_wr_be;
  logic [N-1:0]          p_rd_vld;   // arbiter-gated, to mig_if
  logic [N-1:0]          p_wr_vld;
  logic [N-1:0]          p_rd_gnt;
  logic [N-1:0]          p_wr_gnt;
  logic [N-1:0]          p_rsp_vld;
  logic [N-1:0][511:0]   p_rsp_data;  // beat shift; the port truncates

  // backdoor engine <-> mig_if
  logic                  bk_rd_req, bk_rd_gnt, bk_rd_done;
  logic [BASE_W-1:0]     bk_rd_beat;
  logic [5:0]            bk_rd_lane;
  logic [31:0]           bk_rd_data;
  logic                  bk_wr_req, bk_wr_gnt;
  logic [BASE_W-1:0]     bk_wr_beat;
  logic [5:0]            bk_wr_lane;
  logic [31:0]           bk_wr_data;

  hades_sram_arbiter #(
    .N       (N),
    .IS_SYNC (IS_SYNC)
  ) u_arbiter (
    .ui_clk      (ui_clk),
    .ui_rst      (ui_rst_soft),
    .enable      (enable_eff),
    .period_tick (period_tick),
    .cfg         (cfg_eff),
    .rd_vld_i    (pr_rd_vld),
    .wr_vld_i    (pr_wr_vld),
    .rd_gnt      (p_rd_gnt),
    .wr_gnt      (p_wr_gnt),
    .rd_vld_o    (p_rd_vld),
    .wr_vld_o    (p_wr_vld),
    .slots_done  (slots_done),
    .maint_fire_ok (maint_fire_ok)
  );

  hades_sram_mig_if #(
    .N  (N),
    .DW (512),
    .AW (AW)
  ) u_mig_if (
    .ui_clk        (ui_clk),
    .ui_rst        (ui_rst),
    .cfg           (cfg_eff),
    .enable        (enable_eff),
    .rd_vld        (p_rd_vld),
    .rd_addr       (p_rd_addr),
    .rd_gnt        (p_rd_gnt),
    .wr_vld        (p_wr_vld),
    .wr_addr       (p_wr_addr),
    .wr_data       (p_wr_data),
    .wr_be         (p_wr_be),
    .wr_gnt        (p_wr_gnt),
    .rsp_vld       (p_rsp_vld),
    .rsp_data      (p_rsp_data),
    .m_axi_awid    (m_axi_awid),
    .m_axi_awaddr  (m_axi_awaddr),
    .m_axi_awlen   (m_axi_awlen),
    .m_axi_awsize  (m_axi_awsize),
    .m_axi_awburst (m_axi_awburst),
    .m_axi_awvalid (m_axi_awvalid),
    .m_axi_awready (m_axi_awready),
    .m_axi_wdata   (m_axi_wdata),
    .m_axi_wstrb   (m_axi_wstrb),
    .m_axi_wlast   (m_axi_wlast),
    .m_axi_wvalid  (m_axi_wvalid),
    .m_axi_wready  (m_axi_wready),
    .m_axi_bid     (m_axi_bid),
    .m_axi_bresp   (m_axi_bresp),
    .m_axi_bvalid  (m_axi_bvalid),
    .m_axi_bready  (m_axi_bready),
    .m_axi_arid    (m_axi_arid),
    .m_axi_araddr  (m_axi_araddr),
    .m_axi_arlen   (m_axi_arlen),
    .m_axi_arsize  (m_axi_arsize),
    .m_axi_arburst (m_axi_arburst),
    .m_axi_arvalid (m_axi_arvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_rid     (m_axi_rid),
    .m_axi_rdata   (m_axi_rdata),
    .m_axi_rresp   (m_axi_rresp),
    .m_axi_rlast   (m_axi_rlast),
    .m_axi_rvalid  (m_axi_rvalid),
    .m_axi_rready  (m_axi_rready),
    .stat_tot_rd   (stat_tot_rd),
    .stat_tot_wr   (stat_tot_wr),
    .stat_maxlat   (stat_maxlat),
    .port_stat_rd  (port_stat_rd),
    .port_stat_wr  (port_stat_wr),
    .port_stat_err (port_stat_err),
    .st_err        (st_evt_u),
    .err_clr_port  (port_sel),
    .err_clr       (port_err_clr),
    .soft_rst      (soft_reset_stb),
    .backend_idle  (backend_idle),
    .err_illegal   (mig_err_illegal),
    .err_timeout   (mig_err_timeout),
    .err_slverr    (mig_err_slverr),
    .err_port      (mig_err_port),
    .err_addr      (mig_err_addr),
    .bkp_rd_req    (bk_rd_req),
    .bkp_rd_beat   (bk_rd_beat),
    .bkp_rd_lane   (bk_rd_lane),
    .bkp_rd_gnt    (bk_rd_gnt),
    .bkp_rd_done   (bk_rd_done),
    .bkp_rd_data   (bk_rd_data),
    .bkp_wr_req    (bk_wr_req),
    .bkp_wr_beat   (bk_wr_beat),
    .bkp_wr_lane   (bk_wr_lane),
    .bkp_wr_data   (bk_wr_data),
    .bkp_wr_gnt    (bk_wr_gnt)
  );

  hades_sram_backdoor #(
    .DW (32),
    .AW (AW)
  ) u_backdoor (
    .ui_clk      (ui_clk),
    .ui_rst      (ui_rst_soft),
    .cfg         (cfg_eff),
    .cmd_rd      (bkp_cmd_rd),
    .cmd_wr      (bkp_cmd_wr),
    .cmd_port    (bkp_cmd_port),
    .cmd_addr    (bkp_cmd_addr),
    .cmd_wdata   (bkp_cmd_wdata),
    .busy        (bkp_busy),
    .done        (bkp_done),
    .err         (bkp_err),
    .rdata       (bkp_rdata_eng),
    .bkp_rd_req  (bk_rd_req),
    .bkp_rd_beat (bk_rd_beat),
    .bkp_rd_lane (bk_rd_lane),
    .bkp_rd_gnt  (bk_rd_gnt),
    .bkp_rd_done (bk_rd_done),
    .bkp_rd_data (bk_rd_data),
    .bkp_wr_req  (bk_wr_req),
    .bkp_wr_beat (bk_wr_beat),
    .bkp_wr_lane (bk_wr_lane),
    .bkp_wr_data (bk_wr_data),
    .bkp_wr_gnt  (bk_wr_gnt)
  );

  // pin-level status mirrors work in both variants
  assign bkp_rdata = bkp_rdata_eng;
  assign bkp_ack   = bkp_done;

  // ------------------------------------------------------------------
  // Emulated port array
  // ------------------------------------------------------------------
  logic [N-1:0] p_err_slot;
  logic [N-1:0] win_tog_p, ovf_tog_p;   // port_clk event toggles (from ports)
  logic [N-1:0] win_stky,  ovf_stky;    // port_clk sticky levels (from ports)

  // 64 explicit port instances (v1.1.0): flat per-port interfaces with
  // per-port width/byte-enable; instances beyond N are tied off below.
  if (N > 0) begin : g_port0
  hades_sram_port #(
    .AW           (AW),
    .DW           (W0),
    .BE_EN        (BE0_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (0),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram0_en),
    .we         (sram0_we),
    .addr       (sram0_addr),
    .wdata      (sram0_wdata),
    .be         (sram0_be),
    .rdata      (sram0_rdata),
    .rvalid     (sram0_rvalid),
    .cfg_en     (cfg_eff.port_en[0]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[0]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[0]),
    .rd_addr    (p_rd_addr[0]),
    .rd_gnt     (p_rd_gnt[0]),
    .wr_vld     (pr_wr_vld[0]),
    .wr_addr    (p_wr_addr[0]),
    .wr_data    (p_wr_data[0][W0-1:0]),
    .wr_be      (p_wr_be[0]),
    .wr_gnt     (p_wr_gnt[0]),
    .rsp_vld    (p_rsp_vld[0]),
    .rsp_data   (p_rsp_data[0][W0-1:0]),
    .err_win_tog  (win_tog_p[0]),
    .err_ovf_tog  (ovf_tog_p[0]),
    .err_win_stky (win_stky[0]),
    .err_ovf_stky (ovf_stky[0]),
    .err_slot     (p_err_slot[0]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd0)
  );
  if (W0 < 512) begin : g_wtie0
    assign p_wr_data[0][511:W0] = '0;
  end
  end
  else begin : g_port0_off
    assign sram0_rdata = '0;
    assign sram0_rvalid = 1'b0;
    logic unused_p0;
    assign unused_p0 = &{1'b0, sram0_en, sram0_we, sram0_addr, sram0_wdata, sram0_be};
  end
  if (N > 1) begin : g_port1
  hades_sram_port #(
    .AW           (AW),
    .DW           (W1),
    .BE_EN        (BE1_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (1),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram1_en),
    .we         (sram1_we),
    .addr       (sram1_addr),
    .wdata      (sram1_wdata),
    .be         (sram1_be),
    .rdata      (sram1_rdata),
    .rvalid     (sram1_rvalid),
    .cfg_en     (cfg_eff.port_en[1]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[1]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[1]),
    .rd_addr    (p_rd_addr[1]),
    .rd_gnt     (p_rd_gnt[1]),
    .wr_vld     (pr_wr_vld[1]),
    .wr_addr    (p_wr_addr[1]),
    .wr_data    (p_wr_data[1][W1-1:0]),
    .wr_be      (p_wr_be[1]),
    .wr_gnt     (p_wr_gnt[1]),
    .rsp_vld    (p_rsp_vld[1]),
    .rsp_data   (p_rsp_data[1][W1-1:0]),
    .err_win_tog  (win_tog_p[1]),
    .err_ovf_tog  (ovf_tog_p[1]),
    .err_win_stky (win_stky[1]),
    .err_ovf_stky (ovf_stky[1]),
    .err_slot     (p_err_slot[1]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd1)
  );
  if (W1 < 512) begin : g_wtie1
    assign p_wr_data[1][511:W1] = '0;
  end
  end
  else begin : g_port1_off
    assign sram1_rdata = '0;
    assign sram1_rvalid = 1'b0;
    logic unused_p1;
    assign unused_p1 = &{1'b0, sram1_en, sram1_we, sram1_addr, sram1_wdata, sram1_be};
  end
  if (N > 2) begin : g_port2
  hades_sram_port #(
    .AW           (AW),
    .DW           (W2),
    .BE_EN        (BE2_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (2),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram2_en),
    .we         (sram2_we),
    .addr       (sram2_addr),
    .wdata      (sram2_wdata),
    .be         (sram2_be),
    .rdata      (sram2_rdata),
    .rvalid     (sram2_rvalid),
    .cfg_en     (cfg_eff.port_en[2]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[2]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[2]),
    .rd_addr    (p_rd_addr[2]),
    .rd_gnt     (p_rd_gnt[2]),
    .wr_vld     (pr_wr_vld[2]),
    .wr_addr    (p_wr_addr[2]),
    .wr_data    (p_wr_data[2][W2-1:0]),
    .wr_be      (p_wr_be[2]),
    .wr_gnt     (p_wr_gnt[2]),
    .rsp_vld    (p_rsp_vld[2]),
    .rsp_data   (p_rsp_data[2][W2-1:0]),
    .err_win_tog  (win_tog_p[2]),
    .err_ovf_tog  (ovf_tog_p[2]),
    .err_win_stky (win_stky[2]),
    .err_ovf_stky (ovf_stky[2]),
    .err_slot     (p_err_slot[2]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd2)
  );
  if (W2 < 512) begin : g_wtie2
    assign p_wr_data[2][511:W2] = '0;
  end
  end
  else begin : g_port2_off
    assign sram2_rdata = '0;
    assign sram2_rvalid = 1'b0;
    logic unused_p2;
    assign unused_p2 = &{1'b0, sram2_en, sram2_we, sram2_addr, sram2_wdata, sram2_be};
  end
  if (N > 3) begin : g_port3
  hades_sram_port #(
    .AW           (AW),
    .DW           (W3),
    .BE_EN        (BE3_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (3),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram3_en),
    .we         (sram3_we),
    .addr       (sram3_addr),
    .wdata      (sram3_wdata),
    .be         (sram3_be),
    .rdata      (sram3_rdata),
    .rvalid     (sram3_rvalid),
    .cfg_en     (cfg_eff.port_en[3]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[3]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[3]),
    .rd_addr    (p_rd_addr[3]),
    .rd_gnt     (p_rd_gnt[3]),
    .wr_vld     (pr_wr_vld[3]),
    .wr_addr    (p_wr_addr[3]),
    .wr_data    (p_wr_data[3][W3-1:0]),
    .wr_be      (p_wr_be[3]),
    .wr_gnt     (p_wr_gnt[3]),
    .rsp_vld    (p_rsp_vld[3]),
    .rsp_data   (p_rsp_data[3][W3-1:0]),
    .err_win_tog  (win_tog_p[3]),
    .err_ovf_tog  (ovf_tog_p[3]),
    .err_win_stky (win_stky[3]),
    .err_ovf_stky (ovf_stky[3]),
    .err_slot     (p_err_slot[3]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd3)
  );
  if (W3 < 512) begin : g_wtie3
    assign p_wr_data[3][511:W3] = '0;
  end
  end
  else begin : g_port3_off
    assign sram3_rdata = '0;
    assign sram3_rvalid = 1'b0;
    logic unused_p3;
    assign unused_p3 = &{1'b0, sram3_en, sram3_we, sram3_addr, sram3_wdata, sram3_be};
  end
  if (N > 4) begin : g_port4
  hades_sram_port #(
    .AW           (AW),
    .DW           (W4),
    .BE_EN        (BE4_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (4),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram4_en),
    .we         (sram4_we),
    .addr       (sram4_addr),
    .wdata      (sram4_wdata),
    .be         (sram4_be),
    .rdata      (sram4_rdata),
    .rvalid     (sram4_rvalid),
    .cfg_en     (cfg_eff.port_en[4]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[4]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[4]),
    .rd_addr    (p_rd_addr[4]),
    .rd_gnt     (p_rd_gnt[4]),
    .wr_vld     (pr_wr_vld[4]),
    .wr_addr    (p_wr_addr[4]),
    .wr_data    (p_wr_data[4][W4-1:0]),
    .wr_be      (p_wr_be[4]),
    .wr_gnt     (p_wr_gnt[4]),
    .rsp_vld    (p_rsp_vld[4]),
    .rsp_data   (p_rsp_data[4][W4-1:0]),
    .err_win_tog  (win_tog_p[4]),
    .err_ovf_tog  (ovf_tog_p[4]),
    .err_win_stky (win_stky[4]),
    .err_ovf_stky (ovf_stky[4]),
    .err_slot     (p_err_slot[4]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd4)
  );
  if (W4 < 512) begin : g_wtie4
    assign p_wr_data[4][511:W4] = '0;
  end
  end
  else begin : g_port4_off
    assign sram4_rdata = '0;
    assign sram4_rvalid = 1'b0;
    logic unused_p4;
    assign unused_p4 = &{1'b0, sram4_en, sram4_we, sram4_addr, sram4_wdata, sram4_be};
  end
  if (N > 5) begin : g_port5
  hades_sram_port #(
    .AW           (AW),
    .DW           (W5),
    .BE_EN        (BE5_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (5),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram5_en),
    .we         (sram5_we),
    .addr       (sram5_addr),
    .wdata      (sram5_wdata),
    .be         (sram5_be),
    .rdata      (sram5_rdata),
    .rvalid     (sram5_rvalid),
    .cfg_en     (cfg_eff.port_en[5]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[5]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[5]),
    .rd_addr    (p_rd_addr[5]),
    .rd_gnt     (p_rd_gnt[5]),
    .wr_vld     (pr_wr_vld[5]),
    .wr_addr    (p_wr_addr[5]),
    .wr_data    (p_wr_data[5][W5-1:0]),
    .wr_be      (p_wr_be[5]),
    .wr_gnt     (p_wr_gnt[5]),
    .rsp_vld    (p_rsp_vld[5]),
    .rsp_data   (p_rsp_data[5][W5-1:0]),
    .err_win_tog  (win_tog_p[5]),
    .err_ovf_tog  (ovf_tog_p[5]),
    .err_win_stky (win_stky[5]),
    .err_ovf_stky (ovf_stky[5]),
    .err_slot     (p_err_slot[5]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd5)
  );
  if (W5 < 512) begin : g_wtie5
    assign p_wr_data[5][511:W5] = '0;
  end
  end
  else begin : g_port5_off
    assign sram5_rdata = '0;
    assign sram5_rvalid = 1'b0;
    logic unused_p5;
    assign unused_p5 = &{1'b0, sram5_en, sram5_we, sram5_addr, sram5_wdata, sram5_be};
  end
  if (N > 6) begin : g_port6
  hades_sram_port #(
    .AW           (AW),
    .DW           (W6),
    .BE_EN        (BE6_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (6),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram6_en),
    .we         (sram6_we),
    .addr       (sram6_addr),
    .wdata      (sram6_wdata),
    .be         (sram6_be),
    .rdata      (sram6_rdata),
    .rvalid     (sram6_rvalid),
    .cfg_en     (cfg_eff.port_en[6]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[6]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[6]),
    .rd_addr    (p_rd_addr[6]),
    .rd_gnt     (p_rd_gnt[6]),
    .wr_vld     (pr_wr_vld[6]),
    .wr_addr    (p_wr_addr[6]),
    .wr_data    (p_wr_data[6][W6-1:0]),
    .wr_be      (p_wr_be[6]),
    .wr_gnt     (p_wr_gnt[6]),
    .rsp_vld    (p_rsp_vld[6]),
    .rsp_data   (p_rsp_data[6][W6-1:0]),
    .err_win_tog  (win_tog_p[6]),
    .err_ovf_tog  (ovf_tog_p[6]),
    .err_win_stky (win_stky[6]),
    .err_ovf_stky (ovf_stky[6]),
    .err_slot     (p_err_slot[6]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd6)
  );
  if (W6 < 512) begin : g_wtie6
    assign p_wr_data[6][511:W6] = '0;
  end
  end
  else begin : g_port6_off
    assign sram6_rdata = '0;
    assign sram6_rvalid = 1'b0;
    logic unused_p6;
    assign unused_p6 = &{1'b0, sram6_en, sram6_we, sram6_addr, sram6_wdata, sram6_be};
  end
  if (N > 7) begin : g_port7
  hades_sram_port #(
    .AW           (AW),
    .DW           (W7),
    .BE_EN        (BE7_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (7),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram7_en),
    .we         (sram7_we),
    .addr       (sram7_addr),
    .wdata      (sram7_wdata),
    .be         (sram7_be),
    .rdata      (sram7_rdata),
    .rvalid     (sram7_rvalid),
    .cfg_en     (cfg_eff.port_en[7]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[7]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[7]),
    .rd_addr    (p_rd_addr[7]),
    .rd_gnt     (p_rd_gnt[7]),
    .wr_vld     (pr_wr_vld[7]),
    .wr_addr    (p_wr_addr[7]),
    .wr_data    (p_wr_data[7][W7-1:0]),
    .wr_be      (p_wr_be[7]),
    .wr_gnt     (p_wr_gnt[7]),
    .rsp_vld    (p_rsp_vld[7]),
    .rsp_data   (p_rsp_data[7][W7-1:0]),
    .err_win_tog  (win_tog_p[7]),
    .err_ovf_tog  (ovf_tog_p[7]),
    .err_win_stky (win_stky[7]),
    .err_ovf_stky (ovf_stky[7]),
    .err_slot     (p_err_slot[7]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd7)
  );
  if (W7 < 512) begin : g_wtie7
    assign p_wr_data[7][511:W7] = '0;
  end
  end
  else begin : g_port7_off
    assign sram7_rdata = '0;
    assign sram7_rvalid = 1'b0;
    logic unused_p7;
    assign unused_p7 = &{1'b0, sram7_en, sram7_we, sram7_addr, sram7_wdata, sram7_be};
  end
  if (N > 8) begin : g_port8
  hades_sram_port #(
    .AW           (AW),
    .DW           (W8),
    .BE_EN        (BE8_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (8),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram8_en),
    .we         (sram8_we),
    .addr       (sram8_addr),
    .wdata      (sram8_wdata),
    .be         (sram8_be),
    .rdata      (sram8_rdata),
    .rvalid     (sram8_rvalid),
    .cfg_en     (cfg_eff.port_en[8]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[8]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[8]),
    .rd_addr    (p_rd_addr[8]),
    .rd_gnt     (p_rd_gnt[8]),
    .wr_vld     (pr_wr_vld[8]),
    .wr_addr    (p_wr_addr[8]),
    .wr_data    (p_wr_data[8][W8-1:0]),
    .wr_be      (p_wr_be[8]),
    .wr_gnt     (p_wr_gnt[8]),
    .rsp_vld    (p_rsp_vld[8]),
    .rsp_data   (p_rsp_data[8][W8-1:0]),
    .err_win_tog  (win_tog_p[8]),
    .err_ovf_tog  (ovf_tog_p[8]),
    .err_win_stky (win_stky[8]),
    .err_ovf_stky (ovf_stky[8]),
    .err_slot     (p_err_slot[8]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd8)
  );
  if (W8 < 512) begin : g_wtie8
    assign p_wr_data[8][511:W8] = '0;
  end
  end
  else begin : g_port8_off
    assign sram8_rdata = '0;
    assign sram8_rvalid = 1'b0;
    logic unused_p8;
    assign unused_p8 = &{1'b0, sram8_en, sram8_we, sram8_addr, sram8_wdata, sram8_be};
  end
  if (N > 9) begin : g_port9
  hades_sram_port #(
    .AW           (AW),
    .DW           (W9),
    .BE_EN        (BE9_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (9),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram9_en),
    .we         (sram9_we),
    .addr       (sram9_addr),
    .wdata      (sram9_wdata),
    .be         (sram9_be),
    .rdata      (sram9_rdata),
    .rvalid     (sram9_rvalid),
    .cfg_en     (cfg_eff.port_en[9]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[9]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[9]),
    .rd_addr    (p_rd_addr[9]),
    .rd_gnt     (p_rd_gnt[9]),
    .wr_vld     (pr_wr_vld[9]),
    .wr_addr    (p_wr_addr[9]),
    .wr_data    (p_wr_data[9][W9-1:0]),
    .wr_be      (p_wr_be[9]),
    .wr_gnt     (p_wr_gnt[9]),
    .rsp_vld    (p_rsp_vld[9]),
    .rsp_data   (p_rsp_data[9][W9-1:0]),
    .err_win_tog  (win_tog_p[9]),
    .err_ovf_tog  (ovf_tog_p[9]),
    .err_win_stky (win_stky[9]),
    .err_ovf_stky (ovf_stky[9]),
    .err_slot     (p_err_slot[9]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd9)
  );
  if (W9 < 512) begin : g_wtie9
    assign p_wr_data[9][511:W9] = '0;
  end
  end
  else begin : g_port9_off
    assign sram9_rdata = '0;
    assign sram9_rvalid = 1'b0;
    logic unused_p9;
    assign unused_p9 = &{1'b0, sram9_en, sram9_we, sram9_addr, sram9_wdata, sram9_be};
  end
  if (N > 10) begin : g_port10
  hades_sram_port #(
    .AW           (AW),
    .DW           (W10),
    .BE_EN        (BE10_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (10),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram10_en),
    .we         (sram10_we),
    .addr       (sram10_addr),
    .wdata      (sram10_wdata),
    .be         (sram10_be),
    .rdata      (sram10_rdata),
    .rvalid     (sram10_rvalid),
    .cfg_en     (cfg_eff.port_en[10]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[10]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[10]),
    .rd_addr    (p_rd_addr[10]),
    .rd_gnt     (p_rd_gnt[10]),
    .wr_vld     (pr_wr_vld[10]),
    .wr_addr    (p_wr_addr[10]),
    .wr_data    (p_wr_data[10][W10-1:0]),
    .wr_be      (p_wr_be[10]),
    .wr_gnt     (p_wr_gnt[10]),
    .rsp_vld    (p_rsp_vld[10]),
    .rsp_data   (p_rsp_data[10][W10-1:0]),
    .err_win_tog  (win_tog_p[10]),
    .err_ovf_tog  (ovf_tog_p[10]),
    .err_win_stky (win_stky[10]),
    .err_ovf_stky (ovf_stky[10]),
    .err_slot     (p_err_slot[10]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd10)
  );
  if (W10 < 512) begin : g_wtie10
    assign p_wr_data[10][511:W10] = '0;
  end
  end
  else begin : g_port10_off
    assign sram10_rdata = '0;
    assign sram10_rvalid = 1'b0;
    logic unused_p10;
    assign unused_p10 = &{1'b0, sram10_en, sram10_we, sram10_addr, sram10_wdata, sram10_be};
  end
  if (N > 11) begin : g_port11
  hades_sram_port #(
    .AW           (AW),
    .DW           (W11),
    .BE_EN        (BE11_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (11),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram11_en),
    .we         (sram11_we),
    .addr       (sram11_addr),
    .wdata      (sram11_wdata),
    .be         (sram11_be),
    .rdata      (sram11_rdata),
    .rvalid     (sram11_rvalid),
    .cfg_en     (cfg_eff.port_en[11]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[11]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[11]),
    .rd_addr    (p_rd_addr[11]),
    .rd_gnt     (p_rd_gnt[11]),
    .wr_vld     (pr_wr_vld[11]),
    .wr_addr    (p_wr_addr[11]),
    .wr_data    (p_wr_data[11][W11-1:0]),
    .wr_be      (p_wr_be[11]),
    .wr_gnt     (p_wr_gnt[11]),
    .rsp_vld    (p_rsp_vld[11]),
    .rsp_data   (p_rsp_data[11][W11-1:0]),
    .err_win_tog  (win_tog_p[11]),
    .err_ovf_tog  (ovf_tog_p[11]),
    .err_win_stky (win_stky[11]),
    .err_ovf_stky (ovf_stky[11]),
    .err_slot     (p_err_slot[11]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd11)
  );
  if (W11 < 512) begin : g_wtie11
    assign p_wr_data[11][511:W11] = '0;
  end
  end
  else begin : g_port11_off
    assign sram11_rdata = '0;
    assign sram11_rvalid = 1'b0;
    logic unused_p11;
    assign unused_p11 = &{1'b0, sram11_en, sram11_we, sram11_addr, sram11_wdata, sram11_be};
  end
  if (N > 12) begin : g_port12
  hades_sram_port #(
    .AW           (AW),
    .DW           (W12),
    .BE_EN        (BE12_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (12),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram12_en),
    .we         (sram12_we),
    .addr       (sram12_addr),
    .wdata      (sram12_wdata),
    .be         (sram12_be),
    .rdata      (sram12_rdata),
    .rvalid     (sram12_rvalid),
    .cfg_en     (cfg_eff.port_en[12]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[12]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[12]),
    .rd_addr    (p_rd_addr[12]),
    .rd_gnt     (p_rd_gnt[12]),
    .wr_vld     (pr_wr_vld[12]),
    .wr_addr    (p_wr_addr[12]),
    .wr_data    (p_wr_data[12][W12-1:0]),
    .wr_be      (p_wr_be[12]),
    .wr_gnt     (p_wr_gnt[12]),
    .rsp_vld    (p_rsp_vld[12]),
    .rsp_data   (p_rsp_data[12][W12-1:0]),
    .err_win_tog  (win_tog_p[12]),
    .err_ovf_tog  (ovf_tog_p[12]),
    .err_win_stky (win_stky[12]),
    .err_ovf_stky (ovf_stky[12]),
    .err_slot     (p_err_slot[12]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd12)
  );
  if (W12 < 512) begin : g_wtie12
    assign p_wr_data[12][511:W12] = '0;
  end
  end
  else begin : g_port12_off
    assign sram12_rdata = '0;
    assign sram12_rvalid = 1'b0;
    logic unused_p12;
    assign unused_p12 = &{1'b0, sram12_en, sram12_we, sram12_addr, sram12_wdata, sram12_be};
  end
  if (N > 13) begin : g_port13
  hades_sram_port #(
    .AW           (AW),
    .DW           (W13),
    .BE_EN        (BE13_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (13),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram13_en),
    .we         (sram13_we),
    .addr       (sram13_addr),
    .wdata      (sram13_wdata),
    .be         (sram13_be),
    .rdata      (sram13_rdata),
    .rvalid     (sram13_rvalid),
    .cfg_en     (cfg_eff.port_en[13]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[13]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[13]),
    .rd_addr    (p_rd_addr[13]),
    .rd_gnt     (p_rd_gnt[13]),
    .wr_vld     (pr_wr_vld[13]),
    .wr_addr    (p_wr_addr[13]),
    .wr_data    (p_wr_data[13][W13-1:0]),
    .wr_be      (p_wr_be[13]),
    .wr_gnt     (p_wr_gnt[13]),
    .rsp_vld    (p_rsp_vld[13]),
    .rsp_data   (p_rsp_data[13][W13-1:0]),
    .err_win_tog  (win_tog_p[13]),
    .err_ovf_tog  (ovf_tog_p[13]),
    .err_win_stky (win_stky[13]),
    .err_ovf_stky (ovf_stky[13]),
    .err_slot     (p_err_slot[13]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd13)
  );
  if (W13 < 512) begin : g_wtie13
    assign p_wr_data[13][511:W13] = '0;
  end
  end
  else begin : g_port13_off
    assign sram13_rdata = '0;
    assign sram13_rvalid = 1'b0;
    logic unused_p13;
    assign unused_p13 = &{1'b0, sram13_en, sram13_we, sram13_addr, sram13_wdata, sram13_be};
  end
  if (N > 14) begin : g_port14
  hades_sram_port #(
    .AW           (AW),
    .DW           (W14),
    .BE_EN        (BE14_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (14),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram14_en),
    .we         (sram14_we),
    .addr       (sram14_addr),
    .wdata      (sram14_wdata),
    .be         (sram14_be),
    .rdata      (sram14_rdata),
    .rvalid     (sram14_rvalid),
    .cfg_en     (cfg_eff.port_en[14]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[14]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[14]),
    .rd_addr    (p_rd_addr[14]),
    .rd_gnt     (p_rd_gnt[14]),
    .wr_vld     (pr_wr_vld[14]),
    .wr_addr    (p_wr_addr[14]),
    .wr_data    (p_wr_data[14][W14-1:0]),
    .wr_be      (p_wr_be[14]),
    .wr_gnt     (p_wr_gnt[14]),
    .rsp_vld    (p_rsp_vld[14]),
    .rsp_data   (p_rsp_data[14][W14-1:0]),
    .err_win_tog  (win_tog_p[14]),
    .err_ovf_tog  (ovf_tog_p[14]),
    .err_win_stky (win_stky[14]),
    .err_ovf_stky (ovf_stky[14]),
    .err_slot     (p_err_slot[14]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd14)
  );
  if (W14 < 512) begin : g_wtie14
    assign p_wr_data[14][511:W14] = '0;
  end
  end
  else begin : g_port14_off
    assign sram14_rdata = '0;
    assign sram14_rvalid = 1'b0;
    logic unused_p14;
    assign unused_p14 = &{1'b0, sram14_en, sram14_we, sram14_addr, sram14_wdata, sram14_be};
  end
  if (N > 15) begin : g_port15
  hades_sram_port #(
    .AW           (AW),
    .DW           (W15),
    .BE_EN        (BE15_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (15),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram15_en),
    .we         (sram15_we),
    .addr       (sram15_addr),
    .wdata      (sram15_wdata),
    .be         (sram15_be),
    .rdata      (sram15_rdata),
    .rvalid     (sram15_rvalid),
    .cfg_en     (cfg_eff.port_en[15]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[15]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[15]),
    .rd_addr    (p_rd_addr[15]),
    .rd_gnt     (p_rd_gnt[15]),
    .wr_vld     (pr_wr_vld[15]),
    .wr_addr    (p_wr_addr[15]),
    .wr_data    (p_wr_data[15][W15-1:0]),
    .wr_be      (p_wr_be[15]),
    .wr_gnt     (p_wr_gnt[15]),
    .rsp_vld    (p_rsp_vld[15]),
    .rsp_data   (p_rsp_data[15][W15-1:0]),
    .err_win_tog  (win_tog_p[15]),
    .err_ovf_tog  (ovf_tog_p[15]),
    .err_win_stky (win_stky[15]),
    .err_ovf_stky (ovf_stky[15]),
    .err_slot     (p_err_slot[15]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd15)
  );
  if (W15 < 512) begin : g_wtie15
    assign p_wr_data[15][511:W15] = '0;
  end
  end
  else begin : g_port15_off
    assign sram15_rdata = '0;
    assign sram15_rvalid = 1'b0;
    logic unused_p15;
    assign unused_p15 = &{1'b0, sram15_en, sram15_we, sram15_addr, sram15_wdata, sram15_be};
  end
  if (N > 16) begin : g_port16
  hades_sram_port #(
    .AW           (AW),
    .DW           (W16),
    .BE_EN        (BE16_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (16),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram16_en),
    .we         (sram16_we),
    .addr       (sram16_addr),
    .wdata      (sram16_wdata),
    .be         (sram16_be),
    .rdata      (sram16_rdata),
    .rvalid     (sram16_rvalid),
    .cfg_en     (cfg_eff.port_en[16]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[16]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[16]),
    .rd_addr    (p_rd_addr[16]),
    .rd_gnt     (p_rd_gnt[16]),
    .wr_vld     (pr_wr_vld[16]),
    .wr_addr    (p_wr_addr[16]),
    .wr_data    (p_wr_data[16][W16-1:0]),
    .wr_be      (p_wr_be[16]),
    .wr_gnt     (p_wr_gnt[16]),
    .rsp_vld    (p_rsp_vld[16]),
    .rsp_data   (p_rsp_data[16][W16-1:0]),
    .err_win_tog  (win_tog_p[16]),
    .err_ovf_tog  (ovf_tog_p[16]),
    .err_win_stky (win_stky[16]),
    .err_ovf_stky (ovf_stky[16]),
    .err_slot     (p_err_slot[16]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd16)
  );
  if (W16 < 512) begin : g_wtie16
    assign p_wr_data[16][511:W16] = '0;
  end
  end
  else begin : g_port16_off
    assign sram16_rdata = '0;
    assign sram16_rvalid = 1'b0;
    logic unused_p16;
    assign unused_p16 = &{1'b0, sram16_en, sram16_we, sram16_addr, sram16_wdata, sram16_be};
  end
  if (N > 17) begin : g_port17
  hades_sram_port #(
    .AW           (AW),
    .DW           (W17),
    .BE_EN        (BE17_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (17),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram17_en),
    .we         (sram17_we),
    .addr       (sram17_addr),
    .wdata      (sram17_wdata),
    .be         (sram17_be),
    .rdata      (sram17_rdata),
    .rvalid     (sram17_rvalid),
    .cfg_en     (cfg_eff.port_en[17]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[17]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[17]),
    .rd_addr    (p_rd_addr[17]),
    .rd_gnt     (p_rd_gnt[17]),
    .wr_vld     (pr_wr_vld[17]),
    .wr_addr    (p_wr_addr[17]),
    .wr_data    (p_wr_data[17][W17-1:0]),
    .wr_be      (p_wr_be[17]),
    .wr_gnt     (p_wr_gnt[17]),
    .rsp_vld    (p_rsp_vld[17]),
    .rsp_data   (p_rsp_data[17][W17-1:0]),
    .err_win_tog  (win_tog_p[17]),
    .err_ovf_tog  (ovf_tog_p[17]),
    .err_win_stky (win_stky[17]),
    .err_ovf_stky (ovf_stky[17]),
    .err_slot     (p_err_slot[17]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd17)
  );
  if (W17 < 512) begin : g_wtie17
    assign p_wr_data[17][511:W17] = '0;
  end
  end
  else begin : g_port17_off
    assign sram17_rdata = '0;
    assign sram17_rvalid = 1'b0;
    logic unused_p17;
    assign unused_p17 = &{1'b0, sram17_en, sram17_we, sram17_addr, sram17_wdata, sram17_be};
  end
  if (N > 18) begin : g_port18
  hades_sram_port #(
    .AW           (AW),
    .DW           (W18),
    .BE_EN        (BE18_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (18),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram18_en),
    .we         (sram18_we),
    .addr       (sram18_addr),
    .wdata      (sram18_wdata),
    .be         (sram18_be),
    .rdata      (sram18_rdata),
    .rvalid     (sram18_rvalid),
    .cfg_en     (cfg_eff.port_en[18]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[18]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[18]),
    .rd_addr    (p_rd_addr[18]),
    .rd_gnt     (p_rd_gnt[18]),
    .wr_vld     (pr_wr_vld[18]),
    .wr_addr    (p_wr_addr[18]),
    .wr_data    (p_wr_data[18][W18-1:0]),
    .wr_be      (p_wr_be[18]),
    .wr_gnt     (p_wr_gnt[18]),
    .rsp_vld    (p_rsp_vld[18]),
    .rsp_data   (p_rsp_data[18][W18-1:0]),
    .err_win_tog  (win_tog_p[18]),
    .err_ovf_tog  (ovf_tog_p[18]),
    .err_win_stky (win_stky[18]),
    .err_ovf_stky (ovf_stky[18]),
    .err_slot     (p_err_slot[18]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd18)
  );
  if (W18 < 512) begin : g_wtie18
    assign p_wr_data[18][511:W18] = '0;
  end
  end
  else begin : g_port18_off
    assign sram18_rdata = '0;
    assign sram18_rvalid = 1'b0;
    logic unused_p18;
    assign unused_p18 = &{1'b0, sram18_en, sram18_we, sram18_addr, sram18_wdata, sram18_be};
  end
  if (N > 19) begin : g_port19
  hades_sram_port #(
    .AW           (AW),
    .DW           (W19),
    .BE_EN        (BE19_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (19),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram19_en),
    .we         (sram19_we),
    .addr       (sram19_addr),
    .wdata      (sram19_wdata),
    .be         (sram19_be),
    .rdata      (sram19_rdata),
    .rvalid     (sram19_rvalid),
    .cfg_en     (cfg_eff.port_en[19]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[19]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[19]),
    .rd_addr    (p_rd_addr[19]),
    .rd_gnt     (p_rd_gnt[19]),
    .wr_vld     (pr_wr_vld[19]),
    .wr_addr    (p_wr_addr[19]),
    .wr_data    (p_wr_data[19][W19-1:0]),
    .wr_be      (p_wr_be[19]),
    .wr_gnt     (p_wr_gnt[19]),
    .rsp_vld    (p_rsp_vld[19]),
    .rsp_data   (p_rsp_data[19][W19-1:0]),
    .err_win_tog  (win_tog_p[19]),
    .err_ovf_tog  (ovf_tog_p[19]),
    .err_win_stky (win_stky[19]),
    .err_ovf_stky (ovf_stky[19]),
    .err_slot     (p_err_slot[19]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd19)
  );
  if (W19 < 512) begin : g_wtie19
    assign p_wr_data[19][511:W19] = '0;
  end
  end
  else begin : g_port19_off
    assign sram19_rdata = '0;
    assign sram19_rvalid = 1'b0;
    logic unused_p19;
    assign unused_p19 = &{1'b0, sram19_en, sram19_we, sram19_addr, sram19_wdata, sram19_be};
  end
  if (N > 20) begin : g_port20
  hades_sram_port #(
    .AW           (AW),
    .DW           (W20),
    .BE_EN        (BE20_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (20),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram20_en),
    .we         (sram20_we),
    .addr       (sram20_addr),
    .wdata      (sram20_wdata),
    .be         (sram20_be),
    .rdata      (sram20_rdata),
    .rvalid     (sram20_rvalid),
    .cfg_en     (cfg_eff.port_en[20]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[20]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[20]),
    .rd_addr    (p_rd_addr[20]),
    .rd_gnt     (p_rd_gnt[20]),
    .wr_vld     (pr_wr_vld[20]),
    .wr_addr    (p_wr_addr[20]),
    .wr_data    (p_wr_data[20][W20-1:0]),
    .wr_be      (p_wr_be[20]),
    .wr_gnt     (p_wr_gnt[20]),
    .rsp_vld    (p_rsp_vld[20]),
    .rsp_data   (p_rsp_data[20][W20-1:0]),
    .err_win_tog  (win_tog_p[20]),
    .err_ovf_tog  (ovf_tog_p[20]),
    .err_win_stky (win_stky[20]),
    .err_ovf_stky (ovf_stky[20]),
    .err_slot     (p_err_slot[20]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd20)
  );
  if (W20 < 512) begin : g_wtie20
    assign p_wr_data[20][511:W20] = '0;
  end
  end
  else begin : g_port20_off
    assign sram20_rdata = '0;
    assign sram20_rvalid = 1'b0;
    logic unused_p20;
    assign unused_p20 = &{1'b0, sram20_en, sram20_we, sram20_addr, sram20_wdata, sram20_be};
  end
  if (N > 21) begin : g_port21
  hades_sram_port #(
    .AW           (AW),
    .DW           (W21),
    .BE_EN        (BE21_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (21),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram21_en),
    .we         (sram21_we),
    .addr       (sram21_addr),
    .wdata      (sram21_wdata),
    .be         (sram21_be),
    .rdata      (sram21_rdata),
    .rvalid     (sram21_rvalid),
    .cfg_en     (cfg_eff.port_en[21]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[21]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[21]),
    .rd_addr    (p_rd_addr[21]),
    .rd_gnt     (p_rd_gnt[21]),
    .wr_vld     (pr_wr_vld[21]),
    .wr_addr    (p_wr_addr[21]),
    .wr_data    (p_wr_data[21][W21-1:0]),
    .wr_be      (p_wr_be[21]),
    .wr_gnt     (p_wr_gnt[21]),
    .rsp_vld    (p_rsp_vld[21]),
    .rsp_data   (p_rsp_data[21][W21-1:0]),
    .err_win_tog  (win_tog_p[21]),
    .err_ovf_tog  (ovf_tog_p[21]),
    .err_win_stky (win_stky[21]),
    .err_ovf_stky (ovf_stky[21]),
    .err_slot     (p_err_slot[21]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd21)
  );
  if (W21 < 512) begin : g_wtie21
    assign p_wr_data[21][511:W21] = '0;
  end
  end
  else begin : g_port21_off
    assign sram21_rdata = '0;
    assign sram21_rvalid = 1'b0;
    logic unused_p21;
    assign unused_p21 = &{1'b0, sram21_en, sram21_we, sram21_addr, sram21_wdata, sram21_be};
  end
  if (N > 22) begin : g_port22
  hades_sram_port #(
    .AW           (AW),
    .DW           (W22),
    .BE_EN        (BE22_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (22),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram22_en),
    .we         (sram22_we),
    .addr       (sram22_addr),
    .wdata      (sram22_wdata),
    .be         (sram22_be),
    .rdata      (sram22_rdata),
    .rvalid     (sram22_rvalid),
    .cfg_en     (cfg_eff.port_en[22]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[22]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[22]),
    .rd_addr    (p_rd_addr[22]),
    .rd_gnt     (p_rd_gnt[22]),
    .wr_vld     (pr_wr_vld[22]),
    .wr_addr    (p_wr_addr[22]),
    .wr_data    (p_wr_data[22][W22-1:0]),
    .wr_be      (p_wr_be[22]),
    .wr_gnt     (p_wr_gnt[22]),
    .rsp_vld    (p_rsp_vld[22]),
    .rsp_data   (p_rsp_data[22][W22-1:0]),
    .err_win_tog  (win_tog_p[22]),
    .err_ovf_tog  (ovf_tog_p[22]),
    .err_win_stky (win_stky[22]),
    .err_ovf_stky (ovf_stky[22]),
    .err_slot     (p_err_slot[22]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd22)
  );
  if (W22 < 512) begin : g_wtie22
    assign p_wr_data[22][511:W22] = '0;
  end
  end
  else begin : g_port22_off
    assign sram22_rdata = '0;
    assign sram22_rvalid = 1'b0;
    logic unused_p22;
    assign unused_p22 = &{1'b0, sram22_en, sram22_we, sram22_addr, sram22_wdata, sram22_be};
  end
  if (N > 23) begin : g_port23
  hades_sram_port #(
    .AW           (AW),
    .DW           (W23),
    .BE_EN        (BE23_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (23),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram23_en),
    .we         (sram23_we),
    .addr       (sram23_addr),
    .wdata      (sram23_wdata),
    .be         (sram23_be),
    .rdata      (sram23_rdata),
    .rvalid     (sram23_rvalid),
    .cfg_en     (cfg_eff.port_en[23]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[23]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[23]),
    .rd_addr    (p_rd_addr[23]),
    .rd_gnt     (p_rd_gnt[23]),
    .wr_vld     (pr_wr_vld[23]),
    .wr_addr    (p_wr_addr[23]),
    .wr_data    (p_wr_data[23][W23-1:0]),
    .wr_be      (p_wr_be[23]),
    .wr_gnt     (p_wr_gnt[23]),
    .rsp_vld    (p_rsp_vld[23]),
    .rsp_data   (p_rsp_data[23][W23-1:0]),
    .err_win_tog  (win_tog_p[23]),
    .err_ovf_tog  (ovf_tog_p[23]),
    .err_win_stky (win_stky[23]),
    .err_ovf_stky (ovf_stky[23]),
    .err_slot     (p_err_slot[23]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd23)
  );
  if (W23 < 512) begin : g_wtie23
    assign p_wr_data[23][511:W23] = '0;
  end
  end
  else begin : g_port23_off
    assign sram23_rdata = '0;
    assign sram23_rvalid = 1'b0;
    logic unused_p23;
    assign unused_p23 = &{1'b0, sram23_en, sram23_we, sram23_addr, sram23_wdata, sram23_be};
  end
  if (N > 24) begin : g_port24
  hades_sram_port #(
    .AW           (AW),
    .DW           (W24),
    .BE_EN        (BE24_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (24),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram24_en),
    .we         (sram24_we),
    .addr       (sram24_addr),
    .wdata      (sram24_wdata),
    .be         (sram24_be),
    .rdata      (sram24_rdata),
    .rvalid     (sram24_rvalid),
    .cfg_en     (cfg_eff.port_en[24]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[24]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[24]),
    .rd_addr    (p_rd_addr[24]),
    .rd_gnt     (p_rd_gnt[24]),
    .wr_vld     (pr_wr_vld[24]),
    .wr_addr    (p_wr_addr[24]),
    .wr_data    (p_wr_data[24][W24-1:0]),
    .wr_be      (p_wr_be[24]),
    .wr_gnt     (p_wr_gnt[24]),
    .rsp_vld    (p_rsp_vld[24]),
    .rsp_data   (p_rsp_data[24][W24-1:0]),
    .err_win_tog  (win_tog_p[24]),
    .err_ovf_tog  (ovf_tog_p[24]),
    .err_win_stky (win_stky[24]),
    .err_ovf_stky (ovf_stky[24]),
    .err_slot     (p_err_slot[24]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd24)
  );
  if (W24 < 512) begin : g_wtie24
    assign p_wr_data[24][511:W24] = '0;
  end
  end
  else begin : g_port24_off
    assign sram24_rdata = '0;
    assign sram24_rvalid = 1'b0;
    logic unused_p24;
    assign unused_p24 = &{1'b0, sram24_en, sram24_we, sram24_addr, sram24_wdata, sram24_be};
  end
  if (N > 25) begin : g_port25
  hades_sram_port #(
    .AW           (AW),
    .DW           (W25),
    .BE_EN        (BE25_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (25),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram25_en),
    .we         (sram25_we),
    .addr       (sram25_addr),
    .wdata      (sram25_wdata),
    .be         (sram25_be),
    .rdata      (sram25_rdata),
    .rvalid     (sram25_rvalid),
    .cfg_en     (cfg_eff.port_en[25]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[25]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[25]),
    .rd_addr    (p_rd_addr[25]),
    .rd_gnt     (p_rd_gnt[25]),
    .wr_vld     (pr_wr_vld[25]),
    .wr_addr    (p_wr_addr[25]),
    .wr_data    (p_wr_data[25][W25-1:0]),
    .wr_be      (p_wr_be[25]),
    .wr_gnt     (p_wr_gnt[25]),
    .rsp_vld    (p_rsp_vld[25]),
    .rsp_data   (p_rsp_data[25][W25-1:0]),
    .err_win_tog  (win_tog_p[25]),
    .err_ovf_tog  (ovf_tog_p[25]),
    .err_win_stky (win_stky[25]),
    .err_ovf_stky (ovf_stky[25]),
    .err_slot     (p_err_slot[25]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd25)
  );
  if (W25 < 512) begin : g_wtie25
    assign p_wr_data[25][511:W25] = '0;
  end
  end
  else begin : g_port25_off
    assign sram25_rdata = '0;
    assign sram25_rvalid = 1'b0;
    logic unused_p25;
    assign unused_p25 = &{1'b0, sram25_en, sram25_we, sram25_addr, sram25_wdata, sram25_be};
  end
  if (N > 26) begin : g_port26
  hades_sram_port #(
    .AW           (AW),
    .DW           (W26),
    .BE_EN        (BE26_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (26),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram26_en),
    .we         (sram26_we),
    .addr       (sram26_addr),
    .wdata      (sram26_wdata),
    .be         (sram26_be),
    .rdata      (sram26_rdata),
    .rvalid     (sram26_rvalid),
    .cfg_en     (cfg_eff.port_en[26]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[26]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[26]),
    .rd_addr    (p_rd_addr[26]),
    .rd_gnt     (p_rd_gnt[26]),
    .wr_vld     (pr_wr_vld[26]),
    .wr_addr    (p_wr_addr[26]),
    .wr_data    (p_wr_data[26][W26-1:0]),
    .wr_be      (p_wr_be[26]),
    .wr_gnt     (p_wr_gnt[26]),
    .rsp_vld    (p_rsp_vld[26]),
    .rsp_data   (p_rsp_data[26][W26-1:0]),
    .err_win_tog  (win_tog_p[26]),
    .err_ovf_tog  (ovf_tog_p[26]),
    .err_win_stky (win_stky[26]),
    .err_ovf_stky (ovf_stky[26]),
    .err_slot     (p_err_slot[26]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd26)
  );
  if (W26 < 512) begin : g_wtie26
    assign p_wr_data[26][511:W26] = '0;
  end
  end
  else begin : g_port26_off
    assign sram26_rdata = '0;
    assign sram26_rvalid = 1'b0;
    logic unused_p26;
    assign unused_p26 = &{1'b0, sram26_en, sram26_we, sram26_addr, sram26_wdata, sram26_be};
  end
  if (N > 27) begin : g_port27
  hades_sram_port #(
    .AW           (AW),
    .DW           (W27),
    .BE_EN        (BE27_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (27),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram27_en),
    .we         (sram27_we),
    .addr       (sram27_addr),
    .wdata      (sram27_wdata),
    .be         (sram27_be),
    .rdata      (sram27_rdata),
    .rvalid     (sram27_rvalid),
    .cfg_en     (cfg_eff.port_en[27]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[27]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[27]),
    .rd_addr    (p_rd_addr[27]),
    .rd_gnt     (p_rd_gnt[27]),
    .wr_vld     (pr_wr_vld[27]),
    .wr_addr    (p_wr_addr[27]),
    .wr_data    (p_wr_data[27][W27-1:0]),
    .wr_be      (p_wr_be[27]),
    .wr_gnt     (p_wr_gnt[27]),
    .rsp_vld    (p_rsp_vld[27]),
    .rsp_data   (p_rsp_data[27][W27-1:0]),
    .err_win_tog  (win_tog_p[27]),
    .err_ovf_tog  (ovf_tog_p[27]),
    .err_win_stky (win_stky[27]),
    .err_ovf_stky (ovf_stky[27]),
    .err_slot     (p_err_slot[27]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd27)
  );
  if (W27 < 512) begin : g_wtie27
    assign p_wr_data[27][511:W27] = '0;
  end
  end
  else begin : g_port27_off
    assign sram27_rdata = '0;
    assign sram27_rvalid = 1'b0;
    logic unused_p27;
    assign unused_p27 = &{1'b0, sram27_en, sram27_we, sram27_addr, sram27_wdata, sram27_be};
  end
  if (N > 28) begin : g_port28
  hades_sram_port #(
    .AW           (AW),
    .DW           (W28),
    .BE_EN        (BE28_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (28),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram28_en),
    .we         (sram28_we),
    .addr       (sram28_addr),
    .wdata      (sram28_wdata),
    .be         (sram28_be),
    .rdata      (sram28_rdata),
    .rvalid     (sram28_rvalid),
    .cfg_en     (cfg_eff.port_en[28]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[28]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[28]),
    .rd_addr    (p_rd_addr[28]),
    .rd_gnt     (p_rd_gnt[28]),
    .wr_vld     (pr_wr_vld[28]),
    .wr_addr    (p_wr_addr[28]),
    .wr_data    (p_wr_data[28][W28-1:0]),
    .wr_be      (p_wr_be[28]),
    .wr_gnt     (p_wr_gnt[28]),
    .rsp_vld    (p_rsp_vld[28]),
    .rsp_data   (p_rsp_data[28][W28-1:0]),
    .err_win_tog  (win_tog_p[28]),
    .err_ovf_tog  (ovf_tog_p[28]),
    .err_win_stky (win_stky[28]),
    .err_ovf_stky (ovf_stky[28]),
    .err_slot     (p_err_slot[28]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd28)
  );
  if (W28 < 512) begin : g_wtie28
    assign p_wr_data[28][511:W28] = '0;
  end
  end
  else begin : g_port28_off
    assign sram28_rdata = '0;
    assign sram28_rvalid = 1'b0;
    logic unused_p28;
    assign unused_p28 = &{1'b0, sram28_en, sram28_we, sram28_addr, sram28_wdata, sram28_be};
  end
  if (N > 29) begin : g_port29
  hades_sram_port #(
    .AW           (AW),
    .DW           (W29),
    .BE_EN        (BE29_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (29),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram29_en),
    .we         (sram29_we),
    .addr       (sram29_addr),
    .wdata      (sram29_wdata),
    .be         (sram29_be),
    .rdata      (sram29_rdata),
    .rvalid     (sram29_rvalid),
    .cfg_en     (cfg_eff.port_en[29]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[29]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[29]),
    .rd_addr    (p_rd_addr[29]),
    .rd_gnt     (p_rd_gnt[29]),
    .wr_vld     (pr_wr_vld[29]),
    .wr_addr    (p_wr_addr[29]),
    .wr_data    (p_wr_data[29][W29-1:0]),
    .wr_be      (p_wr_be[29]),
    .wr_gnt     (p_wr_gnt[29]),
    .rsp_vld    (p_rsp_vld[29]),
    .rsp_data   (p_rsp_data[29][W29-1:0]),
    .err_win_tog  (win_tog_p[29]),
    .err_ovf_tog  (ovf_tog_p[29]),
    .err_win_stky (win_stky[29]),
    .err_ovf_stky (ovf_stky[29]),
    .err_slot     (p_err_slot[29]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd29)
  );
  if (W29 < 512) begin : g_wtie29
    assign p_wr_data[29][511:W29] = '0;
  end
  end
  else begin : g_port29_off
    assign sram29_rdata = '0;
    assign sram29_rvalid = 1'b0;
    logic unused_p29;
    assign unused_p29 = &{1'b0, sram29_en, sram29_we, sram29_addr, sram29_wdata, sram29_be};
  end
  if (N > 30) begin : g_port30
  hades_sram_port #(
    .AW           (AW),
    .DW           (W30),
    .BE_EN        (BE30_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (30),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram30_en),
    .we         (sram30_we),
    .addr       (sram30_addr),
    .wdata      (sram30_wdata),
    .be         (sram30_be),
    .rdata      (sram30_rdata),
    .rvalid     (sram30_rvalid),
    .cfg_en     (cfg_eff.port_en[30]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[30]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[30]),
    .rd_addr    (p_rd_addr[30]),
    .rd_gnt     (p_rd_gnt[30]),
    .wr_vld     (pr_wr_vld[30]),
    .wr_addr    (p_wr_addr[30]),
    .wr_data    (p_wr_data[30][W30-1:0]),
    .wr_be      (p_wr_be[30]),
    .wr_gnt     (p_wr_gnt[30]),
    .rsp_vld    (p_rsp_vld[30]),
    .rsp_data   (p_rsp_data[30][W30-1:0]),
    .err_win_tog  (win_tog_p[30]),
    .err_ovf_tog  (ovf_tog_p[30]),
    .err_win_stky (win_stky[30]),
    .err_ovf_stky (ovf_stky[30]),
    .err_slot     (p_err_slot[30]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd30)
  );
  if (W30 < 512) begin : g_wtie30
    assign p_wr_data[30][511:W30] = '0;
  end
  end
  else begin : g_port30_off
    assign sram30_rdata = '0;
    assign sram30_rvalid = 1'b0;
    logic unused_p30;
    assign unused_p30 = &{1'b0, sram30_en, sram30_we, sram30_addr, sram30_wdata, sram30_be};
  end
  if (N > 31) begin : g_port31
  hades_sram_port #(
    .AW           (AW),
    .DW           (W31),
    .BE_EN        (BE31_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (31),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram31_en),
    .we         (sram31_we),
    .addr       (sram31_addr),
    .wdata      (sram31_wdata),
    .be         (sram31_be),
    .rdata      (sram31_rdata),
    .rvalid     (sram31_rvalid),
    .cfg_en     (cfg_eff.port_en[31]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[31]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[31]),
    .rd_addr    (p_rd_addr[31]),
    .rd_gnt     (p_rd_gnt[31]),
    .wr_vld     (pr_wr_vld[31]),
    .wr_addr    (p_wr_addr[31]),
    .wr_data    (p_wr_data[31][W31-1:0]),
    .wr_be      (p_wr_be[31]),
    .wr_gnt     (p_wr_gnt[31]),
    .rsp_vld    (p_rsp_vld[31]),
    .rsp_data   (p_rsp_data[31][W31-1:0]),
    .err_win_tog  (win_tog_p[31]),
    .err_ovf_tog  (ovf_tog_p[31]),
    .err_win_stky (win_stky[31]),
    .err_ovf_stky (ovf_stky[31]),
    .err_slot     (p_err_slot[31]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd31)
  );
  if (W31 < 512) begin : g_wtie31
    assign p_wr_data[31][511:W31] = '0;
  end
  end
  else begin : g_port31_off
    assign sram31_rdata = '0;
    assign sram31_rvalid = 1'b0;
    logic unused_p31;
    assign unused_p31 = &{1'b0, sram31_en, sram31_we, sram31_addr, sram31_wdata, sram31_be};
  end
  if (N > 32) begin : g_port32
  hades_sram_port #(
    .AW           (AW),
    .DW           (W32),
    .BE_EN        (BE32_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (32),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram32_en),
    .we         (sram32_we),
    .addr       (sram32_addr),
    .wdata      (sram32_wdata),
    .be         (sram32_be),
    .rdata      (sram32_rdata),
    .rvalid     (sram32_rvalid),
    .cfg_en     (cfg_eff.port_en[32]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[32]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[32]),
    .rd_addr    (p_rd_addr[32]),
    .rd_gnt     (p_rd_gnt[32]),
    .wr_vld     (pr_wr_vld[32]),
    .wr_addr    (p_wr_addr[32]),
    .wr_data    (p_wr_data[32][W32-1:0]),
    .wr_be      (p_wr_be[32]),
    .wr_gnt     (p_wr_gnt[32]),
    .rsp_vld    (p_rsp_vld[32]),
    .rsp_data   (p_rsp_data[32][W32-1:0]),
    .err_win_tog  (win_tog_p[32]),
    .err_ovf_tog  (ovf_tog_p[32]),
    .err_win_stky (win_stky[32]),
    .err_ovf_stky (ovf_stky[32]),
    .err_slot     (p_err_slot[32]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd32)
  );
  if (W32 < 512) begin : g_wtie32
    assign p_wr_data[32][511:W32] = '0;
  end
  end
  else begin : g_port32_off
    assign sram32_rdata = '0;
    assign sram32_rvalid = 1'b0;
    logic unused_p32;
    assign unused_p32 = &{1'b0, sram32_en, sram32_we, sram32_addr, sram32_wdata, sram32_be};
  end
  if (N > 33) begin : g_port33
  hades_sram_port #(
    .AW           (AW),
    .DW           (W33),
    .BE_EN        (BE33_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (33),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram33_en),
    .we         (sram33_we),
    .addr       (sram33_addr),
    .wdata      (sram33_wdata),
    .be         (sram33_be),
    .rdata      (sram33_rdata),
    .rvalid     (sram33_rvalid),
    .cfg_en     (cfg_eff.port_en[33]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[33]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[33]),
    .rd_addr    (p_rd_addr[33]),
    .rd_gnt     (p_rd_gnt[33]),
    .wr_vld     (pr_wr_vld[33]),
    .wr_addr    (p_wr_addr[33]),
    .wr_data    (p_wr_data[33][W33-1:0]),
    .wr_be      (p_wr_be[33]),
    .wr_gnt     (p_wr_gnt[33]),
    .rsp_vld    (p_rsp_vld[33]),
    .rsp_data   (p_rsp_data[33][W33-1:0]),
    .err_win_tog  (win_tog_p[33]),
    .err_ovf_tog  (ovf_tog_p[33]),
    .err_win_stky (win_stky[33]),
    .err_ovf_stky (ovf_stky[33]),
    .err_slot     (p_err_slot[33]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd33)
  );
  if (W33 < 512) begin : g_wtie33
    assign p_wr_data[33][511:W33] = '0;
  end
  end
  else begin : g_port33_off
    assign sram33_rdata = '0;
    assign sram33_rvalid = 1'b0;
    logic unused_p33;
    assign unused_p33 = &{1'b0, sram33_en, sram33_we, sram33_addr, sram33_wdata, sram33_be};
  end
  if (N > 34) begin : g_port34
  hades_sram_port #(
    .AW           (AW),
    .DW           (W34),
    .BE_EN        (BE34_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (34),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram34_en),
    .we         (sram34_we),
    .addr       (sram34_addr),
    .wdata      (sram34_wdata),
    .be         (sram34_be),
    .rdata      (sram34_rdata),
    .rvalid     (sram34_rvalid),
    .cfg_en     (cfg_eff.port_en[34]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[34]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[34]),
    .rd_addr    (p_rd_addr[34]),
    .rd_gnt     (p_rd_gnt[34]),
    .wr_vld     (pr_wr_vld[34]),
    .wr_addr    (p_wr_addr[34]),
    .wr_data    (p_wr_data[34][W34-1:0]),
    .wr_be      (p_wr_be[34]),
    .wr_gnt     (p_wr_gnt[34]),
    .rsp_vld    (p_rsp_vld[34]),
    .rsp_data   (p_rsp_data[34][W34-1:0]),
    .err_win_tog  (win_tog_p[34]),
    .err_ovf_tog  (ovf_tog_p[34]),
    .err_win_stky (win_stky[34]),
    .err_ovf_stky (ovf_stky[34]),
    .err_slot     (p_err_slot[34]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd34)
  );
  if (W34 < 512) begin : g_wtie34
    assign p_wr_data[34][511:W34] = '0;
  end
  end
  else begin : g_port34_off
    assign sram34_rdata = '0;
    assign sram34_rvalid = 1'b0;
    logic unused_p34;
    assign unused_p34 = &{1'b0, sram34_en, sram34_we, sram34_addr, sram34_wdata, sram34_be};
  end
  if (N > 35) begin : g_port35
  hades_sram_port #(
    .AW           (AW),
    .DW           (W35),
    .BE_EN        (BE35_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (35),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram35_en),
    .we         (sram35_we),
    .addr       (sram35_addr),
    .wdata      (sram35_wdata),
    .be         (sram35_be),
    .rdata      (sram35_rdata),
    .rvalid     (sram35_rvalid),
    .cfg_en     (cfg_eff.port_en[35]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[35]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[35]),
    .rd_addr    (p_rd_addr[35]),
    .rd_gnt     (p_rd_gnt[35]),
    .wr_vld     (pr_wr_vld[35]),
    .wr_addr    (p_wr_addr[35]),
    .wr_data    (p_wr_data[35][W35-1:0]),
    .wr_be      (p_wr_be[35]),
    .wr_gnt     (p_wr_gnt[35]),
    .rsp_vld    (p_rsp_vld[35]),
    .rsp_data   (p_rsp_data[35][W35-1:0]),
    .err_win_tog  (win_tog_p[35]),
    .err_ovf_tog  (ovf_tog_p[35]),
    .err_win_stky (win_stky[35]),
    .err_ovf_stky (ovf_stky[35]),
    .err_slot     (p_err_slot[35]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd35)
  );
  if (W35 < 512) begin : g_wtie35
    assign p_wr_data[35][511:W35] = '0;
  end
  end
  else begin : g_port35_off
    assign sram35_rdata = '0;
    assign sram35_rvalid = 1'b0;
    logic unused_p35;
    assign unused_p35 = &{1'b0, sram35_en, sram35_we, sram35_addr, sram35_wdata, sram35_be};
  end
  if (N > 36) begin : g_port36
  hades_sram_port #(
    .AW           (AW),
    .DW           (W36),
    .BE_EN        (BE36_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (36),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram36_en),
    .we         (sram36_we),
    .addr       (sram36_addr),
    .wdata      (sram36_wdata),
    .be         (sram36_be),
    .rdata      (sram36_rdata),
    .rvalid     (sram36_rvalid),
    .cfg_en     (cfg_eff.port_en[36]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[36]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[36]),
    .rd_addr    (p_rd_addr[36]),
    .rd_gnt     (p_rd_gnt[36]),
    .wr_vld     (pr_wr_vld[36]),
    .wr_addr    (p_wr_addr[36]),
    .wr_data    (p_wr_data[36][W36-1:0]),
    .wr_be      (p_wr_be[36]),
    .wr_gnt     (p_wr_gnt[36]),
    .rsp_vld    (p_rsp_vld[36]),
    .rsp_data   (p_rsp_data[36][W36-1:0]),
    .err_win_tog  (win_tog_p[36]),
    .err_ovf_tog  (ovf_tog_p[36]),
    .err_win_stky (win_stky[36]),
    .err_ovf_stky (ovf_stky[36]),
    .err_slot     (p_err_slot[36]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd36)
  );
  if (W36 < 512) begin : g_wtie36
    assign p_wr_data[36][511:W36] = '0;
  end
  end
  else begin : g_port36_off
    assign sram36_rdata = '0;
    assign sram36_rvalid = 1'b0;
    logic unused_p36;
    assign unused_p36 = &{1'b0, sram36_en, sram36_we, sram36_addr, sram36_wdata, sram36_be};
  end
  if (N > 37) begin : g_port37
  hades_sram_port #(
    .AW           (AW),
    .DW           (W37),
    .BE_EN        (BE37_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (37),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram37_en),
    .we         (sram37_we),
    .addr       (sram37_addr),
    .wdata      (sram37_wdata),
    .be         (sram37_be),
    .rdata      (sram37_rdata),
    .rvalid     (sram37_rvalid),
    .cfg_en     (cfg_eff.port_en[37]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[37]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[37]),
    .rd_addr    (p_rd_addr[37]),
    .rd_gnt     (p_rd_gnt[37]),
    .wr_vld     (pr_wr_vld[37]),
    .wr_addr    (p_wr_addr[37]),
    .wr_data    (p_wr_data[37][W37-1:0]),
    .wr_be      (p_wr_be[37]),
    .wr_gnt     (p_wr_gnt[37]),
    .rsp_vld    (p_rsp_vld[37]),
    .rsp_data   (p_rsp_data[37][W37-1:0]),
    .err_win_tog  (win_tog_p[37]),
    .err_ovf_tog  (ovf_tog_p[37]),
    .err_win_stky (win_stky[37]),
    .err_ovf_stky (ovf_stky[37]),
    .err_slot     (p_err_slot[37]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd37)
  );
  if (W37 < 512) begin : g_wtie37
    assign p_wr_data[37][511:W37] = '0;
  end
  end
  else begin : g_port37_off
    assign sram37_rdata = '0;
    assign sram37_rvalid = 1'b0;
    logic unused_p37;
    assign unused_p37 = &{1'b0, sram37_en, sram37_we, sram37_addr, sram37_wdata, sram37_be};
  end
  if (N > 38) begin : g_port38
  hades_sram_port #(
    .AW           (AW),
    .DW           (W38),
    .BE_EN        (BE38_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (38),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram38_en),
    .we         (sram38_we),
    .addr       (sram38_addr),
    .wdata      (sram38_wdata),
    .be         (sram38_be),
    .rdata      (sram38_rdata),
    .rvalid     (sram38_rvalid),
    .cfg_en     (cfg_eff.port_en[38]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[38]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[38]),
    .rd_addr    (p_rd_addr[38]),
    .rd_gnt     (p_rd_gnt[38]),
    .wr_vld     (pr_wr_vld[38]),
    .wr_addr    (p_wr_addr[38]),
    .wr_data    (p_wr_data[38][W38-1:0]),
    .wr_be      (p_wr_be[38]),
    .wr_gnt     (p_wr_gnt[38]),
    .rsp_vld    (p_rsp_vld[38]),
    .rsp_data   (p_rsp_data[38][W38-1:0]),
    .err_win_tog  (win_tog_p[38]),
    .err_ovf_tog  (ovf_tog_p[38]),
    .err_win_stky (win_stky[38]),
    .err_ovf_stky (ovf_stky[38]),
    .err_slot     (p_err_slot[38]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd38)
  );
  if (W38 < 512) begin : g_wtie38
    assign p_wr_data[38][511:W38] = '0;
  end
  end
  else begin : g_port38_off
    assign sram38_rdata = '0;
    assign sram38_rvalid = 1'b0;
    logic unused_p38;
    assign unused_p38 = &{1'b0, sram38_en, sram38_we, sram38_addr, sram38_wdata, sram38_be};
  end
  if (N > 39) begin : g_port39
  hades_sram_port #(
    .AW           (AW),
    .DW           (W39),
    .BE_EN        (BE39_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (39),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram39_en),
    .we         (sram39_we),
    .addr       (sram39_addr),
    .wdata      (sram39_wdata),
    .be         (sram39_be),
    .rdata      (sram39_rdata),
    .rvalid     (sram39_rvalid),
    .cfg_en     (cfg_eff.port_en[39]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[39]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[39]),
    .rd_addr    (p_rd_addr[39]),
    .rd_gnt     (p_rd_gnt[39]),
    .wr_vld     (pr_wr_vld[39]),
    .wr_addr    (p_wr_addr[39]),
    .wr_data    (p_wr_data[39][W39-1:0]),
    .wr_be      (p_wr_be[39]),
    .wr_gnt     (p_wr_gnt[39]),
    .rsp_vld    (p_rsp_vld[39]),
    .rsp_data   (p_rsp_data[39][W39-1:0]),
    .err_win_tog  (win_tog_p[39]),
    .err_ovf_tog  (ovf_tog_p[39]),
    .err_win_stky (win_stky[39]),
    .err_ovf_stky (ovf_stky[39]),
    .err_slot     (p_err_slot[39]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd39)
  );
  if (W39 < 512) begin : g_wtie39
    assign p_wr_data[39][511:W39] = '0;
  end
  end
  else begin : g_port39_off
    assign sram39_rdata = '0;
    assign sram39_rvalid = 1'b0;
    logic unused_p39;
    assign unused_p39 = &{1'b0, sram39_en, sram39_we, sram39_addr, sram39_wdata, sram39_be};
  end
  if (N > 40) begin : g_port40
  hades_sram_port #(
    .AW           (AW),
    .DW           (W40),
    .BE_EN        (BE40_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (40),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram40_en),
    .we         (sram40_we),
    .addr       (sram40_addr),
    .wdata      (sram40_wdata),
    .be         (sram40_be),
    .rdata      (sram40_rdata),
    .rvalid     (sram40_rvalid),
    .cfg_en     (cfg_eff.port_en[40]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[40]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[40]),
    .rd_addr    (p_rd_addr[40]),
    .rd_gnt     (p_rd_gnt[40]),
    .wr_vld     (pr_wr_vld[40]),
    .wr_addr    (p_wr_addr[40]),
    .wr_data    (p_wr_data[40][W40-1:0]),
    .wr_be      (p_wr_be[40]),
    .wr_gnt     (p_wr_gnt[40]),
    .rsp_vld    (p_rsp_vld[40]),
    .rsp_data   (p_rsp_data[40][W40-1:0]),
    .err_win_tog  (win_tog_p[40]),
    .err_ovf_tog  (ovf_tog_p[40]),
    .err_win_stky (win_stky[40]),
    .err_ovf_stky (ovf_stky[40]),
    .err_slot     (p_err_slot[40]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd40)
  );
  if (W40 < 512) begin : g_wtie40
    assign p_wr_data[40][511:W40] = '0;
  end
  end
  else begin : g_port40_off
    assign sram40_rdata = '0;
    assign sram40_rvalid = 1'b0;
    logic unused_p40;
    assign unused_p40 = &{1'b0, sram40_en, sram40_we, sram40_addr, sram40_wdata, sram40_be};
  end
  if (N > 41) begin : g_port41
  hades_sram_port #(
    .AW           (AW),
    .DW           (W41),
    .BE_EN        (BE41_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (41),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram41_en),
    .we         (sram41_we),
    .addr       (sram41_addr),
    .wdata      (sram41_wdata),
    .be         (sram41_be),
    .rdata      (sram41_rdata),
    .rvalid     (sram41_rvalid),
    .cfg_en     (cfg_eff.port_en[41]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[41]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[41]),
    .rd_addr    (p_rd_addr[41]),
    .rd_gnt     (p_rd_gnt[41]),
    .wr_vld     (pr_wr_vld[41]),
    .wr_addr    (p_wr_addr[41]),
    .wr_data    (p_wr_data[41][W41-1:0]),
    .wr_be      (p_wr_be[41]),
    .wr_gnt     (p_wr_gnt[41]),
    .rsp_vld    (p_rsp_vld[41]),
    .rsp_data   (p_rsp_data[41][W41-1:0]),
    .err_win_tog  (win_tog_p[41]),
    .err_ovf_tog  (ovf_tog_p[41]),
    .err_win_stky (win_stky[41]),
    .err_ovf_stky (ovf_stky[41]),
    .err_slot     (p_err_slot[41]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd41)
  );
  if (W41 < 512) begin : g_wtie41
    assign p_wr_data[41][511:W41] = '0;
  end
  end
  else begin : g_port41_off
    assign sram41_rdata = '0;
    assign sram41_rvalid = 1'b0;
    logic unused_p41;
    assign unused_p41 = &{1'b0, sram41_en, sram41_we, sram41_addr, sram41_wdata, sram41_be};
  end
  if (N > 42) begin : g_port42
  hades_sram_port #(
    .AW           (AW),
    .DW           (W42),
    .BE_EN        (BE42_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (42),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram42_en),
    .we         (sram42_we),
    .addr       (sram42_addr),
    .wdata      (sram42_wdata),
    .be         (sram42_be),
    .rdata      (sram42_rdata),
    .rvalid     (sram42_rvalid),
    .cfg_en     (cfg_eff.port_en[42]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[42]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[42]),
    .rd_addr    (p_rd_addr[42]),
    .rd_gnt     (p_rd_gnt[42]),
    .wr_vld     (pr_wr_vld[42]),
    .wr_addr    (p_wr_addr[42]),
    .wr_data    (p_wr_data[42][W42-1:0]),
    .wr_be      (p_wr_be[42]),
    .wr_gnt     (p_wr_gnt[42]),
    .rsp_vld    (p_rsp_vld[42]),
    .rsp_data   (p_rsp_data[42][W42-1:0]),
    .err_win_tog  (win_tog_p[42]),
    .err_ovf_tog  (ovf_tog_p[42]),
    .err_win_stky (win_stky[42]),
    .err_ovf_stky (ovf_stky[42]),
    .err_slot     (p_err_slot[42]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd42)
  );
  if (W42 < 512) begin : g_wtie42
    assign p_wr_data[42][511:W42] = '0;
  end
  end
  else begin : g_port42_off
    assign sram42_rdata = '0;
    assign sram42_rvalid = 1'b0;
    logic unused_p42;
    assign unused_p42 = &{1'b0, sram42_en, sram42_we, sram42_addr, sram42_wdata, sram42_be};
  end
  if (N > 43) begin : g_port43
  hades_sram_port #(
    .AW           (AW),
    .DW           (W43),
    .BE_EN        (BE43_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (43),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram43_en),
    .we         (sram43_we),
    .addr       (sram43_addr),
    .wdata      (sram43_wdata),
    .be         (sram43_be),
    .rdata      (sram43_rdata),
    .rvalid     (sram43_rvalid),
    .cfg_en     (cfg_eff.port_en[43]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[43]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[43]),
    .rd_addr    (p_rd_addr[43]),
    .rd_gnt     (p_rd_gnt[43]),
    .wr_vld     (pr_wr_vld[43]),
    .wr_addr    (p_wr_addr[43]),
    .wr_data    (p_wr_data[43][W43-1:0]),
    .wr_be      (p_wr_be[43]),
    .wr_gnt     (p_wr_gnt[43]),
    .rsp_vld    (p_rsp_vld[43]),
    .rsp_data   (p_rsp_data[43][W43-1:0]),
    .err_win_tog  (win_tog_p[43]),
    .err_ovf_tog  (ovf_tog_p[43]),
    .err_win_stky (win_stky[43]),
    .err_ovf_stky (ovf_stky[43]),
    .err_slot     (p_err_slot[43]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd43)
  );
  if (W43 < 512) begin : g_wtie43
    assign p_wr_data[43][511:W43] = '0;
  end
  end
  else begin : g_port43_off
    assign sram43_rdata = '0;
    assign sram43_rvalid = 1'b0;
    logic unused_p43;
    assign unused_p43 = &{1'b0, sram43_en, sram43_we, sram43_addr, sram43_wdata, sram43_be};
  end
  if (N > 44) begin : g_port44
  hades_sram_port #(
    .AW           (AW),
    .DW           (W44),
    .BE_EN        (BE44_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (44),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram44_en),
    .we         (sram44_we),
    .addr       (sram44_addr),
    .wdata      (sram44_wdata),
    .be         (sram44_be),
    .rdata      (sram44_rdata),
    .rvalid     (sram44_rvalid),
    .cfg_en     (cfg_eff.port_en[44]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[44]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[44]),
    .rd_addr    (p_rd_addr[44]),
    .rd_gnt     (p_rd_gnt[44]),
    .wr_vld     (pr_wr_vld[44]),
    .wr_addr    (p_wr_addr[44]),
    .wr_data    (p_wr_data[44][W44-1:0]),
    .wr_be      (p_wr_be[44]),
    .wr_gnt     (p_wr_gnt[44]),
    .rsp_vld    (p_rsp_vld[44]),
    .rsp_data   (p_rsp_data[44][W44-1:0]),
    .err_win_tog  (win_tog_p[44]),
    .err_ovf_tog  (ovf_tog_p[44]),
    .err_win_stky (win_stky[44]),
    .err_ovf_stky (ovf_stky[44]),
    .err_slot     (p_err_slot[44]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd44)
  );
  if (W44 < 512) begin : g_wtie44
    assign p_wr_data[44][511:W44] = '0;
  end
  end
  else begin : g_port44_off
    assign sram44_rdata = '0;
    assign sram44_rvalid = 1'b0;
    logic unused_p44;
    assign unused_p44 = &{1'b0, sram44_en, sram44_we, sram44_addr, sram44_wdata, sram44_be};
  end
  if (N > 45) begin : g_port45
  hades_sram_port #(
    .AW           (AW),
    .DW           (W45),
    .BE_EN        (BE45_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (45),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram45_en),
    .we         (sram45_we),
    .addr       (sram45_addr),
    .wdata      (sram45_wdata),
    .be         (sram45_be),
    .rdata      (sram45_rdata),
    .rvalid     (sram45_rvalid),
    .cfg_en     (cfg_eff.port_en[45]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[45]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[45]),
    .rd_addr    (p_rd_addr[45]),
    .rd_gnt     (p_rd_gnt[45]),
    .wr_vld     (pr_wr_vld[45]),
    .wr_addr    (p_wr_addr[45]),
    .wr_data    (p_wr_data[45][W45-1:0]),
    .wr_be      (p_wr_be[45]),
    .wr_gnt     (p_wr_gnt[45]),
    .rsp_vld    (p_rsp_vld[45]),
    .rsp_data   (p_rsp_data[45][W45-1:0]),
    .err_win_tog  (win_tog_p[45]),
    .err_ovf_tog  (ovf_tog_p[45]),
    .err_win_stky (win_stky[45]),
    .err_ovf_stky (ovf_stky[45]),
    .err_slot     (p_err_slot[45]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd45)
  );
  if (W45 < 512) begin : g_wtie45
    assign p_wr_data[45][511:W45] = '0;
  end
  end
  else begin : g_port45_off
    assign sram45_rdata = '0;
    assign sram45_rvalid = 1'b0;
    logic unused_p45;
    assign unused_p45 = &{1'b0, sram45_en, sram45_we, sram45_addr, sram45_wdata, sram45_be};
  end
  if (N > 46) begin : g_port46
  hades_sram_port #(
    .AW           (AW),
    .DW           (W46),
    .BE_EN        (BE46_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (46),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram46_en),
    .we         (sram46_we),
    .addr       (sram46_addr),
    .wdata      (sram46_wdata),
    .be         (sram46_be),
    .rdata      (sram46_rdata),
    .rvalid     (sram46_rvalid),
    .cfg_en     (cfg_eff.port_en[46]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[46]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[46]),
    .rd_addr    (p_rd_addr[46]),
    .rd_gnt     (p_rd_gnt[46]),
    .wr_vld     (pr_wr_vld[46]),
    .wr_addr    (p_wr_addr[46]),
    .wr_data    (p_wr_data[46][W46-1:0]),
    .wr_be      (p_wr_be[46]),
    .wr_gnt     (p_wr_gnt[46]),
    .rsp_vld    (p_rsp_vld[46]),
    .rsp_data   (p_rsp_data[46][W46-1:0]),
    .err_win_tog  (win_tog_p[46]),
    .err_ovf_tog  (ovf_tog_p[46]),
    .err_win_stky (win_stky[46]),
    .err_ovf_stky (ovf_stky[46]),
    .err_slot     (p_err_slot[46]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd46)
  );
  if (W46 < 512) begin : g_wtie46
    assign p_wr_data[46][511:W46] = '0;
  end
  end
  else begin : g_port46_off
    assign sram46_rdata = '0;
    assign sram46_rvalid = 1'b0;
    logic unused_p46;
    assign unused_p46 = &{1'b0, sram46_en, sram46_we, sram46_addr, sram46_wdata, sram46_be};
  end
  if (N > 47) begin : g_port47
  hades_sram_port #(
    .AW           (AW),
    .DW           (W47),
    .BE_EN        (BE47_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (47),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram47_en),
    .we         (sram47_we),
    .addr       (sram47_addr),
    .wdata      (sram47_wdata),
    .be         (sram47_be),
    .rdata      (sram47_rdata),
    .rvalid     (sram47_rvalid),
    .cfg_en     (cfg_eff.port_en[47]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[47]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[47]),
    .rd_addr    (p_rd_addr[47]),
    .rd_gnt     (p_rd_gnt[47]),
    .wr_vld     (pr_wr_vld[47]),
    .wr_addr    (p_wr_addr[47]),
    .wr_data    (p_wr_data[47][W47-1:0]),
    .wr_be      (p_wr_be[47]),
    .wr_gnt     (p_wr_gnt[47]),
    .rsp_vld    (p_rsp_vld[47]),
    .rsp_data   (p_rsp_data[47][W47-1:0]),
    .err_win_tog  (win_tog_p[47]),
    .err_ovf_tog  (ovf_tog_p[47]),
    .err_win_stky (win_stky[47]),
    .err_ovf_stky (ovf_stky[47]),
    .err_slot     (p_err_slot[47]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd47)
  );
  if (W47 < 512) begin : g_wtie47
    assign p_wr_data[47][511:W47] = '0;
  end
  end
  else begin : g_port47_off
    assign sram47_rdata = '0;
    assign sram47_rvalid = 1'b0;
    logic unused_p47;
    assign unused_p47 = &{1'b0, sram47_en, sram47_we, sram47_addr, sram47_wdata, sram47_be};
  end
  if (N > 48) begin : g_port48
  hades_sram_port #(
    .AW           (AW),
    .DW           (W48),
    .BE_EN        (BE48_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (48),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram48_en),
    .we         (sram48_we),
    .addr       (sram48_addr),
    .wdata      (sram48_wdata),
    .be         (sram48_be),
    .rdata      (sram48_rdata),
    .rvalid     (sram48_rvalid),
    .cfg_en     (cfg_eff.port_en[48]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[48]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[48]),
    .rd_addr    (p_rd_addr[48]),
    .rd_gnt     (p_rd_gnt[48]),
    .wr_vld     (pr_wr_vld[48]),
    .wr_addr    (p_wr_addr[48]),
    .wr_data    (p_wr_data[48][W48-1:0]),
    .wr_be      (p_wr_be[48]),
    .wr_gnt     (p_wr_gnt[48]),
    .rsp_vld    (p_rsp_vld[48]),
    .rsp_data   (p_rsp_data[48][W48-1:0]),
    .err_win_tog  (win_tog_p[48]),
    .err_ovf_tog  (ovf_tog_p[48]),
    .err_win_stky (win_stky[48]),
    .err_ovf_stky (ovf_stky[48]),
    .err_slot     (p_err_slot[48]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd48)
  );
  if (W48 < 512) begin : g_wtie48
    assign p_wr_data[48][511:W48] = '0;
  end
  end
  else begin : g_port48_off
    assign sram48_rdata = '0;
    assign sram48_rvalid = 1'b0;
    logic unused_p48;
    assign unused_p48 = &{1'b0, sram48_en, sram48_we, sram48_addr, sram48_wdata, sram48_be};
  end
  if (N > 49) begin : g_port49
  hades_sram_port #(
    .AW           (AW),
    .DW           (W49),
    .BE_EN        (BE49_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (49),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram49_en),
    .we         (sram49_we),
    .addr       (sram49_addr),
    .wdata      (sram49_wdata),
    .be         (sram49_be),
    .rdata      (sram49_rdata),
    .rvalid     (sram49_rvalid),
    .cfg_en     (cfg_eff.port_en[49]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[49]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[49]),
    .rd_addr    (p_rd_addr[49]),
    .rd_gnt     (p_rd_gnt[49]),
    .wr_vld     (pr_wr_vld[49]),
    .wr_addr    (p_wr_addr[49]),
    .wr_data    (p_wr_data[49][W49-1:0]),
    .wr_be      (p_wr_be[49]),
    .wr_gnt     (p_wr_gnt[49]),
    .rsp_vld    (p_rsp_vld[49]),
    .rsp_data   (p_rsp_data[49][W49-1:0]),
    .err_win_tog  (win_tog_p[49]),
    .err_ovf_tog  (ovf_tog_p[49]),
    .err_win_stky (win_stky[49]),
    .err_ovf_stky (ovf_stky[49]),
    .err_slot     (p_err_slot[49]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd49)
  );
  if (W49 < 512) begin : g_wtie49
    assign p_wr_data[49][511:W49] = '0;
  end
  end
  else begin : g_port49_off
    assign sram49_rdata = '0;
    assign sram49_rvalid = 1'b0;
    logic unused_p49;
    assign unused_p49 = &{1'b0, sram49_en, sram49_we, sram49_addr, sram49_wdata, sram49_be};
  end
  if (N > 50) begin : g_port50
  hades_sram_port #(
    .AW           (AW),
    .DW           (W50),
    .BE_EN        (BE50_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (50),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram50_en),
    .we         (sram50_we),
    .addr       (sram50_addr),
    .wdata      (sram50_wdata),
    .be         (sram50_be),
    .rdata      (sram50_rdata),
    .rvalid     (sram50_rvalid),
    .cfg_en     (cfg_eff.port_en[50]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[50]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[50]),
    .rd_addr    (p_rd_addr[50]),
    .rd_gnt     (p_rd_gnt[50]),
    .wr_vld     (pr_wr_vld[50]),
    .wr_addr    (p_wr_addr[50]),
    .wr_data    (p_wr_data[50][W50-1:0]),
    .wr_be      (p_wr_be[50]),
    .wr_gnt     (p_wr_gnt[50]),
    .rsp_vld    (p_rsp_vld[50]),
    .rsp_data   (p_rsp_data[50][W50-1:0]),
    .err_win_tog  (win_tog_p[50]),
    .err_ovf_tog  (ovf_tog_p[50]),
    .err_win_stky (win_stky[50]),
    .err_ovf_stky (ovf_stky[50]),
    .err_slot     (p_err_slot[50]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd50)
  );
  if (W50 < 512) begin : g_wtie50
    assign p_wr_data[50][511:W50] = '0;
  end
  end
  else begin : g_port50_off
    assign sram50_rdata = '0;
    assign sram50_rvalid = 1'b0;
    logic unused_p50;
    assign unused_p50 = &{1'b0, sram50_en, sram50_we, sram50_addr, sram50_wdata, sram50_be};
  end
  if (N > 51) begin : g_port51
  hades_sram_port #(
    .AW           (AW),
    .DW           (W51),
    .BE_EN        (BE51_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (51),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram51_en),
    .we         (sram51_we),
    .addr       (sram51_addr),
    .wdata      (sram51_wdata),
    .be         (sram51_be),
    .rdata      (sram51_rdata),
    .rvalid     (sram51_rvalid),
    .cfg_en     (cfg_eff.port_en[51]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[51]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[51]),
    .rd_addr    (p_rd_addr[51]),
    .rd_gnt     (p_rd_gnt[51]),
    .wr_vld     (pr_wr_vld[51]),
    .wr_addr    (p_wr_addr[51]),
    .wr_data    (p_wr_data[51][W51-1:0]),
    .wr_be      (p_wr_be[51]),
    .wr_gnt     (p_wr_gnt[51]),
    .rsp_vld    (p_rsp_vld[51]),
    .rsp_data   (p_rsp_data[51][W51-1:0]),
    .err_win_tog  (win_tog_p[51]),
    .err_ovf_tog  (ovf_tog_p[51]),
    .err_win_stky (win_stky[51]),
    .err_ovf_stky (ovf_stky[51]),
    .err_slot     (p_err_slot[51]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd51)
  );
  if (W51 < 512) begin : g_wtie51
    assign p_wr_data[51][511:W51] = '0;
  end
  end
  else begin : g_port51_off
    assign sram51_rdata = '0;
    assign sram51_rvalid = 1'b0;
    logic unused_p51;
    assign unused_p51 = &{1'b0, sram51_en, sram51_we, sram51_addr, sram51_wdata, sram51_be};
  end
  if (N > 52) begin : g_port52
  hades_sram_port #(
    .AW           (AW),
    .DW           (W52),
    .BE_EN        (BE52_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (52),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram52_en),
    .we         (sram52_we),
    .addr       (sram52_addr),
    .wdata      (sram52_wdata),
    .be         (sram52_be),
    .rdata      (sram52_rdata),
    .rvalid     (sram52_rvalid),
    .cfg_en     (cfg_eff.port_en[52]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[52]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[52]),
    .rd_addr    (p_rd_addr[52]),
    .rd_gnt     (p_rd_gnt[52]),
    .wr_vld     (pr_wr_vld[52]),
    .wr_addr    (p_wr_addr[52]),
    .wr_data    (p_wr_data[52][W52-1:0]),
    .wr_be      (p_wr_be[52]),
    .wr_gnt     (p_wr_gnt[52]),
    .rsp_vld    (p_rsp_vld[52]),
    .rsp_data   (p_rsp_data[52][W52-1:0]),
    .err_win_tog  (win_tog_p[52]),
    .err_ovf_tog  (ovf_tog_p[52]),
    .err_win_stky (win_stky[52]),
    .err_ovf_stky (ovf_stky[52]),
    .err_slot     (p_err_slot[52]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd52)
  );
  if (W52 < 512) begin : g_wtie52
    assign p_wr_data[52][511:W52] = '0;
  end
  end
  else begin : g_port52_off
    assign sram52_rdata = '0;
    assign sram52_rvalid = 1'b0;
    logic unused_p52;
    assign unused_p52 = &{1'b0, sram52_en, sram52_we, sram52_addr, sram52_wdata, sram52_be};
  end
  if (N > 53) begin : g_port53
  hades_sram_port #(
    .AW           (AW),
    .DW           (W53),
    .BE_EN        (BE53_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (53),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram53_en),
    .we         (sram53_we),
    .addr       (sram53_addr),
    .wdata      (sram53_wdata),
    .be         (sram53_be),
    .rdata      (sram53_rdata),
    .rvalid     (sram53_rvalid),
    .cfg_en     (cfg_eff.port_en[53]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[53]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[53]),
    .rd_addr    (p_rd_addr[53]),
    .rd_gnt     (p_rd_gnt[53]),
    .wr_vld     (pr_wr_vld[53]),
    .wr_addr    (p_wr_addr[53]),
    .wr_data    (p_wr_data[53][W53-1:0]),
    .wr_be      (p_wr_be[53]),
    .wr_gnt     (p_wr_gnt[53]),
    .rsp_vld    (p_rsp_vld[53]),
    .rsp_data   (p_rsp_data[53][W53-1:0]),
    .err_win_tog  (win_tog_p[53]),
    .err_ovf_tog  (ovf_tog_p[53]),
    .err_win_stky (win_stky[53]),
    .err_ovf_stky (ovf_stky[53]),
    .err_slot     (p_err_slot[53]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd53)
  );
  if (W53 < 512) begin : g_wtie53
    assign p_wr_data[53][511:W53] = '0;
  end
  end
  else begin : g_port53_off
    assign sram53_rdata = '0;
    assign sram53_rvalid = 1'b0;
    logic unused_p53;
    assign unused_p53 = &{1'b0, sram53_en, sram53_we, sram53_addr, sram53_wdata, sram53_be};
  end
  if (N > 54) begin : g_port54
  hades_sram_port #(
    .AW           (AW),
    .DW           (W54),
    .BE_EN        (BE54_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (54),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram54_en),
    .we         (sram54_we),
    .addr       (sram54_addr),
    .wdata      (sram54_wdata),
    .be         (sram54_be),
    .rdata      (sram54_rdata),
    .rvalid     (sram54_rvalid),
    .cfg_en     (cfg_eff.port_en[54]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[54]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[54]),
    .rd_addr    (p_rd_addr[54]),
    .rd_gnt     (p_rd_gnt[54]),
    .wr_vld     (pr_wr_vld[54]),
    .wr_addr    (p_wr_addr[54]),
    .wr_data    (p_wr_data[54][W54-1:0]),
    .wr_be      (p_wr_be[54]),
    .wr_gnt     (p_wr_gnt[54]),
    .rsp_vld    (p_rsp_vld[54]),
    .rsp_data   (p_rsp_data[54][W54-1:0]),
    .err_win_tog  (win_tog_p[54]),
    .err_ovf_tog  (ovf_tog_p[54]),
    .err_win_stky (win_stky[54]),
    .err_ovf_stky (ovf_stky[54]),
    .err_slot     (p_err_slot[54]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd54)
  );
  if (W54 < 512) begin : g_wtie54
    assign p_wr_data[54][511:W54] = '0;
  end
  end
  else begin : g_port54_off
    assign sram54_rdata = '0;
    assign sram54_rvalid = 1'b0;
    logic unused_p54;
    assign unused_p54 = &{1'b0, sram54_en, sram54_we, sram54_addr, sram54_wdata, sram54_be};
  end
  if (N > 55) begin : g_port55
  hades_sram_port #(
    .AW           (AW),
    .DW           (W55),
    .BE_EN        (BE55_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (55),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram55_en),
    .we         (sram55_we),
    .addr       (sram55_addr),
    .wdata      (sram55_wdata),
    .be         (sram55_be),
    .rdata      (sram55_rdata),
    .rvalid     (sram55_rvalid),
    .cfg_en     (cfg_eff.port_en[55]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[55]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[55]),
    .rd_addr    (p_rd_addr[55]),
    .rd_gnt     (p_rd_gnt[55]),
    .wr_vld     (pr_wr_vld[55]),
    .wr_addr    (p_wr_addr[55]),
    .wr_data    (p_wr_data[55][W55-1:0]),
    .wr_be      (p_wr_be[55]),
    .wr_gnt     (p_wr_gnt[55]),
    .rsp_vld    (p_rsp_vld[55]),
    .rsp_data   (p_rsp_data[55][W55-1:0]),
    .err_win_tog  (win_tog_p[55]),
    .err_ovf_tog  (ovf_tog_p[55]),
    .err_win_stky (win_stky[55]),
    .err_ovf_stky (ovf_stky[55]),
    .err_slot     (p_err_slot[55]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd55)
  );
  if (W55 < 512) begin : g_wtie55
    assign p_wr_data[55][511:W55] = '0;
  end
  end
  else begin : g_port55_off
    assign sram55_rdata = '0;
    assign sram55_rvalid = 1'b0;
    logic unused_p55;
    assign unused_p55 = &{1'b0, sram55_en, sram55_we, sram55_addr, sram55_wdata, sram55_be};
  end
  if (N > 56) begin : g_port56
  hades_sram_port #(
    .AW           (AW),
    .DW           (W56),
    .BE_EN        (BE56_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (56),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram56_en),
    .we         (sram56_we),
    .addr       (sram56_addr),
    .wdata      (sram56_wdata),
    .be         (sram56_be),
    .rdata      (sram56_rdata),
    .rvalid     (sram56_rvalid),
    .cfg_en     (cfg_eff.port_en[56]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[56]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[56]),
    .rd_addr    (p_rd_addr[56]),
    .rd_gnt     (p_rd_gnt[56]),
    .wr_vld     (pr_wr_vld[56]),
    .wr_addr    (p_wr_addr[56]),
    .wr_data    (p_wr_data[56][W56-1:0]),
    .wr_be      (p_wr_be[56]),
    .wr_gnt     (p_wr_gnt[56]),
    .rsp_vld    (p_rsp_vld[56]),
    .rsp_data   (p_rsp_data[56][W56-1:0]),
    .err_win_tog  (win_tog_p[56]),
    .err_ovf_tog  (ovf_tog_p[56]),
    .err_win_stky (win_stky[56]),
    .err_ovf_stky (ovf_stky[56]),
    .err_slot     (p_err_slot[56]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd56)
  );
  if (W56 < 512) begin : g_wtie56
    assign p_wr_data[56][511:W56] = '0;
  end
  end
  else begin : g_port56_off
    assign sram56_rdata = '0;
    assign sram56_rvalid = 1'b0;
    logic unused_p56;
    assign unused_p56 = &{1'b0, sram56_en, sram56_we, sram56_addr, sram56_wdata, sram56_be};
  end
  if (N > 57) begin : g_port57
  hades_sram_port #(
    .AW           (AW),
    .DW           (W57),
    .BE_EN        (BE57_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (57),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram57_en),
    .we         (sram57_we),
    .addr       (sram57_addr),
    .wdata      (sram57_wdata),
    .be         (sram57_be),
    .rdata      (sram57_rdata),
    .rvalid     (sram57_rvalid),
    .cfg_en     (cfg_eff.port_en[57]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[57]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[57]),
    .rd_addr    (p_rd_addr[57]),
    .rd_gnt     (p_rd_gnt[57]),
    .wr_vld     (pr_wr_vld[57]),
    .wr_addr    (p_wr_addr[57]),
    .wr_data    (p_wr_data[57][W57-1:0]),
    .wr_be      (p_wr_be[57]),
    .wr_gnt     (p_wr_gnt[57]),
    .rsp_vld    (p_rsp_vld[57]),
    .rsp_data   (p_rsp_data[57][W57-1:0]),
    .err_win_tog  (win_tog_p[57]),
    .err_ovf_tog  (ovf_tog_p[57]),
    .err_win_stky (win_stky[57]),
    .err_ovf_stky (ovf_stky[57]),
    .err_slot     (p_err_slot[57]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd57)
  );
  if (W57 < 512) begin : g_wtie57
    assign p_wr_data[57][511:W57] = '0;
  end
  end
  else begin : g_port57_off
    assign sram57_rdata = '0;
    assign sram57_rvalid = 1'b0;
    logic unused_p57;
    assign unused_p57 = &{1'b0, sram57_en, sram57_we, sram57_addr, sram57_wdata, sram57_be};
  end
  if (N > 58) begin : g_port58
  hades_sram_port #(
    .AW           (AW),
    .DW           (W58),
    .BE_EN        (BE58_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (58),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram58_en),
    .we         (sram58_we),
    .addr       (sram58_addr),
    .wdata      (sram58_wdata),
    .be         (sram58_be),
    .rdata      (sram58_rdata),
    .rvalid     (sram58_rvalid),
    .cfg_en     (cfg_eff.port_en[58]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[58]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[58]),
    .rd_addr    (p_rd_addr[58]),
    .rd_gnt     (p_rd_gnt[58]),
    .wr_vld     (pr_wr_vld[58]),
    .wr_addr    (p_wr_addr[58]),
    .wr_data    (p_wr_data[58][W58-1:0]),
    .wr_be      (p_wr_be[58]),
    .wr_gnt     (p_wr_gnt[58]),
    .rsp_vld    (p_rsp_vld[58]),
    .rsp_data   (p_rsp_data[58][W58-1:0]),
    .err_win_tog  (win_tog_p[58]),
    .err_ovf_tog  (ovf_tog_p[58]),
    .err_win_stky (win_stky[58]),
    .err_ovf_stky (ovf_stky[58]),
    .err_slot     (p_err_slot[58]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd58)
  );
  if (W58 < 512) begin : g_wtie58
    assign p_wr_data[58][511:W58] = '0;
  end
  end
  else begin : g_port58_off
    assign sram58_rdata = '0;
    assign sram58_rvalid = 1'b0;
    logic unused_p58;
    assign unused_p58 = &{1'b0, sram58_en, sram58_we, sram58_addr, sram58_wdata, sram58_be};
  end
  if (N > 59) begin : g_port59
  hades_sram_port #(
    .AW           (AW),
    .DW           (W59),
    .BE_EN        (BE59_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (59),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram59_en),
    .we         (sram59_we),
    .addr       (sram59_addr),
    .wdata      (sram59_wdata),
    .be         (sram59_be),
    .rdata      (sram59_rdata),
    .rvalid     (sram59_rvalid),
    .cfg_en     (cfg_eff.port_en[59]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[59]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[59]),
    .rd_addr    (p_rd_addr[59]),
    .rd_gnt     (p_rd_gnt[59]),
    .wr_vld     (pr_wr_vld[59]),
    .wr_addr    (p_wr_addr[59]),
    .wr_data    (p_wr_data[59][W59-1:0]),
    .wr_be      (p_wr_be[59]),
    .wr_gnt     (p_wr_gnt[59]),
    .rsp_vld    (p_rsp_vld[59]),
    .rsp_data   (p_rsp_data[59][W59-1:0]),
    .err_win_tog  (win_tog_p[59]),
    .err_ovf_tog  (ovf_tog_p[59]),
    .err_win_stky (win_stky[59]),
    .err_ovf_stky (ovf_stky[59]),
    .err_slot     (p_err_slot[59]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd59)
  );
  if (W59 < 512) begin : g_wtie59
    assign p_wr_data[59][511:W59] = '0;
  end
  end
  else begin : g_port59_off
    assign sram59_rdata = '0;
    assign sram59_rvalid = 1'b0;
    logic unused_p59;
    assign unused_p59 = &{1'b0, sram59_en, sram59_we, sram59_addr, sram59_wdata, sram59_be};
  end
  if (N > 60) begin : g_port60
  hades_sram_port #(
    .AW           (AW),
    .DW           (W60),
    .BE_EN        (BE60_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (60),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram60_en),
    .we         (sram60_we),
    .addr       (sram60_addr),
    .wdata      (sram60_wdata),
    .be         (sram60_be),
    .rdata      (sram60_rdata),
    .rvalid     (sram60_rvalid),
    .cfg_en     (cfg_eff.port_en[60]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[60]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[60]),
    .rd_addr    (p_rd_addr[60]),
    .rd_gnt     (p_rd_gnt[60]),
    .wr_vld     (pr_wr_vld[60]),
    .wr_addr    (p_wr_addr[60]),
    .wr_data    (p_wr_data[60][W60-1:0]),
    .wr_be      (p_wr_be[60]),
    .wr_gnt     (p_wr_gnt[60]),
    .rsp_vld    (p_rsp_vld[60]),
    .rsp_data   (p_rsp_data[60][W60-1:0]),
    .err_win_tog  (win_tog_p[60]),
    .err_ovf_tog  (ovf_tog_p[60]),
    .err_win_stky (win_stky[60]),
    .err_ovf_stky (ovf_stky[60]),
    .err_slot     (p_err_slot[60]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd60)
  );
  if (W60 < 512) begin : g_wtie60
    assign p_wr_data[60][511:W60] = '0;
  end
  end
  else begin : g_port60_off
    assign sram60_rdata = '0;
    assign sram60_rvalid = 1'b0;
    logic unused_p60;
    assign unused_p60 = &{1'b0, sram60_en, sram60_we, sram60_addr, sram60_wdata, sram60_be};
  end
  if (N > 61) begin : g_port61
  hades_sram_port #(
    .AW           (AW),
    .DW           (W61),
    .BE_EN        (BE61_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (61),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram61_en),
    .we         (sram61_we),
    .addr       (sram61_addr),
    .wdata      (sram61_wdata),
    .be         (sram61_be),
    .rdata      (sram61_rdata),
    .rvalid     (sram61_rvalid),
    .cfg_en     (cfg_eff.port_en[61]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[61]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[61]),
    .rd_addr    (p_rd_addr[61]),
    .rd_gnt     (p_rd_gnt[61]),
    .wr_vld     (pr_wr_vld[61]),
    .wr_addr    (p_wr_addr[61]),
    .wr_data    (p_wr_data[61][W61-1:0]),
    .wr_be      (p_wr_be[61]),
    .wr_gnt     (p_wr_gnt[61]),
    .rsp_vld    (p_rsp_vld[61]),
    .rsp_data   (p_rsp_data[61][W61-1:0]),
    .err_win_tog  (win_tog_p[61]),
    .err_ovf_tog  (ovf_tog_p[61]),
    .err_win_stky (win_stky[61]),
    .err_ovf_stky (ovf_stky[61]),
    .err_slot     (p_err_slot[61]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd61)
  );
  if (W61 < 512) begin : g_wtie61
    assign p_wr_data[61][511:W61] = '0;
  end
  end
  else begin : g_port61_off
    assign sram61_rdata = '0;
    assign sram61_rvalid = 1'b0;
    logic unused_p61;
    assign unused_p61 = &{1'b0, sram61_en, sram61_we, sram61_addr, sram61_wdata, sram61_be};
  end
  if (N > 62) begin : g_port62
  hades_sram_port #(
    .AW           (AW),
    .DW           (W62),
    .BE_EN        (BE62_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (62),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram62_en),
    .we         (sram62_we),
    .addr       (sram62_addr),
    .wdata      (sram62_wdata),
    .be         (sram62_be),
    .rdata      (sram62_rdata),
    .rvalid     (sram62_rvalid),
    .cfg_en     (cfg_eff.port_en[62]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[62]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[62]),
    .rd_addr    (p_rd_addr[62]),
    .rd_gnt     (p_rd_gnt[62]),
    .wr_vld     (pr_wr_vld[62]),
    .wr_addr    (p_wr_addr[62]),
    .wr_data    (p_wr_data[62][W62-1:0]),
    .wr_be      (p_wr_be[62]),
    .wr_gnt     (p_wr_gnt[62]),
    .rsp_vld    (p_rsp_vld[62]),
    .rsp_data   (p_rsp_data[62][W62-1:0]),
    .err_win_tog  (win_tog_p[62]),
    .err_ovf_tog  (ovf_tog_p[62]),
    .err_win_stky (win_stky[62]),
    .err_ovf_stky (ovf_stky[62]),
    .err_slot     (p_err_slot[62]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd62)
  );
  if (W62 < 512) begin : g_wtie62
    assign p_wr_data[62][511:W62] = '0;
  end
  end
  else begin : g_port62_off
    assign sram62_rdata = '0;
    assign sram62_rvalid = 1'b0;
    logic unused_p62;
    assign unused_p62 = &{1'b0, sram62_en, sram62_we, sram62_addr, sram62_wdata, sram62_be};
  end
  if (N > 63) begin : g_port63
  hades_sram_port #(
    .AW           (AW),
    .DW           (W63),
    .BE_EN        (BE63_EN),
    .IS_SYNC      (IS_SYNC),
    .SELFTEST_EN  (SELFTEST_EN),
    .PORT_ID      (63),
    .SELFTEST_BLK (SELFTEST_BLK)
  ) u_port (
    .port_clk   (port_clk),
    .port_rst   (port_rst_eff),
    .en         (sram63_en),
    .we         (sram63_we),
    .addr       (sram63_addr),
    .wdata      (sram63_wdata),
    .be         (sram63_be),
    .rdata      (sram63_rdata),
    .rvalid     (sram63_rvalid),
    .cfg_en     (cfg_eff.port_en[63]),
    .cfg_lat    (cfg_eff.latency),
    .enabled    (enable_eff),
    .st_run     (selftest_run),
    .err_st_tog (st_tog_p[63]),
    .ui_clk     (ui_clk),
    .ui_rst     (ui_rst_soft),
    .rd_vld     (pr_rd_vld[63]),
    .rd_addr    (p_rd_addr[63]),
    .rd_gnt     (p_rd_gnt[63]),
    .wr_vld     (pr_wr_vld[63]),
    .wr_addr    (p_wr_addr[63]),
    .wr_data    (p_wr_data[63][W63-1:0]),
    .wr_be      (p_wr_be[63]),
    .wr_gnt     (p_wr_gnt[63]),
    .rsp_vld    (p_rsp_vld[63]),
    .rsp_data   (p_rsp_data[63][W63-1:0]),
    .err_win_tog  (win_tog_p[63]),
    .err_ovf_tog  (ovf_tog_p[63]),
    .err_win_stky (win_stky[63]),
    .err_ovf_stky (ovf_stky[63]),
    .err_slot     (p_err_slot[63]),
    .err_clr      (clr_edge_p && clr_port_u == 8'd63)
  );
  if (W63 < 512) begin : g_wtie63
    assign p_wr_data[63][511:W63] = '0;
  end
  end
  else begin : g_port63_off
    assign sram63_rdata = '0;
    assign sram63_rvalid = 1'b0;
    logic unused_p63;
    assign unused_p63 = &{1'b0, sram63_en, sram63_we, sram63_addr, sram63_wdata, sram63_be};
  end

  // ------------------------------------------------------------------
  // Error-event plumbing
  //  - window/overflow records are kept per port inside hades_sram_port (sticky
  //    level for the static pin mirror + event toggle).  The toggles cross
  //    to ui_clk through sync2 + edge detect into 1-cycle pulses; ERR_STATUS
  //    bits 2/5 are set by these pulses, so a W1C clear sticks (a level
  //    source would re-set the bit until the port-side sticky is cleared).
  //  - the sticky levels cross quasi-statically for the static mirror and
  //    are cleared in place by the CSR indexed W1C clear crossing below.
  //  - slot-overflow pulses are already ui_clk-domain pulses.
  // ------------------------------------------------------------------
  logic         slot_stky_u;             // ui_clk sticky (any port's slot ovf)
  logic [N-1:0] win_lvl_u, ovf_lvl_u;   // ui_clk synced levels
  logic [N-1:0] win_dl_u, ovf_dl_u;     // ui_clk delayed (edge detect)

  wire logic [N-1:0] win_evt_u = win_lvl_u ^ win_dl_u;
  wire logic [N-1:0] ovf_evt_u = ovf_lvl_u ^ ovf_dl_u;

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      clr_tog_u  <= 1'b0;
      clr_port_u <= 8'd0;
    end else if (port_err_clr) begin
      clr_tog_u  <= ~clr_tog_u;
      clr_port_u <= port_sel;
    end
  end

  hades_sram_sync2 u_clr_sync (.clk(port_clk), .rst(port_rst), .d(clr_tog_u), .q(clr_tog_p));

  always_ff @(posedge port_clk) begin
    if (port_rst) clr_tog_pd <= 1'b0;
    else          clr_tog_pd <= clr_tog_p;
  end

  // ui_clk-domain slot-overflow sticky (cleared by any indexed W1C clear);
  // the set path is a fault-only sentinel — unreachable in legal operation
  // (the slot budget guarantees a slot is free at every response); excluded
  // from coverage with justification in sim/cov_excl.el
  always_ff @(posedge ui_clk) begin
    if (ui_rst_soft) begin
      slot_stky_u <= 1'b0;
    end else begin
      if (|p_err_slot)   slot_stky_u <= 1'b1;
      if (port_err_clr)  slot_stky_u <= 1'b0;
    end
  end

  for (genvar i = 0; i < N; i++) begin : g_err_stky
    hades_sram_sync2 u_win_evt (.clk(ui_clk), .rst(ui_rst_soft),
                           .d(win_tog_p[i]), .q(win_lvl_u[i]));
    hades_sram_sync2 u_ovf_evt (.clk(ui_clk), .rst(ui_rst_soft),
                           .d(ovf_tog_p[i]), .q(ovf_lvl_u[i]));
    always_ff @(posedge ui_clk) begin
      if (ui_rst_soft) begin
        win_dl_u[i]  <= 1'b0;
        ovf_dl_u[i]  <= 1'b0;
      end else begin
        win_dl_u[i] <= win_lvl_u[i];
        ovf_dl_u[i] <= ovf_lvl_u[i];
      end
    end
  end

  // selftest error toggles: same toggle/sync2/edge-detect scheme; the pulses
  // feed the mig_if PORT_STAT_ERR counters (blanked by evt_en via st_evt_u)
  for (genvar i = 0; i < N; i++) begin : g_st_evt
    hades_sram_sync2 u_st_evt (.clk(ui_clk), .rst(ui_rst_soft),
                          .d(st_tog_p[i]), .q(st_lvl_u[i]));
    always_ff @(posedge ui_clk) begin
      if (ui_rst_soft) st_dl_u[i] <= 1'b0;
      else             st_dl_u[i] <= st_lvl_u[i];
    end
  end

  // quasi-static views of the port_clk stickies for the ui_clk domain
  logic [N-1:0] win_stky_q, ovf_stky_q;
  for (genvar i = 0; i < N; i++) begin : g_stky_qs
    hades_sram_qs_bus #(.WIDTH(2), .DST_SYNC_STAGES(0)) u_stky_qs (
      .src_clk   (1'b0), .src_rst (1'b0),
      .src_data  ({win_stky[i], ovf_stky[i]}),
      .src_upd   (1'b1),
      .dst_clk   (1'b0), .dst_rst (1'b0),
      .dst_data  ({win_stky_q[i], ovf_stky_q[i]}),
      .dst_valid ()
    );
  end

  // first set index (for ERR_STATUS port field)
  function automatic logic [7:0] first_idx(input logic [N-1:0] v);
    logic [7:0] r;
    r = 8'd0;
    for (int i = N - 1; i >= 0; i--)
      if (v[i]) r = 8'(i);
    return r;
  endfunction

  assign win_stky_any = |win_stky_q;
  assign ovf_stky_any = |ovf_stky_q | slot_stky_u;

  // Event blanking after SOFT_RESET: the ui_clk side of the event toggles
  // resets with ui_rst_soft, but the port_clk toggles clear only after the
  // soft-reset stretch crosses (~2 target periods later); a stale pre-reset
  // toggle would otherwise re-cross as a spurious event and re-set the bit
  // the reset just cleared.  10000 ui cycles > 8192-cycle stretch + 3 slowest
  // target periods.  No legitimate violation is lost: SOFT_RESET clears
  // ENABLE, and violations require an accepted request.
  // (evt_blk / evt_en declarations are hoisted above the backend instances.)
  always_ff @(posedge ui_clk) begin
    if (ui_rst)                    evt_blk <= 14'd0;
    else if (soft_reset_stb)       evt_blk <= 14'd10000;
    else if (evt_blk != 14'd0)     evt_blk <= evt_blk - 14'd1;
  end

  always_comb begin
    err_in[0] = mig_err_illegal;
    err_in[1] = mig_err_timeout;
    err_in[2] = evt_en & ((|ovf_evt_u) | (|p_err_slot));
    err_in[3] = mig_err_slverr;
    err_in[4] = evt_en & (|win_evt_u);
    err_in_port = first_idx(win_evt_u | ovf_evt_u | p_err_slot);
    err_in_addr = 32'd0;
    if (mig_err_illegal || mig_err_slverr) begin
      err_in_port = mig_err_port;
      err_in_addr = mig_err_addr;
    end else if (mig_err_timeout) begin
      err_in_port = mig_err_port;      // timeout has no address; keep 0
    end
  end

  // ------------------------------------------------------------------
  // Refresh/ZQCS scheduler (M3).  ui_rst_soft so SOFT_RESET also clears
  // STAT_REFCNT and re-gears maintenance to the new configuration (T12).
  // ------------------------------------------------------------------
  hades_sram_refresh_sched u_refresh_sched (
    .ui_clk         (ui_clk),
    .ui_rst         (ui_rst_soft),
    .calib_done     (calib_q),
    .enable         (enable_eff),
    .engine_idle    (backend_idle && maint_fire_ok),
    .port_clk       (port_clk),
    .refresh_div    (cfg_eff.refresh_div),
    .zq_div         (cfg_eff.zq_div),
    .period_tick    (period_tick),
    .app_ref_req    (app_ref_req),
    .app_ref_ack    (ref_ack_q),
    .app_zq_req     (app_zq_req),
    .app_zq_ack     (zq_ack_q),
    .refresh_active (refresh_active),
    .zq_active      (zq_active),
    .stat_refcnt    (stat_refcnt)
  );

  // ------------------------------------------------------------------
  // consume not-yet-used inputs
  // ------------------------------------------------------------------
  logic unused;
  assign unused = &{1'b0,
                    meas_period[31] /* MEAS read by CSR only when CSR_EN */};

endmodule

`default_nettype wire
