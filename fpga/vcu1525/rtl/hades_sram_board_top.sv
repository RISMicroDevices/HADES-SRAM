//-----------------------------------------------------------------------------
// HADES-SRAM VCU1525 — board top level (M5-hw).
//
//   MIG C0 (DDR4-2400 RDIMM ECC, AXI4 512-bit, ui_clk 300 MHz,
//           UserRefresh_ZQCS = on -> app_ref/app_zq handshake)
//     <- hades_sram_top (N=64, CSR_EN=1, SELFTEST_EN=1; IS_SYNC per build)
//   JTAG-AXI (AXI4-Lite) -> board_axil_xbar -> 0x0000_0000 HADES IP CSR
//                                           -> 0x0001_0000 board_ctrl
//   port_clk: SYNC  = fabric-divided ui_clk (same-source, XDC-declared)
//             ASYNC = fabric-divided independent source (PCIe slot refclk
//                     via IBUFDS_GTE4 ODIV2 when BOARD_CLKSRC_PCIE, else a
//                     second MMCM on default_300mhz_clk1)
//
// Reset: MIG sys_rst is ACTIVE_HIGH but the CPU_RESET button idles HIGH
// (active-low press) — wire it inverted (spike lesson).  ui_rst for the
// fabric logic is the MIG's ui_clk_sync_rst; hades_sram_rst_sync re-syncs it into
// each domain internally.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module hades_sram_board_top #(
  parameter bit SYNC_MODE = 1'b1    // 1: SYNC build, 0: ASYNC build
) (
  input  wire logic        cpu_resetn,       // AL20 push button, active low
  input  wire logic        c0_sys_clk_p,     // onboard 300 MHz (MIG reference)
  input  wire logic        c0_sys_clk_n,
  input  wire logic        pcie_refclk_p,    // ASYNC: PCIe slot 100 MHz refclk
  input  wire logic        pcie_refclk_n,
  input  wire logic        clk1_p,           // ASYNC fallback: onboard 300 MHz clk1
  input  wire logic        clk1_n,

  // DDR4 C0
  output wire logic        c0_ddr4_act_n,
  output wire logic [16:0] c0_ddr4_adr,
  output wire logic [1:0]  c0_ddr4_ba,
  output wire logic [1:0]  c0_ddr4_bg,
  output wire logic [0:0]  c0_ddr4_cke,
  output wire logic [0:0]  c0_ddr4_odt,
  output wire logic [0:0]  c0_ddr4_cs_n,
  output wire logic [0:0]  c0_ddr4_ck_t,
  output wire logic [0:0]  c0_ddr4_ck_c,
  output wire logic        c0_ddr4_reset_n,
  output wire logic        c0_ddr4_parity,
  inout  wire       [71:0] c0_ddr4_dq,
  inout  wire       [17:0] c0_ddr4_dqs_t,
  inout  wire       [17:0] c0_ddr4_dqs_c,

  output      logic [2:0]  led
);

  // ------------------------------------------------------------------
  // Reset + MIG
  // ------------------------------------------------------------------
  logic ui_clk, ui_rst, calib;

  // cpu_resetn glitch filter (2026-10-20 hardware finding): the button pin
  // (AL20) drove mig_sys_rst combinationally, and noise on it spontaneously
  // reset the MIG mid-session (3 recalibration events in one day, killing
  // long regressions).  Qualify: assert only when the pin stays low for
  // ~3.5 ms (2^20 ui_clk cycles); clear as soon as it goes high.  The filter
  // runs on the MIG's own ui_clk — pre-lock it sits idle (the MIG simply
  // boots), and a noise glitch can never accumulate a full count.
  logic [19:0] rst_filt_cnt = 20'd0;
  logic        mig_sys_rst;

  always_ff @(posedge ui_clk) begin
    if (!cpu_resetn) begin
      if (rst_filt_cnt != 20'hFFFFF) rst_filt_cnt <= rst_filt_cnt + 20'd1;
    end else begin
      rst_filt_cnt <= 20'd0;
    end
  end
  assign mig_sys_rst = (rst_filt_cnt == 20'hFFFFF);
  wire  logic ui_rst_n    = ~ui_rst;

  // HADES <-> MIG AXI4
  logic [3:0]         axi_awid;
  logic [39:0]        axi_awaddr;
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
  logic [39:0]        axi_araddr;
  logic [7:0]         axi_arlen;
  logic [2:0]         axi_arsize;
  logic [1:0]         axi_arburst;
  logic               axi_arvalid, axi_arready;
  logic [3:0]         axi_rid;
  logic [511:0]       axi_rdata;
  logic [1:0]         axi_rresp;
  logic               axi_rlast, axi_rvalid, axi_rready;

  logic ref_req, ref_ack, zq_req, zq_ack;

  mig_0 u_mig (
    .sys_rst                     (mig_sys_rst),
    .c0_sys_clk_p                (c0_sys_clk_p),
    .c0_sys_clk_n                (c0_sys_clk_n),
    .c0_ddr4_act_n               (c0_ddr4_act_n),
    .c0_ddr4_adr                 (c0_ddr4_adr),
    .c0_ddr4_ba                  (c0_ddr4_ba),
    .c0_ddr4_bg                  (c0_ddr4_bg),
    .c0_ddr4_cke                 (c0_ddr4_cke),
    .c0_ddr4_odt                 (c0_ddr4_odt),
    .c0_ddr4_cs_n                (c0_ddr4_cs_n),
    .c0_ddr4_ck_t                (c0_ddr4_ck_t),
    .c0_ddr4_ck_c                (c0_ddr4_ck_c),
    .c0_ddr4_reset_n             (c0_ddr4_reset_n),
    .c0_ddr4_parity              (c0_ddr4_parity),
    .c0_ddr4_dq                  (c0_ddr4_dq),
    .c0_ddr4_dqs_t               (c0_ddr4_dqs_t),
    .c0_ddr4_dqs_c               (c0_ddr4_dqs_c),
    .c0_init_calib_complete      (calib),
    .c0_ddr4_ui_clk              (ui_clk),
    .c0_ddr4_ui_clk_sync_rst     (ui_rst),
    .c0_ddr4_app_ref_req         (ref_req),
    .c0_ddr4_app_ref_ack         (ref_ack),
    .c0_ddr4_app_zq_req          (zq_req),
    .c0_ddr4_app_zq_ack          (zq_ack),
    .addn_ui_clkout1             (),
    .dbg_clk                     (),
    .dbg_bus                     (),
    // ECC/parity management interface (present even with Ecc=false): unused
    .c0_ddr4_s_axi_ctrl_awvalid  (1'b0),
    .c0_ddr4_s_axi_ctrl_awaddr   (32'd0),
    .c0_ddr4_s_axi_ctrl_wvalid   (1'b0),
    .c0_ddr4_s_axi_ctrl_wdata    (32'd0),
    .c0_ddr4_s_axi_ctrl_bready   (1'b1),
    .c0_ddr4_s_axi_ctrl_arvalid  (1'b0),
    .c0_ddr4_s_axi_ctrl_araddr   (32'd0),
    .c0_ddr4_s_axi_ctrl_rready   (1'b1),
    .c0_ddr4_s_axi_ctrl_awready  (),
    .c0_ddr4_s_axi_ctrl_wready   (),
    .c0_ddr4_s_axi_ctrl_bvalid   (),
    .c0_ddr4_s_axi_ctrl_bresp    (),
    .c0_ddr4_s_axi_ctrl_arready  (),
    .c0_ddr4_s_axi_ctrl_rvalid   (),
    .c0_ddr4_s_axi_ctrl_rdata    (),
    .c0_ddr4_s_axi_ctrl_rresp    (),
    .c0_ddr4_interrupt           (),
    // AXI4 slave port <- HADES master
    .c0_ddr4_aresetn             (ui_rst_n),
    .c0_ddr4_s_axi_awid          (axi_awid),
    .c0_ddr4_s_axi_awaddr        (axi_awaddr[33:0]),
    .c0_ddr4_s_axi_awlen         (axi_awlen),
    .c0_ddr4_s_axi_awsize        (axi_awsize),
    .c0_ddr4_s_axi_awburst       (axi_awburst),
    .c0_ddr4_s_axi_awlock        (1'b0),
    .c0_ddr4_s_axi_awcache       (4'b0010),
    .c0_ddr4_s_axi_awprot        (3'b000),
    .c0_ddr4_s_axi_awqos         (4'b0000),
    .c0_ddr4_s_axi_awvalid       (axi_awvalid),
    .c0_ddr4_s_axi_awready       (axi_awready),
    .c0_ddr4_s_axi_wdata         (axi_wdata),
    .c0_ddr4_s_axi_wstrb         (axi_wstrb),
    .c0_ddr4_s_axi_wlast         (axi_wlast),
    .c0_ddr4_s_axi_wvalid        (axi_wvalid),
    .c0_ddr4_s_axi_wready        (axi_wready),
    .c0_ddr4_s_axi_bready        (axi_bready),
    .c0_ddr4_s_axi_bid           (axi_bid),
    .c0_ddr4_s_axi_bresp         (axi_bresp),
    .c0_ddr4_s_axi_bvalid        (axi_bvalid),
    .c0_ddr4_s_axi_arid          (axi_arid),
    .c0_ddr4_s_axi_araddr        (axi_araddr[33:0]),
    .c0_ddr4_s_axi_arlen         (axi_arlen),
    .c0_ddr4_s_axi_arsize        (axi_arsize),
    .c0_ddr4_s_axi_arburst       (axi_arburst),
    .c0_ddr4_s_axi_arlock        (1'b0),
    .c0_ddr4_s_axi_arcache       (4'b0010),
    .c0_ddr4_s_axi_arprot        (3'b000),
    .c0_ddr4_s_axi_arqos         (4'b0000),
    .c0_ddr4_s_axi_arvalid       (axi_arvalid),
    .c0_ddr4_s_axi_arready       (axi_arready),
    .c0_ddr4_s_axi_rready        (axi_rready),
    .c0_ddr4_s_axi_rid           (axi_rid),
    .c0_ddr4_s_axi_rdata         (axi_rdata),
    .c0_ddr4_s_axi_rresp         (axi_rresp),
    .c0_ddr4_s_axi_rlast         (axi_rlast),
    .c0_ddr4_s_axi_rvalid        (axi_rvalid)
  );

  // ------------------------------------------------------------------
  // port_clk generation
  // ------------------------------------------------------------------
  logic        port_clk;
  logic [15:0] clk_div;
  logic        clk_gate, clk_commit;
  logic [15:0] clk_div_active;

  logic        async_src;
  logic        async_src_rst;

  generate
    if (SYNC_MODE) begin : g_clk_sync
      assign async_src     = 1'b0;
      assign async_src_rst = 1'b0;
    end else begin : g_clk_async
`ifdef BOARD_CLKSRC_PCIE
      // PCIe slot 100 MHz refclk (motherboard crystal — independent of the
      // onboard 300 MHz).  ODIV2 (50 MHz) is the fabric-usable output.
      logic refclk_div;
      IBUFDS_GTE4 #(
        .REFCLK_HROW_CK_SEL (2'b00)
      ) u_pcie_refclk (
        .I     (pcie_refclk_p),
        .IB    (pcie_refclk_n),
        .CEB   (1'b0),
        .O     (),
        .ODIV2 (refclk_div)
      );
      BUFG u_bufg_async (.I(refclk_div), .O(async_src));
      // reset stretcher on the async source
      logic [3:0] rst_sr = 4'hF;
      always_ff @(posedge async_src) rst_sr <= {rst_sr[2:0], 1'b0};
      assign async_src_rst = rst_sr[3];
`else
      // fallback: second MMCM on the second onboard 300 MHz input (same
      // crystal family — documented A10b deviation), 100.00 MHz output
      logic clk1_ib, clk_fb, clk_100;
      logic mmcm2_locked;
      IBUFGDS u_ibufds_clk1 (.I(clk1_p), .IB(clk1_n), .O(clk1_ib));
      MMCME4_BASE #(
        .CLKIN1_PERIOD   (3.333),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (4.0),      // VCO 1200 MHz
        .CLKOUT0_DIVIDE_F(12.0)      // 100.0 MHz
      ) u_mmcm2 (
        .CLKIN1   (clk1_ib),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (clk_100),
        .LOCKED   (mmcm2_locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0),
        .CLKOUT0B (), .CLKOUT1 (), .CLKOUT1B (), .CLKOUT2 (), .CLKOUT2B (),
        .CLKOUT3 (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
        .CLKFBOUTB ()
      );
      BUFG u_bufg_async (.I(clk_100), .O(async_src));
      logic [3:0] rst_sr = 4'hF;
      always_ff @(posedge async_src or negedge mmcm2_locked)
        if (!mmcm2_locked) rst_sr <= 4'hF;
        else               rst_sr <= {rst_sr[2:0], 1'b0};
      assign async_src_rst = rst_sr[3];
`endif
    end
  endgenerate

  wire logic src_clk = SYNC_MODE ? ui_clk : async_src;
  wire logic src_rst = SYNC_MODE ? ui_rst : async_src_rst;

  board_clk_gen u_clkgen (
    .src_clk    (src_clk),
    .src_rst    (src_rst),
    .div        (clk_div),
    .div_commit (clk_commit),
    .gate       (clk_gate),
    .port_clk   (port_clk),
    .div_active (clk_div_active)
  );

  // ------------------------------------------------------------------
  // HADES IP (N=64, CSR, self-test engines)
  // ------------------------------------------------------------------
  logic [2047:0]        sram_rdata;
  logic [63:0]          sram_rvalid;

  // CSR AXI4-Lite from the xbar (M0)
  logic [15:0] c_awaddr, c_araddr;
  logic        c_awvalid, c_awready, c_wvalid, c_wready, c_bvalid, c_bready;
  logic [31:0] c_wdata, c_rdata;
  logic [3:0]  c_wstrb;
  logic [1:0]  c_bresp, c_rresp;
  logic        c_arvalid, c_arready, c_rvalid, c_rready;

  hades_sram_top #(
    .N                    (64),
    .W0(32), .W1(32), .W2(32), .W3(32), .W4(32), .W5(32), .W6(32), .W7(32),
    .W8(32), .W9(32), .W10(32), .W11(32), .W12(32), .W13(32), .W14(32), .W15(32),
    .W16(32), .W17(32), .W18(32), .W19(32), .W20(32), .W21(32), .W22(32), .W23(32),
    .W24(32), .W25(32), .W26(32), .W27(32), .W28(32), .W29(32), .W30(32), .W31(32),
    .W32(32), .W33(32), .W34(32), .W35(32), .W36(32), .W37(32), .W38(32), .W39(32),
    .W40(32), .W41(32), .W42(32), .W43(32), .W44(32), .W45(32), .W46(32), .W47(32),
    .W48(32), .W49(32), .W50(32), .W51(32), .W52(32), .W53(32), .W54(32), .W55(32),
    .W56(32), .W57(32), .W58(32), .W59(32), .W60(32), .W61(32), .W62(32), .W63(32),
    .BE0_EN(1'b0), .BE1_EN(1'b0), .BE2_EN(1'b0), .BE3_EN(1'b0),
    .BE4_EN(1'b0), .BE5_EN(1'b0), .BE6_EN(1'b0), .BE7_EN(1'b0),
    .BE8_EN(1'b0), .BE9_EN(1'b0), .BE10_EN(1'b0), .BE11_EN(1'b0),
    .BE12_EN(1'b0), .BE13_EN(1'b0), .BE14_EN(1'b0), .BE15_EN(1'b0),
    .BE16_EN(1'b0), .BE17_EN(1'b0), .BE18_EN(1'b0), .BE19_EN(1'b0),
    .BE20_EN(1'b0), .BE21_EN(1'b0), .BE22_EN(1'b0), .BE23_EN(1'b0),
    .BE24_EN(1'b0), .BE25_EN(1'b0), .BE26_EN(1'b0), .BE27_EN(1'b0),
    .BE28_EN(1'b0), .BE29_EN(1'b0), .BE30_EN(1'b0), .BE31_EN(1'b0),
    .BE32_EN(1'b0), .BE33_EN(1'b0), .BE34_EN(1'b0), .BE35_EN(1'b0),
    .BE36_EN(1'b0), .BE37_EN(1'b0), .BE38_EN(1'b0), .BE39_EN(1'b0),
    .BE40_EN(1'b0), .BE41_EN(1'b0), .BE42_EN(1'b0), .BE43_EN(1'b0),
    .BE44_EN(1'b0), .BE45_EN(1'b0), .BE46_EN(1'b0), .BE47_EN(1'b0),
    .BE48_EN(1'b0), .BE49_EN(1'b0), .BE50_EN(1'b0), .BE51_EN(1'b0),
    .BE52_EN(1'b0), .BE53_EN(1'b0), .BE54_EN(1'b0), .BE55_EN(1'b0),
    .BE56_EN(1'b0), .BE57_EN(1'b0), .BE58_EN(1'b0), .BE59_EN(1'b0),
    .BE60_EN(1'b0), .BE61_EN(1'b0), .BE62_EN(1'b0), .BE63_EN(1'b0),
    .AW                   (22),
    .IS_SYNC              (SYNC_MODE),
    .CSR_EN               (1'b1),
    .SELFTEST_EN          (1'b1),
    .TARGET_PERIOD_CYCLES (600)
  ) u_hades (
    .ui_clk        (ui_clk),
    .ui_rst_n      (ui_rst_n),
    .port_clk      (port_clk),
    .port_rst_n    (ui_rst_n),
    .calib_done    (calib),
    // No external integrator on the board; the self-test engines drive internally.
    .sram0_en(1'b0), .sram0_we(1'b0), .sram0_addr('0),
    .sram0_wdata(32'd0), .sram0_be(64'd0),
    .sram0_rdata(sram_rdata[0*32 +: 32]), .sram0_rvalid(sram_rvalid[0]),
    .sram1_en(1'b0), .sram1_we(1'b0), .sram1_addr('0),
    .sram1_wdata(32'd0), .sram1_be(64'd0),
    .sram1_rdata(sram_rdata[1*32 +: 32]), .sram1_rvalid(sram_rvalid[1]),
    .sram2_en(1'b0), .sram2_we(1'b0), .sram2_addr('0),
    .sram2_wdata(32'd0), .sram2_be(64'd0),
    .sram2_rdata(sram_rdata[2*32 +: 32]), .sram2_rvalid(sram_rvalid[2]),
    .sram3_en(1'b0), .sram3_we(1'b0), .sram3_addr('0),
    .sram3_wdata(32'd0), .sram3_be(64'd0),
    .sram3_rdata(sram_rdata[3*32 +: 32]), .sram3_rvalid(sram_rvalid[3]),
    .sram4_en(1'b0), .sram4_we(1'b0), .sram4_addr('0),
    .sram4_wdata(32'd0), .sram4_be(64'd0),
    .sram4_rdata(sram_rdata[4*32 +: 32]), .sram4_rvalid(sram_rvalid[4]),
    .sram5_en(1'b0), .sram5_we(1'b0), .sram5_addr('0),
    .sram5_wdata(32'd0), .sram5_be(64'd0),
    .sram5_rdata(sram_rdata[5*32 +: 32]), .sram5_rvalid(sram_rvalid[5]),
    .sram6_en(1'b0), .sram6_we(1'b0), .sram6_addr('0),
    .sram6_wdata(32'd0), .sram6_be(64'd0),
    .sram6_rdata(sram_rdata[6*32 +: 32]), .sram6_rvalid(sram_rvalid[6]),
    .sram7_en(1'b0), .sram7_we(1'b0), .sram7_addr('0),
    .sram7_wdata(32'd0), .sram7_be(64'd0),
    .sram7_rdata(sram_rdata[7*32 +: 32]), .sram7_rvalid(sram_rvalid[7]),
    .sram8_en(1'b0), .sram8_we(1'b0), .sram8_addr('0),
    .sram8_wdata(32'd0), .sram8_be(64'd0),
    .sram8_rdata(sram_rdata[8*32 +: 32]), .sram8_rvalid(sram_rvalid[8]),
    .sram9_en(1'b0), .sram9_we(1'b0), .sram9_addr('0),
    .sram9_wdata(32'd0), .sram9_be(64'd0),
    .sram9_rdata(sram_rdata[9*32 +: 32]), .sram9_rvalid(sram_rvalid[9]),
    .sram10_en(1'b0), .sram10_we(1'b0), .sram10_addr('0),
    .sram10_wdata(32'd0), .sram10_be(64'd0),
    .sram10_rdata(sram_rdata[10*32 +: 32]), .sram10_rvalid(sram_rvalid[10]),
    .sram11_en(1'b0), .sram11_we(1'b0), .sram11_addr('0),
    .sram11_wdata(32'd0), .sram11_be(64'd0),
    .sram11_rdata(sram_rdata[11*32 +: 32]), .sram11_rvalid(sram_rvalid[11]),
    .sram12_en(1'b0), .sram12_we(1'b0), .sram12_addr('0),
    .sram12_wdata(32'd0), .sram12_be(64'd0),
    .sram12_rdata(sram_rdata[12*32 +: 32]), .sram12_rvalid(sram_rvalid[12]),
    .sram13_en(1'b0), .sram13_we(1'b0), .sram13_addr('0),
    .sram13_wdata(32'd0), .sram13_be(64'd0),
    .sram13_rdata(sram_rdata[13*32 +: 32]), .sram13_rvalid(sram_rvalid[13]),
    .sram14_en(1'b0), .sram14_we(1'b0), .sram14_addr('0),
    .sram14_wdata(32'd0), .sram14_be(64'd0),
    .sram14_rdata(sram_rdata[14*32 +: 32]), .sram14_rvalid(sram_rvalid[14]),
    .sram15_en(1'b0), .sram15_we(1'b0), .sram15_addr('0),
    .sram15_wdata(32'd0), .sram15_be(64'd0),
    .sram15_rdata(sram_rdata[15*32 +: 32]), .sram15_rvalid(sram_rvalid[15]),
    .sram16_en(1'b0), .sram16_we(1'b0), .sram16_addr('0),
    .sram16_wdata(32'd0), .sram16_be(64'd0),
    .sram16_rdata(sram_rdata[16*32 +: 32]), .sram16_rvalid(sram_rvalid[16]),
    .sram17_en(1'b0), .sram17_we(1'b0), .sram17_addr('0),
    .sram17_wdata(32'd0), .sram17_be(64'd0),
    .sram17_rdata(sram_rdata[17*32 +: 32]), .sram17_rvalid(sram_rvalid[17]),
    .sram18_en(1'b0), .sram18_we(1'b0), .sram18_addr('0),
    .sram18_wdata(32'd0), .sram18_be(64'd0),
    .sram18_rdata(sram_rdata[18*32 +: 32]), .sram18_rvalid(sram_rvalid[18]),
    .sram19_en(1'b0), .sram19_we(1'b0), .sram19_addr('0),
    .sram19_wdata(32'd0), .sram19_be(64'd0),
    .sram19_rdata(sram_rdata[19*32 +: 32]), .sram19_rvalid(sram_rvalid[19]),
    .sram20_en(1'b0), .sram20_we(1'b0), .sram20_addr('0),
    .sram20_wdata(32'd0), .sram20_be(64'd0),
    .sram20_rdata(sram_rdata[20*32 +: 32]), .sram20_rvalid(sram_rvalid[20]),
    .sram21_en(1'b0), .sram21_we(1'b0), .sram21_addr('0),
    .sram21_wdata(32'd0), .sram21_be(64'd0),
    .sram21_rdata(sram_rdata[21*32 +: 32]), .sram21_rvalid(sram_rvalid[21]),
    .sram22_en(1'b0), .sram22_we(1'b0), .sram22_addr('0),
    .sram22_wdata(32'd0), .sram22_be(64'd0),
    .sram22_rdata(sram_rdata[22*32 +: 32]), .sram22_rvalid(sram_rvalid[22]),
    .sram23_en(1'b0), .sram23_we(1'b0), .sram23_addr('0),
    .sram23_wdata(32'd0), .sram23_be(64'd0),
    .sram23_rdata(sram_rdata[23*32 +: 32]), .sram23_rvalid(sram_rvalid[23]),
    .sram24_en(1'b0), .sram24_we(1'b0), .sram24_addr('0),
    .sram24_wdata(32'd0), .sram24_be(64'd0),
    .sram24_rdata(sram_rdata[24*32 +: 32]), .sram24_rvalid(sram_rvalid[24]),
    .sram25_en(1'b0), .sram25_we(1'b0), .sram25_addr('0),
    .sram25_wdata(32'd0), .sram25_be(64'd0),
    .sram25_rdata(sram_rdata[25*32 +: 32]), .sram25_rvalid(sram_rvalid[25]),
    .sram26_en(1'b0), .sram26_we(1'b0), .sram26_addr('0),
    .sram26_wdata(32'd0), .sram26_be(64'd0),
    .sram26_rdata(sram_rdata[26*32 +: 32]), .sram26_rvalid(sram_rvalid[26]),
    .sram27_en(1'b0), .sram27_we(1'b0), .sram27_addr('0),
    .sram27_wdata(32'd0), .sram27_be(64'd0),
    .sram27_rdata(sram_rdata[27*32 +: 32]), .sram27_rvalid(sram_rvalid[27]),
    .sram28_en(1'b0), .sram28_we(1'b0), .sram28_addr('0),
    .sram28_wdata(32'd0), .sram28_be(64'd0),
    .sram28_rdata(sram_rdata[28*32 +: 32]), .sram28_rvalid(sram_rvalid[28]),
    .sram29_en(1'b0), .sram29_we(1'b0), .sram29_addr('0),
    .sram29_wdata(32'd0), .sram29_be(64'd0),
    .sram29_rdata(sram_rdata[29*32 +: 32]), .sram29_rvalid(sram_rvalid[29]),
    .sram30_en(1'b0), .sram30_we(1'b0), .sram30_addr('0),
    .sram30_wdata(32'd0), .sram30_be(64'd0),
    .sram30_rdata(sram_rdata[30*32 +: 32]), .sram30_rvalid(sram_rvalid[30]),
    .sram31_en(1'b0), .sram31_we(1'b0), .sram31_addr('0),
    .sram31_wdata(32'd0), .sram31_be(64'd0),
    .sram31_rdata(sram_rdata[31*32 +: 32]), .sram31_rvalid(sram_rvalid[31]),
    .sram32_en(1'b0), .sram32_we(1'b0), .sram32_addr('0),
    .sram32_wdata(32'd0), .sram32_be(64'd0),
    .sram32_rdata(sram_rdata[32*32 +: 32]), .sram32_rvalid(sram_rvalid[32]),
    .sram33_en(1'b0), .sram33_we(1'b0), .sram33_addr('0),
    .sram33_wdata(32'd0), .sram33_be(64'd0),
    .sram33_rdata(sram_rdata[33*32 +: 32]), .sram33_rvalid(sram_rvalid[33]),
    .sram34_en(1'b0), .sram34_we(1'b0), .sram34_addr('0),
    .sram34_wdata(32'd0), .sram34_be(64'd0),
    .sram34_rdata(sram_rdata[34*32 +: 32]), .sram34_rvalid(sram_rvalid[34]),
    .sram35_en(1'b0), .sram35_we(1'b0), .sram35_addr('0),
    .sram35_wdata(32'd0), .sram35_be(64'd0),
    .sram35_rdata(sram_rdata[35*32 +: 32]), .sram35_rvalid(sram_rvalid[35]),
    .sram36_en(1'b0), .sram36_we(1'b0), .sram36_addr('0),
    .sram36_wdata(32'd0), .sram36_be(64'd0),
    .sram36_rdata(sram_rdata[36*32 +: 32]), .sram36_rvalid(sram_rvalid[36]),
    .sram37_en(1'b0), .sram37_we(1'b0), .sram37_addr('0),
    .sram37_wdata(32'd0), .sram37_be(64'd0),
    .sram37_rdata(sram_rdata[37*32 +: 32]), .sram37_rvalid(sram_rvalid[37]),
    .sram38_en(1'b0), .sram38_we(1'b0), .sram38_addr('0),
    .sram38_wdata(32'd0), .sram38_be(64'd0),
    .sram38_rdata(sram_rdata[38*32 +: 32]), .sram38_rvalid(sram_rvalid[38]),
    .sram39_en(1'b0), .sram39_we(1'b0), .sram39_addr('0),
    .sram39_wdata(32'd0), .sram39_be(64'd0),
    .sram39_rdata(sram_rdata[39*32 +: 32]), .sram39_rvalid(sram_rvalid[39]),
    .sram40_en(1'b0), .sram40_we(1'b0), .sram40_addr('0),
    .sram40_wdata(32'd0), .sram40_be(64'd0),
    .sram40_rdata(sram_rdata[40*32 +: 32]), .sram40_rvalid(sram_rvalid[40]),
    .sram41_en(1'b0), .sram41_we(1'b0), .sram41_addr('0),
    .sram41_wdata(32'd0), .sram41_be(64'd0),
    .sram41_rdata(sram_rdata[41*32 +: 32]), .sram41_rvalid(sram_rvalid[41]),
    .sram42_en(1'b0), .sram42_we(1'b0), .sram42_addr('0),
    .sram42_wdata(32'd0), .sram42_be(64'd0),
    .sram42_rdata(sram_rdata[42*32 +: 32]), .sram42_rvalid(sram_rvalid[42]),
    .sram43_en(1'b0), .sram43_we(1'b0), .sram43_addr('0),
    .sram43_wdata(32'd0), .sram43_be(64'd0),
    .sram43_rdata(sram_rdata[43*32 +: 32]), .sram43_rvalid(sram_rvalid[43]),
    .sram44_en(1'b0), .sram44_we(1'b0), .sram44_addr('0),
    .sram44_wdata(32'd0), .sram44_be(64'd0),
    .sram44_rdata(sram_rdata[44*32 +: 32]), .sram44_rvalid(sram_rvalid[44]),
    .sram45_en(1'b0), .sram45_we(1'b0), .sram45_addr('0),
    .sram45_wdata(32'd0), .sram45_be(64'd0),
    .sram45_rdata(sram_rdata[45*32 +: 32]), .sram45_rvalid(sram_rvalid[45]),
    .sram46_en(1'b0), .sram46_we(1'b0), .sram46_addr('0),
    .sram46_wdata(32'd0), .sram46_be(64'd0),
    .sram46_rdata(sram_rdata[46*32 +: 32]), .sram46_rvalid(sram_rvalid[46]),
    .sram47_en(1'b0), .sram47_we(1'b0), .sram47_addr('0),
    .sram47_wdata(32'd0), .sram47_be(64'd0),
    .sram47_rdata(sram_rdata[47*32 +: 32]), .sram47_rvalid(sram_rvalid[47]),
    .sram48_en(1'b0), .sram48_we(1'b0), .sram48_addr('0),
    .sram48_wdata(32'd0), .sram48_be(64'd0),
    .sram48_rdata(sram_rdata[48*32 +: 32]), .sram48_rvalid(sram_rvalid[48]),
    .sram49_en(1'b0), .sram49_we(1'b0), .sram49_addr('0),
    .sram49_wdata(32'd0), .sram49_be(64'd0),
    .sram49_rdata(sram_rdata[49*32 +: 32]), .sram49_rvalid(sram_rvalid[49]),
    .sram50_en(1'b0), .sram50_we(1'b0), .sram50_addr('0),
    .sram50_wdata(32'd0), .sram50_be(64'd0),
    .sram50_rdata(sram_rdata[50*32 +: 32]), .sram50_rvalid(sram_rvalid[50]),
    .sram51_en(1'b0), .sram51_we(1'b0), .sram51_addr('0),
    .sram51_wdata(32'd0), .sram51_be(64'd0),
    .sram51_rdata(sram_rdata[51*32 +: 32]), .sram51_rvalid(sram_rvalid[51]),
    .sram52_en(1'b0), .sram52_we(1'b0), .sram52_addr('0),
    .sram52_wdata(32'd0), .sram52_be(64'd0),
    .sram52_rdata(sram_rdata[52*32 +: 32]), .sram52_rvalid(sram_rvalid[52]),
    .sram53_en(1'b0), .sram53_we(1'b0), .sram53_addr('0),
    .sram53_wdata(32'd0), .sram53_be(64'd0),
    .sram53_rdata(sram_rdata[53*32 +: 32]), .sram53_rvalid(sram_rvalid[53]),
    .sram54_en(1'b0), .sram54_we(1'b0), .sram54_addr('0),
    .sram54_wdata(32'd0), .sram54_be(64'd0),
    .sram54_rdata(sram_rdata[54*32 +: 32]), .sram54_rvalid(sram_rvalid[54]),
    .sram55_en(1'b0), .sram55_we(1'b0), .sram55_addr('0),
    .sram55_wdata(32'd0), .sram55_be(64'd0),
    .sram55_rdata(sram_rdata[55*32 +: 32]), .sram55_rvalid(sram_rvalid[55]),
    .sram56_en(1'b0), .sram56_we(1'b0), .sram56_addr('0),
    .sram56_wdata(32'd0), .sram56_be(64'd0),
    .sram56_rdata(sram_rdata[56*32 +: 32]), .sram56_rvalid(sram_rvalid[56]),
    .sram57_en(1'b0), .sram57_we(1'b0), .sram57_addr('0),
    .sram57_wdata(32'd0), .sram57_be(64'd0),
    .sram57_rdata(sram_rdata[57*32 +: 32]), .sram57_rvalid(sram_rvalid[57]),
    .sram58_en(1'b0), .sram58_we(1'b0), .sram58_addr('0),
    .sram58_wdata(32'd0), .sram58_be(64'd0),
    .sram58_rdata(sram_rdata[58*32 +: 32]), .sram58_rvalid(sram_rvalid[58]),
    .sram59_en(1'b0), .sram59_we(1'b0), .sram59_addr('0),
    .sram59_wdata(32'd0), .sram59_be(64'd0),
    .sram59_rdata(sram_rdata[59*32 +: 32]), .sram59_rvalid(sram_rvalid[59]),
    .sram60_en(1'b0), .sram60_we(1'b0), .sram60_addr('0),
    .sram60_wdata(32'd0), .sram60_be(64'd0),
    .sram60_rdata(sram_rdata[60*32 +: 32]), .sram60_rvalid(sram_rvalid[60]),
    .sram61_en(1'b0), .sram61_we(1'b0), .sram61_addr('0),
    .sram61_wdata(32'd0), .sram61_be(64'd0),
    .sram61_rdata(sram_rdata[61*32 +: 32]), .sram61_rvalid(sram_rvalid[61]),
    .sram62_en(1'b0), .sram62_we(1'b0), .sram62_addr('0),
    .sram62_wdata(32'd0), .sram62_be(64'd0),
    .sram62_rdata(sram_rdata[62*32 +: 32]), .sram62_rvalid(sram_rvalid[62]),
    .sram63_en(1'b0), .sram63_we(1'b0), .sram63_addr('0),
    .sram63_wdata(32'd0), .sram63_be(64'd0),
    .sram63_rdata(sram_rdata[63*32 +: 32]), .sram63_rvalid(sram_rvalid[63]),
    .m_axi_awid    (axi_awid),
    .m_axi_awaddr  (axi_awaddr),
    .m_axi_awlen   (axi_awlen),
    .m_axi_awsize  (axi_awsize),
    .m_axi_awburst (axi_awburst),
    .m_axi_awvalid (axi_awvalid),
    .m_axi_awready (axi_awready),
    .m_axi_wdata   (axi_wdata),
    .m_axi_wstrb   (axi_wstrb),
    .m_axi_wlast   (axi_wlast),
    .m_axi_wvalid  (axi_wvalid),
    .m_axi_wready  (axi_wready),
    .m_axi_bid     (axi_bid),
    .m_axi_bresp   (axi_bresp),
    .m_axi_bvalid  (axi_bvalid),
    .m_axi_bready  (axi_bready),
    .m_axi_arid    (axi_arid),
    .m_axi_araddr  (axi_araddr),
    .m_axi_arlen   (axi_arlen),
    .m_axi_arsize  (axi_arsize),
    .m_axi_arburst (axi_arburst),
    .m_axi_arvalid (axi_arvalid),
    .m_axi_arready (axi_arready),
    .m_axi_rid     (axi_rid),
    .m_axi_rdata   (axi_rdata),
    .m_axi_rresp   (axi_rresp),
    .m_axi_rlast   (axi_rlast),
    .m_axi_rvalid  (axi_rvalid),
    .m_axi_rready  (axi_rready),
    .app_ref_req   (ref_req),
    .app_ref_ack   (ref_ack),
    .app_zq_req    (zq_req),
    .app_zq_ack    (zq_ack),
    .s_axil_awaddr (c_awaddr),
    .s_axil_awvalid(c_awvalid),
    .s_axil_awready(c_awready),
    .s_axil_wdata  (c_wdata),
    .s_axil_wstrb  (c_wstrb),
    .s_axil_wvalid (c_wvalid),
    .s_axil_wready (c_wready),
    .s_axil_bresp  (c_bresp),
    .s_axil_bvalid (c_bvalid),
    .s_axil_bready (c_bready),
    .s_axil_araddr (c_araddr),
    .s_axil_arvalid(c_arvalid),
    .s_axil_arready(c_arready),
    .s_axil_rdata  (c_rdata),
    .s_axil_rresp  (c_rresp),
    .s_axil_rvalid (c_rvalid),
    .s_axil_rready (c_rready),
    .stat_calib_done     (),
    .stat_ready          (),
    .stat_refresh_active (),
    .stat_zq_active      (),
    .stat_err            (),
    .bkp_req    (1'b0),
    .bkp_we     (1'b0),
    .bkp_port   (8'd0),
    .bkp_addr   ('0),
    .bkp_wdata  (32'd0),
    .bkp_rdata  (),
    .bkp_ack    ()
  );

  // ------------------------------------------------------------------
  // host path: JTAG-AXI (AXI4-Lite) -> xbar -> HADES CSR / board_ctrl
  // ------------------------------------------------------------------
  logic [31:0] j_awaddr, j_wdata, j_rdata, j_araddr;
  logic [3:0]  j_wstrb;
  logic        j_awvalid, j_awready, j_wvalid, j_wready, j_bvalid, j_bready;
  logic [1:0]  j_bresp, j_rresp;
  logic        j_arvalid, j_arready, j_rvalid, j_rready;

  jtag_axi_0 u_jtag_axi (
    .aclk          (ui_clk),
    .aresetn       (ui_rst_n),
    .m_axi_awaddr  (j_awaddr),
    .m_axi_awvalid (j_awvalid),
    .m_axi_awready (j_awready),
    .m_axi_wdata   (j_wdata),
    .m_axi_wstrb   (j_wstrb),
    .m_axi_wvalid  (j_wvalid),
    .m_axi_wready  (j_wready),
    .m_axi_bresp   (j_bresp),
    .m_axi_bvalid  (j_bvalid),
    .m_axi_bready  (j_bready),
    .m_axi_araddr  (j_araddr),
    .m_axi_arvalid (j_arvalid),
    .m_axi_arready (j_arready),
    .m_axi_rdata   (j_rdata),
    .m_axi_rresp   (j_rresp),
    .m_axi_rvalid  (j_rvalid),
    .m_axi_rready  (j_rready)
  );

  // board_ctrl AXI4-Lite (M1)
  logic [15:0] b_awaddr, b_araddr;
  logic        b_awvalid, b_awready, b_wvalid, b_wready, b_bvalid, b_bready;
  logic [31:0] b_wdata, b_rdata;
  logic [3:0]  b_wstrb;
  logic [1:0]  b_bresp, b_rresp;
  logic        b_arvalid, b_arready, b_rvalid, b_rready;

  board_axil_xbar u_xbar (
    .ui_clk(ui_clk), .ui_rst(ui_rst),
    .s_axil_awaddr (j_awaddr),
    .s_axil_awvalid(j_awvalid),
    .s_axil_awready(j_awready),
    .s_axil_wdata  (j_wdata),
    .s_axil_wstrb  (j_wstrb),
    .s_axil_wvalid (j_wvalid),
    .s_axil_wready (j_wready),
    .s_axil_bresp  (j_bresp),
    .s_axil_bvalid (j_bvalid),
    .s_axil_bready (j_bready),
    .s_axil_araddr (j_araddr),
    .s_axil_arvalid(j_arvalid),
    .s_axil_arready(j_arready),
    .s_axil_rdata  (j_rdata),
    .s_axil_rresp  (j_rresp),
    .s_axil_rvalid (j_rvalid),
    .s_axil_rready (j_rready),
    .m0_axil_awaddr (c_awaddr),
    .m0_axil_awvalid(c_awvalid),
    .m0_axil_awready(c_awready),
    .m0_axil_wdata  (c_wdata),
    .m0_axil_wstrb  (c_wstrb),
    .m0_axil_wvalid (c_wvalid),
    .m0_axil_wready (c_wready),
    .m0_axil_bresp  (c_bresp),
    .m0_axil_bvalid (c_bvalid),
    .m0_axil_bready (c_bready),
    .m0_axil_araddr (c_araddr),
    .m0_axil_arvalid(c_arvalid),
    .m0_axil_arready(c_arready),
    .m0_axil_rdata  (c_rdata),
    .m0_axil_rresp  (c_rresp),
    .m0_axil_rvalid (c_rvalid),
    .m0_axil_rready (c_rready),
    .m1_axil_awaddr (b_awaddr),
    .m1_axil_awvalid(b_awvalid),
    .m1_axil_awready(b_awready),
    .m1_axil_wdata  (b_wdata),
    .m1_axil_wstrb  (b_wstrb),
    .m1_axil_wvalid (b_wvalid),
    .m1_axil_wready (b_wready),
    .m1_axil_bresp  (b_bresp),
    .m1_axil_bvalid (b_bvalid),
    .m1_axil_bready (b_bready),
    .m1_axil_araddr (b_araddr),
    .m1_axil_arvalid(b_arvalid),
    .m1_axil_arready(b_arready),
    .m1_axil_rdata  (b_rdata),
    .m1_axil_rresp  (b_rresp),
    .m1_axil_rvalid (b_rvalid),
    .m1_axil_rready (b_rready)
  );

  board_ctrl u_ctrl (
    .ui_clk(ui_clk), .ui_rst(ui_rst),
    .s_axil_awaddr (b_awaddr),
    .s_axil_awvalid(b_awvalid),
    .s_axil_awready(b_awready),
    .s_axil_wdata  (b_wdata),
    .s_axil_wstrb  (b_wstrb),
    .s_axil_wvalid (b_wvalid),
    .s_axil_wready (b_wready),
    .s_axil_bresp  (b_bresp),
    .s_axil_bvalid (b_bvalid),
    .s_axil_bready (b_bready),
    .s_axil_araddr (b_araddr),
    .s_axil_arvalid(b_arvalid),
    .s_axil_arready(b_arready),
    .s_axil_rdata  (b_rdata),
    .s_axil_rresp  (b_rresp),
    .s_axil_rvalid (b_rvalid),
    .s_axil_rready (b_rready),
    .clk_div    (clk_div),
    .clk_gate   (clk_gate),
    .clk_commit (clk_commit)
  );

  // ------------------------------------------------------------------
  // ILA (ui_clk): refresh/ZQCS handshake + backend AXI activity + calib
  // ------------------------------------------------------------------
  ila_ui_0 u_ila_ui (
    .clk    (ui_clk),
    .probe0 ({ref_req, ref_ack, zq_req, zq_ack}),
    .probe1 ({axi_awvalid, axi_awready, axi_wvalid, axi_wready, axi_bvalid,
              axi_arvalid, axi_arready, axi_rvalid, axi_rready}),
    .probe2 ({calib, ui_rst, axi_rlast})
  );

  // ------------------------------------------------------------------
  // LEDs + sticky SLVERR indicator
  // ------------------------------------------------------------------
  logic [25:0] hb_cnt;
  logic        slverr_stky;
  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      hb_cnt      <= 26'd0;
      slverr_stky <= 1'b0;
    end else begin
      hb_cnt <= hb_cnt + 26'd1;
      if ((axi_bvalid && axi_bresp != 2'b00) || (axi_rvalid && axi_rresp != 2'b00))
        slverr_stky <= 1'b1;
    end
  end

  always_comb begin
    led[0] = calib;            // DDR4 calibrated
    led[1] = hb_cnt[25];       // ~4.5 Hz heartbeat: ui_clk alive
    led[2] = slverr_stky;      // any backend SLVERR since reset
  end

  // consume unused
  logic unused;
  assign unused = &{1'b0, axi_awaddr[39:34], axi_araddr[39:34], axi_bid, axi_rid,
                    clk_div_active, axi_rresp, sram_rdata};

endmodule

`default_nettype wire
