//-----------------------------------------------------------------------------
// HADES-SRAM — SV testbench harness (M5).
// Pin-level protocol here (dual clocks, resets, AXI4-Lite BFM, SRAM port
// drivers/monitors, MIG model wiring); test intent in sim/cpp/hades_sram_tb.cpp
// via DPI-C (expected memory, exact-latency due-cycle queues, accounting).
//
// Build variants (+define+):
//   (none)                 CSR_EN=1, SYNC    TEST=all_csr
//                          (t6,t1,t2,t3,t4,t5,t7,t9,t12,rst,t13b/c/d,t13a)
//   ASYNC                  CSR_EN=1, ASYNC   TEST=all_csr (t7/t13d walk phase)
//   CSR_STATIC             CSR_EN=0, SYNC    TEST=all_static (static,t3,t9)
//   CSR_STATIC+PARAM_OVRD  CSR_EN=0, SYNC, user P_PORT_BASE/SIZE overrides
//   SELFTEST               CSR_EN=1, SYNC + SELFTEST_EN=1, BLK=16
//                          (TEST=selftest on-chip self-test smoke; the engine
//                          is inert in every other TEST — pins pass through)
// Dedicated runs (not in all_*): TEST=t3 +MAINT_STRESS=1 (worst-case
// maintenance alignment), TEST=t14 +RD_LAT_ADD=1500 (bit5 sentinel fault),
// TEST=t8 +DROP_RD_BEAT/+DROP_RD_BEAT2/+SLVERR_RD_BEAT/+SLVERR_WR_BEAT
// (error paths), TEST=ovf +AR_STALL_LEN=8000 (request-FIFO overflow),
// TEST=t10 +T10_PER=n (long regression; +WDOG_MS raises the watchdog),
// TEST=st_full +REF_BLOCK=300 (st variant; 64-port full-load selftest under
// pessimistic maintenance blocking — the A4 board scenario).
//
// Clocks: ui_clk 300 MHz.  SYNC: port_clk derived from ui_clk by integer
// divider (same-source).  ASYNC: independent realtime generator,
// incommensurate 499.983 KHz by default; T7 adds a phase walk (~4.9 deg
// steps) and +-0.5% slow drift.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_hades_top #(
  parameter int N = 64,   // DUT active ports (regression default)
  parameter int W0 = 32,
  parameter int W1 = 32,
  parameter int W2 = 32,
  parameter int W3 = 32,
  parameter int W4 = 32,
  parameter int W5 = 32,
  parameter int W6 = 32,
  parameter int W7 = 32,
  parameter int W8 = 32,
  parameter int W9 = 32,
  parameter int W10 = 32,
  parameter int W11 = 32,
  parameter int W12 = 32,
  parameter int W13 = 32,
  parameter int W14 = 32,
  parameter int W15 = 32,
  parameter int W16 = 32,
  parameter int W17 = 32,
  parameter int W18 = 32,
  parameter int W19 = 32,
  parameter int W20 = 32,
  parameter int W21 = 32,
  parameter int W22 = 32,
  parameter int W23 = 32,
  parameter int W24 = 32,
  parameter int W25 = 32,
  parameter int W26 = 32,
  parameter int W27 = 32,
  parameter int W28 = 32,
  parameter int W29 = 32,
  parameter int W30 = 32,
  parameter int W31 = 32,
  parameter int W32 = 32,
  parameter int W33 = 32,
  parameter int W34 = 32,
  parameter int W35 = 32,
  parameter int W36 = 32,
  parameter int W37 = 32,
  parameter int W38 = 32,
  parameter int W39 = 32,
  parameter int W40 = 32,
  parameter int W41 = 32,
  parameter int W42 = 32,
  parameter int W43 = 32,
  parameter int W44 = 32,
  parameter int W45 = 32,
  parameter int W46 = 32,
  parameter int W47 = 32,
  parameter int W48 = 32,
  parameter int W49 = 32,
  parameter int W50 = 32,
  parameter int W51 = 32,
  parameter int W52 = 32,
  parameter int W53 = 32,
  parameter int W54 = 32,
  parameter int W55 = 32,
  parameter int W56 = 32,
  parameter int W57 = 32,
  parameter int W58 = 32,
  parameter int W59 = 32,
  parameter int W60 = 32,
  parameter int W61 = 32,
  parameter int W62 = 32,
  parameter int W63 = 32,
  parameter bit BE0_EN = 1'b0,
  parameter bit BE1_EN = 1'b0,
  parameter bit BE2_EN = 1'b0,
  parameter bit BE3_EN = 1'b0,
  parameter bit BE4_EN = 1'b0,
  parameter bit BE5_EN = 1'b0,
  parameter bit BE6_EN = 1'b0,
  parameter bit BE7_EN = 1'b0,
  parameter bit BE8_EN = 1'b0,
  parameter bit BE9_EN = 1'b0,
  parameter bit BE10_EN = 1'b0,
  parameter bit BE11_EN = 1'b0,
  parameter bit BE12_EN = 1'b0,
  parameter bit BE13_EN = 1'b0,
  parameter bit BE14_EN = 1'b0,
  parameter bit BE15_EN = 1'b0,
  parameter bit BE16_EN = 1'b0,
  parameter bit BE17_EN = 1'b0,
  parameter bit BE18_EN = 1'b0,
  parameter bit BE19_EN = 1'b0,
  parameter bit BE20_EN = 1'b0,
  parameter bit BE21_EN = 1'b0,
  parameter bit BE22_EN = 1'b0,
  parameter bit BE23_EN = 1'b0,
  parameter bit BE24_EN = 1'b0,
  parameter bit BE25_EN = 1'b0,
  parameter bit BE26_EN = 1'b0,
  parameter bit BE27_EN = 1'b0,
  parameter bit BE28_EN = 1'b0,
  parameter bit BE29_EN = 1'b0,
  parameter bit BE30_EN = 1'b0,
  parameter bit BE31_EN = 1'b0,
  parameter bit BE32_EN = 1'b0,
  parameter bit BE33_EN = 1'b0,
  parameter bit BE34_EN = 1'b0,
  parameter bit BE35_EN = 1'b0,
  parameter bit BE36_EN = 1'b0,
  parameter bit BE37_EN = 1'b0,
  parameter bit BE38_EN = 1'b0,
  parameter bit BE39_EN = 1'b0,
  parameter bit BE40_EN = 1'b0,
  parameter bit BE41_EN = 1'b0,
  parameter bit BE42_EN = 1'b0,
  parameter bit BE43_EN = 1'b0,
  parameter bit BE44_EN = 1'b0,
  parameter bit BE45_EN = 1'b0,
  parameter bit BE46_EN = 1'b0,
  parameter bit BE47_EN = 1'b0,
  parameter bit BE48_EN = 1'b0,
  parameter bit BE49_EN = 1'b0,
  parameter bit BE50_EN = 1'b0,
  parameter bit BE51_EN = 1'b0,
  parameter bit BE52_EN = 1'b0,
  parameter bit BE53_EN = 1'b0,
  parameter bit BE54_EN = 1'b0,
  parameter bit BE55_EN = 1'b0,
  parameter bit BE56_EN = 1'b0,
  parameter bit BE57_EN = 1'b0,
  parameter bit BE58_EN = 1'b0,
  parameter bit BE59_EN = 1'b0,
  parameter bit BE60_EN = 1'b0,
  parameter bit BE61_EN = 1'b0,
  parameter bit BE62_EN = 1'b0,
  parameter bit BE63_EN = 1'b0
) ();
  import hades_sram_pkg::*;

  // ------------------------------------------------------------------
  // Build-variant parameters
  // ------------------------------------------------------------------
`ifdef CSR_STATIC
  localparam bit TB_CSR_EN = 1'b0;
`else
  localparam bit TB_CSR_EN = 1'b1;
`endif
`ifdef ASYNC
  localparam bit TB_SYNC = 1'b0;
`else
  localparam bit TB_SYNC = 1'b1;
`endif
`ifdef SELFTEST
  localparam bit TB_SELFTEST = 1'b1;
`else
  localparam bit TB_SELFTEST = 1'b0;
`endif


  // TB mirror of the DUT's per-port width parameters (v1.1.0)
  function automatic int w_of(input int p);
    case (p)
      0: return W0;
      1: return W1;
      2: return W2;
      3: return W3;
      4: return W4;
      5: return W5;
      6: return W6;
      7: return W7;
      8: return W8;
      9: return W9;
      10: return W10;
      11: return W11;
      12: return W12;
      13: return W13;
      14: return W14;
      15: return W15;
      16: return W16;
      17: return W17;
      18: return W18;
      19: return W19;
      20: return W20;
      21: return W21;
      22: return W22;
      23: return W23;
      24: return W24;
      25: return W25;
      26: return W26;
      27: return W27;
      28: return W28;
      29: return W29;
      30: return W30;
      31: return W31;
      32: return W32;
      33: return W33;
      34: return W34;
      35: return W35;
      36: return W36;
      37: return W37;
      38: return W38;
      39: return W39;
      40: return W40;
      41: return W41;
      42: return W42;
      43: return W43;
      44: return W44;
      45: return W45;
      46: return W46;
      47: return W47;
      48: return W48;
      49: return W49;
      50: return W50;
      51: return W51;
      52: return W52;
      53: return W53;
      54: return W54;
      55: return W55;
      56: return W56;
      57: return W57;
      58: return W58;
      59: return W59;
      60: return W60;
      61: return W61;
      62: return W62;
      63: return W63;
      default: return 32;
    endcase
  endfunction

  function automatic int be_of(input int p);
    case (p)
      0: return BE0_EN;
      1: return BE1_EN;
      2: return BE2_EN;
      3: return BE3_EN;
      4: return BE4_EN;
      5: return BE5_EN;
      6: return BE6_EN;
      7: return BE7_EN;
      8: return BE8_EN;
      9: return BE9_EN;
      10: return BE10_EN;
      11: return BE11_EN;
      12: return BE12_EN;
      13: return BE13_EN;
      14: return BE14_EN;
      15: return BE15_EN;
      16: return BE16_EN;
      17: return BE17_EN;
      18: return BE18_EN;
      19: return BE19_EN;
      20: return BE20_EN;
      21: return BE21_EN;
      22: return BE22_EN;
      23: return BE23_EN;
      24: return BE24_EN;
      25: return BE25_EN;
      26: return BE26_EN;
      27: return BE27_EN;
      28: return BE28_EN;
      29: return BE29_EN;
      30: return BE30_EN;
      31: return BE31_EN;
      32: return BE32_EN;
      33: return BE33_EN;
      34: return BE34_EN;
      35: return BE35_EN;
      36: return BE36_EN;
      37: return BE37_EN;
      38: return BE38_EN;
      39: return BE39_EN;
      40: return BE40_EN;
      41: return BE41_EN;
      42: return BE42_EN;
      43: return BE43_EN;
      44: return BE44_EN;
      45: return BE45_EN;
      46: return BE46_EN;
      47: return BE47_EN;
      48: return BE48_EN;
      49: return BE49_EN;
      50: return BE50_EN;
      51: return BE51_EN;
      52: return BE52_EN;
      53: return BE53_EN;
      54: return BE54_EN;
      55: return BE55_EN;
      56: return BE56_EN;
      57: return BE57_EN;
      58: return BE58_EN;
      59: return BE59_EN;
      60: return BE60_EN;
      61: return BE61_EN;
      62: return BE62_EN;
      63: return BE63_EN;
      default: return 0;
    endcase
  endfunction

  localparam logic [BASE_W-1:0] OVRD_BASE3 = 34'h1_2345_0000;
  localparam logic [31:0]       OVRD_SIZE3 = 32'h0002_0000;
  localparam logic [BASE_W-1:0] OVRD_BASE5 = 34'h0_ABCD_0000;

  function automatic logic [N_MAX*BASE_W-1:0] tb_base_flat();
    logic [N_MAX*BASE_W-1:0] v;
    v = dflt_base_flat();
`ifdef PARAM_OVRD
    v[3*BASE_W +: BASE_W] = OVRD_BASE3;
    v[5*BASE_W +: BASE_W] = OVRD_BASE5;
`endif
    return v;
  endfunction

  function automatic logic [N_MAX*32-1:0] tb_size_flat();
    logic [N_MAX*32-1:0] v;
    v = dflt_size_flat(DW_DEFAULT);
`ifdef PARAM_OVRD
    v[3*32 +: 32] = OVRD_SIZE3;
`endif
    return v;
  endfunction

  // ------------------------------------------------------------------
  // Clocks
  // ------------------------------------------------------------------
  logic ui_clk = 1'b0;
  always #(1.6666667) ui_clk = ~ui_clk;   // 300 MHz

  bit   pc_run = 1'b1;
  logic port_clk = 1'b0;

  // current gear's base half period (ns); used by the T7 phase walk/drift
  realtime gear_half_ns;
  initial gear_half_ns = 1000.034;   // 500 KHz gear (also SYNC divider base)

`ifdef ASYNC
  // independent incommensurate source: 499.983 KHz (period 2000.068 ns).
  // T7 phase walk: pc_shift_ns is a one-shot phase nudge (<= 5 deg of the
  // period per step) applied to the next half period; drift walks pc_half_ns
  // around gear_half_ns within +-0.5%.
  realtime pc_half_ns;
  realtime pc_shift_ns = 0.0;
  initial pc_half_ns = 1000.034;
  always begin : g_pclk
    realtime h;
    h = pc_half_ns + pc_shift_ns;
    pc_shift_ns = 0.0;
    #(h);
    if (pc_run) port_clk = ~port_clk;
  end
  task automatic port_clk_set_khz(input int khz);
    gear_half_ns = 500000.0 / khz;
    pc_half_ns   = gear_half_ns;
  endtask

  bit      phase_walk_en = 1'b0;
  realtime drift         = 0.0;
  int      drift_dir     = 1;
  always begin : g_walk
    repeat (3) @(posedge port_clk);
    if (phase_walk_en) begin
      pc_shift_ns = gear_half_ns * 0.049;   // ~4.9 deg step (<= 5 deg)
      if (drift_dir) drift = drift + 0.0004; else drift = drift - 0.0004;
      if (drift >  0.005) begin drift =  0.005; drift_dir = 0; end
      if (drift < -0.005) begin drift = -0.005; drift_dir = 1; end
      pc_half_ns = gear_half_ns * (1.0 + drift);
    end
  end
`else
  // SYNC: integer divider from ui_clk (same-source, like an MMCM output)
  int pc_div = 600;      // ui cycles per port period; 600 => 500 KHz
  int pc_cnt = 0;
  always @(posedge ui_clk) begin
    if (!pc_run) begin
      pc_cnt   <= 0;
      port_clk <= 1'b0;
    end else if (pc_cnt >= pc_div/2 - 1) begin
      pc_cnt   <= 0;
      port_clk <= ~port_clk;
    end else begin
      pc_cnt   <= pc_cnt + 1;
    end
  end
  task automatic port_clk_set_khz(input int khz);
    pc_div       = 300_000 / khz;
    gear_half_ns = 500000.0 / khz;
  endtask
`endif

  task automatic port_clk_stop();  begin pc_run = 1'b0; port_clk = 1'b0; end endtask
  task automatic port_clk_start(); begin pc_run = 1'b1; end endtask

  logic ui_rst_n   = 1'b0;
  logic port_rst_n = 1'b0;
  logic calib_done = 1'b0;

  // ------------------------------------------------------------------
  // DUT <-> MIG model wiring
  // ------------------------------------------------------------------
  // TB-internal packed views (runtime-indexable); the boundary assigns
  // below map them onto the DUT's flat per-port signals (v1.1.0)
  logic [N_MAX-1:0]                t_en    = '0;
  logic [N_MAX-1:0]                t_we    = '0;
  logic [N_MAX-1:0][AW_DEFAULT-1:0] t_addr  = '0;
  logic [N_MAX-1:0][511:0]         t_wdata = '0;
  logic [N_MAX-1:0][63:0]          t_be    = '1;
  logic [N_MAX-1:0][511:0]         t_rdata;
  logic [N_MAX-1:0]                t_rvalid;

  logic [15:0] s_axil_awaddr = 16'd0;
  logic        s_axil_awvalid = 1'b0;
  logic        s_axil_awready;
  logic [31:0] s_axil_wdata = 32'd0;
  logic [3:0]  s_axil_wstrb = 4'h0;
  logic        s_axil_wvalid = 1'b0;
  logic        s_axil_wready;
  logic [1:0]  s_axil_bresp;
  logic        s_axil_bvalid;
  logic        s_axil_bready = 1'b0;
  logic [15:0] s_axil_araddr = 16'd0;
  logic        s_axil_arvalid = 1'b0;
  logic        s_axil_arready;
  logic [31:0] s_axil_rdata;
  logic [1:0]  s_axil_rresp;
  logic        s_axil_rvalid;
  logic        s_axil_rready = 1'b0;

  logic        stat_calib_done, stat_ready, stat_refresh_active, stat_zq_active;
  logic [7:0]  stat_err;

  // DUT <-> model maintenance handshake
  logic        ref_req, ref_ack, zq_req, zq_ack;

  // pin-level backdoor (used in CSR_STATIC builds; tied off otherwise)
  logic                      bkp_req_t = 1'b0, bkp_we_t = 1'b0;
  logic [7:0]                bkp_port_t = 8'd0;
  logic [BASE_W-1:0]         bkp_addr_t = '0;
  logic [DW_DEFAULT-1:0]     bkp_wdata_t = '0;
  logic [DW_DEFAULT-1:0]     bkp_rdata_t;
  logic                      bkp_ack_t;

  // T14: set while fault-injected late responses are expected; gates the
  // rdata X/mismatch checks (rvalid must still assert on schedule)
  bit expect_sentinel = 1'b0;

  // DUT AXI4 master <-> model slave
  logic [3:0]         axi_awid;
  logic [AXI_ADDR_W-1:0] axi_awaddr;
  logic [7:0]         axi_awlen;
  logic [2:0]         axi_awsize;
  logic [1:0]         axi_awburst;
  logic               axi_awvalid, axi_awready;
  logic [511:0]       axi_wdata;
  logic [63:0]        axi_wstrb;
  logic               axi_wlast, axi_wvalid, axi_wready;
  logic [3:0]         axi_bid;
  logic [1:0]         axi_bresp;
  logic               axi_bvalid, axi_bready;
  logic [3:0]         axi_arid;
  logic [AXI_ADDR_W-1:0] axi_araddr;
  logic [7:0]         axi_arlen;
  logic [2:0]         axi_arsize;
  logic [1:0]         axi_arburst;
  logic               axi_arvalid, axi_arready;
  logic [3:0]         axi_rid;
  logic [511:0]       axi_rdata;
  logic [1:0]         axi_rresp;
  logic               axi_rlast, axi_rvalid, axi_rready;

  logic ui_rst;

  // flat per-port DUT signal declarations (v1.1.0)
  logic sram0_en, sram0_we;
  logic [AW_DEFAULT-1:0] sram0_addr;
  logic [W0-1:0] sram0_wdata;
  logic [63:0] sram0_be;
  logic [W0-1:0] sram0_rdata;
  logic sram0_rvalid;
  logic sram1_en, sram1_we;
  logic [AW_DEFAULT-1:0] sram1_addr;
  logic [W1-1:0] sram1_wdata;
  logic [63:0] sram1_be;
  logic [W1-1:0] sram1_rdata;
  logic sram1_rvalid;
  logic sram2_en, sram2_we;
  logic [AW_DEFAULT-1:0] sram2_addr;
  logic [W2-1:0] sram2_wdata;
  logic [63:0] sram2_be;
  logic [W2-1:0] sram2_rdata;
  logic sram2_rvalid;
  logic sram3_en, sram3_we;
  logic [AW_DEFAULT-1:0] sram3_addr;
  logic [W3-1:0] sram3_wdata;
  logic [63:0] sram3_be;
  logic [W3-1:0] sram3_rdata;
  logic sram3_rvalid;
  logic sram4_en, sram4_we;
  logic [AW_DEFAULT-1:0] sram4_addr;
  logic [W4-1:0] sram4_wdata;
  logic [63:0] sram4_be;
  logic [W4-1:0] sram4_rdata;
  logic sram4_rvalid;
  logic sram5_en, sram5_we;
  logic [AW_DEFAULT-1:0] sram5_addr;
  logic [W5-1:0] sram5_wdata;
  logic [63:0] sram5_be;
  logic [W5-1:0] sram5_rdata;
  logic sram5_rvalid;
  logic sram6_en, sram6_we;
  logic [AW_DEFAULT-1:0] sram6_addr;
  logic [W6-1:0] sram6_wdata;
  logic [63:0] sram6_be;
  logic [W6-1:0] sram6_rdata;
  logic sram6_rvalid;
  logic sram7_en, sram7_we;
  logic [AW_DEFAULT-1:0] sram7_addr;
  logic [W7-1:0] sram7_wdata;
  logic [63:0] sram7_be;
  logic [W7-1:0] sram7_rdata;
  logic sram7_rvalid;
  logic sram8_en, sram8_we;
  logic [AW_DEFAULT-1:0] sram8_addr;
  logic [W8-1:0] sram8_wdata;
  logic [63:0] sram8_be;
  logic [W8-1:0] sram8_rdata;
  logic sram8_rvalid;
  logic sram9_en, sram9_we;
  logic [AW_DEFAULT-1:0] sram9_addr;
  logic [W9-1:0] sram9_wdata;
  logic [63:0] sram9_be;
  logic [W9-1:0] sram9_rdata;
  logic sram9_rvalid;
  logic sram10_en, sram10_we;
  logic [AW_DEFAULT-1:0] sram10_addr;
  logic [W10-1:0] sram10_wdata;
  logic [63:0] sram10_be;
  logic [W10-1:0] sram10_rdata;
  logic sram10_rvalid;
  logic sram11_en, sram11_we;
  logic [AW_DEFAULT-1:0] sram11_addr;
  logic [W11-1:0] sram11_wdata;
  logic [63:0] sram11_be;
  logic [W11-1:0] sram11_rdata;
  logic sram11_rvalid;
  logic sram12_en, sram12_we;
  logic [AW_DEFAULT-1:0] sram12_addr;
  logic [W12-1:0] sram12_wdata;
  logic [63:0] sram12_be;
  logic [W12-1:0] sram12_rdata;
  logic sram12_rvalid;
  logic sram13_en, sram13_we;
  logic [AW_DEFAULT-1:0] sram13_addr;
  logic [W13-1:0] sram13_wdata;
  logic [63:0] sram13_be;
  logic [W13-1:0] sram13_rdata;
  logic sram13_rvalid;
  logic sram14_en, sram14_we;
  logic [AW_DEFAULT-1:0] sram14_addr;
  logic [W14-1:0] sram14_wdata;
  logic [63:0] sram14_be;
  logic [W14-1:0] sram14_rdata;
  logic sram14_rvalid;
  logic sram15_en, sram15_we;
  logic [AW_DEFAULT-1:0] sram15_addr;
  logic [W15-1:0] sram15_wdata;
  logic [63:0] sram15_be;
  logic [W15-1:0] sram15_rdata;
  logic sram15_rvalid;
  logic sram16_en, sram16_we;
  logic [AW_DEFAULT-1:0] sram16_addr;
  logic [W16-1:0] sram16_wdata;
  logic [63:0] sram16_be;
  logic [W16-1:0] sram16_rdata;
  logic sram16_rvalid;
  logic sram17_en, sram17_we;
  logic [AW_DEFAULT-1:0] sram17_addr;
  logic [W17-1:0] sram17_wdata;
  logic [63:0] sram17_be;
  logic [W17-1:0] sram17_rdata;
  logic sram17_rvalid;
  logic sram18_en, sram18_we;
  logic [AW_DEFAULT-1:0] sram18_addr;
  logic [W18-1:0] sram18_wdata;
  logic [63:0] sram18_be;
  logic [W18-1:0] sram18_rdata;
  logic sram18_rvalid;
  logic sram19_en, sram19_we;
  logic [AW_DEFAULT-1:0] sram19_addr;
  logic [W19-1:0] sram19_wdata;
  logic [63:0] sram19_be;
  logic [W19-1:0] sram19_rdata;
  logic sram19_rvalid;
  logic sram20_en, sram20_we;
  logic [AW_DEFAULT-1:0] sram20_addr;
  logic [W20-1:0] sram20_wdata;
  logic [63:0] sram20_be;
  logic [W20-1:0] sram20_rdata;
  logic sram20_rvalid;
  logic sram21_en, sram21_we;
  logic [AW_DEFAULT-1:0] sram21_addr;
  logic [W21-1:0] sram21_wdata;
  logic [63:0] sram21_be;
  logic [W21-1:0] sram21_rdata;
  logic sram21_rvalid;
  logic sram22_en, sram22_we;
  logic [AW_DEFAULT-1:0] sram22_addr;
  logic [W22-1:0] sram22_wdata;
  logic [63:0] sram22_be;
  logic [W22-1:0] sram22_rdata;
  logic sram22_rvalid;
  logic sram23_en, sram23_we;
  logic [AW_DEFAULT-1:0] sram23_addr;
  logic [W23-1:0] sram23_wdata;
  logic [63:0] sram23_be;
  logic [W23-1:0] sram23_rdata;
  logic sram23_rvalid;
  logic sram24_en, sram24_we;
  logic [AW_DEFAULT-1:0] sram24_addr;
  logic [W24-1:0] sram24_wdata;
  logic [63:0] sram24_be;
  logic [W24-1:0] sram24_rdata;
  logic sram24_rvalid;
  logic sram25_en, sram25_we;
  logic [AW_DEFAULT-1:0] sram25_addr;
  logic [W25-1:0] sram25_wdata;
  logic [63:0] sram25_be;
  logic [W25-1:0] sram25_rdata;
  logic sram25_rvalid;
  logic sram26_en, sram26_we;
  logic [AW_DEFAULT-1:0] sram26_addr;
  logic [W26-1:0] sram26_wdata;
  logic [63:0] sram26_be;
  logic [W26-1:0] sram26_rdata;
  logic sram26_rvalid;
  logic sram27_en, sram27_we;
  logic [AW_DEFAULT-1:0] sram27_addr;
  logic [W27-1:0] sram27_wdata;
  logic [63:0] sram27_be;
  logic [W27-1:0] sram27_rdata;
  logic sram27_rvalid;
  logic sram28_en, sram28_we;
  logic [AW_DEFAULT-1:0] sram28_addr;
  logic [W28-1:0] sram28_wdata;
  logic [63:0] sram28_be;
  logic [W28-1:0] sram28_rdata;
  logic sram28_rvalid;
  logic sram29_en, sram29_we;
  logic [AW_DEFAULT-1:0] sram29_addr;
  logic [W29-1:0] sram29_wdata;
  logic [63:0] sram29_be;
  logic [W29-1:0] sram29_rdata;
  logic sram29_rvalid;
  logic sram30_en, sram30_we;
  logic [AW_DEFAULT-1:0] sram30_addr;
  logic [W30-1:0] sram30_wdata;
  logic [63:0] sram30_be;
  logic [W30-1:0] sram30_rdata;
  logic sram30_rvalid;
  logic sram31_en, sram31_we;
  logic [AW_DEFAULT-1:0] sram31_addr;
  logic [W31-1:0] sram31_wdata;
  logic [63:0] sram31_be;
  logic [W31-1:0] sram31_rdata;
  logic sram31_rvalid;
  logic sram32_en, sram32_we;
  logic [AW_DEFAULT-1:0] sram32_addr;
  logic [W32-1:0] sram32_wdata;
  logic [63:0] sram32_be;
  logic [W32-1:0] sram32_rdata;
  logic sram32_rvalid;
  logic sram33_en, sram33_we;
  logic [AW_DEFAULT-1:0] sram33_addr;
  logic [W33-1:0] sram33_wdata;
  logic [63:0] sram33_be;
  logic [W33-1:0] sram33_rdata;
  logic sram33_rvalid;
  logic sram34_en, sram34_we;
  logic [AW_DEFAULT-1:0] sram34_addr;
  logic [W34-1:0] sram34_wdata;
  logic [63:0] sram34_be;
  logic [W34-1:0] sram34_rdata;
  logic sram34_rvalid;
  logic sram35_en, sram35_we;
  logic [AW_DEFAULT-1:0] sram35_addr;
  logic [W35-1:0] sram35_wdata;
  logic [63:0] sram35_be;
  logic [W35-1:0] sram35_rdata;
  logic sram35_rvalid;
  logic sram36_en, sram36_we;
  logic [AW_DEFAULT-1:0] sram36_addr;
  logic [W36-1:0] sram36_wdata;
  logic [63:0] sram36_be;
  logic [W36-1:0] sram36_rdata;
  logic sram36_rvalid;
  logic sram37_en, sram37_we;
  logic [AW_DEFAULT-1:0] sram37_addr;
  logic [W37-1:0] sram37_wdata;
  logic [63:0] sram37_be;
  logic [W37-1:0] sram37_rdata;
  logic sram37_rvalid;
  logic sram38_en, sram38_we;
  logic [AW_DEFAULT-1:0] sram38_addr;
  logic [W38-1:0] sram38_wdata;
  logic [63:0] sram38_be;
  logic [W38-1:0] sram38_rdata;
  logic sram38_rvalid;
  logic sram39_en, sram39_we;
  logic [AW_DEFAULT-1:0] sram39_addr;
  logic [W39-1:0] sram39_wdata;
  logic [63:0] sram39_be;
  logic [W39-1:0] sram39_rdata;
  logic sram39_rvalid;
  logic sram40_en, sram40_we;
  logic [AW_DEFAULT-1:0] sram40_addr;
  logic [W40-1:0] sram40_wdata;
  logic [63:0] sram40_be;
  logic [W40-1:0] sram40_rdata;
  logic sram40_rvalid;
  logic sram41_en, sram41_we;
  logic [AW_DEFAULT-1:0] sram41_addr;
  logic [W41-1:0] sram41_wdata;
  logic [63:0] sram41_be;
  logic [W41-1:0] sram41_rdata;
  logic sram41_rvalid;
  logic sram42_en, sram42_we;
  logic [AW_DEFAULT-1:0] sram42_addr;
  logic [W42-1:0] sram42_wdata;
  logic [63:0] sram42_be;
  logic [W42-1:0] sram42_rdata;
  logic sram42_rvalid;
  logic sram43_en, sram43_we;
  logic [AW_DEFAULT-1:0] sram43_addr;
  logic [W43-1:0] sram43_wdata;
  logic [63:0] sram43_be;
  logic [W43-1:0] sram43_rdata;
  logic sram43_rvalid;
  logic sram44_en, sram44_we;
  logic [AW_DEFAULT-1:0] sram44_addr;
  logic [W44-1:0] sram44_wdata;
  logic [63:0] sram44_be;
  logic [W44-1:0] sram44_rdata;
  logic sram44_rvalid;
  logic sram45_en, sram45_we;
  logic [AW_DEFAULT-1:0] sram45_addr;
  logic [W45-1:0] sram45_wdata;
  logic [63:0] sram45_be;
  logic [W45-1:0] sram45_rdata;
  logic sram45_rvalid;
  logic sram46_en, sram46_we;
  logic [AW_DEFAULT-1:0] sram46_addr;
  logic [W46-1:0] sram46_wdata;
  logic [63:0] sram46_be;
  logic [W46-1:0] sram46_rdata;
  logic sram46_rvalid;
  logic sram47_en, sram47_we;
  logic [AW_DEFAULT-1:0] sram47_addr;
  logic [W47-1:0] sram47_wdata;
  logic [63:0] sram47_be;
  logic [W47-1:0] sram47_rdata;
  logic sram47_rvalid;
  logic sram48_en, sram48_we;
  logic [AW_DEFAULT-1:0] sram48_addr;
  logic [W48-1:0] sram48_wdata;
  logic [63:0] sram48_be;
  logic [W48-1:0] sram48_rdata;
  logic sram48_rvalid;
  logic sram49_en, sram49_we;
  logic [AW_DEFAULT-1:0] sram49_addr;
  logic [W49-1:0] sram49_wdata;
  logic [63:0] sram49_be;
  logic [W49-1:0] sram49_rdata;
  logic sram49_rvalid;
  logic sram50_en, sram50_we;
  logic [AW_DEFAULT-1:0] sram50_addr;
  logic [W50-1:0] sram50_wdata;
  logic [63:0] sram50_be;
  logic [W50-1:0] sram50_rdata;
  logic sram50_rvalid;
  logic sram51_en, sram51_we;
  logic [AW_DEFAULT-1:0] sram51_addr;
  logic [W51-1:0] sram51_wdata;
  logic [63:0] sram51_be;
  logic [W51-1:0] sram51_rdata;
  logic sram51_rvalid;
  logic sram52_en, sram52_we;
  logic [AW_DEFAULT-1:0] sram52_addr;
  logic [W52-1:0] sram52_wdata;
  logic [63:0] sram52_be;
  logic [W52-1:0] sram52_rdata;
  logic sram52_rvalid;
  logic sram53_en, sram53_we;
  logic [AW_DEFAULT-1:0] sram53_addr;
  logic [W53-1:0] sram53_wdata;
  logic [63:0] sram53_be;
  logic [W53-1:0] sram53_rdata;
  logic sram53_rvalid;
  logic sram54_en, sram54_we;
  logic [AW_DEFAULT-1:0] sram54_addr;
  logic [W54-1:0] sram54_wdata;
  logic [63:0] sram54_be;
  logic [W54-1:0] sram54_rdata;
  logic sram54_rvalid;
  logic sram55_en, sram55_we;
  logic [AW_DEFAULT-1:0] sram55_addr;
  logic [W55-1:0] sram55_wdata;
  logic [63:0] sram55_be;
  logic [W55-1:0] sram55_rdata;
  logic sram55_rvalid;
  logic sram56_en, sram56_we;
  logic [AW_DEFAULT-1:0] sram56_addr;
  logic [W56-1:0] sram56_wdata;
  logic [63:0] sram56_be;
  logic [W56-1:0] sram56_rdata;
  logic sram56_rvalid;
  logic sram57_en, sram57_we;
  logic [AW_DEFAULT-1:0] sram57_addr;
  logic [W57-1:0] sram57_wdata;
  logic [63:0] sram57_be;
  logic [W57-1:0] sram57_rdata;
  logic sram57_rvalid;
  logic sram58_en, sram58_we;
  logic [AW_DEFAULT-1:0] sram58_addr;
  logic [W58-1:0] sram58_wdata;
  logic [63:0] sram58_be;
  logic [W58-1:0] sram58_rdata;
  logic sram58_rvalid;
  logic sram59_en, sram59_we;
  logic [AW_DEFAULT-1:0] sram59_addr;
  logic [W59-1:0] sram59_wdata;
  logic [63:0] sram59_be;
  logic [W59-1:0] sram59_rdata;
  logic sram59_rvalid;
  logic sram60_en, sram60_we;
  logic [AW_DEFAULT-1:0] sram60_addr;
  logic [W60-1:0] sram60_wdata;
  logic [63:0] sram60_be;
  logic [W60-1:0] sram60_rdata;
  logic sram60_rvalid;
  logic sram61_en, sram61_we;
  logic [AW_DEFAULT-1:0] sram61_addr;
  logic [W61-1:0] sram61_wdata;
  logic [63:0] sram61_be;
  logic [W61-1:0] sram61_rdata;
  logic sram61_rvalid;
  logic sram62_en, sram62_we;
  logic [AW_DEFAULT-1:0] sram62_addr;
  logic [W62-1:0] sram62_wdata;
  logic [63:0] sram62_be;
  logic [W62-1:0] sram62_rdata;
  logic sram62_rvalid;
  logic sram63_en, sram63_we;
  logic [AW_DEFAULT-1:0] sram63_addr;
  logic [W63-1:0] sram63_wdata;
  logic [63:0] sram63_be;
  logic [W63-1:0] sram63_rdata;
  logic sram63_rvalid;

  // ---- DUT boundary: t_* packed views <-> flat per-port signals (generated)
  assign sram0_en     = t_en[0];
  assign sram0_we     = t_we[0];
  assign sram0_addr   = t_addr[0];
  assign sram0_wdata  = t_wdata[0][W0-1:0];
  assign sram0_be     = t_be[0];
  assign t_rdata[0]   = 512'(sram0_rdata);
  assign t_rvalid[0]  = sram0_rvalid;
  assign sram1_en     = t_en[1];
  assign sram1_we     = t_we[1];
  assign sram1_addr   = t_addr[1];
  assign sram1_wdata  = t_wdata[1][W1-1:0];
  assign sram1_be     = t_be[1];
  assign t_rdata[1]   = 512'(sram1_rdata);
  assign t_rvalid[1]  = sram1_rvalid;
  assign sram2_en     = t_en[2];
  assign sram2_we     = t_we[2];
  assign sram2_addr   = t_addr[2];
  assign sram2_wdata  = t_wdata[2][W2-1:0];
  assign sram2_be     = t_be[2];
  assign t_rdata[2]   = 512'(sram2_rdata);
  assign t_rvalid[2]  = sram2_rvalid;
  assign sram3_en     = t_en[3];
  assign sram3_we     = t_we[3];
  assign sram3_addr   = t_addr[3];
  assign sram3_wdata  = t_wdata[3][W3-1:0];
  assign sram3_be     = t_be[3];
  assign t_rdata[3]   = 512'(sram3_rdata);
  assign t_rvalid[3]  = sram3_rvalid;
  assign sram4_en     = t_en[4];
  assign sram4_we     = t_we[4];
  assign sram4_addr   = t_addr[4];
  assign sram4_wdata  = t_wdata[4][W4-1:0];
  assign sram4_be     = t_be[4];
  assign t_rdata[4]   = 512'(sram4_rdata);
  assign t_rvalid[4]  = sram4_rvalid;
  assign sram5_en     = t_en[5];
  assign sram5_we     = t_we[5];
  assign sram5_addr   = t_addr[5];
  assign sram5_wdata  = t_wdata[5][W5-1:0];
  assign sram5_be     = t_be[5];
  assign t_rdata[5]   = 512'(sram5_rdata);
  assign t_rvalid[5]  = sram5_rvalid;
  assign sram6_en     = t_en[6];
  assign sram6_we     = t_we[6];
  assign sram6_addr   = t_addr[6];
  assign sram6_wdata  = t_wdata[6][W6-1:0];
  assign sram6_be     = t_be[6];
  assign t_rdata[6]   = 512'(sram6_rdata);
  assign t_rvalid[6]  = sram6_rvalid;
  assign sram7_en     = t_en[7];
  assign sram7_we     = t_we[7];
  assign sram7_addr   = t_addr[7];
  assign sram7_wdata  = t_wdata[7][W7-1:0];
  assign sram7_be     = t_be[7];
  assign t_rdata[7]   = 512'(sram7_rdata);
  assign t_rvalid[7]  = sram7_rvalid;
  assign sram8_en     = t_en[8];
  assign sram8_we     = t_we[8];
  assign sram8_addr   = t_addr[8];
  assign sram8_wdata  = t_wdata[8][W8-1:0];
  assign sram8_be     = t_be[8];
  assign t_rdata[8]   = 512'(sram8_rdata);
  assign t_rvalid[8]  = sram8_rvalid;
  assign sram9_en     = t_en[9];
  assign sram9_we     = t_we[9];
  assign sram9_addr   = t_addr[9];
  assign sram9_wdata  = t_wdata[9][W9-1:0];
  assign sram9_be     = t_be[9];
  assign t_rdata[9]   = 512'(sram9_rdata);
  assign t_rvalid[9]  = sram9_rvalid;
  assign sram10_en     = t_en[10];
  assign sram10_we     = t_we[10];
  assign sram10_addr   = t_addr[10];
  assign sram10_wdata  = t_wdata[10][W10-1:0];
  assign sram10_be     = t_be[10];
  assign t_rdata[10]   = 512'(sram10_rdata);
  assign t_rvalid[10]  = sram10_rvalid;
  assign sram11_en     = t_en[11];
  assign sram11_we     = t_we[11];
  assign sram11_addr   = t_addr[11];
  assign sram11_wdata  = t_wdata[11][W11-1:0];
  assign sram11_be     = t_be[11];
  assign t_rdata[11]   = 512'(sram11_rdata);
  assign t_rvalid[11]  = sram11_rvalid;
  assign sram12_en     = t_en[12];
  assign sram12_we     = t_we[12];
  assign sram12_addr   = t_addr[12];
  assign sram12_wdata  = t_wdata[12][W12-1:0];
  assign sram12_be     = t_be[12];
  assign t_rdata[12]   = 512'(sram12_rdata);
  assign t_rvalid[12]  = sram12_rvalid;
  assign sram13_en     = t_en[13];
  assign sram13_we     = t_we[13];
  assign sram13_addr   = t_addr[13];
  assign sram13_wdata  = t_wdata[13][W13-1:0];
  assign sram13_be     = t_be[13];
  assign t_rdata[13]   = 512'(sram13_rdata);
  assign t_rvalid[13]  = sram13_rvalid;
  assign sram14_en     = t_en[14];
  assign sram14_we     = t_we[14];
  assign sram14_addr   = t_addr[14];
  assign sram14_wdata  = t_wdata[14][W14-1:0];
  assign sram14_be     = t_be[14];
  assign t_rdata[14]   = 512'(sram14_rdata);
  assign t_rvalid[14]  = sram14_rvalid;
  assign sram15_en     = t_en[15];
  assign sram15_we     = t_we[15];
  assign sram15_addr   = t_addr[15];
  assign sram15_wdata  = t_wdata[15][W15-1:0];
  assign sram15_be     = t_be[15];
  assign t_rdata[15]   = 512'(sram15_rdata);
  assign t_rvalid[15]  = sram15_rvalid;
  assign sram16_en     = t_en[16];
  assign sram16_we     = t_we[16];
  assign sram16_addr   = t_addr[16];
  assign sram16_wdata  = t_wdata[16][W16-1:0];
  assign sram16_be     = t_be[16];
  assign t_rdata[16]   = 512'(sram16_rdata);
  assign t_rvalid[16]  = sram16_rvalid;
  assign sram17_en     = t_en[17];
  assign sram17_we     = t_we[17];
  assign sram17_addr   = t_addr[17];
  assign sram17_wdata  = t_wdata[17][W17-1:0];
  assign sram17_be     = t_be[17];
  assign t_rdata[17]   = 512'(sram17_rdata);
  assign t_rvalid[17]  = sram17_rvalid;
  assign sram18_en     = t_en[18];
  assign sram18_we     = t_we[18];
  assign sram18_addr   = t_addr[18];
  assign sram18_wdata  = t_wdata[18][W18-1:0];
  assign sram18_be     = t_be[18];
  assign t_rdata[18]   = 512'(sram18_rdata);
  assign t_rvalid[18]  = sram18_rvalid;
  assign sram19_en     = t_en[19];
  assign sram19_we     = t_we[19];
  assign sram19_addr   = t_addr[19];
  assign sram19_wdata  = t_wdata[19][W19-1:0];
  assign sram19_be     = t_be[19];
  assign t_rdata[19]   = 512'(sram19_rdata);
  assign t_rvalid[19]  = sram19_rvalid;
  assign sram20_en     = t_en[20];
  assign sram20_we     = t_we[20];
  assign sram20_addr   = t_addr[20];
  assign sram20_wdata  = t_wdata[20][W20-1:0];
  assign sram20_be     = t_be[20];
  assign t_rdata[20]   = 512'(sram20_rdata);
  assign t_rvalid[20]  = sram20_rvalid;
  assign sram21_en     = t_en[21];
  assign sram21_we     = t_we[21];
  assign sram21_addr   = t_addr[21];
  assign sram21_wdata  = t_wdata[21][W21-1:0];
  assign sram21_be     = t_be[21];
  assign t_rdata[21]   = 512'(sram21_rdata);
  assign t_rvalid[21]  = sram21_rvalid;
  assign sram22_en     = t_en[22];
  assign sram22_we     = t_we[22];
  assign sram22_addr   = t_addr[22];
  assign sram22_wdata  = t_wdata[22][W22-1:0];
  assign sram22_be     = t_be[22];
  assign t_rdata[22]   = 512'(sram22_rdata);
  assign t_rvalid[22]  = sram22_rvalid;
  assign sram23_en     = t_en[23];
  assign sram23_we     = t_we[23];
  assign sram23_addr   = t_addr[23];
  assign sram23_wdata  = t_wdata[23][W23-1:0];
  assign sram23_be     = t_be[23];
  assign t_rdata[23]   = 512'(sram23_rdata);
  assign t_rvalid[23]  = sram23_rvalid;
  assign sram24_en     = t_en[24];
  assign sram24_we     = t_we[24];
  assign sram24_addr   = t_addr[24];
  assign sram24_wdata  = t_wdata[24][W24-1:0];
  assign sram24_be     = t_be[24];
  assign t_rdata[24]   = 512'(sram24_rdata);
  assign t_rvalid[24]  = sram24_rvalid;
  assign sram25_en     = t_en[25];
  assign sram25_we     = t_we[25];
  assign sram25_addr   = t_addr[25];
  assign sram25_wdata  = t_wdata[25][W25-1:0];
  assign sram25_be     = t_be[25];
  assign t_rdata[25]   = 512'(sram25_rdata);
  assign t_rvalid[25]  = sram25_rvalid;
  assign sram26_en     = t_en[26];
  assign sram26_we     = t_we[26];
  assign sram26_addr   = t_addr[26];
  assign sram26_wdata  = t_wdata[26][W26-1:0];
  assign sram26_be     = t_be[26];
  assign t_rdata[26]   = 512'(sram26_rdata);
  assign t_rvalid[26]  = sram26_rvalid;
  assign sram27_en     = t_en[27];
  assign sram27_we     = t_we[27];
  assign sram27_addr   = t_addr[27];
  assign sram27_wdata  = t_wdata[27][W27-1:0];
  assign sram27_be     = t_be[27];
  assign t_rdata[27]   = 512'(sram27_rdata);
  assign t_rvalid[27]  = sram27_rvalid;
  assign sram28_en     = t_en[28];
  assign sram28_we     = t_we[28];
  assign sram28_addr   = t_addr[28];
  assign sram28_wdata  = t_wdata[28][W28-1:0];
  assign sram28_be     = t_be[28];
  assign t_rdata[28]   = 512'(sram28_rdata);
  assign t_rvalid[28]  = sram28_rvalid;
  assign sram29_en     = t_en[29];
  assign sram29_we     = t_we[29];
  assign sram29_addr   = t_addr[29];
  assign sram29_wdata  = t_wdata[29][W29-1:0];
  assign sram29_be     = t_be[29];
  assign t_rdata[29]   = 512'(sram29_rdata);
  assign t_rvalid[29]  = sram29_rvalid;
  assign sram30_en     = t_en[30];
  assign sram30_we     = t_we[30];
  assign sram30_addr   = t_addr[30];
  assign sram30_wdata  = t_wdata[30][W30-1:0];
  assign sram30_be     = t_be[30];
  assign t_rdata[30]   = 512'(sram30_rdata);
  assign t_rvalid[30]  = sram30_rvalid;
  assign sram31_en     = t_en[31];
  assign sram31_we     = t_we[31];
  assign sram31_addr   = t_addr[31];
  assign sram31_wdata  = t_wdata[31][W31-1:0];
  assign sram31_be     = t_be[31];
  assign t_rdata[31]   = 512'(sram31_rdata);
  assign t_rvalid[31]  = sram31_rvalid;
  assign sram32_en     = t_en[32];
  assign sram32_we     = t_we[32];
  assign sram32_addr   = t_addr[32];
  assign sram32_wdata  = t_wdata[32][W32-1:0];
  assign sram32_be     = t_be[32];
  assign t_rdata[32]   = 512'(sram32_rdata);
  assign t_rvalid[32]  = sram32_rvalid;
  assign sram33_en     = t_en[33];
  assign sram33_we     = t_we[33];
  assign sram33_addr   = t_addr[33];
  assign sram33_wdata  = t_wdata[33][W33-1:0];
  assign sram33_be     = t_be[33];
  assign t_rdata[33]   = 512'(sram33_rdata);
  assign t_rvalid[33]  = sram33_rvalid;
  assign sram34_en     = t_en[34];
  assign sram34_we     = t_we[34];
  assign sram34_addr   = t_addr[34];
  assign sram34_wdata  = t_wdata[34][W34-1:0];
  assign sram34_be     = t_be[34];
  assign t_rdata[34]   = 512'(sram34_rdata);
  assign t_rvalid[34]  = sram34_rvalid;
  assign sram35_en     = t_en[35];
  assign sram35_we     = t_we[35];
  assign sram35_addr   = t_addr[35];
  assign sram35_wdata  = t_wdata[35][W35-1:0];
  assign sram35_be     = t_be[35];
  assign t_rdata[35]   = 512'(sram35_rdata);
  assign t_rvalid[35]  = sram35_rvalid;
  assign sram36_en     = t_en[36];
  assign sram36_we     = t_we[36];
  assign sram36_addr   = t_addr[36];
  assign sram36_wdata  = t_wdata[36][W36-1:0];
  assign sram36_be     = t_be[36];
  assign t_rdata[36]   = 512'(sram36_rdata);
  assign t_rvalid[36]  = sram36_rvalid;
  assign sram37_en     = t_en[37];
  assign sram37_we     = t_we[37];
  assign sram37_addr   = t_addr[37];
  assign sram37_wdata  = t_wdata[37][W37-1:0];
  assign sram37_be     = t_be[37];
  assign t_rdata[37]   = 512'(sram37_rdata);
  assign t_rvalid[37]  = sram37_rvalid;
  assign sram38_en     = t_en[38];
  assign sram38_we     = t_we[38];
  assign sram38_addr   = t_addr[38];
  assign sram38_wdata  = t_wdata[38][W38-1:0];
  assign sram38_be     = t_be[38];
  assign t_rdata[38]   = 512'(sram38_rdata);
  assign t_rvalid[38]  = sram38_rvalid;
  assign sram39_en     = t_en[39];
  assign sram39_we     = t_we[39];
  assign sram39_addr   = t_addr[39];
  assign sram39_wdata  = t_wdata[39][W39-1:0];
  assign sram39_be     = t_be[39];
  assign t_rdata[39]   = 512'(sram39_rdata);
  assign t_rvalid[39]  = sram39_rvalid;
  assign sram40_en     = t_en[40];
  assign sram40_we     = t_we[40];
  assign sram40_addr   = t_addr[40];
  assign sram40_wdata  = t_wdata[40][W40-1:0];
  assign sram40_be     = t_be[40];
  assign t_rdata[40]   = 512'(sram40_rdata);
  assign t_rvalid[40]  = sram40_rvalid;
  assign sram41_en     = t_en[41];
  assign sram41_we     = t_we[41];
  assign sram41_addr   = t_addr[41];
  assign sram41_wdata  = t_wdata[41][W41-1:0];
  assign sram41_be     = t_be[41];
  assign t_rdata[41]   = 512'(sram41_rdata);
  assign t_rvalid[41]  = sram41_rvalid;
  assign sram42_en     = t_en[42];
  assign sram42_we     = t_we[42];
  assign sram42_addr   = t_addr[42];
  assign sram42_wdata  = t_wdata[42][W42-1:0];
  assign sram42_be     = t_be[42];
  assign t_rdata[42]   = 512'(sram42_rdata);
  assign t_rvalid[42]  = sram42_rvalid;
  assign sram43_en     = t_en[43];
  assign sram43_we     = t_we[43];
  assign sram43_addr   = t_addr[43];
  assign sram43_wdata  = t_wdata[43][W43-1:0];
  assign sram43_be     = t_be[43];
  assign t_rdata[43]   = 512'(sram43_rdata);
  assign t_rvalid[43]  = sram43_rvalid;
  assign sram44_en     = t_en[44];
  assign sram44_we     = t_we[44];
  assign sram44_addr   = t_addr[44];
  assign sram44_wdata  = t_wdata[44][W44-1:0];
  assign sram44_be     = t_be[44];
  assign t_rdata[44]   = 512'(sram44_rdata);
  assign t_rvalid[44]  = sram44_rvalid;
  assign sram45_en     = t_en[45];
  assign sram45_we     = t_we[45];
  assign sram45_addr   = t_addr[45];
  assign sram45_wdata  = t_wdata[45][W45-1:0];
  assign sram45_be     = t_be[45];
  assign t_rdata[45]   = 512'(sram45_rdata);
  assign t_rvalid[45]  = sram45_rvalid;
  assign sram46_en     = t_en[46];
  assign sram46_we     = t_we[46];
  assign sram46_addr   = t_addr[46];
  assign sram46_wdata  = t_wdata[46][W46-1:0];
  assign sram46_be     = t_be[46];
  assign t_rdata[46]   = 512'(sram46_rdata);
  assign t_rvalid[46]  = sram46_rvalid;
  assign sram47_en     = t_en[47];
  assign sram47_we     = t_we[47];
  assign sram47_addr   = t_addr[47];
  assign sram47_wdata  = t_wdata[47][W47-1:0];
  assign sram47_be     = t_be[47];
  assign t_rdata[47]   = 512'(sram47_rdata);
  assign t_rvalid[47]  = sram47_rvalid;
  assign sram48_en     = t_en[48];
  assign sram48_we     = t_we[48];
  assign sram48_addr   = t_addr[48];
  assign sram48_wdata  = t_wdata[48][W48-1:0];
  assign sram48_be     = t_be[48];
  assign t_rdata[48]   = 512'(sram48_rdata);
  assign t_rvalid[48]  = sram48_rvalid;
  assign sram49_en     = t_en[49];
  assign sram49_we     = t_we[49];
  assign sram49_addr   = t_addr[49];
  assign sram49_wdata  = t_wdata[49][W49-1:0];
  assign sram49_be     = t_be[49];
  assign t_rdata[49]   = 512'(sram49_rdata);
  assign t_rvalid[49]  = sram49_rvalid;
  assign sram50_en     = t_en[50];
  assign sram50_we     = t_we[50];
  assign sram50_addr   = t_addr[50];
  assign sram50_wdata  = t_wdata[50][W50-1:0];
  assign sram50_be     = t_be[50];
  assign t_rdata[50]   = 512'(sram50_rdata);
  assign t_rvalid[50]  = sram50_rvalid;
  assign sram51_en     = t_en[51];
  assign sram51_we     = t_we[51];
  assign sram51_addr   = t_addr[51];
  assign sram51_wdata  = t_wdata[51][W51-1:0];
  assign sram51_be     = t_be[51];
  assign t_rdata[51]   = 512'(sram51_rdata);
  assign t_rvalid[51]  = sram51_rvalid;
  assign sram52_en     = t_en[52];
  assign sram52_we     = t_we[52];
  assign sram52_addr   = t_addr[52];
  assign sram52_wdata  = t_wdata[52][W52-1:0];
  assign sram52_be     = t_be[52];
  assign t_rdata[52]   = 512'(sram52_rdata);
  assign t_rvalid[52]  = sram52_rvalid;
  assign sram53_en     = t_en[53];
  assign sram53_we     = t_we[53];
  assign sram53_addr   = t_addr[53];
  assign sram53_wdata  = t_wdata[53][W53-1:0];
  assign sram53_be     = t_be[53];
  assign t_rdata[53]   = 512'(sram53_rdata);
  assign t_rvalid[53]  = sram53_rvalid;
  assign sram54_en     = t_en[54];
  assign sram54_we     = t_we[54];
  assign sram54_addr   = t_addr[54];
  assign sram54_wdata  = t_wdata[54][W54-1:0];
  assign sram54_be     = t_be[54];
  assign t_rdata[54]   = 512'(sram54_rdata);
  assign t_rvalid[54]  = sram54_rvalid;
  assign sram55_en     = t_en[55];
  assign sram55_we     = t_we[55];
  assign sram55_addr   = t_addr[55];
  assign sram55_wdata  = t_wdata[55][W55-1:0];
  assign sram55_be     = t_be[55];
  assign t_rdata[55]   = 512'(sram55_rdata);
  assign t_rvalid[55]  = sram55_rvalid;
  assign sram56_en     = t_en[56];
  assign sram56_we     = t_we[56];
  assign sram56_addr   = t_addr[56];
  assign sram56_wdata  = t_wdata[56][W56-1:0];
  assign sram56_be     = t_be[56];
  assign t_rdata[56]   = 512'(sram56_rdata);
  assign t_rvalid[56]  = sram56_rvalid;
  assign sram57_en     = t_en[57];
  assign sram57_we     = t_we[57];
  assign sram57_addr   = t_addr[57];
  assign sram57_wdata  = t_wdata[57][W57-1:0];
  assign sram57_be     = t_be[57];
  assign t_rdata[57]   = 512'(sram57_rdata);
  assign t_rvalid[57]  = sram57_rvalid;
  assign sram58_en     = t_en[58];
  assign sram58_we     = t_we[58];
  assign sram58_addr   = t_addr[58];
  assign sram58_wdata  = t_wdata[58][W58-1:0];
  assign sram58_be     = t_be[58];
  assign t_rdata[58]   = 512'(sram58_rdata);
  assign t_rvalid[58]  = sram58_rvalid;
  assign sram59_en     = t_en[59];
  assign sram59_we     = t_we[59];
  assign sram59_addr   = t_addr[59];
  assign sram59_wdata  = t_wdata[59][W59-1:0];
  assign sram59_be     = t_be[59];
  assign t_rdata[59]   = 512'(sram59_rdata);
  assign t_rvalid[59]  = sram59_rvalid;
  assign sram60_en     = t_en[60];
  assign sram60_we     = t_we[60];
  assign sram60_addr   = t_addr[60];
  assign sram60_wdata  = t_wdata[60][W60-1:0];
  assign sram60_be     = t_be[60];
  assign t_rdata[60]   = 512'(sram60_rdata);
  assign t_rvalid[60]  = sram60_rvalid;
  assign sram61_en     = t_en[61];
  assign sram61_we     = t_we[61];
  assign sram61_addr   = t_addr[61];
  assign sram61_wdata  = t_wdata[61][W61-1:0];
  assign sram61_be     = t_be[61];
  assign t_rdata[61]   = 512'(sram61_rdata);
  assign t_rvalid[61]  = sram61_rvalid;
  assign sram62_en     = t_en[62];
  assign sram62_we     = t_we[62];
  assign sram62_addr   = t_addr[62];
  assign sram62_wdata  = t_wdata[62][W62-1:0];
  assign sram62_be     = t_be[62];
  assign t_rdata[62]   = 512'(sram62_rdata);
  assign t_rvalid[62]  = sram62_rvalid;
  assign sram63_en     = t_en[63];
  assign sram63_we     = t_we[63];
  assign sram63_addr   = t_addr[63];
  assign sram63_wdata  = t_wdata[63][W63-1:0];
  assign sram63_be     = t_be[63];
  assign t_rdata[63]   = 512'(sram63_rdata);
  assign t_rvalid[63]  = sram63_rvalid;

  hades_sram_top #(
    .N        (N),
    .AW       (AW_DEFAULT),
    .IS_SYNC  (TB_SYNC),
    .CSR_EN   (TB_CSR_EN),
    .SELFTEST_EN  (TB_SELFTEST),
    .SELFTEST_BLK (16),          // short passes: fast smoke coverage
    .P_PORT_BASE (tb_base_flat()),
    .P_PORT_SIZE (tb_size_flat()),
    .W0 (W0),
    .W1 (W1),
    .W2 (W2),
    .W3 (W3),
    .W4 (W4),
    .W5 (W5),
    .W6 (W6),
    .W7 (W7),
    .W8 (W8),
    .W9 (W9),
    .W10 (W10),
    .W11 (W11),
    .W12 (W12),
    .W13 (W13),
    .W14 (W14),
    .W15 (W15),
    .W16 (W16),
    .W17 (W17),
    .W18 (W18),
    .W19 (W19),
    .W20 (W20),
    .W21 (W21),
    .W22 (W22),
    .W23 (W23),
    .W24 (W24),
    .W25 (W25),
    .W26 (W26),
    .W27 (W27),
    .W28 (W28),
    .W29 (W29),
    .W30 (W30),
    .W31 (W31),
    .W32 (W32),
    .W33 (W33),
    .W34 (W34),
    .W35 (W35),
    .W36 (W36),
    .W37 (W37),
    .W38 (W38),
    .W39 (W39),
    .W40 (W40),
    .W41 (W41),
    .W42 (W42),
    .W43 (W43),
    .W44 (W44),
    .W45 (W45),
    .W46 (W46),
    .W47 (W47),
    .W48 (W48),
    .W49 (W49),
    .W50 (W50),
    .W51 (W51),
    .W52 (W52),
    .W53 (W53),
    .W54 (W54),
    .W55 (W55),
    .W56 (W56),
    .W57 (W57),
    .W58 (W58),
    .W59 (W59),
    .W60 (W60),
    .W61 (W61),
    .W62 (W62),
    .W63 (W63),
    .BE0_EN (BE0_EN),
    .BE1_EN (BE1_EN),
    .BE2_EN (BE2_EN),
    .BE3_EN (BE3_EN),
    .BE4_EN (BE4_EN),
    .BE5_EN (BE5_EN),
    .BE6_EN (BE6_EN),
    .BE7_EN (BE7_EN),
    .BE8_EN (BE8_EN),
    .BE9_EN (BE9_EN),
    .BE10_EN (BE10_EN),
    .BE11_EN (BE11_EN),
    .BE12_EN (BE12_EN),
    .BE13_EN (BE13_EN),
    .BE14_EN (BE14_EN),
    .BE15_EN (BE15_EN),
    .BE16_EN (BE16_EN),
    .BE17_EN (BE17_EN),
    .BE18_EN (BE18_EN),
    .BE19_EN (BE19_EN),
    .BE20_EN (BE20_EN),
    .BE21_EN (BE21_EN),
    .BE22_EN (BE22_EN),
    .BE23_EN (BE23_EN),
    .BE24_EN (BE24_EN),
    .BE25_EN (BE25_EN),
    .BE26_EN (BE26_EN),
    .BE27_EN (BE27_EN),
    .BE28_EN (BE28_EN),
    .BE29_EN (BE29_EN),
    .BE30_EN (BE30_EN),
    .BE31_EN (BE31_EN),
    .BE32_EN (BE32_EN),
    .BE33_EN (BE33_EN),
    .BE34_EN (BE34_EN),
    .BE35_EN (BE35_EN),
    .BE36_EN (BE36_EN),
    .BE37_EN (BE37_EN),
    .BE38_EN (BE38_EN),
    .BE39_EN (BE39_EN),
    .BE40_EN (BE40_EN),
    .BE41_EN (BE41_EN),
    .BE42_EN (BE42_EN),
    .BE43_EN (BE43_EN),
    .BE44_EN (BE44_EN),
    .BE45_EN (BE45_EN),
    .BE46_EN (BE46_EN),
    .BE47_EN (BE47_EN),
    .BE48_EN (BE48_EN),
    .BE49_EN (BE49_EN),
    .BE50_EN (BE50_EN),
    .BE51_EN (BE51_EN),
    .BE52_EN (BE52_EN),
    .BE53_EN (BE53_EN),
    .BE54_EN (BE54_EN),
    .BE55_EN (BE55_EN),
    .BE56_EN (BE56_EN),
    .BE57_EN (BE57_EN),
    .BE58_EN (BE58_EN),
    .BE59_EN (BE59_EN),
    .BE60_EN (BE60_EN),
    .BE61_EN (BE61_EN),
    .BE62_EN (BE62_EN),
    .BE63_EN (BE63_EN)
  ) dut (
    .ui_clk         (ui_clk),
    .ui_rst_n       (ui_rst_n),
    .port_clk       (port_clk),
    .port_rst_n     (port_rst_n),
    .calib_done     (calib_done),
    .sram0_en     (sram0_en),
    .sram0_we     (sram0_we),
    .sram0_addr   (sram0_addr),
    .sram0_wdata  (sram0_wdata),
    .sram0_be     (sram0_be),
    .sram0_rdata  (sram0_rdata),
    .sram0_rvalid (sram0_rvalid),
    .sram1_en     (sram1_en),
    .sram1_we     (sram1_we),
    .sram1_addr   (sram1_addr),
    .sram1_wdata  (sram1_wdata),
    .sram1_be     (sram1_be),
    .sram1_rdata  (sram1_rdata),
    .sram1_rvalid (sram1_rvalid),
    .sram2_en     (sram2_en),
    .sram2_we     (sram2_we),
    .sram2_addr   (sram2_addr),
    .sram2_wdata  (sram2_wdata),
    .sram2_be     (sram2_be),
    .sram2_rdata  (sram2_rdata),
    .sram2_rvalid (sram2_rvalid),
    .sram3_en     (sram3_en),
    .sram3_we     (sram3_we),
    .sram3_addr   (sram3_addr),
    .sram3_wdata  (sram3_wdata),
    .sram3_be     (sram3_be),
    .sram3_rdata  (sram3_rdata),
    .sram3_rvalid (sram3_rvalid),
    .sram4_en     (sram4_en),
    .sram4_we     (sram4_we),
    .sram4_addr   (sram4_addr),
    .sram4_wdata  (sram4_wdata),
    .sram4_be     (sram4_be),
    .sram4_rdata  (sram4_rdata),
    .sram4_rvalid (sram4_rvalid),
    .sram5_en     (sram5_en),
    .sram5_we     (sram5_we),
    .sram5_addr   (sram5_addr),
    .sram5_wdata  (sram5_wdata),
    .sram5_be     (sram5_be),
    .sram5_rdata  (sram5_rdata),
    .sram5_rvalid (sram5_rvalid),
    .sram6_en     (sram6_en),
    .sram6_we     (sram6_we),
    .sram6_addr   (sram6_addr),
    .sram6_wdata  (sram6_wdata),
    .sram6_be     (sram6_be),
    .sram6_rdata  (sram6_rdata),
    .sram6_rvalid (sram6_rvalid),
    .sram7_en     (sram7_en),
    .sram7_we     (sram7_we),
    .sram7_addr   (sram7_addr),
    .sram7_wdata  (sram7_wdata),
    .sram7_be     (sram7_be),
    .sram7_rdata  (sram7_rdata),
    .sram7_rvalid (sram7_rvalid),
    .sram8_en     (sram8_en),
    .sram8_we     (sram8_we),
    .sram8_addr   (sram8_addr),
    .sram8_wdata  (sram8_wdata),
    .sram8_be     (sram8_be),
    .sram8_rdata  (sram8_rdata),
    .sram8_rvalid (sram8_rvalid),
    .sram9_en     (sram9_en),
    .sram9_we     (sram9_we),
    .sram9_addr   (sram9_addr),
    .sram9_wdata  (sram9_wdata),
    .sram9_be     (sram9_be),
    .sram9_rdata  (sram9_rdata),
    .sram9_rvalid (sram9_rvalid),
    .sram10_en     (sram10_en),
    .sram10_we     (sram10_we),
    .sram10_addr   (sram10_addr),
    .sram10_wdata  (sram10_wdata),
    .sram10_be     (sram10_be),
    .sram10_rdata  (sram10_rdata),
    .sram10_rvalid (sram10_rvalid),
    .sram11_en     (sram11_en),
    .sram11_we     (sram11_we),
    .sram11_addr   (sram11_addr),
    .sram11_wdata  (sram11_wdata),
    .sram11_be     (sram11_be),
    .sram11_rdata  (sram11_rdata),
    .sram11_rvalid (sram11_rvalid),
    .sram12_en     (sram12_en),
    .sram12_we     (sram12_we),
    .sram12_addr   (sram12_addr),
    .sram12_wdata  (sram12_wdata),
    .sram12_be     (sram12_be),
    .sram12_rdata  (sram12_rdata),
    .sram12_rvalid (sram12_rvalid),
    .sram13_en     (sram13_en),
    .sram13_we     (sram13_we),
    .sram13_addr   (sram13_addr),
    .sram13_wdata  (sram13_wdata),
    .sram13_be     (sram13_be),
    .sram13_rdata  (sram13_rdata),
    .sram13_rvalid (sram13_rvalid),
    .sram14_en     (sram14_en),
    .sram14_we     (sram14_we),
    .sram14_addr   (sram14_addr),
    .sram14_wdata  (sram14_wdata),
    .sram14_be     (sram14_be),
    .sram14_rdata  (sram14_rdata),
    .sram14_rvalid (sram14_rvalid),
    .sram15_en     (sram15_en),
    .sram15_we     (sram15_we),
    .sram15_addr   (sram15_addr),
    .sram15_wdata  (sram15_wdata),
    .sram15_be     (sram15_be),
    .sram15_rdata  (sram15_rdata),
    .sram15_rvalid (sram15_rvalid),
    .sram16_en     (sram16_en),
    .sram16_we     (sram16_we),
    .sram16_addr   (sram16_addr),
    .sram16_wdata  (sram16_wdata),
    .sram16_be     (sram16_be),
    .sram16_rdata  (sram16_rdata),
    .sram16_rvalid (sram16_rvalid),
    .sram17_en     (sram17_en),
    .sram17_we     (sram17_we),
    .sram17_addr   (sram17_addr),
    .sram17_wdata  (sram17_wdata),
    .sram17_be     (sram17_be),
    .sram17_rdata  (sram17_rdata),
    .sram17_rvalid (sram17_rvalid),
    .sram18_en     (sram18_en),
    .sram18_we     (sram18_we),
    .sram18_addr   (sram18_addr),
    .sram18_wdata  (sram18_wdata),
    .sram18_be     (sram18_be),
    .sram18_rdata  (sram18_rdata),
    .sram18_rvalid (sram18_rvalid),
    .sram19_en     (sram19_en),
    .sram19_we     (sram19_we),
    .sram19_addr   (sram19_addr),
    .sram19_wdata  (sram19_wdata),
    .sram19_be     (sram19_be),
    .sram19_rdata  (sram19_rdata),
    .sram19_rvalid (sram19_rvalid),
    .sram20_en     (sram20_en),
    .sram20_we     (sram20_we),
    .sram20_addr   (sram20_addr),
    .sram20_wdata  (sram20_wdata),
    .sram20_be     (sram20_be),
    .sram20_rdata  (sram20_rdata),
    .sram20_rvalid (sram20_rvalid),
    .sram21_en     (sram21_en),
    .sram21_we     (sram21_we),
    .sram21_addr   (sram21_addr),
    .sram21_wdata  (sram21_wdata),
    .sram21_be     (sram21_be),
    .sram21_rdata  (sram21_rdata),
    .sram21_rvalid (sram21_rvalid),
    .sram22_en     (sram22_en),
    .sram22_we     (sram22_we),
    .sram22_addr   (sram22_addr),
    .sram22_wdata  (sram22_wdata),
    .sram22_be     (sram22_be),
    .sram22_rdata  (sram22_rdata),
    .sram22_rvalid (sram22_rvalid),
    .sram23_en     (sram23_en),
    .sram23_we     (sram23_we),
    .sram23_addr   (sram23_addr),
    .sram23_wdata  (sram23_wdata),
    .sram23_be     (sram23_be),
    .sram23_rdata  (sram23_rdata),
    .sram23_rvalid (sram23_rvalid),
    .sram24_en     (sram24_en),
    .sram24_we     (sram24_we),
    .sram24_addr   (sram24_addr),
    .sram24_wdata  (sram24_wdata),
    .sram24_be     (sram24_be),
    .sram24_rdata  (sram24_rdata),
    .sram24_rvalid (sram24_rvalid),
    .sram25_en     (sram25_en),
    .sram25_we     (sram25_we),
    .sram25_addr   (sram25_addr),
    .sram25_wdata  (sram25_wdata),
    .sram25_be     (sram25_be),
    .sram25_rdata  (sram25_rdata),
    .sram25_rvalid (sram25_rvalid),
    .sram26_en     (sram26_en),
    .sram26_we     (sram26_we),
    .sram26_addr   (sram26_addr),
    .sram26_wdata  (sram26_wdata),
    .sram26_be     (sram26_be),
    .sram26_rdata  (sram26_rdata),
    .sram26_rvalid (sram26_rvalid),
    .sram27_en     (sram27_en),
    .sram27_we     (sram27_we),
    .sram27_addr   (sram27_addr),
    .sram27_wdata  (sram27_wdata),
    .sram27_be     (sram27_be),
    .sram27_rdata  (sram27_rdata),
    .sram27_rvalid (sram27_rvalid),
    .sram28_en     (sram28_en),
    .sram28_we     (sram28_we),
    .sram28_addr   (sram28_addr),
    .sram28_wdata  (sram28_wdata),
    .sram28_be     (sram28_be),
    .sram28_rdata  (sram28_rdata),
    .sram28_rvalid (sram28_rvalid),
    .sram29_en     (sram29_en),
    .sram29_we     (sram29_we),
    .sram29_addr   (sram29_addr),
    .sram29_wdata  (sram29_wdata),
    .sram29_be     (sram29_be),
    .sram29_rdata  (sram29_rdata),
    .sram29_rvalid (sram29_rvalid),
    .sram30_en     (sram30_en),
    .sram30_we     (sram30_we),
    .sram30_addr   (sram30_addr),
    .sram30_wdata  (sram30_wdata),
    .sram30_be     (sram30_be),
    .sram30_rdata  (sram30_rdata),
    .sram30_rvalid (sram30_rvalid),
    .sram31_en     (sram31_en),
    .sram31_we     (sram31_we),
    .sram31_addr   (sram31_addr),
    .sram31_wdata  (sram31_wdata),
    .sram31_be     (sram31_be),
    .sram31_rdata  (sram31_rdata),
    .sram31_rvalid (sram31_rvalid),
    .sram32_en     (sram32_en),
    .sram32_we     (sram32_we),
    .sram32_addr   (sram32_addr),
    .sram32_wdata  (sram32_wdata),
    .sram32_be     (sram32_be),
    .sram32_rdata  (sram32_rdata),
    .sram32_rvalid (sram32_rvalid),
    .sram33_en     (sram33_en),
    .sram33_we     (sram33_we),
    .sram33_addr   (sram33_addr),
    .sram33_wdata  (sram33_wdata),
    .sram33_be     (sram33_be),
    .sram33_rdata  (sram33_rdata),
    .sram33_rvalid (sram33_rvalid),
    .sram34_en     (sram34_en),
    .sram34_we     (sram34_we),
    .sram34_addr   (sram34_addr),
    .sram34_wdata  (sram34_wdata),
    .sram34_be     (sram34_be),
    .sram34_rdata  (sram34_rdata),
    .sram34_rvalid (sram34_rvalid),
    .sram35_en     (sram35_en),
    .sram35_we     (sram35_we),
    .sram35_addr   (sram35_addr),
    .sram35_wdata  (sram35_wdata),
    .sram35_be     (sram35_be),
    .sram35_rdata  (sram35_rdata),
    .sram35_rvalid (sram35_rvalid),
    .sram36_en     (sram36_en),
    .sram36_we     (sram36_we),
    .sram36_addr   (sram36_addr),
    .sram36_wdata  (sram36_wdata),
    .sram36_be     (sram36_be),
    .sram36_rdata  (sram36_rdata),
    .sram36_rvalid (sram36_rvalid),
    .sram37_en     (sram37_en),
    .sram37_we     (sram37_we),
    .sram37_addr   (sram37_addr),
    .sram37_wdata  (sram37_wdata),
    .sram37_be     (sram37_be),
    .sram37_rdata  (sram37_rdata),
    .sram37_rvalid (sram37_rvalid),
    .sram38_en     (sram38_en),
    .sram38_we     (sram38_we),
    .sram38_addr   (sram38_addr),
    .sram38_wdata  (sram38_wdata),
    .sram38_be     (sram38_be),
    .sram38_rdata  (sram38_rdata),
    .sram38_rvalid (sram38_rvalid),
    .sram39_en     (sram39_en),
    .sram39_we     (sram39_we),
    .sram39_addr   (sram39_addr),
    .sram39_wdata  (sram39_wdata),
    .sram39_be     (sram39_be),
    .sram39_rdata  (sram39_rdata),
    .sram39_rvalid (sram39_rvalid),
    .sram40_en     (sram40_en),
    .sram40_we     (sram40_we),
    .sram40_addr   (sram40_addr),
    .sram40_wdata  (sram40_wdata),
    .sram40_be     (sram40_be),
    .sram40_rdata  (sram40_rdata),
    .sram40_rvalid (sram40_rvalid),
    .sram41_en     (sram41_en),
    .sram41_we     (sram41_we),
    .sram41_addr   (sram41_addr),
    .sram41_wdata  (sram41_wdata),
    .sram41_be     (sram41_be),
    .sram41_rdata  (sram41_rdata),
    .sram41_rvalid (sram41_rvalid),
    .sram42_en     (sram42_en),
    .sram42_we     (sram42_we),
    .sram42_addr   (sram42_addr),
    .sram42_wdata  (sram42_wdata),
    .sram42_be     (sram42_be),
    .sram42_rdata  (sram42_rdata),
    .sram42_rvalid (sram42_rvalid),
    .sram43_en     (sram43_en),
    .sram43_we     (sram43_we),
    .sram43_addr   (sram43_addr),
    .sram43_wdata  (sram43_wdata),
    .sram43_be     (sram43_be),
    .sram43_rdata  (sram43_rdata),
    .sram43_rvalid (sram43_rvalid),
    .sram44_en     (sram44_en),
    .sram44_we     (sram44_we),
    .sram44_addr   (sram44_addr),
    .sram44_wdata  (sram44_wdata),
    .sram44_be     (sram44_be),
    .sram44_rdata  (sram44_rdata),
    .sram44_rvalid (sram44_rvalid),
    .sram45_en     (sram45_en),
    .sram45_we     (sram45_we),
    .sram45_addr   (sram45_addr),
    .sram45_wdata  (sram45_wdata),
    .sram45_be     (sram45_be),
    .sram45_rdata  (sram45_rdata),
    .sram45_rvalid (sram45_rvalid),
    .sram46_en     (sram46_en),
    .sram46_we     (sram46_we),
    .sram46_addr   (sram46_addr),
    .sram46_wdata  (sram46_wdata),
    .sram46_be     (sram46_be),
    .sram46_rdata  (sram46_rdata),
    .sram46_rvalid (sram46_rvalid),
    .sram47_en     (sram47_en),
    .sram47_we     (sram47_we),
    .sram47_addr   (sram47_addr),
    .sram47_wdata  (sram47_wdata),
    .sram47_be     (sram47_be),
    .sram47_rdata  (sram47_rdata),
    .sram47_rvalid (sram47_rvalid),
    .sram48_en     (sram48_en),
    .sram48_we     (sram48_we),
    .sram48_addr   (sram48_addr),
    .sram48_wdata  (sram48_wdata),
    .sram48_be     (sram48_be),
    .sram48_rdata  (sram48_rdata),
    .sram48_rvalid (sram48_rvalid),
    .sram49_en     (sram49_en),
    .sram49_we     (sram49_we),
    .sram49_addr   (sram49_addr),
    .sram49_wdata  (sram49_wdata),
    .sram49_be     (sram49_be),
    .sram49_rdata  (sram49_rdata),
    .sram49_rvalid (sram49_rvalid),
    .sram50_en     (sram50_en),
    .sram50_we     (sram50_we),
    .sram50_addr   (sram50_addr),
    .sram50_wdata  (sram50_wdata),
    .sram50_be     (sram50_be),
    .sram50_rdata  (sram50_rdata),
    .sram50_rvalid (sram50_rvalid),
    .sram51_en     (sram51_en),
    .sram51_we     (sram51_we),
    .sram51_addr   (sram51_addr),
    .sram51_wdata  (sram51_wdata),
    .sram51_be     (sram51_be),
    .sram51_rdata  (sram51_rdata),
    .sram51_rvalid (sram51_rvalid),
    .sram52_en     (sram52_en),
    .sram52_we     (sram52_we),
    .sram52_addr   (sram52_addr),
    .sram52_wdata  (sram52_wdata),
    .sram52_be     (sram52_be),
    .sram52_rdata  (sram52_rdata),
    .sram52_rvalid (sram52_rvalid),
    .sram53_en     (sram53_en),
    .sram53_we     (sram53_we),
    .sram53_addr   (sram53_addr),
    .sram53_wdata  (sram53_wdata),
    .sram53_be     (sram53_be),
    .sram53_rdata  (sram53_rdata),
    .sram53_rvalid (sram53_rvalid),
    .sram54_en     (sram54_en),
    .sram54_we     (sram54_we),
    .sram54_addr   (sram54_addr),
    .sram54_wdata  (sram54_wdata),
    .sram54_be     (sram54_be),
    .sram54_rdata  (sram54_rdata),
    .sram54_rvalid (sram54_rvalid),
    .sram55_en     (sram55_en),
    .sram55_we     (sram55_we),
    .sram55_addr   (sram55_addr),
    .sram55_wdata  (sram55_wdata),
    .sram55_be     (sram55_be),
    .sram55_rdata  (sram55_rdata),
    .sram55_rvalid (sram55_rvalid),
    .sram56_en     (sram56_en),
    .sram56_we     (sram56_we),
    .sram56_addr   (sram56_addr),
    .sram56_wdata  (sram56_wdata),
    .sram56_be     (sram56_be),
    .sram56_rdata  (sram56_rdata),
    .sram56_rvalid (sram56_rvalid),
    .sram57_en     (sram57_en),
    .sram57_we     (sram57_we),
    .sram57_addr   (sram57_addr),
    .sram57_wdata  (sram57_wdata),
    .sram57_be     (sram57_be),
    .sram57_rdata  (sram57_rdata),
    .sram57_rvalid (sram57_rvalid),
    .sram58_en     (sram58_en),
    .sram58_we     (sram58_we),
    .sram58_addr   (sram58_addr),
    .sram58_wdata  (sram58_wdata),
    .sram58_be     (sram58_be),
    .sram58_rdata  (sram58_rdata),
    .sram58_rvalid (sram58_rvalid),
    .sram59_en     (sram59_en),
    .sram59_we     (sram59_we),
    .sram59_addr   (sram59_addr),
    .sram59_wdata  (sram59_wdata),
    .sram59_be     (sram59_be),
    .sram59_rdata  (sram59_rdata),
    .sram59_rvalid (sram59_rvalid),
    .sram60_en     (sram60_en),
    .sram60_we     (sram60_we),
    .sram60_addr   (sram60_addr),
    .sram60_wdata  (sram60_wdata),
    .sram60_be     (sram60_be),
    .sram60_rdata  (sram60_rdata),
    .sram60_rvalid (sram60_rvalid),
    .sram61_en     (sram61_en),
    .sram61_we     (sram61_we),
    .sram61_addr   (sram61_addr),
    .sram61_wdata  (sram61_wdata),
    .sram61_be     (sram61_be),
    .sram61_rdata  (sram61_rdata),
    .sram61_rvalid (sram61_rvalid),
    .sram62_en     (sram62_en),
    .sram62_we     (sram62_we),
    .sram62_addr   (sram62_addr),
    .sram62_wdata  (sram62_wdata),
    .sram62_be     (sram62_be),
    .sram62_rdata  (sram62_rdata),
    .sram62_rvalid (sram62_rvalid),
    .sram63_en     (sram63_en),
    .sram63_we     (sram63_we),
    .sram63_addr   (sram63_addr),
    .sram63_wdata  (sram63_wdata),
    .sram63_be     (sram63_be),
    .sram63_rdata  (sram63_rdata),
    .sram63_rvalid (sram63_rvalid),

    .m_axi_awid     (axi_awid),
    .m_axi_awaddr   (axi_awaddr),
    .m_axi_awlen    (axi_awlen),
    .m_axi_awsize   (axi_awsize),
    .m_axi_awburst  (axi_awburst),
    .m_axi_awvalid  (axi_awvalid),
    .m_axi_awready  (axi_awready),
    .m_axi_wdata    (axi_wdata),
    .m_axi_wstrb    (axi_wstrb),
    .m_axi_wlast    (axi_wlast),
    .m_axi_wvalid   (axi_wvalid),
    .m_axi_wready   (axi_wready),
    .m_axi_bid      (axi_bid),
    .m_axi_bresp    (axi_bresp),
    .m_axi_bvalid   (axi_bvalid),
    .m_axi_bready   (axi_bready),
    .m_axi_arid     (axi_arid),
    .m_axi_araddr   (axi_araddr),
    .m_axi_arlen    (axi_arlen),
    .m_axi_arsize   (axi_arsize),
    .m_axi_arburst  (axi_arburst),
    .m_axi_arvalid  (axi_arvalid),
    .m_axi_arready  (axi_arready),
    .m_axi_rid      (axi_rid),
    .m_axi_rdata    (axi_rdata),
    .m_axi_rresp    (axi_rresp),
    .m_axi_rlast    (axi_rlast),
    .m_axi_rvalid   (axi_rvalid),
    .m_axi_rready   (axi_rready),
    .app_ref_req    (ref_req),
    .app_ref_ack    (ref_ack),
    .app_zq_req     (zq_req),
    .app_zq_ack     (zq_ack),
    .s_axil_awaddr  (s_axil_awaddr),
    .s_axil_awvalid (s_axil_awvalid),
    .s_axil_awready (s_axil_awready),
    .s_axil_wdata   (s_axil_wdata),
    .s_axil_wstrb   (s_axil_wstrb),
    .s_axil_wvalid  (s_axil_wvalid),
    .s_axil_wready  (s_axil_wready),
    .s_axil_bresp   (s_axil_bresp),
    .s_axil_bvalid  (s_axil_bvalid),
    .s_axil_bready  (s_axil_bready),
    .s_axil_araddr  (s_axil_araddr),
    .s_axil_arvalid (s_axil_arvalid),
    .s_axil_arready (s_axil_arready),
    .s_axil_rdata   (s_axil_rdata),
    .s_axil_rresp   (s_axil_rresp),
    .s_axil_rvalid  (s_axil_rvalid),
    .s_axil_rready  (s_axil_rready),
    .stat_calib_done    (stat_calib_done),
    .stat_ready         (stat_ready),
    .stat_refresh_active(stat_refresh_active),
    .stat_zq_active     (stat_zq_active),
    .stat_err           (stat_err),
    .bkp_req    (bkp_req_t),
    .bkp_we     (bkp_we_t),
    .bkp_port   (bkp_port_t),
    .bkp_addr   (bkp_addr_t),
    .bkp_wdata  (bkp_wdata_t),
    .bkp_rdata  (bkp_rdata_t),
    .bkp_ack    (bkp_ack_t)
  );

  assign ui_rst = ~ui_rst_n;

  mig_axi4_model u_mig_model (
    .aclk          (ui_clk),
    .arst          (ui_rst),
    .s_axi_awid    (axi_awid),
    .s_axi_awaddr  (axi_awaddr),
    .s_axi_awlen   (axi_awlen),
    .s_axi_awsize  (axi_awsize),
    .s_axi_awburst (axi_awburst),
    .s_axi_awvalid (axi_awvalid),
    .s_axi_awready (axi_awready),
    .s_axi_wdata   (axi_wdata),
    .s_axi_wstrb   (axi_wstrb),
    .s_axi_wlast   (axi_wlast),
    .s_axi_wvalid  (axi_wvalid),
    .s_axi_wready  (axi_wready),
    .s_axi_bid     (axi_bid),
    .s_axi_bresp   (axi_bresp),
    .s_axi_bvalid  (axi_bvalid),
    .s_axi_bready  (axi_bready),
    .s_axi_arid    (axi_arid),
    .s_axi_araddr  (axi_araddr),
    .s_axi_arlen   (axi_arlen),
    .s_axi_arsize  (axi_arsize),
    .s_axi_arburst (axi_arburst),
    .s_axi_arvalid (axi_arvalid),
    .s_axi_arready (axi_arready),
    .s_axi_rid     (axi_rid),
    .s_axi_rdata   (axi_rdata),
    .s_axi_rresp   (axi_rresp),
    .s_axi_rlast   (axi_rlast),
    .s_axi_rvalid  (axi_rvalid),
    .s_axi_rready  (axi_rready),
    .app_ref_req   (ref_req),
    .app_ref_ack   (ref_ack),
    .app_zq_req    (zq_req),
    .app_zq_ack    (zq_ack)
  );

  // ------------------------------------------------------------------
  // DPI-C imports
  // ------------------------------------------------------------------
  import "DPI-C" context function void     hades_init();
  import "DPI-C" context function void     hades_phase_init();
  import "DPI-C" context function void     hades_suspend_checks(int on);
  import "DPI-C" context function longint  hades_exp_id();
  import "DPI-C" context function longint  hades_exp_params(int is_sync, int ui_mhz,
                                                           int port_mib, int dw, int n_max);
  import "DPI-C" context function void     hades_set_port_cfg(int port, longint base, int size);
  import "DPI-C" context function void     hades_set_port_width(int port, int bits);
  import "DPI-C" context function longint  hades_exp_base(int port);
  import "DPI-C" context function int      hades_exp_size(int port);
  import "DPI-C" context function void     hades_mem_write(int port, int addr, bit [511:0] data);
  import "DPI-C" context function void     hades_mem_write_be(int port, int addr, bit [511:0] data, longint be);
  import "DPI-C" context function void     hades_read_expect(int port, longint due_cycle, int addr);
  import "DPI-C" context function void     hades_read_expect0(int port, longint due_cycle);
  import "DPI-C" context function void     hades_read_expect_late(int port, longint due_cycle);
  import "DPI-C" context function void     hades_port_edge(int port, longint cycle,
                                                           int rvalid, bit [511:0] rdata);
  import "DPI-C" context function void     hades_check_eq(string what, longint got, longint exp);
  import "DPI-C" context function void     hades_check_range(string what, longint got,
                                                             longint lo, longint hi);
  import "DPI-C" context function void     hades_fail(string msg);
  import "DPI-C" context function void     hades_log(string msg);
  import "DPI-C" context function int      hades_err_count();
  import "DPI-C" context function void     hades_report();

  // ------------------------------------------------------------------
  // portable PRNG (xorshift32) — identical stimulus on VCS and xsim
  // ------------------------------------------------------------------
  logic [31:0] rng_s = 32'h5EED_1234;

  task automatic rnd(input int unsigned lo, input int unsigned hi,
                     output int unsigned v);
    logic [31:0] x;
    begin
      x = rng_s;
      x ^= x << 13; x ^= x >> 17; x ^= x << 5;
      rng_s = x;
      v = lo + (x % (hi - lo + 1));
    end
  endtask

  // ------------------------------------------------------------------
  // AXI4-Lite master BFM (ui_clk domain)
  // ------------------------------------------------------------------
  task automatic axil_wr(input logic [15:0] a, input logic [31:0] d);
    @(posedge ui_clk);
    s_axil_awaddr  <= a;
    s_axil_awvalid <= 1'b1;
    s_axil_wdata   <= d;
    s_axil_wstrb   <= 4'hF;
    s_axil_wvalid  <= 1'b1;
    forever begin
      @(posedge ui_clk);
      if (s_axil_awready && s_axil_wready) break;
    end
    s_axil_awvalid <= 1'b0;
    s_axil_wvalid  <= 1'b0;
    s_axil_bready  <= 1'b1;
    forever begin
      @(posedge ui_clk);
      if (s_axil_bvalid) break;
    end
    s_axil_bready <= 1'b0;
  endtask

  task automatic axil_rd(input logic [15:0] a, output logic [31:0] d);
    @(posedge ui_clk);
    s_axil_araddr  <= a;
    s_axil_arvalid <= 1'b1;
    s_axil_rready  <= 1'b1;
    forever begin
      @(posedge ui_clk);
      if (s_axil_arready) break;
    end
    s_axil_arvalid <= 1'b0;
    forever begin
      @(posedge ui_clk);
      if (s_axil_rvalid) begin
        d = s_axil_rdata;
        break;
      end
    end
    s_axil_rready <= 1'b0;
  endtask

  // ------------------------------------------------------------------
  // port_clk edge counter + response monitor (exact-latency checking)
  // ------------------------------------------------------------------
  longint pcycle = 0;

  always @(posedge port_clk) begin
    #(0.001);   // 1 ps after the edge: post-NBA sample
    pcycle = pcycle + 1;
    for (int p = 0; p < N_MAX; p++) begin
      if ($isunknown(t_rvalid[p]) ||
          (!expect_sentinel && t_rvalid[p] === 1'b1 && $isunknown(t_rdata[p])))
        hades_fail($sformatf("X on port %0d outputs at pcycle %0d (rvalid=%b rdata=%h)",
                             p, pcycle, t_rvalid[p], t_rdata[p]));
      hades_port_edge(p, pcycle, (t_rvalid[p] === 1'b1) ? 1 : 0,
                      t_rdata[p]);
    end
  end

  // ------------------------------------------------------------------
  // SRAM port drivers (drive at negedge; sampled at next posedge = pcycle+1)
  // ------------------------------------------------------------------
  int cur_lat = 2;   // TB's view of the active L

  task automatic sram_write(input int port, input int addr, input bit [511:0] data);
    @(negedge port_clk);
    t_en[port]    <= 1'b1;
    t_we[port]    <= 1'b1;
    t_addr[port]  <= addr;
    t_wdata[port] <= data;
    hades_mem_write(port, addr, data);
    @(negedge port_clk);
    t_en[port]    <= 1'b0;
  endtask

  // byte-enabled write (v1.1.0): drives t_be with the word (ports with
  // BE<i>_EN=0 ignore it) and merges enabled bytes in the expected model
  task automatic sram_write_be(input int port, input int addr,
                               input bit [511:0] data, input bit [63:0] be);
    @(negedge port_clk);
    t_en[port]    <= 1'b1;
    t_we[port]    <= 1'b1;
    t_addr[port]  <= addr;
    t_wdata[port] <= data;
    t_be[port]    <= be;
    hades_mem_write_be(port, addr, data, be);
    @(negedge port_clk);
    t_en[port]    <= 1'b0;
    t_be[port]    <= '1;
  endtask

  task automatic sram_read(input int port, input int addr);
    @(negedge port_clk);
    t_en[port]    <= 1'b1;
    t_we[port]    <= 1'b0;
    t_addr[port]  <= addr;
    hades_read_expect(port, pcycle + 1 + cur_lat, addr);
    @(negedge port_clk);
    t_en[port]    <= 1'b0;
  endtask

  // fully back-to-back read burst (one read every port period)
  task automatic sram_read_burst(input int port, input int n, input int addr0);
    for (int k = 0; k < n; k++) begin
      @(negedge port_clk);
      t_en[port]   <= 1'b1;
      t_we[port]   <= 1'b0;
      t_addr[port] <= addr0 + k;
      hades_read_expect(port, pcycle + 1 + cur_lat, addr0 + k);
    end
    @(negedge port_clk);
    t_en[port] <= 1'b0;
  endtask

  // fully back-to-back write burst
  task automatic sram_write_burst(input int port, input int n, input int addr0,
                                  input bit [511:0] data0);
    for (int k = 0; k < n; k++) begin
      @(negedge port_clk);
      t_en[port]   <= 1'b1;
      t_we[port]   <= 1'b1;
      t_addr[port] <= addr0 + k;
      t_wdata[port] <= data0 + k;
      hades_mem_write(port, addr0 + k, data0 + k);
    end
    @(negedge port_clk);
    t_en[port] <= 1'b0;
  endtask

  // read to an illegal address: synthetic zero response, still on schedule
  task automatic sram_read_illegal(input int port, input int addr);
    @(negedge port_clk);
    t_en[port]    <= 1'b1;
    t_we[port]    <= 1'b0;
    t_addr[port]  <= addr;
    hades_read_expect0(port, pcycle + 1 + cur_lat);
    @(negedge port_clk);
    t_en[port]    <= 1'b0;
  endtask

  // let all outstanding reads release
  task automatic drain();
    repeat (5) @(negedge port_clk);
  endtask

  // ------------------------------------------------------------------
  // Reset.  Resets must be held for >= 3 port_clk periods: the port domain
  // (FIFOs, shaper) is synchronous to the slow clock, and the afifo's two
  // sides must reset together — a ui-only pulse would corrupt the Gray
  // pointers.  (The CSR SOFT_RESET instead stretches into the port domain
  // by design; see the top level.)  calib_done drops (the TB models the
  // MIG recalibrating across a system reset).
  // ------------------------------------------------------------------
  task automatic do_reset();
    begin
      ui_rst_n   = 1'b0;
      port_rst_n = 1'b0;
      calib_done = 1'b0;
      repeat (3) @(posedge port_clk);
      ui_rst_n   = 1'b1;
      port_rst_n = 1'b1;
      repeat (10) @(posedge ui_clk);
    end
  endtask

  // Default flat address map for all ports.  T6 writes a custom map and T1
  // shrinks PORT_SIZE for error tests — every traffic phase must start from
  // the default flat map.
  task automatic csr_default_map();
    begin
      for (int p = 0; p < N_MAX; p++) begin
        axil_wr(CSR_PORT_SEL, 32'(p));
        axil_wr(CSR_PORT_BASE, 32'(p * 32'h0004_0000));  // i * 2^18 beats
        axil_wr(CSR_PORT_BASE_HI, 32'd0);
        axil_wr(CSR_PORT_SIZE, 32'h0040_0000);           // 16 MiB in DW32 words
      end
    end
  endtask

  // CSR helper: program L and enable mask, wait for ready.
  // The frequency monitor must observe a running, legal port_clk first
  // (spec init sequence: check MEAS_PERIOD before ENABLE; 4-period average
  // is valid after 5 edges).  n_active programs CFG_PORTS (arbiter
  // slot-table extent).
  task automatic csr_enable(input int lat, input longint en_mask,
                            input int n_active = N_MAX);
    logic [31:0] rd;
    begin
      axil_wr(CSR_CTRL, 32'h0);
      axil_wr(CSR_CFG_LATENCY, 32'(lat));
      axil_wr(CSR_PORT_EN_LO, 32'(en_mask));
      axil_wr(CSR_PORT_EN_HI, 32'(en_mask >> 32));
      axil_wr(CSR_CFG_PORTS, 32'(n_active));
      csr_default_map();
      repeat (6) @(posedge port_clk);   // let freq_mon measure the clock
      axil_wr(CSR_CTRL, 32'h1);
      // poll READY: after a SOFT_RESET the port-domain reset stretch gates
      // ENABLE for ~9.4k ui_clk cycles; each poll is ~10 cycles
      for (int t = 0; t < 2500; t++) begin
        axil_rd(CSR_STATUS, rd);
        if ((rd & 32'h3) == 32'h3) break;
      end
      hades_check_eq("STATUS ready after ENABLE", rd & 32'h3, 32'h3);
      cur_lat = lat;
    end
  endtask

  // ------------------------------------------------------------------
  // T6 basic (CSR_EN=1)
  // ------------------------------------------------------------------
  task automatic test_t6_csr();
    logic [31:0] rd;
    longint      b;
    int unsigned s;
    begin
      hades_log("--- T6 basic: CSR flow ---");

      axil_rd(CSR_ID, rd);
      hades_check_eq("ID", rd, hades_exp_id());
      axil_rd(CSR_PARAMS, rd);
      hades_check_eq("PARAMS", rd, hades_exp_params(TB_SYNC ? 1 : 0, UI_CLK_MHZ,
                                                    PORT_MB_DEFAULT, DW_DEFAULT, N_MAX));

      // ENABLE rejected while calib_done=0
      axil_wr(CSR_CTRL, 32'h1);
      axil_rd(CSR_CTRL, rd);
      hades_check_eq("ENABLE reject (no calib)", rd, 0);
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("ERR_STATUS.bit4 (no calib)", rd, 32'h10);
      axil_wr(CSR_ERR_STATUS, 32'h10);
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("ERR_STATUS W1C", rd, 0);
      calib_done = 1'b1;
      repeat (4) @(posedge ui_clk);

      // indexed window: program + readback all 64 ports
      for (int p = 0; p < N_MAX; p++) begin
        b = p * 64'h0100_0000 + 64'h0000_4000;
        if (p == 5) b = (64'h2 << 32) | 64'h1234_5678;
        s = 32'h0001_0000 + p;
        hades_set_port_cfg(p, b, s);
        axil_wr(CSR_PORT_SEL, p);
        axil_wr(CSR_PORT_BASE, 32'(b));
        axil_wr(CSR_PORT_BASE_HI, 32'(b >> 32));
        axil_wr(CSR_PORT_SIZE, s);
      end
      for (int p = 0; p < N_MAX; p++) begin
        axil_wr(CSR_PORT_SEL, p);
        axil_rd(CSR_PORT_BASE, rd);
        hades_check_eq($sformatf("PORT_BASE[%0d]", p), rd, hades_exp_base(p) & 64'hFFFF_FFFF);
        axil_rd(CSR_PORT_BASE_HI, rd);
        hades_check_eq($sformatf("PORT_BASE_HI[%0d]", p), rd, (hades_exp_base(p) >> 32) & 64'h3);
        axil_rd(CSR_PORT_SIZE, rd);
        hades_check_eq($sformatf("PORT_SIZE[%0d]", p), rd, hades_exp_size(p) & 64'hFFFF_FFFF);
      end

      // out-of-range PORT_SEL
      axil_wr(CSR_PORT_SEL, 32'd200);
      axil_rd(CSR_PORT_BASE, rd);
      hades_check_eq("PORT_SEL oob read 0", rd, 0);
      axil_wr(CSR_PORT_BASE, 32'hFFFF_FFFF);
      axil_wr(CSR_PORT_SEL, 32'd0);
      axil_rd(CSR_PORT_BASE, rd);
      hades_check_eq("oob write ignored", rd, hades_exp_base(0) & 64'hFFFF_FFFF);

      // CFG_LATENCY legal/illegal
      axil_wr(CSR_CFG_LATENCY, 32'd1);
      axil_rd(CSR_CFG_LATENCY, rd);
      hades_check_eq("CFG_LATENCY=1", rd, 1);
      axil_wr(CSR_CFG_LATENCY, 32'd3);
      axil_rd(CSR_CFG_LATENCY, rd);
      hades_check_eq("CFG_LATENCY illegal ignored", rd, 1);
      axil_wr(CSR_CFG_LATENCY, 32'd2);
      axil_rd(CSR_CFG_LATENCY, rd);
      hades_check_eq("CFG_LATENCY=2", rd, 2);

      axil_wr(CSR_PORT_EN_LO, 32'hDEAD_BEEF);
      axil_rd(CSR_PORT_EN_LO, rd);
      hades_check_eq("PORT_EN_LO", rd, 32'hDEAD_BEEF);
      axil_wr(CSR_PORT_EN_HI, 32'h0BAD_F00D);
      axil_rd(CSR_PORT_EN_HI, rd);
      hades_check_eq("PORT_EN_HI", rd, 32'h0BAD_F00D);
      axil_wr(CSR_CFG_PORTS, 32'd64);
      axil_rd(CSR_CFG_PORTS, rd);
      hades_check_eq("CFG_PORTS", rd, 64);

      // MEAS_PERIOD: SYNC divider => exactly 600; ASYNC => incommensurate
      repeat (6) @(posedge port_clk);
      axil_rd(CSR_MEAS_PERIOD, rd);
`ifdef ASYNC
      hades_check_range("MEAS_PERIOD @~500KHz", rd, 595, 605);
`else
      hades_check_eq("MEAS_PERIOD @500KHz", rd, 600);
`endif

      // ENABLE -> READY; SOFT_RESET
      axil_wr(CSR_CTRL, 32'h1);
      axil_rd(CSR_CTRL, rd);
      hades_check_eq("ENABLE set", rd, 1);
      axil_rd(CSR_STATUS, rd);
      hades_check_eq("STATUS calib+ready", rd, 32'h3);
      axil_wr(CSR_CTRL, 32'h2);
      axil_rd(CSR_CTRL, rd);
      hades_check_eq("SOFT_RESET clears enable", rd, 0);
      axil_rd(CSR_STATUS, rd);
      hades_check_eq("SOFT_RESET ready=0", rd, 32'h1);
      axil_rd(CSR_CFG_PORTS, rd);
      hades_check_eq("config retained", rd, 64);

      // clock stop / restart interlock
      port_clk_stop();
      #60_000;
      axil_wr(CSR_CTRL, 32'h1);
      axil_rd(CSR_CTRL, rd);
      hades_check_eq("ENABLE reject (clk stopped)", rd, 0);
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("ERR_STATUS.bit4 (clk stopped)", rd, 32'h10);
      axil_wr(CSR_ERR_STATUS, 32'h10);
      port_clk_start();
      #20_000;
      axil_wr(CSR_CTRL, 32'h1);
      axil_rd(CSR_CTRL, rd);
      hades_check_eq("ENABLE after clk restart", rd, 1);
      axil_wr(CSR_CTRL, 32'h0);

      // over-frequency interlock
      port_clk_set_khz(2000);
      #10_000;
      axil_wr(CSR_CTRL, 32'h1);
      axil_rd(CSR_CTRL, rd);
      hades_check_eq("ENABLE reject (over-freq)", rd, 0);
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("ERR_STATUS.bit4 (over-freq)", rd, 32'h10);
      axil_wr(CSR_ERR_STATUS, 32'h10);
      port_clk_set_khz(500);
      #20_000;
      axil_wr(CSR_CTRL, 32'h1);
      axil_rd(CSR_CTRL, rd);
      hades_check_eq("ENABLE after freq restore", rd, 1);
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // T1: single-port random read/write, 100% data correctness
  // ------------------------------------------------------------------
  task automatic test_t1(input int n_ops);
    int unsigned addr;
    int unsigned data;
    int unsigned we_u;
    logic [31:0] rd;
    begin
      hades_log($sformatf("--- T1: single-port random R/W, %0d ops ---", n_ops));
      calib_done = 1'b1;
      csr_enable(2, 64'h1);   // port 0, L=2

      for (int k = 0; k < n_ops; k++) begin
        int unsigned gap;
        rnd(0, (1 << 22) - 1, addr);
        rnd(0, 32'hFFFF_FFFF, data);
        rnd(0, 1, we_u);
        if (we_u == 1) sram_write(0, addr, data);
        else           sram_read(0, addr);
        rnd(0, 3, gap);
        if (gap == 0) @(negedge port_clk);   // random idle gap
      end
      drain();

      // illegal-address read: shrink port 0's size, then read beyond it
      // (synthetic zero response on schedule + ERR_STATUS.bit0)
      axil_wr(CSR_PORT_SEL, 32'd0);
      axil_wr(CSR_PORT_SIZE, 32'h0000_1000);
      sram_read_illegal(0, 32'h0000_2000);
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("ERR_STATUS.bit0 (illegal addr)", rd & 32'h1, 32'h1);
      axil_rd(CSR_ERR_ADDR, rd);
      hades_check_eq("ERR_ADDR = port0:0x2000", rd, 32'h0000_2000);
      axil_wr(CSR_ERR_STATUS, 32'h1);   // W1C
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("ERR_STATUS cleared", rd, 32'h0);

      // per-port stats sanity
      axil_wr(CSR_PORT_SEL, 32'd0);
      axil_rd(CSR_PORT_STAT_ERR, rd);
      hades_check_eq("port0 err count = 1 (illegal)", rd, 1);
      axil_wr(CSR_PORT_STAT_ERR, 32'h1);  // W1C clear
      axil_rd(CSR_PORT_STAT_ERR, rd);
      hades_check_eq("port0 err cleared", rd, 0);

      axil_wr(CSR_PORT_SIZE, 32'h0040_0000);   // restore default 16 MiB
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // T2: latency exactness — rvalid exactly at request+L port edges.
  // L=2 and L=1, back-to-back bursts and gapped traffic.
  // ------------------------------------------------------------------
  task automatic test_t2();
    begin
      hades_log("--- T2: latency exactness, L=2 and L=1 ---");
      calib_done = 1'b1;

      for (int lat = 2; lat >= 1; lat--) begin
        csr_enable(lat, 64'h3);          // ports 0 and 1
        // seed memory then fully back-to-back burst reads
        sram_write_burst(0, 64, 32'h1000, 32'hA500_0000);
        sram_write_burst(1, 64, 32'h2000, 32'h5A00_0000);
        drain();
        sram_read_burst(0, 64, 32'h1000);
        drain();
        // two ports concurrently: writes then reads, interleaved in time
        fork
          begin
            sram_write_burst(0, 32, 32'h4000, 32'hC000_0000);
            sram_read_burst(0, 32, 32'h4000);
          end
          begin
            sram_write_burst(1, 32, 32'h5000, 32'h0300_0000);
            sram_read_burst(1, 32, 32'h5000);
          end
        join
        drain();
        // RAW: write then read same address on adjacent cycles
        @(negedge port_clk);
        t_en[0] <= 1'b1; t_we[0] <= 1'b1; t_addr[0] <= 32'h777; t_wdata[0] <= 32'hDEAD_1234;
        hades_mem_write(0, 32'h777, 32'hDEAD_1234);
        @(negedge port_clk);
        t_en[0] <= 1'b1; t_we[0] <= 1'b0; t_addr[0] <= 32'h777;
        hades_read_expect(0, pcycle + 1 + cur_lat, 32'h777);
        @(negedge port_clk);
        t_en[0] <= 1'b0;
        drain();
      end
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // T3: maintenance stress — worst refresh+ZQCS+periodic-read combination,
  // repeating the full T2 content.  Maintenance cadence is shrunk so the
  // window is exercised every target period (refresh due every period,
  // ZQCS every 4 periods); the MAINT_STRESS plusarg additionally forces a
  // PHY periodic read into every refresh window (model side).
  // Determinism proof: ERR_STATUS stays 0 (bit5 sentinel silent) and the
  // refresh rate tracks CFG_REFRESH_DIV (A6 rehearsal).
  // ------------------------------------------------------------------
  task automatic test_t3();
    logic [31:0] rd;
    logic [31:0] refc0, refc1;
    longint      w0, w1;
    begin
      hades_log("--- T3: maintenance stress, T2 content ---");
      calib_done = 1'b1;
`ifdef CSR_STATIC
      // static variant: fixed P_REFRESH_DIV=2100 / P_ZQ_DIV=32000 / L=2
      #10_000;
      fork
        begin
          sram_write_burst(0, 64, 32'h9000, 32'h3C00_0000);
          sram_read_burst(0, 64, 32'h9000);
        end
        begin
          sram_write_burst(1, 64, 32'hA000, 32'hC300_0000);
          sram_read_burst(1, 64, 32'hA000);
        end
      join
      drain();
      hades_check_eq("T3 static: stat_err clean", stat_err, 0);
`else
      axil_wr(CSR_CTRL, 32'h0);
      axil_wr(CSR_CFG_REFRESH_DIV, 32'd600);   // one refresh due per window
      axil_wr(CSR_CFG_ZQ_DIV, 32'd4);          // ZQCS every 4 windows
      test_t2();                               // spec: repeat T2 under stress

      // refresh rate over 100 windows (enabled, no traffic)
      csr_enable(2, 64'h3);
      axil_rd(CSR_STAT_REFCNT, refc0);
      w0 = pcycle;
      repeat (100) @(posedge port_clk);
      axil_rd(CSR_STAT_REFCNT, refc1);
      w1 = pcycle;
      hades_check_range("T3 STAT_REFCNT rate (~1/window)",
                        refc1 - refc0, (w1 - w0) * 95 / 100, (w1 - w0) * 105 / 100 + 2);

      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T3: ERR_STATUS clean under worst maintenance", rd & 32'h3F, 0);
      axil_wr(CSR_CFG_REFRESH_DIV, 32'd2100);  // restore defaults
      axil_wr(CSR_CFG_ZQ_DIV, 32'd32000);
      axil_wr(CSR_CTRL, 32'h0);
`endif
    end
  endtask

  // ------------------------------------------------------------------
  // T14: response-window sentinel — the model's +RD_LAT_ADD stretches every
  // backend read past the L-cycle contract; each release must still assert
  // rvalid on schedule (data don't-care) and ERR_STATUS.bit5 must set.
  // Dedicated run only (not part of all_csr/all_static).
  // ------------------------------------------------------------------
  task automatic test_t14();
    logic [31:0] rd;
    int unsigned lat_add;
    begin
      hades_log("--- T14: response-window sentinel fault injection ---");
      if (!$value$plusargs("RD_LAT_ADD=%d", lat_add) || lat_add == 0) begin
        hades_log("T14 skipped: needs +RD_LAT_ADD=<n> model stretch");
        return;
      end
      calib_done = 1'b1;
`ifdef CSR_STATIC
      #10_000;   // static auto-enable, P_L=2
      expect_sentinel = 1;
      sram_write(0, 32'h300, 32'h5AFE_0001);
      for (int k = 0; k < 3; k++) begin
        @(negedge port_clk);
        t_en[0] <= 1'b1; t_we[0] <= 1'b0; t_addr[0] <= 32'h300 + k;
        hades_read_expect_late(0, pcycle + 1 + 2);
        @(negedge port_clk);
        t_en[0] <= 1'b0;
        @(negedge port_clk);
      end
      drain();
      expect_sentinel = 0;
      // L=2 + the 768-cycle backend-timeout backstop: the synthetic zero
      // lands before the release edge, so a dead backend surfaces as bit1
      // (timeout), not bit5.  The sentinel is reachable at L=1 (CSR runs).
      hades_check_eq("T14 static: timeout backstop stat_err[1]", stat_err[1], 1);
      hades_check_eq("T14 static: sentinel bit5 stays 0", stat_err[5], 0);
`else
      csr_enable(1, 64'h1);   // L=1: tightest response window
      expect_sentinel = 1;
      sram_write(0, 32'h300, 32'h5AFE_0001);
      for (int k = 0; k < 3; k++) begin
        @(negedge port_clk);
        t_en[0] <= 1'b1; t_we[0] <= 1'b0; t_addr[0] <= 32'h300 + k;
        hades_read_expect_late(0, pcycle + 1 + cur_lat);
        @(negedge port_clk);
        t_en[0] <= 1'b0;
        @(negedge port_clk);
      end
      drain();
      expect_sentinel = 0;
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T14: ERR_STATUS.bit5 sentinel set", rd & 32'h20, 32'h20);
      hades_check_eq("T14: first-error port = 0", (rd >> 8) & 32'hFF, 0);
      axil_wr(CSR_ERR_STATUS, 32'h3F);   // W1C all (timeout bit1 also fired)
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T14: error bits W1C clear", rd & 32'h3F, 0);
      axil_wr(CSR_CTRL, 32'h0);
`endif
    end
  endtask

  // ------------------------------------------------------------------
  // T8: error paths.  Needs the model fault knobs (+DROP_RD_BEAT /
  //  +SLVERR_RD_BEAT / +SLVERR_WR_BEAT); skipped without them.  Fixed
  //  target addresses, so the beats are known at launch:
  //    timeout    : port 0 word 0x77777 -> beat 0x07777
  //    SLVERR rd  : port 1 word 0x05555 -> beat 0x40555
  //    SLVERR wr  : port 0 word 0x09999 -> beat 0x00999
  //  Criteria: right ERR_STATUS/stat_err bits with the right port, the
  //  faulted access still completes (synthetic zero on schedule for the
  //  timeout, real data with SLVERR status), and traffic continues clean
  //  afterwards (no hang).
  // ------------------------------------------------------------------
  task automatic test_t8();
    logic [31:0] rd;
    longint unsigned kn_drop, kn_slvrd, kn_slvwr, kn_drop2;
    begin
      hades_log("--- T8: error paths (illegal / timeout / SLVERR) ---");
      if (!($value$plusargs("DROP_RD_BEAT=%h", kn_drop)
            && $value$plusargs("DROP_RD_BEAT2=%h", kn_drop2)
            && $value$plusargs("SLVERR_RD_BEAT=%h", kn_slvrd)
            && $value$plusargs("SLVERR_WR_BEAT=%h", kn_slvwr))) begin
        hades_log("T8 skipped: needs +DROP_RD_BEAT/+DROP_RD_BEAT2/+SLVERR_RD_BEAT/+SLVERR_WR_BEAT");
        return;
      end
      calib_done = 1'b1;
`ifdef CSR_STATIC
      #10_000;   // auto-enable (P_L=2)
      cur_lat = 2;
`ifdef PARAM_OVRD
      // illegal: port 3 is shrunk to 128 KiW by the override — read beyond
      // it.  (In the plain static map every 22-bit address is legal by
      // construction, so bit0 is exercised here and in the CSR variants.)
      @(negedge port_clk);
      t_en[3] <= 1'b1; t_we[3] <= 1'b0; t_addr[3] <= 32'h0002_0000;
      hades_read_expect0(3, pcycle + 1 + cur_lat);
      @(negedge port_clk);
      t_en[3] <= 1'b0;
      drain();
`endif
      // timeout: the dropped read completes as scheduled zeros
      @(negedge port_clk);
      t_en[0] <= 1'b1; t_we[0] <= 1'b0; t_addr[0] <= 32'h0007_7777;
      hades_read_expect0(0, pcycle + 1 + cur_lat);
      @(negedge port_clk);
      t_en[0] <= 1'b0;
      drain();
      // SLVERR read (real data + error flag) and SLVERR write (applied,
      // then flagged on B)
      sram_write(1, 32'h5555, 32'hABCD_0001);
      drain();
      sram_read(1, 32'h5555);
      sram_write(0, 32'h9999, 32'h0BAD_0BAD);
      drain();
      sram_read(0, 32'h9999);   // written data survives the SLVERR flag
      drain();
`ifdef PARAM_OVRD
      hades_check_eq("T8 static: stat_err bits 0/1/3", stat_err, 8'h0B);
`else
      // plain static map: bit0 unreachable (every 22-bit address legal)
      hades_check_eq("T8 static: stat_err bits 1/3", stat_err, 8'h0A);
`endif
      // no hang: clean burst afterwards (scoreboard validates)
      sram_write_burst(0, 32, 32'h4000, 32'h1234_0000);
      sram_read_burst(0, 32, 32'h4000);
      drain();
`else
      csr_enable(2, 64'hF, 4);

      // (1) backdoor read of the drop2 beat: the backend timeout completes
      // it with zeros; bit1 sets with the backdoor marker port 0xFF (done
      // FIRST so the first-error latch is clean)
      begin
        logic [31:0] bst, bd;
        bkp_rd(3, 32'h0000_ACE0, bd, bst);
        hades_check_eq("T8: bkp timeout completes err-free", bst & 32'h7, 32'h2);
        hades_check_eq("T8: bkp timeout data = 0", bd, 0);
      end
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T8: bit1 set (backdoor timeout)", (rd >> 1) & 32'h1, 32'h1);
      hades_check_eq("T8: backdoor timeout port = 0xFF", (rd >> 8) & 32'hFF, 32'hFF);

      // (2) illegal read: shrink port 0, read beyond it (synthetic zero).
      // bit0 now sets ALONGSIDE bit1 -> first-error info must not change
      axil_wr(CSR_PORT_SEL, 32'd0);
      axil_wr(CSR_PORT_SIZE, 32'h0000_1000);
      sram_read_illegal(0, 32'h0000_2000);
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T8: bit0 illegal set", rd & 32'h1, 32'h1);
      hades_check_eq("T8: first-error port stays 0xFF", (rd >> 8) & 32'hFF, 32'hFF);

      // (2b) illegal WRITE: discarded silently (posted), same bit0
      @(negedge port_clk);
      t_en[0] <= 1'b1; t_we[0] <= 1'b1; t_addr[0] <= 32'h0000_2000;
      t_wdata[0] <= 32'hBAD5_0000;
      @(negedge port_clk);
      t_en[0] <= 1'b0;
      drain();

      // partial W1C: bits 0+1 set; clearing only bit0 must leave bit1
      axil_wr(CSR_ERR_STATUS, 32'h1);
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T8: partial W1C keeps bit1", rd & 32'h3, 32'h2);
      axil_wr(CSR_ERR_STATUS, 32'h3F);
      csr_default_map();                  // restore port 0 size

      // (3) backend timeout on a port: the dropped read completes as
      // scheduled zeros (timeout 768 < L=2 release at 1200 -> no sentinel)
      sram_write(0, 32'h0007_7777, 32'h1234_5678);
      @(negedge port_clk);
      t_en[0] <= 1'b1; t_we[0] <= 1'b0; t_addr[0] <= 32'h0007_7777;
      hades_read_expect0(0, pcycle + 1 + cur_lat);
      @(negedge port_clk);
      t_en[0] <= 1'b0;
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T8: bit1 timeout set", (rd >> 1) & 32'h1, 32'h1);
      hades_check_eq("T8: timeout port = 0", (rd >> 8) & 32'hFF, 0);
      axil_wr(CSR_ERR_STATUS, 32'h3F);

      // (4) SLVERR read: real data returned, bit3 flagged, port 1
      sram_write(1, 32'h5555, 32'hABCD_0001);
      drain();
      sram_read(1, 32'h5555);
      drain();
      // (5) SLVERR write: applied to memory, flagged on B; readback clean
      sram_write(0, 32'h9999, 32'h0BAD_0BAD);
      drain();
      sram_read(0, 32'h9999);
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T8: bit3 SLVERR set", (rd >> 3) & 32'h1, 32'h1);
      axil_wr(CSR_ERR_STATUS, 32'h3F);

      // (6) no hang: clean burst traffic, no residual errors
      sram_write_burst(0, 32, 32'h4000, 32'h1234_0000);
      sram_read_burst(0, 32, 32'h4000);
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T8: clean after faults", rd & 32'h3F, 0);
      axil_wr(CSR_CTRL, 32'h0);
`endif
    end
  endtask

`ifndef CSR_STATIC
  // ------------------------------------------------------------------
  // OVF: port request-FIFO overflow (ERR_STATUS.bit2, the "dropped request"
  // sentinel).  With the model's AR channel stalled (+AR_STALL_LEN), a
  // back-to-back read burst overruns the depth-8 request FIFO.  All reads
  // still release on schedule (sentinel fires too — fault expected); the
  // documented recovery is SOFT_RESET, verified with clean traffic after.
  // Dedicated run only (not part of all_csr).
  // ------------------------------------------------------------------
  task automatic test_ovf();
    logic [31:0] rd;
    int unsigned stall_len;
    begin
      hades_log("--- OVF: port request-FIFO overflow (bit2) ---");
      if (!$value$plusargs("AR_STALL_LEN=%d", stall_len) || stall_len < 8000) begin
        hades_log("OVF skipped: needs +AR_STALL_LEN>=8000");
        return;
      end
      calib_done = 1'b1;
      csr_enable(1, 64'h1, 1);
      for (int k = 0; k < 12; k++) begin
        @(negedge port_clk);
        t_en[0] <= 1'b1; t_we[0] <= 1'b0; t_addr[0] <= 32'h800 + 32'(k);
        hades_read_expect_late(0, pcycle + 1 + cur_lat);  // data don't-care
      end
      @(negedge port_clk);
      t_en[0] <= 1'b0;
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("OVF: bit2 dropped-request set", (rd >> 2) & 32'h1, 32'h1);
      // documented recovery: SOFT_RESET, re-init, clean traffic
      axil_wr(CSR_CTRL, 32'h2);
      repeat (20) @(posedge port_clk);
      csr_enable(1, 64'h1, 1);
      sram_write_burst(0, 16, 32'h9000, 32'hCAFE_1000);
      sram_read_burst(0, 16, 32'h9000);
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("OVF: clean after SOFT_RESET", rd & 32'h3F, 0);
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask
`endif

  // ------------------------------------------------------------------
  // Backdoor access helpers (CSR register channel / static pin channel)
  // ------------------------------------------------------------------
`ifndef CSR_STATIC
  task automatic bkp_wr(input int port, input int unsigned addr,
                        input int unsigned d, output logic [31:0] st);
    begin
      axil_wr(CSR_BKP_PORT, 32'(port));
      axil_wr(CSR_BKP_ADDR, addr);
      axil_wr(CSR_BKP_ADDR_HI, 32'd0);
      axil_wr(CSR_BKP_WDATA, d);
      axil_wr(CSR_BKP_CMD, 32'h1);
      st = 32'h0;
      for (int t = 0; t < 400; t++) begin
        axil_rd(CSR_BKP_STATUS, st);
        if (st[1]) break;
      end
      hades_check_eq("bkp_wr done seen", st & 32'h2, 32'h2);
    end
  endtask

  task automatic bkp_rd(input int port, input int unsigned addr,
                        output logic [31:0] d, output logic [31:0] st);
    begin
      axil_wr(CSR_BKP_PORT, 32'(port));
      axil_wr(CSR_BKP_ADDR, addr);
      axil_wr(CSR_BKP_ADDR_HI, 32'd0);
      axil_wr(CSR_BKP_CMD, 32'h2);
      st = 32'h0;
      for (int t = 0; t < 400; t++) begin
        axil_rd(CSR_BKP_STATUS, st);
        if (st[1]) break;
      end
      hades_check_eq("bkp_rd done seen", st & 32'h2, 32'h2);
      axil_rd(CSR_BKP_RDATA, d);
    end
  endtask
`else
  task automatic bkp_pin(input bit we, input int port, input int unsigned addr,
                         input int unsigned wd, output logic [31:0] rd);
    begin
      @(posedge ui_clk);
      bkp_port_t  <= 8'(port);
      bkp_addr_t  <= BASE_W'(addr);
      bkp_wdata_t <= wd;
      bkp_we_t    <= we;
      bkp_req_t   <= 1'b1;
      forever begin
        @(posedge ui_clk);
        if (bkp_ack_t) break;
      end
      @(posedge ui_clk);
      bkp_req_t <= 1'b0;
      rd = bkp_rdata_t;
      repeat (4) @(posedge ui_clk);   // let the engine return to idle
    end
  endtask
`endif

  // ------------------------------------------------------------------
  // T4 driver: one pseudo-random access per enabled port per target period
  // (en held 1 across the run).  Single driver process with per-port
  // xorshift state -> identical stimulus on VCS and xsim.  amask caps the
  // random address (the PARAM_OVRD build shrinks port 3 to 128 KiW).
  // ------------------------------------------------------------------
  task automatic t4_run(input int n_ports, input int n_per,
                        input int unsigned amask = (32'h1 << 22) - 1);
    int unsigned rs[N_MAX];
    int unsigned a, d, w;
    begin
      for (int p = 0; p < n_ports; p++)
        rs[p] = (32'h9E37_79B9 ^ (32'(p) * 32'h0101_0101)) | 32'h1;
      for (int k = 0; k < n_per; k++) begin
        @(negedge port_clk);
        for (int p = 0; p < n_ports; p++) begin
          rs[p] ^= rs[p] << 13; rs[p] ^= rs[p] >> 17; rs[p] ^= rs[p] << 5;
          a = rs[p] & amask;
          rs[p] ^= rs[p] << 13; rs[p] ^= rs[p] >> 17; rs[p] ^= rs[p] << 5;
          d = rs[p];
          rs[p] ^= rs[p] << 13; rs[p] ^= rs[p] >> 17; rs[p] ^= rs[p] << 5;
          w = rs[p] & 32'h1;
          t_en[p]    <= 1'b1;
          t_we[p]    <= 1'(w[0]);
          t_addr[p]  <= a;
          t_wdata[p] <= d;
          if (w[0]) hades_mem_write(p, a, d);
          else      hades_read_expect(p, pcycle + 1 + cur_lat, a);
        end
      end
      @(negedge port_clk);
      for (int p = 0; p < n_ports; p++) t_en[p] <= 1'b0;
    end
  endtask

  // ------------------------------------------------------------------
  // T4: full-port-load concurrency — all enabled ports access every period;
  // data correct, per-port latency exact (scoreboard), ERR_STATUS.bit2 == 0.
  // Gears 64/32/16/8 via CFG_PORTS + PORT_EN; plus L=1 at full load.
  // ------------------------------------------------------------------
  task automatic test_t4();
    logic [31:0] rd;
    int          k;
    begin
      hades_log("--- T4: full-load concurrency, gears 64/32/16/8 + L=1 ---");
      calib_done = 1'b1;
      for (int g = 0; g < 4; g++) begin
        k = 64 >> g;
        csr_enable(2, {64{1'b1}} >> (64 - k), k);
        t4_run(k, 32);
        drain();
        axil_rd(CSR_ERR_STATUS, rd);
        hades_check_eq($sformatf("T4 gear N=%0d: ERR_STATUS clean", k),
                       rd & 32'h3F, 0);
      end
      csr_enable(1, {64{1'b1}}, 64);   // L=1 at full load
      t4_run(64, 32);
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T4 N=64 L=1: ERR_STATUS clean", rd & 32'h3F, 0);
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // T5: read-after-write mix — every port writes address X at one period
  // and reads X back at the next (adjacent periods), 64 ports in parallel
  // ------------------------------------------------------------------
  task automatic test_t5();
    int unsigned a, d;
    logic [31:0] rd;
    begin
      hades_log("--- T5: RAW mix, 64 ports ---");
      calib_done = 1'b1;
      csr_enable(2, {64{1'b1}}, 64);
      for (int k = 0; k < 32; k++) begin
        @(negedge port_clk);
        for (int p = 0; p < N_MAX; p++) begin
          a = 32'h0001_0000 + 32'(k);
          d = 32'h5A00_0000 ^ (32'(p) << 16) ^ 32'(k);
          t_en[p] <= 1'b1; t_we[p] <= 1'b1;
          t_addr[p] <= a; t_wdata[p] <= d;
          hades_mem_write(p, a, d);
        end
        @(negedge port_clk);
        for (int p = 0; p < N_MAX; p++) begin
          a = 32'h0001_0000 + 32'(k);
          t_en[p] <= 1'b1; t_we[p] <= 1'b0; t_addr[p] <= a;
          hades_read_expect(p, pcycle + 1 + cur_lat, a);   // RAW: new data
        end
      end
      @(negedge port_clk);
      for (int p = 0; p < N_MAX; p++) t_en[p] <= 1'b0;
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T5: ERR_STATUS clean", rd & 32'h3F, 0);
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // T7: frequency gears 100/500 KHz with T2+T4 subsets at each gear.
  // SYNC: same-source divider switch.  ASYNC: also enables the phase walk
  // (~4.9 deg steps) and +-0.5% slow drift for the whole test.
  // CFG_MIN_PERIOD is relaxed to 590 so -0.5% drift at the 500 KHz gear
  // (period 597) does not trip the over-freq interlock.
  // ------------------------------------------------------------------
  task automatic test_t7();
    logic [31:0] rd;
    int          khz;
    begin
      hades_log("--- T7: gears 100/500 KHz (+ ASYNC phase walk/drift) ---");
      calib_done = 1'b1;
      axil_wr(CSR_CTRL, 32'h0);
      axil_wr(CSR_CFG_MIN_PERIOD, 32'd590);
`ifdef ASYNC
      phase_walk_en = 1'b1;
`endif
      for (int g = 0; g < 2; g++) begin
        khz = (g == 0) ? 100 : 500;
        hades_log($sformatf("T7 gear: %0d KHz", khz));
        port_clk_set_khz(khz);
        repeat (8) @(posedge port_clk);   // freq_mon re-measures the new gear
        csr_enable(2, 64'hF, 4);
        sram_write_burst(0, 32, 32'h6000, 32'h7700_0000);
        sram_write_burst(1, 32, 32'h7000, 32'h0077_0000);
        drain();
        sram_read_burst(0, 32, 32'h6000);
        sram_read_burst(1, 32, 32'h7000);
        drain();
        t4_run(4, 24);
        drain();
        axil_rd(CSR_ERR_STATUS, rd);
        hades_check_eq($sformatf("T7 %0d KHz: ERR_STATUS clean", khz),
                       rd & 32'h3F, 0);
        axil_wr(CSR_CTRL, 32'h0);
      end
`ifdef ASYNC
      phase_walk_en = 1'b0;
      drift         = 0.0;
      port_clk_set_khz(500);
`endif
      axil_wr(CSR_CFG_MIN_PERIOD, 32'(TARGET_PERIOD_500K));   // restore 600
    end
  endtask

  // ------------------------------------------------------------------
  // T9: backdoor channel
  //  A: pre-ENABLE init of all 64 ports through the backdoor, read back
  //     through the target domain
  //  B: backdoor concurrent with live traffic — T2 exactness unaffected,
  //     backdoor data correct; disjoint scratch regions, so no races
  //  C: illegal backdoor address completes with err, no hang, no datapath
  //     error
  // ------------------------------------------------------------------
`ifndef CSR_STATIC
  task automatic test_t9();
    logic [31:0] rd, d, st;
    begin
      hades_log("--- T9: backdoor channel ---");
      calib_done = 1'b1;
      axil_wr(CSR_CTRL, 32'h0);
      csr_default_map();      // phase A runs pre-ENABLE; do not rely on order

      for (int p = 0; p < N_MAX; p++) begin
        for (int w = 0; w < 4; w++) begin
          int unsigned a, dd;
          a  = 32'h0002_0000 + 32'(w);
          dd = 32'hB100_0000 ^ (32'(p) << 8) ^ 32'(w);
          bkp_wr(p, a, dd, st);
          if (st[2]) hades_fail($sformatf("bkp_wr init err port %0d", p));
          hades_mem_write(p, a, dd);
        end
      end

      csr_enable(2, {64{1'b1}}, 64);
      for (int p = 0; p < N_MAX; p++)
        for (int w = 0; w < 4; w++)
          sram_read(p, 32'h0002_0000 + 32'(w));
      drain();

      fork
        begin
          sram_write_burst(0, 48, 32'h0800, 32'h0800_0000);
          sram_read_burst(0, 48, 32'h0800);
        end
        begin
          sram_write_burst(1, 48, 32'h0900, 32'h0900_0000);
          sram_read_burst(1, 48, 32'h0900);
        end
        begin
          for (int p = 4; p < 12; p++) begin
            int unsigned a, dd;
            a  = 32'h0003_0000 + 32'(p);
            dd = 32'hCAFE_0000 ^ 32'(p);
            bkp_wr(p, a, dd, st);
            if (st[2]) hades_fail($sformatf("bkp_wr err port %0d", p));
            hades_mem_write(p, a, dd);
            bkp_rd(p, a, d, st);
            if (st[2]) hades_fail($sformatf("bkp_rd err port %0d", p));
            hades_check_eq($sformatf("bkp readback port %0d", p), d, dd);
          end
        end
      join
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T9: ERR_STATUS clean (backdoor invisible)", rd & 32'h3F, 0);

      bkp_rd(0, 32'h0040_0000, d, st);   // == PORT_SIZE: illegal
      hades_check_eq("T9: illegal bkp addr -> done+err", st & 32'h7, 32'h6);
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T9: backdoor err not a datapath error", rd & 32'h3F, 0);
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask
`else
  task automatic test_t9();
    logic [31:0] d;
    begin
      hades_log("--- T9 static: pin backdoor ---");
      #10_000;
      // pin backdoor init of ports 0/1 scratch, read back via target domain
      for (int w = 0; w < 4; w++) begin
        bkp_pin(1, 0, 32'h0002_0000 + w, 32'hB100_0000 + w, d);
        hades_mem_write(0, 32'h0002_0000 + w, 32'hB100_0000 + w);
        bkp_pin(1, 1, 32'h0002_1000 + w, 32'hB200_0000 + w, d);
        hades_mem_write(1, 32'h0002_1000 + w, 32'hB200_0000 + w);
      end
      sram_read_burst(0, 4, 32'h0002_0000);
      sram_read_burst(1, 4, 32'h0002_1000);
      drain();
      // concurrent: traffic on port 0 + pin backdoor on port 2
      fork
        begin
          sram_write_burst(0, 32, 32'h0800, 32'h0808_0000);
          sram_read_burst(0, 32, 32'h0800);
        end
        begin
          bkp_pin(1, 2, 32'h0003_0000, 32'hDEAD_5678, d);
          hades_mem_write(2, 32'h0003_0000, 32'hDEAD_5678);
          bkp_pin(0, 2, 32'h0003_0000, 0, d);
          hades_check_eq("static bkp readback", d, 32'hDEAD_5678);
        end
      join
      drain();
      hades_check_eq("T9 static: stat_err clean", stat_err, 0);
    end
  endtask
`endif

`ifndef CSR_STATIC
  // ------------------------------------------------------------------
  // T10: long regression — N=64 full load for T10_PER target periods
  // (default suite: 1e6 on VCS, reduced on xsim; dedicated run).
  // Criteria: zero errors; refresh count tracks the configured rate.
  // ------------------------------------------------------------------
  task automatic test_t10(input int n_per);
    logic [31:0] rd;
    longint      exp_ref;
    begin
      hades_log($sformatf("--- T10: long regression, N=64 x %0d periods ---",
                          n_per));
      calib_done = 1'b1;
      csr_enable(2, {64{1'b1}}, 64);
      t4_run(64, n_per);
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T10: ERR_STATUS clean", rd & 32'h3F, 0);
      axil_rd(CSR_STAT_TOT_RD_LO, rd);
      hades_check_range("T10: reads happened", rd, 32'(n_per / 4), 32'h7FFF_FFFF);
      // default refresh_div=2100 at the 500 KHz gear: exp = n_per*600/2100
      axil_rd(CSR_STAT_REFCNT, rd);
      exp_ref = (64'(n_per) * 600) / 2100;
      hades_check_range("T10: refresh count on rate", rd,
                        exp_ref * 98 / 100, exp_ref * 102 / 100 + 2);
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // M5-hw on-chip self-test smoke (SELFTEST_EN builds only; spec 6.2):
  //   1. clean run: the engines drive all enabled ports; PORT_STAT_ERR must
  //      stay 0, ERR_STATUS must stay 0, traffic counters must advance
  //   2. data-fault injection (force shaper rdata)  -> PORT_STAT_ERR grows
  //   3. phase-fault injection (force shaper rvalid) -> PORT_STAT_ERR grows
  //   4. W1C clear + healthy re-run at L=2 and L=1
  // The C++ expected-queue checker is suspended while the engines drive (they
  // are self-checking); the SV X-propagation monitor stays armed.
  // ------------------------------------------------------------------
  task automatic test_selftest();
    logic [31:0] rd;
    logic [31:0] err_cnt;
    begin
      hades_log("--- M5-hw: on-chip self-test smoke ---");
      calib_done = 1'b1;
      csr_default_map();
      csr_enable(2, 64'hF, 4);
      hades_suspend_checks(1);

      // start the engines (CTRL = ENABLE|SELFTEST)
      axil_wr(CSR_CTRL, 32'h5);
      // >= 10 passes at BLK=16 (one pass = 2*16 issues + drain)
      repeat (500) @(posedge port_clk);

      // clean run: no errors anywhere, and traffic really happened
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("SELFTEST: ERR_STATUS clean", rd & 32'h3F, 32'h0);
      for (int i = 0; i < 4; i++) begin
        axil_wr(CSR_PORT_SEL, 32'(i));
        axil_rd(CSR_PORT_STAT_ERR, err_cnt);
        hades_check_eq($sformatf("SELFTEST: PORT_STAT_ERR[%0d] clean", i),
                       err_cnt, 32'h0);
        axil_rd(CSR_PORT_STAT_RD, rd);
        hades_check_range($sformatf("SELFTEST: PORT_STAT_RD[%0d] advanced", i),
                          rd, 32'd50, 32'h7FFF_FFFF);
        axil_rd(CSR_PORT_STAT_WR, rd);
        hades_check_range($sformatf("SELFTEST: PORT_STAT_WR[%0d] advanced", i),
                          rd, 32'd50, 32'h7FFF_FFFF);
      end

      // data-fault injection on port 0: corrupt the shaper's rdata for a few
      // periods -> the per-cycle checker must count mismatches
      force dut.g_port0.u_port.u_shaper.rdata = 32'hDEAD_BEEF;
      repeat (8) @(posedge port_clk);
      release dut.g_port0.u_port.u_shaper.rdata;
      repeat (20) @(posedge port_clk);   // let the toggles cross + count
      axil_wr(CSR_PORT_SEL, 32'd0);
      axil_rd(CSR_PORT_STAT_ERR, err_cnt);
      hades_check_range("SELFTEST: PORT_STAT_ERR[0] after data fault",
                        err_cnt, 32'd1, 32'h7FFF_FFFF);

      // phase-fault injection on port 0: swallow rvalid for a few periods
      force dut.g_port0.u_port.u_shaper.rvalid = 1'b0;
      repeat (4) @(posedge port_clk);
      release dut.g_port0.u_port.u_shaper.rvalid;
      repeat (20) @(posedge port_clk);
      axil_rd(CSR_PORT_STAT_ERR, rd);
      hades_check_range("SELFTEST: PORT_STAT_ERR[0] after phase fault",
                        rd, err_cnt + 32'd1, 32'h7FFF_FFFF);

      // W1C clear, then a clean re-run must stay at 0
      axil_wr(CSR_PORT_STAT_ERR, 32'h1);   // any write clears the selected port
      axil_rd(CSR_PORT_STAT_ERR, rd);
      hades_check_eq("SELFTEST: PORT_STAT_ERR[0] cleared", rd, 32'h0);
      repeat (200) @(posedge port_clk);
      axil_rd(CSR_PORT_STAT_ERR, rd);
      hades_check_eq("SELFTEST: PORT_STAT_ERR[0] stays 0 on re-run", rd, 32'h0);

      // L=1 leg: stop the engines and let in-flight reads drain BEFORE
      // dropping ENABLE (accepted-but-ungranted requests would otherwise be
      // stuck behind the enable mask and trip the window sentinel — the
      // host must quiesce selftest before reprogramming, same as pin traffic)
      axil_wr(CSR_CTRL, 32'h1);
      repeat (16) @(posedge port_clk);
      csr_enable(1, 64'hF, 4);
      axil_wr(CSR_CTRL, 32'h5);
      repeat (300) @(posedge port_clk);
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("SELFTEST: ERR_STATUS clean at L=1", rd & 32'h3F, 32'h0);
      for (int i = 0; i < 4; i++) begin
        axil_wr(CSR_PORT_SEL, 32'(i));
        axil_rd(CSR_PORT_STAT_ERR, err_cnt);
        hades_check_eq($sformatf("SELFTEST: PORT_STAT_ERR[%0d] clean at L=1", i),
                       err_cnt, 32'h0);
      end

      // engines off; they drain (in-flight releases) before checks resume
      axil_wr(CSR_CTRL, 32'h1);
      repeat (16) @(posedge port_clk);
      hades_suspend_checks(0);
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // st_full (M5-hw: the A4 board scenario, in sim): 64-port full-load
  // selftest under pessimistic maintenance (run with +REF_BLOCK=300 on the
  // st variant).  The 64-port drain plus a refresh AR-block must fit inside
  // the L=1 window at 500 KHz.  The 2026-10-21 board failure (PORT_STAT_ERR
  // on tail ports 47+) only reproduces with a realistic refresh block — the
  // default REF_BLOCK=105 is too kind.  Criteria: ERR_STATUS and all 64
  // PORT_STAT_ERR stay 0 at L=2 and at L=1.
  // ------------------------------------------------------------------
  task automatic test_st_full();
    logic [31:0] rd, err_cnt;
    begin
      hades_log("--- ST_FULL: 64-port selftest under pessimistic refresh ---");
      calib_done = 1'b1;
      csr_default_map();
      csr_enable(2, {64{1'b1}}, 64);
      hades_suspend_checks(1);
      axil_wr(CSR_CTRL, 32'h5);            // ENABLE|SELFTEST
      repeat (1200) @(posedge port_clk);   // ~340 refresh dues at div=2100
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("ST_FULL: ERR_STATUS clean at L=2", rd & 32'h3F, 32'h0);
      for (int i = 0; i < 64; i++) begin
        axil_wr(CSR_PORT_SEL, 32'(i));
        axil_rd(CSR_PORT_STAT_ERR, err_cnt);
        hades_check_eq($sformatf("ST_FULL: PORT_STAT_ERR[%0d]=0 at L=2", i),
                       err_cnt, 32'h0);
      end
      // quiesce the engines before dropping ENABLE (documented host rule)
      axil_wr(CSR_CTRL, 32'h1);
      repeat (16) @(posedge port_clk);
      csr_enable(1, {64{1'b1}}, 64);
      axil_wr(CSR_CTRL, 32'h5);
      repeat (1200) @(posedge port_clk);
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("ST_FULL: ERR_STATUS clean at L=1", rd & 32'h3F, 32'h0);
      for (int i = 0; i < 64; i++) begin
        axil_wr(CSR_PORT_SEL, 32'(i));
        axil_rd(CSR_PORT_STAT_ERR, err_cnt);
        hades_check_eq($sformatf("ST_FULL: PORT_STAT_ERR[%0d]=0 at L=1", i),
                       err_cnt, 32'h0);
      end
      axil_wr(CSR_CTRL, 32'h1);
      repeat (16) @(posedge port_clk);
      hades_suspend_checks(0);
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // T12: configuration reload — run, DISABLE, change N/L/CFG_MIN_PERIOD,
  // re-ENABLE; behavior follows the new configuration with no state leak.
  // Also covers SOFT_RESET stat clearing and the CSR read sweep.
  // ------------------------------------------------------------------
  task automatic test_t12();
    logic [31:0] rd;
    begin
      hades_log("--- T12: configuration reload ---");
      calib_done = 1'b1;

      csr_enable(2, 64'hFF, 8);
      t4_run(8, 16);
      drain();

      // DISABLE, change N (8->4), L (2->1), CFG_MIN_PERIOD
      axil_wr(CSR_CTRL, 32'h0);
      axil_wr(CSR_CFG_MIN_PERIOD, 32'd590);
      csr_enable(1, 64'h0F, 4);
      axil_rd(CSR_CFG_MIN_PERIOD, rd);
      hades_check_eq("T12: CFG_MIN_PERIOD reloaded", rd, 590);
      t4_run(4, 16);   // scoreboard validates the new L=1 per port
      drain();
      // a request on a now-disabled port must be ignored (the monitor
      // flags any unexpected rvalid)
      @(negedge port_clk);
      t_en[5] <= 1'b1; t_we[5] <= 1'b0; t_addr[5] <= 32'h100;
      @(negedge port_clk);
      t_en[5] <= 1'b0;
      repeat (4) @(negedge port_clk);
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T12: clean after reload", rd & 32'h3F, 0);

      // SOFT_RESET: stats cleared, configuration retained
      axil_wr(CSR_CTRL, 32'h2);
      axil_rd(CSR_STAT_TOT_RD_LO, rd);
      hades_check_eq("T12: stats cleared by SOFT_RESET", rd, 0);
      axil_rd(CSR_CFG_PORTS, rd);
      hades_check_eq("T12: config retained", rd, 4);
      axil_rd(CSR_CFG_LATENCY, rd);
      hades_check_eq("T12: L retained", rd & 32'h3, 1);

      // CSR read sweep (register coverage)
      axil_rd(CSR_STAT_TOT_RD_HI, rd);
      axil_rd(CSR_STAT_TOT_WR_LO, rd);
      axil_rd(CSR_STAT_TOT_WR_HI, rd);
      axil_rd(CSR_STAT_MAXLAT, rd);
      axil_rd(CSR_STAT_REFCNT, rd);
      axil_wr(CSR_PORT_SEL, 32'd3);
      axil_rd(CSR_PORT_STAT_RD, rd);
      axil_rd(CSR_PORT_STAT_WR, rd);
      axil_rd(CSR_PORT_SEL, rd);
      hades_check_eq("T12: PORT_SEL readback", rd & 32'hFF, 3);
      axil_rd(CSR_BKP_STATUS, rd);
      axil_rd(CSR_BKP_ADDR_HI, rd);
      axil_rd(CSR_BKP_PORT, rd);
      axil_rd(CSR_BKP_ADDR, rd);
      axil_rd(CSR_BKP_WDATA, rd);
      axil_rd(CSR_BKP_CMD, rd);
      axil_wr(16'h00C0, 32'hFFFF_FFFF);   // unmapped offset: ignored, no error
      axil_rd(CSR_CFG_REFRESH_DIV, rd);
      hades_check_eq("T12: CFG_REFRESH_DIV default", rd, 2100);
      axil_rd(CSR_CFG_ZQ_DIV, rd);
      hades_check_eq("T12: CFG_ZQ_DIV default", rd, 32000);

      // exercise the indexed per-port error-clear crossing on a spread of
      // ports (spaced: the toggle crossing needs one port period per clear)
      for (int p = 0; p < N_MAX; p += 7) begin
        axil_wr(CSR_PORT_SEL, 32'(p));
        axil_wr(CSR_PORT_STAT_ERR, 32'h1);
        repeat (3) @(posedge port_clk);
      end

      // restore defaults for subsequent phases
      axil_wr(CSR_CFG_MIN_PERIOD, 32'(TARGET_PERIOD_500K));
      csr_enable(2, 64'h3, 2);
      sram_write_burst(0, 16, 32'h2000, 32'h77AA_0000);
      sram_read_burst(0, 16, 32'h2000);
      drain();
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // Reset recovery: assert BOTH resets while the backend is mid-flight
  // (right after a 64-port full-load round), suppress the due-cycle
  // checks over the wiped in-flight traffic, drop the orphaned
  // expectations, then restart cleanly.  Previously written data persists
  // (the model keeps memory across ui_rst, like real DDR).  Also covers
  // the FSM reset arcs (any state -> IDLE) for coverage.
  // ------------------------------------------------------------------
  task automatic test_rst();
    logic [31:0] rd;
    int unsigned a, d;
    begin
      hades_log("--- RST: mid-flight reset recovery ---");
      calib_done = 1'b1;
      csr_enable(2, {64{1'b1}}, 64);
      // round 0: posted writes (all lands well before the reset)
      @(negedge port_clk);
      for (int p = 0; p < N_MAX; p++) begin
        a = 32'h0000_5000 + 32'(p);
        d = 32'hD00D_0000 + 32'(p);
        t_en[p] <= 1'b1; t_we[p] <= 1'b1;
        t_addr[p] <= a; t_wdata[p] <= d;
        hades_mem_write(p, a, d);
      end
      // round 1: reads; engines busy when the reset lands right after
      @(negedge port_clk);
      for (int p = 0; p < N_MAX; p++) begin
        a = 32'h0000_5040 + 32'(p);
        t_en[p] <= 1'b1; t_we[p] <= 1'b0; t_addr[p] <= a;
        hades_read_expect(p, pcycle + 1 + cur_lat, a);
      end
      // suppress checks across the wiped in-flight traffic, reset NOW
      // (engines are mid-flight), drop orphaned expectations, resume
      hades_suspend_checks(1);
      for (int p = 0; p < N_MAX; p++) t_en[p] <= 1'b0;
      do_reset();
      hades_phase_init();
      hades_suspend_checks(0);
      calib_done = 1'b1;      // model "recalibrates" after the system reset
      // restart: re-enable (soft-reset stretch gates READY via polling) and
      // verify round-0 data survived
      csr_enable(2, 64'h3, 2);
      sram_read_burst(0, 16, 32'h5000);
      sram_read_burst(1, 16, 32'h5000);
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("RST: clean after reset recovery", rd & 32'h3F, 0);
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // T13b: port_clk random stop/start and gear jumps between traffic
  // bursts.  bit4 must set while the clock is stopped and armed; the
  // enable auto-recovers after restart (no software rewrite); no data
  // error, no deadlock.  (Stops happen only on drained boundaries — a
  // stopped clock freezes the target domain by definition.)
  // ------------------------------------------------------------------
  task automatic test_t13b();
    logic [31:0] rd;
    int unsigned wait_us;
    begin
      hades_log("--- T13b: port_clk stop/start + gear jumps ---");
      calib_done = 1'b1;
      csr_enable(2, 64'h3, 2);
      sram_write_burst(0, 16, 32'h3000, 32'hE000_0000);
      sram_read_burst(0, 16, 32'h3000);
      drain();

      for (int k = 0; k < 4; k++) begin
        rnd(60, 80, wait_us);
        port_clk_stop();
        repeat (wait_us) #(1_000);   // 60-80 us: past the 55 us stop timeout
        axil_rd(CSR_ERR_STATUS, rd);
        hades_check_eq("T13b: bit4 set while stopped", rd & 32'h10, 32'h10);
        axil_rd(CSR_STATUS, rd);
        hades_check_eq("T13b: READY dropped", rd & 32'h2, 0);
        // restart, alternating gear (500 -> 100 -> 500 ...)
        port_clk_set_khz((k % 2 == 0) ? 100 : 500);
        port_clk_start();
        repeat (10) @(posedge port_clk);   // freq_mon re-measures
        axil_rd(CSR_STATUS, rd);
        hades_check_eq("T13b: auto-recovered", rd & 32'h3, 32'h3);
        axil_wr(CSR_ERR_STATUS, 32'h3F);   // clear bit4 for the next round
        // traffic at this gear: clean
        sram_write_burst(0, 16, 32'h3100 + 32'(k * 64), 32'hE100_0000);
        sram_read_burst(0, 16, 32'h3100 + 32'(k * 64));
        drain();
        axil_rd(CSR_ERR_STATUS, rd);
        hades_check_eq("T13b: clean after restart", rd & 32'h3F, 0);
      end
      port_clk_set_khz(500);
      #20_000;
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // T13c: over-frequency port_clk (2 MHz) — ENABLE drops/rejects and NO
  // target-domain response is produced; auto-recovery on restore.
  // ------------------------------------------------------------------
  task automatic test_t13c();
    logic [31:0] rd;
    begin
      hades_log("--- T13c: over-freq rejection, no target response ---");
      calib_done = 1'b1;
      csr_enable(2, 64'h3, 2);
      port_clk_set_khz(2000);
      #10_000;   // ~25 edges: measure + trip
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T13c: bit4 set (over-freq while armed)", rd & 32'h10, 32'h10);
      // drive target requests at 2 MHz: no rvalid may appear (monitor
      // errors on any unexpected rvalid automatically)
      for (int k = 0; k < 3; k++) begin
        @(negedge port_clk);
        t_en[0] <= 1'b1; t_we[0] <= 1'b0; t_addr[0] <= 32'h40;
        @(negedge port_clk);
        t_en[0] <= 1'b0;
      end
      repeat (4) @(negedge port_clk);
      port_clk_set_khz(500);
      #20_000;
      axil_wr(CSR_ERR_STATUS, 32'h3F);
      axil_rd(CSR_STATUS, rd);
      hades_check_eq("T13c: auto-recovered after restore", rd & 32'h3, 32'h3);
      sram_write_burst(0, 16, 32'h3200, 32'hE200_0000);
      sram_read_burst(0, 16, 32'h3200);
      drain();
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T13c: clean after recovery", rd & 32'h3F, 0);
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // T13d (ASYNC only): metastability coverage.  RTL event simulation has
  // no analog metastability model; the evidence for "no metastable state
  // propagates to the outputs" is the whitelist CDC structure plus a
  // full-load run while the port_clk phase sweeps the whole circle and
  // the frequency drifts +-0.5% — every crossing is sampled at a
  // continuously varying, effectively random phase.  Zero errors expected.
  // ------------------------------------------------------------------
  task automatic test_t13d();
    logic [31:0] rd;
    begin
      hades_log("--- T13d: ASYNC metastability coverage (phase walk) ---");
`ifdef ASYNC
      calib_done = 1'b1;
      axil_wr(CSR_CTRL, 32'h0);
      axil_wr(CSR_CFG_MIN_PERIOD, 32'd590);   // below the -0.5% drift floor
      phase_walk_en = 1'b1;
      csr_enable(2, {64{1'b1}}, 64);
      t4_run(64, 96);   // 96 periods = 32 walk steps x 3 periods
      drain();
      phase_walk_en = 1'b0;
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T13d: clean under phase walk + drift", rd & 32'h3F, 0);
      axil_wr(CSR_CTRL, 32'h0);
      axil_wr(CSR_CFG_MIN_PERIOD, 32'(TARGET_PERIOD_500K));
`else
      hades_log("T13d: SYNC build — covered by T13a/b; skipping");
`endif
    end
  endtask
`endif   // CSR_STATIC: T10/T12/T13b/c/d are CSR-variant tests; the static
          // variant covers clock stop/start + over-freq in test_static


  // ------------------------------------------------------------------
  // T13a (lite): X on CDC paths / inputs must not reach data outputs
  // (full X-propagation and metastability campaign is M5/T13)
  // ------------------------------------------------------------------
  task automatic test_t13a();
    begin
      hades_log("--- T13a lite: X-propagation guards ---");
      calib_done = 1'b1;
      csr_enable(2, 64'h1);

      // X on emulated-port inputs while en=0: ignored by design.
      // (whole-vector force: xsim forbids part-selects of variables in force)
      force t_addr  = 'x;
      force t_wdata = 'x;
      repeat (3) @(posedge port_clk);
      release t_addr;
      release t_wdata;

      // X on the internal quasi-static slot data while idle: the shaper must
      // never sample it (no release pending)
      force dut.g_port0.u_port.slot_data_u = 'x;
      repeat (3) @(posedge port_clk);
      release dut.g_port0.u_port.slot_data_u;

      // X on the idle AXI R channel (rvalid=0): rdata/rresp may be garbage
      // in a real MIG when no read is in flight; must not reach the slots
      force axi_rdata  = 'x;
      force axi_rresp  = 2'bxx;
      force axi_rid    = 4'bxxxx;
      force axi_rvalid = 1'b0;   // protocol level held valid (no phantom read)
      repeat (3) @(posedge port_clk);
      release axi_rdata; release axi_rresp; release axi_rid; release axi_rvalid;

      // X on the maintenance handshake acks while idle: the scheduler must
      // not sample them outside S_REF/S_ZQ
      force ref_ack = 1'bx;
      force zq_ack  = 1'bx;
      repeat (3) @(posedge port_clk);
      release ref_ack; release zq_ack;

      // traffic afterwards must be clean (monitor checks every edge)
      sram_write_burst(0, 16, 32'h8000, 32'h1357_0000);
      sram_read_burst(0, 16, 32'h8000);
      drain();
      axil_wr(CSR_CTRL, 32'h0);
    end
  endtask

  // ------------------------------------------------------------------
  // Static-variant smoke + traffic (CSR_EN=0)
  // ------------------------------------------------------------------
  task automatic test_static();
    begin
      hades_log("--- static variant: smoke + traffic ---");
      #10_000;
      hades_check_eq("static: not ready before calib", stat_ready, 0);
      calib_done = 1'b1;
      #10_000;
      hades_check_eq("static: stat_calib_done", stat_calib_done, 1);
      hades_check_eq("static: auto-enabled ready", stat_ready, 1);
      hades_check_eq("static: stat_err clean", stat_err, 0);

      // traffic on two ports concurrently (P_L=2, all ports enabled)
      fork
        begin
          sram_write_burst(0, 32, 32'h100, 32'hAAAA_0000);
          sram_read_burst(0, 32, 32'h100);
        end
        begin
          sram_write_burst(1, 32, 32'h200, 32'h5555_0000);
          sram_read_burst(1, 32, 32'h200);
        end
      join
      drain();
      hades_check_eq("static: stat_err clean after traffic", stat_err, 0);

      // clock stop / over-freq handling (pin-level)
      port_clk_stop();
      #60_000;
      hades_check_eq("static: ready drops on clk stop", stat_ready, 0);
      hades_check_eq("static: stat_err bit4", stat_err[4], 1);
      port_clk_start();
      #20_000;
      hades_check_eq("static: auto-recover", stat_ready, 1);
      hades_check_eq("static: stat_err clean again", stat_err, 0);
      port_clk_set_khz(2000);
      #10_000;
      hades_check_eq("static: over-freq blocks ready", stat_ready, 0);
      hades_check_eq("static: over-freq bit4", stat_err[4], 1);
      port_clk_set_khz(500);
      #20_000;
      hades_check_eq("static: ready after restore", stat_ready, 1);

      // 100 KHz gear + full-load subset (static T4/T7 coverage; P_L=2).
      // PARAM_OVRD: port 3 is shrunk to 128 KiW by the override — cap the
      // random addresses so every port's map is respected (a plain static
      // map has every 22-bit address legal by construction).
      cur_lat = 2;
      port_clk_set_khz(100);
      #200_000;                      // freq_mon re-measure (5x10 us periods)
      hades_check_eq("static: ready at 100 KHz", stat_ready, 1);
`ifdef PARAM_OVRD
      t4_run(64, 16, 32'h0001_FFFF);
`else
      t4_run(64, 16);
`endif
      drain();
      hades_check_eq("static 100KHz full-load: stat_err clean", stat_err, 0);
      port_clk_set_khz(500);
      #20_000;

`ifdef PARAM_OVRD
      hades_check_eq("ovrd base[3]", dut.cfg_eff.port_base[3], OVRD_BASE3);
      hades_check_eq("ovrd size[3]", dut.cfg_eff.port_size[3], OVRD_SIZE3);
      hades_check_eq("ovrd base[5]", dut.cfg_eff.port_base[5], OVRD_BASE5);
      hades_check_eq("dflt base[0] kept", dut.cfg_eff.port_base[0], 0);
      hades_check_eq("dflt size[0] kept", dut.cfg_eff.port_size[0],
                     32'((64'(PORT_MB_DEFAULT) * 1024 * 1024) / (DW_DEFAULT / 8)));
`endif
    end
  endtask

  // ------------------------------------------------------------------
  // Width-matrix tests (v1.1.0): per-port widths 1..512 + byte enables.
  // ------------------------------------------------------------------
  // per-port W-word address ceiling: 16 MiB default window / stride
  function automatic int aw_max(input int p);
    return ((PORT_MB_DEFAULT * 1024 * 1024 / 4) >> wshift_f(w_of(p))) - 1;
  endfunction

  // byte-enable mask of the actually-used byte lanes of port p
  function automatic bit [63:0] be_mask(input int p);
    int nb;
    nb = (w_of(p) + 7) / 8;
    return (nb >= 64) ? {64{1'b1}} : ((64'(1) << nb) - 1);
  endfunction

  // full-width replicated pattern, tagged by port+addr
  function automatic bit [511:0] wpat(input int port, input int addr);
    logic [31:0] x;
    x = 32'hA500_0000 ^ 32'(port * 32'h101) ^ 32'(addr);
    return {16{x}};
  endfunction

  // W1: width smoke on every active port — seed + readback, exact-L checking
  task automatic test_w1();
    begin
      hades_log($sformatf("--- W1: per-port width smoke, N=%0d ---", N));
      calib_done = 1'b1;
      csr_enable(2, (64'(1) << N) - 1);
      for (int p = 0; p < N; p++) begin
        for (int a = 0; a < 4; a++)
          sram_write(p, (a * 64'h111) & 64'(aw_max(p)), wpat(p, (a * 64'h111) & 64'(aw_max(p))));
      end
      drain();
      for (int p = 0; p < N; p++) begin
        for (int a = 0; a < 4; a++)
          sram_read(p, (a * 64'h111) & 64'(aw_max(p)));
      end
      drain();
    end
  endtask

  // W2: exact-latency bursts at L=2 and L=1 across all active ports
  task automatic test_w2();
    begin
      hades_log("--- W2: latency exactness under the width config ---");
      calib_done = 1'b1;
      for (int lat = 2; lat >= 1; lat--) begin
        csr_enable(lat, (64'(1) << N) - 1);
        for (int p = 0; p < N; p++) sram_write_burst(p, 16, 0, wpat(p, 0));
        drain();
        for (int p = 0; p < N; p++) sram_read_burst(p, 16, 0);
        drain();
      end
    end
  endtask

  // WBE: byte-enable partial writes — merge, all-off no-op, full overwrite
  task automatic test_wbe();
    int done_any;
    begin
      hades_log("--- WBE: byte-enable partial writes ---");
      calib_done = 1'b1;
      csr_enable(2, (64'(1) << N) - 1);
      done_any = 0;
      for (int p = 0; p < N; p++) begin
        if (be_of(p)) begin
          done_any++;
          sram_write(p, 0, wpat(p, 0));                          // seed
          drain();
          sram_write_be(p, 0, {16{32'h5A5A_5A01}},               // even bytes only
                        64'h5555_5555_5555_5555 & be_mask(p));
          drain();
          sram_read(p, 0);                                       // merged value
          drain();
          sram_write_be(p, 0, {16{32'hDEAD_BEEF}}, '0);          // no-op
          drain();
          sram_read(p, 0);                                       // still merged
          drain();
          sram_write_be(p, 0, wpat(p, 7), be_mask(p));           // full overwrite
          drain();
          sram_read(p, 0);
          drain();
        end
      end
      if (done_any == 0)
        hades_log("WBE: no BE-enabled ports in this configuration — skipped");
    end
  endtask

  // ------------------------------------------------------------------
  // Main
  // ------------------------------------------------------------------
  initial begin : p_main
    string test;
    int    n_ops;
    if (!$value$plusargs("TEST=%s", test)) test = "all";
    if (!$value$plusargs("OPS=%d", n_ops)) n_ops = 100_000;
    // no seed plusarg: $urandom(seed) is unsupported by xsim; default seeds
    // are fixed in both simulators, so regressions are reproducible.

    hades_init();
    for (int p = 0; p < N_MAX; p++) hades_set_port_width(p, w_of(p));
    do_reset();

    if (test == "all" || test == "all_csr" || test == "all_static") begin
`ifdef CSR_STATIC
      test_static();
      hades_phase_init();
      test_t3();
      hades_phase_init();
      test_t9();
`else
      test_t6_csr();
      hades_phase_init();
      test_t1(n_ops);
      hades_phase_init();
      test_t2();
      hades_phase_init();
      test_t3();
      hades_phase_init();
      test_t4();
      hades_phase_init();
      test_t5();
      hades_phase_init();
      test_t7();
      hades_phase_init();
      test_t9();
      hades_phase_init();
      test_t12();
      hades_phase_init();
      test_rst();
      hades_phase_init();
      test_t13b();
      hades_phase_init();
      test_t13c();
      hades_phase_init();
      test_t13d();
      hades_phase_init();
      test_t13a();
`endif
    end else if (test == "t6_csr")        test_t6_csr();
    else if (test == "t1") begin calib_done = 1'b1; test_t1(n_ops); end
    else if (test == "t2") begin calib_done = 1'b1; test_t2();      end
    else if (test == "t3") begin calib_done = 1'b1; test_t3();      end
    else if (test == "t4") begin calib_done = 1'b1; test_t4();      end
    else if (test == "t5") begin calib_done = 1'b1; test_t5();      end
    else if (test == "w1") begin calib_done = 1'b1; test_w1();      end
    else if (test == "w2") begin calib_done = 1'b1; test_w2();      end
    else if (test == "wbe") begin calib_done = 1'b1; test_wbe();    end
    else if (test == "wall") begin
      calib_done = 1'b1;
      test_w1(); hades_phase_init();
      test_w2(); hades_phase_init();
      test_wbe();
    end
    else if (test == "t7") begin calib_done = 1'b1; test_t7();      end
    else if (test == "t8") begin calib_done = 1'b1; test_t8();      end
    else if (test == "t9") begin calib_done = 1'b1; test_t9();      end
`ifndef CSR_STATIC
    else if (test == "t12") begin calib_done = 1'b1; test_t12();    end
    else if (test == "selftest")             test_selftest();
    else if (test == "st_full")              test_st_full();
    else if (test == "t13b") begin calib_done = 1'b1; test_t13b();  end
    else if (test == "rst")  begin calib_done = 1'b1; test_rst();   end
    else if (test == "ovf")  begin calib_done = 1'b1; test_ovf();   end
    else if (test == "t13c") begin calib_done = 1'b1; test_t13c();  end
    else if (test == "t13d") begin calib_done = 1'b1; test_t13d();  end
    else if (test == "t10") begin
      int t10_per;
      if (!$value$plusargs("T10_PER=%d", t10_per)) t10_per = 1_000_000;
      test_t10(t10_per);
    end
`endif
    else if (test == "t14") begin                    test_t14();    end
    else if (test == "t13a") begin calib_done = 1'b1; test_t13a();  end
    else if (test == "static_smoke")     test_static();
    else $display("[HADES-TB] unknown TEST=%s", test);

    hades_report();
    if (hades_err_count() == 0) $display("HADES_TEST_PASS");
    else                        $display("HADES_TEST_FAIL");
    $finish;
  end

  // watchdog (t1 at 1e5 ops needs ~200 ms; T10 needs ~2.5 s at 1e6 periods)
  initial begin
    int wdog_ms;
    if (!$value$plusargs("WDOG_MS=%d", wdog_ms)) wdog_ms = 600;
    #(64'(wdog_ms) * 1_000_000);
    $display("HADES_TEST_FAIL: watchdog timeout");
    $finish;
  end

endmodule

`default_nettype wire
