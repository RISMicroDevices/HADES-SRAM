//-----------------------------------------------------------------------------
// HADES-SRAM — SV testbench harness.
// Pin-level protocol lives here (dual clocks, resets, AXI4-Lite BFM, SRAM
// port drive/sample); test intent lives in sim/cpp/hades_tb.cpp via DPI-C.
//
// Build variants (via +define+):
//   (none)                 CSR_EN=1, SYNC clocks   -> TEST=t6_csr
//   CSR_STATIC             CSR_EN=0                -> TEST=static_smoke
//   CSR_STATIC+PARAM_OVRD  CSR_EN=0 with user P_PORT_BASE/SIZE overrides
//
// Clocks: ui_clk 300 MHz.  In SYNC builds port_clk is derived from ui_clk by
// an integer divider (same-source, like an MMCM output); default 500 KHz
// (divide by 600).  ASYNC (independent realtime generator) hooks arrive M2+.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_hades_top;
  import hades_pkg::*;

  // ------------------------------------------------------------------
  // Build-variant parameters
  // ------------------------------------------------------------------
`ifdef CSR_STATIC
  localparam bit TB_CSR_EN = 1'b0;
`else
  localparam bit TB_CSR_EN = 1'b1;
`endif

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
    v = dflt_size_flat();
`ifdef PARAM_OVRD
    v[3*32 +: 32] = OVRD_SIZE3;
`endif
    return v;
  endfunction

  // ------------------------------------------------------------------
  // Clocks / resets / board-level inputs
  // ------------------------------------------------------------------
  logic ui_clk = 1'b0;
  always #(1.6666667) ui_clk = ~ui_clk;   // 300 MHz

  // port_clk: divided from ui_clk (SYNC: same source).  pc_div = ui cycles
  // per port period; 600 => 500 KHz, 150 => 2 MHz (over-freq fault case).
  int   pc_div = 600;
  bit   pc_run = 1'b1;
  int   pc_cnt = 0;
  logic port_clk = 1'b0;

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

  task automatic port_clk_stop();                 pc_run = 1'b0; endtask
  task automatic port_clk_start();                pc_run = 1'b1; endtask
  task automatic port_clk_set_khz(input int khz); pc_div = 300_000 / khz; endtask

  logic ui_rst_n   = 1'b0;
  logic port_rst_n = 1'b0;
  logic calib_done = 1'b0;

  // ------------------------------------------------------------------
  // DUT signals
  // ------------------------------------------------------------------
  logic [N_MAX-1:0]          sram_en    = '0;
  logic [N_MAX-1:0]          sram_we    = '0;
  logic [N_MAX-1:0][AW_DEFAULT-1:0] sram_addr  = '0;
  logic [N_MAX-1:0][DW_DEFAULT-1:0] sram_wdata = '0;
  logic [N_MAX-1:0][DW_DEFAULT-1:0] sram_rdata;
  logic [N_MAX-1:0]          sram_rvalid;

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

  hades_sram_top #(
    .N        (N_MAX),
    .DW       (DW_DEFAULT),
    .AW       (AW_DEFAULT),
    .IS_SYNC  (1'b1),
    .CSR_EN   (TB_CSR_EN),
    .P_PORT_BASE (tb_base_flat()),
    .P_PORT_SIZE (tb_size_flat())
  ) dut (
    .ui_clk         (ui_clk),
    .ui_rst_n       (ui_rst_n),
    .port_clk       (port_clk),
    .port_rst_n     (port_rst_n),
    .calib_done     (calib_done),
    .sram_en        (sram_en),
    .sram_we        (sram_we),
    .sram_addr      (sram_addr),
    .sram_wdata     (sram_wdata),
    .sram_rdata     (sram_rdata),
    .sram_rvalid    (sram_rvalid),
    .m_axi_awid     (),
    .m_axi_awaddr   (),
    .m_axi_awlen    (),
    .m_axi_awsize   (),
    .m_axi_awburst  (),
    .m_axi_awvalid  (),
    .m_axi_awready  (1'b0),
    .m_axi_wdata    (),
    .m_axi_wstrb    (),
    .m_axi_wlast    (),
    .m_axi_wvalid   (),
    .m_axi_wready   (1'b0),
    .m_axi_bid      (4'd0),
    .m_axi_bresp    (2'd0),
    .m_axi_bvalid   (1'b0),
    .m_axi_bready   (),
    .m_axi_arid     (),
    .m_axi_araddr   (),
    .m_axi_arlen    (),
    .m_axi_arsize   (),
    .m_axi_arburst  (),
    .m_axi_arvalid  (),
    .m_axi_arready  (1'b0),
    .m_axi_rid      (4'd0),
    .m_axi_rdata    (512'd0),
    .m_axi_rresp    (2'd0),
    .m_axi_rlast    (1'b0),
    .m_axi_rvalid   (1'b0),
    .m_axi_rready   (),
    .app_ref_req    (),
    .app_ref_ack    (1'b0),
    .app_zq_req     (),
    .app_zq_ack     (1'b0),
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
    .bkp_req    (1'b0),
    .bkp_we     (1'b0),
    .bkp_port   (8'd0),
    .bkp_addr   ('0),
    .bkp_wdata  ('0),
    .bkp_rdata  (),
    .bkp_ack    ()
  );

  // ------------------------------------------------------------------
  // DPI-C imports (C++ side: expected models + pass/fail accounting)
  // ------------------------------------------------------------------
  import "DPI-C" context function void     hades_init();
  import "DPI-C" context function longint  hades_exp_id();
  import "DPI-C" context function longint  hades_exp_params(int is_sync, int ui_mhz,
                                                           int port_mib, int dw, int n_max);
  import "DPI-C" context function void     hades_set_port_cfg(int port, longint base, int size);
  import "DPI-C" context function longint  hades_exp_base(int port);
  import "DPI-C" context function int      hades_exp_size(int port);
  import "DPI-C" context function void     hades_check_eq(string what, longint got, longint exp);
  import "DPI-C" context function void     hades_check_range(string what, longint got,
                                                             longint lo, longint hi);
  import "DPI-C" context function void     hades_log(string msg);
  import "DPI-C" context function int      hades_err_count();
  import "DPI-C" context function void     hades_report();

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
  // Reset
  // ------------------------------------------------------------------
  task automatic do_reset();
    begin
      ui_rst_n   = 1'b0;
      port_rst_n = 1'b0;
      calib_done = 1'b0;
      repeat (10) @(posedge ui_clk);
      ui_rst_n   = 1'b1;
      port_rst_n = 1'b1;
      repeat (10) @(posedge ui_clk);
    end
  endtask

  // ------------------------------------------------------------------
  // T6 basic (CSR_EN=1): register map, indexed window, meas period,
  // enable / soft-reset flow, frequency interlock
  // ------------------------------------------------------------------
  task automatic test_t6_csr();
    logic [31:0] rd;
    longint      b;
    int unsigned s;
    begin
      hades_log("--- T6 basic: CSR flow ---");

      // ID / PARAMS
      axil_rd(CSR_ID, rd);
      hades_check_eq("ID", rd, hades_exp_id());
      axil_rd(CSR_PARAMS, rd);
      hades_check_eq("PARAMS", rd, hades_exp_params(1, UI_CLK_MHZ, PORT_MB_DEFAULT,
                                                    DW_DEFAULT, N_MAX));

      // ENABLE rejected while calib_done=0
      axil_wr(CSR_CTRL, 32'h1);
      axil_rd(CSR_CTRL, rd);
      hades_check_eq("ENABLE reject (no calib)", rd, 0);
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("ERR_STATUS.bit4 (no calib)", rd, 32'h10);
      axil_wr(CSR_ERR_STATUS, 32'h10);       // W1C
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("ERR_STATUS W1C", rd, 0);
      calib_done = 1'b1;
      repeat (4) @(posedge ui_clk);

      // indexed window: program all 64 ports
      for (int p = 0; p < N_MAX; p++) begin
        b = p * 64'h0100_0000 + 64'h0000_4000;
        if (p == 5) b = (64'h2 << 32) | 64'h1234_5678;  // exercise PORT_BASE_HI
        s = 32'h0001_0000 + p;
        hades_set_port_cfg(p, b, s);
        axil_wr(CSR_PORT_SEL, p);
        axil_wr(CSR_PORT_BASE, 32'(b));
        axil_wr(CSR_PORT_BASE_HI, 32'(b >> 32));
        axil_wr(CSR_PORT_SIZE, s);
      end
      // read back and verify
      for (int p = 0; p < N_MAX; p++) begin
        axil_wr(CSR_PORT_SEL, p);
        axil_rd(CSR_PORT_BASE, rd);
        hades_check_eq($sformatf("PORT_BASE[%0d]", p), rd, hades_exp_base(p) & 64'hFFFF_FFFF);
        axil_rd(CSR_PORT_BASE_HI, rd);
        hades_check_eq($sformatf("PORT_BASE_HI[%0d]", p), rd,
                       (hades_exp_base(p) >> 32) & 64'h3);
        axil_rd(CSR_PORT_SIZE, rd);
        hades_check_eq($sformatf("PORT_SIZE[%0d]", p), rd,
                       hades_exp_size(p) & 64'hFFFF_FFFF);
      end

      // out-of-range PORT_SEL: reads return 0, writes ignored
      axil_wr(CSR_PORT_SEL, 32'd200);
      axil_rd(CSR_PORT_BASE, rd);
      hades_check_eq("PORT_SEL oob read 0", rd, 0);
      axil_wr(CSR_PORT_BASE, 32'hFFFF_FFFF);
      axil_wr(CSR_PORT_SEL, 32'd0);
      axil_rd(CSR_PORT_BASE, rd);
      hades_check_eq("oob write ignored", rd, hades_exp_base(0) & 64'hFFFF_FFFF);

      // CFG_LATENCY: legal/illegal values
      axil_wr(CSR_CFG_LATENCY, 32'd1);
      axil_rd(CSR_CFG_LATENCY, rd);
      hades_check_eq("CFG_LATENCY=1", rd, 1);
      axil_wr(CSR_CFG_LATENCY, 32'd3);
      axil_rd(CSR_CFG_LATENCY, rd);
      hades_check_eq("CFG_LATENCY illegal ignored", rd, 1);
      axil_wr(CSR_CFG_LATENCY, 32'd2);
      axil_rd(CSR_CFG_LATENCY, rd);
      hades_check_eq("CFG_LATENCY=2", rd, 2);

      // PORT_EN masks / CFG_PORTS
      axil_wr(CSR_PORT_EN_LO, 32'hDEAD_BEEF);
      axil_rd(CSR_PORT_EN_LO, rd);
      hades_check_eq("PORT_EN_LO", rd, 32'hDEAD_BEEF);
      axil_wr(CSR_PORT_EN_HI, 32'h0BAD_F00D);
      axil_rd(CSR_PORT_EN_HI, rd);
      hades_check_eq("PORT_EN_HI", rd, 32'h0BAD_F00D);
      axil_wr(CSR_CFG_PORTS, 32'd64);
      axil_rd(CSR_CFG_PORTS, rd);
      hades_check_eq("CFG_PORTS", rd, 64);

      // MEAS_PERIOD: SYNC divider clock => exactly 600 ui_clk cycles
      repeat (5) @(posedge port_clk);
      axil_rd(CSR_MEAS_PERIOD, rd);
      hades_check_eq("MEAS_PERIOD @500KHz", rd, 600);

      // ENABLE -> READY
      axil_wr(CSR_CTRL, 32'h1);
      axil_rd(CSR_CTRL, rd);
      hades_check_eq("ENABLE set", rd, 1);
      axil_rd(CSR_STATUS, rd);
      hades_check_eq("STATUS calib+ready", rd, 32'h3);

      // SOFT_RESET: state cleared, config retained
      axil_wr(CSR_CTRL, 32'h2);
      axil_rd(CSR_CTRL, rd);
      hades_check_eq("SOFT_RESET clears enable", rd, 0);
      axil_rd(CSR_STATUS, rd);
      hades_check_eq("SOFT_RESET ready=0", rd, 32'h1);   // calib still done
      axil_rd(CSR_CFG_PORTS, rd);
      hades_check_eq("config retained", rd, 64);

      // clock stop: ENABLE rejected, bit4 set, W1C, auto-recover on restart
      port_clk_stop();
      #60_000;                                          // > STOP_TIMEOUT
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

      // over-frequency: 2 MHz > 500 KHz limit => reject
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
  // Static-variant smoke (CSR_EN=0): no bus traffic; auto-enable; pins
  // ------------------------------------------------------------------
  task automatic test_static_smoke();
    begin
      hades_log("--- static-variant smoke (CSR_EN=0) ---");
      #10_000;
      hades_check_eq("static: not ready before calib", stat_ready, 0);
      calib_done = 1'b1;
      #10_000;
      hades_check_eq("static: stat_calib_done", stat_calib_done, 1);
      hades_check_eq("static: auto-enabled ready", stat_ready, 1);
      hades_check_eq("static: stat_err clean", stat_err, 0);

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

`ifdef PARAM_OVRD
      // user P_PORT_BASE / P_PORT_SIZE overrides must reach cfg_t
      hades_check_eq("ovrd base[3]", dut.cfg_eff.port_base[3], OVRD_BASE3);
      hades_check_eq("ovrd size[3]", dut.cfg_eff.port_size[3], OVRD_SIZE3);
      hades_check_eq("ovrd base[5]", dut.cfg_eff.port_base[5], OVRD_BASE5);
      hades_check_eq("dflt base[0] kept", dut.cfg_eff.port_base[0], 0);
      hades_check_eq("dflt size[0] kept", dut.cfg_eff.port_size[0], 32'(PORT_WORDS_DEFAULT));
`endif
    end
  endtask

  // ------------------------------------------------------------------
  // Main
  // ------------------------------------------------------------------
  initial begin : p_main
    string test;
    if (!$value$plusargs("TEST=%s", test)) test = "t6_csr";
    hades_init();
    do_reset();
    if (test == "t6_csr")              test_t6_csr();
    else if (test == "static_smoke")   test_static_smoke();
    else $display("[HADES-TB] unknown TEST=%s", test);
    hades_report();
    if (hades_err_count() == 0) $display("HADES_TEST_PASS");
    else                        $display("HADES_TEST_FAIL");
    $finish;
  end

  // watchdog
  initial begin
    #10_000_000;   // 10 ms
    $display("HADES_TEST_FAIL: watchdog timeout");
    $finish;
  end

endmodule

`default_nettype wire
