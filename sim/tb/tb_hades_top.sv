//-----------------------------------------------------------------------------
// HADES-SRAM — SV testbench harness (M2).
// Pin-level protocol here (dual clocks, resets, AXI4-Lite BFM, SRAM port
// drivers/monitors, MIG model wiring); test intent in sim/cpp/hades_tb.cpp
// via DPI-C (expected memory, exact-latency due-cycle queues, accounting).
//
// Build variants (+define+):
//   (none)                 CSR_EN=1, SYNC    TEST=all_csr (t6_csr,t1,t2,t3,t13a)
//   ASYNC                  CSR_EN=1, ASYNC   TEST=all_csr
//   CSR_STATIC             CSR_EN=0, SYNC    TEST=all_static (static,t3)
//   CSR_STATIC+PARAM_OVRD  CSR_EN=0, SYNC, user P_PORT_BASE/SIZE overrides
// Dedicated runs (not in all_*): TEST=t3 +MAINT_STRESS=1 (worst-case
// maintenance alignment), TEST=t14 +RD_LAT_ADD=<n> (bit5 sentinel fault).
//
// Clocks: ui_clk 300 MHz.  SYNC: port_clk derived from ui_clk by integer
// divider (same-source).  ASYNC: independent realtime generator,
// incommensurate 499.983 KHz by default.
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
`ifdef ASYNC
  localparam bit TB_SYNC = 1'b0;
`else
  localparam bit TB_SYNC = 1'b1;
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

`ifdef ASYNC
  // independent incommensurate source: 499.983 KHz (period 2000.068 ns)
  realtime pc_half_ns;
  initial pc_half_ns = 1000.034;
  always begin
    #(pc_half_ns);
    if (pc_run) port_clk = ~port_clk;
  end
  task automatic port_clk_set_khz(input int khz); pc_half_ns = 500000.0 / khz; endtask
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
  task automatic port_clk_set_khz(input int khz); pc_div = 300_000 / khz; endtask
`endif

  task automatic port_clk_stop();  begin pc_run = 1'b0; port_clk = 1'b0; end endtask
  task automatic port_clk_start(); begin pc_run = 1'b1; end endtask

  logic ui_rst_n   = 1'b0;
  logic port_rst_n = 1'b0;
  logic calib_done = 1'b0;

  // ------------------------------------------------------------------
  // DUT <-> MIG model wiring
  // ------------------------------------------------------------------
  logic [N_MAX-1:0]                sram_en    = '0;
  logic [N_MAX-1:0]                sram_we    = '0;
  logic [N_MAX-1:0][AW_DEFAULT-1:0] sram_addr  = '0;
  logic [N_MAX-1:0][DW_DEFAULT-1:0] sram_wdata = '0;
  logic [N_MAX-1:0][DW_DEFAULT-1:0] sram_rdata;
  logic [N_MAX-1:0]                sram_rvalid;

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
  hades_sram_top #(
    .N        (N_MAX),
    .DW       (DW_DEFAULT),
    .AW       (AW_DEFAULT),
    .IS_SYNC  (TB_SYNC),
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
    .bkp_req    (1'b0),
    .bkp_we     (1'b0),
    .bkp_port   (8'd0),
    .bkp_addr   ('0),
    .bkp_wdata  ('0),
    .bkp_rdata  (),
    .bkp_ack    ()
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
  import "DPI-C" context function longint  hades_exp_id();
  import "DPI-C" context function longint  hades_exp_params(int is_sync, int ui_mhz,
                                                           int port_mib, int dw, int n_max);
  import "DPI-C" context function void     hades_set_port_cfg(int port, longint base, int size);
  import "DPI-C" context function longint  hades_exp_base(int port);
  import "DPI-C" context function int      hades_exp_size(int port);
  import "DPI-C" context function void     hades_mem_write(int port, int addr, int data);
  import "DPI-C" context function void     hades_read_expect(int port, longint due_cycle, int addr);
  import "DPI-C" context function void     hades_read_expect0(int port, longint due_cycle);
  import "DPI-C" context function void     hades_read_expect_late(int port, longint due_cycle);
  import "DPI-C" context function void     hades_port_edge(int port, longint cycle,
                                                           int rvalid, int rdata);
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
      if ($isunknown(sram_rvalid[p]) ||
          (!expect_sentinel && sram_rvalid[p] === 1'b1 && $isunknown(sram_rdata[p])))
        hades_fail($sformatf("X on port %0d outputs at pcycle %0d (rvalid=%b rdata=%h)",
                             p, pcycle, sram_rvalid[p], sram_rdata[p]));
      hades_port_edge(p, pcycle, (sram_rvalid[p] === 1'b1) ? 1 : 0,
                      32'(sram_rdata[p]));
    end
  end

  // ------------------------------------------------------------------
  // SRAM port drivers (drive at negedge; sampled at next posedge = pcycle+1)
  // ------------------------------------------------------------------
  int cur_lat = 2;   // TB's view of the active L

  task automatic sram_write(input int port, input int addr, input int data);
    @(negedge port_clk);
    sram_en[port]    <= 1'b1;
    sram_we[port]    <= 1'b1;
    sram_addr[port]  <= addr;
    sram_wdata[port] <= data;
    hades_mem_write(port, addr, data);
    @(negedge port_clk);
    sram_en[port]    <= 1'b0;
  endtask

  task automatic sram_read(input int port, input int addr);
    @(negedge port_clk);
    sram_en[port]    <= 1'b1;
    sram_we[port]    <= 1'b0;
    sram_addr[port]  <= addr;
    hades_read_expect(port, pcycle + 1 + cur_lat, addr);
    @(negedge port_clk);
    sram_en[port]    <= 1'b0;
  endtask

  // fully back-to-back read burst (one read every port period)
  task automatic sram_read_burst(input int port, input int n, input int addr0);
    for (int k = 0; k < n; k++) begin
      @(negedge port_clk);
      sram_en[port]   <= 1'b1;
      sram_we[port]   <= 1'b0;
      sram_addr[port] <= addr0 + k;
      hades_read_expect(port, pcycle + 1 + cur_lat, addr0 + k);
    end
    @(negedge port_clk);
    sram_en[port] <= 1'b0;
  endtask

  // fully back-to-back write burst
  task automatic sram_write_burst(input int port, input int n, input int addr0,
                                  input int data0);
    for (int k = 0; k < n; k++) begin
      @(negedge port_clk);
      sram_en[port]   <= 1'b1;
      sram_we[port]   <= 1'b1;
      sram_addr[port] <= addr0 + k;
      sram_wdata[port] <= data0 + k;
      hades_mem_write(port, addr0 + k, data0 + k);
    end
    @(negedge port_clk);
    sram_en[port] <= 1'b0;
  endtask

  // read to an illegal address: synthetic zero response, still on schedule
  task automatic sram_read_illegal(input int port, input int addr);
    @(negedge port_clk);
    sram_en[port]    <= 1'b1;
    sram_we[port]    <= 1'b0;
    sram_addr[port]  <= addr;
    hades_read_expect0(port, pcycle + 1 + cur_lat);
    @(negedge port_clk);
    sram_en[port]    <= 1'b0;
  endtask

  // let all outstanding reads release
  task automatic drain();
    repeat (5) @(negedge port_clk);
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

  // CSR helper: program L and enable mask, wait for ready.
  // The frequency monitor must observe a running, legal port_clk first
  // (spec init sequence: check MEAS_PERIOD before ENABLE; 4-period average
  // is valid after 5 edges).  Also normalize the address map of the test
  // ports (previous phases may have shrunk PORT_SIZE for error tests).
  task automatic csr_enable(input int lat, input longint en_mask);
    logic [31:0] rd;
    begin
      axil_wr(CSR_CTRL, 32'h0);
      axil_wr(CSR_CFG_LATENCY, 32'(lat));
      axil_wr(CSR_PORT_EN_LO, 32'(en_mask));
      axil_wr(CSR_PORT_EN_HI, 32'(en_mask >> 32));
      axil_wr(CSR_CFG_PORTS, 32'(N_MAX));
      for (int p = 0; p < 2; p++) begin
        axil_wr(CSR_PORT_SEL, 32'(p));
        axil_wr(CSR_PORT_BASE, 32'(p * 32'h0004_0000));  // i * 2^18 beats
        axil_wr(CSR_PORT_BASE_HI, 32'd0);
        axil_wr(CSR_PORT_SIZE, 32'h0040_0000);           // 16 MiB in DW32 words
      end
      repeat (6) @(posedge port_clk);   // let freq_mon measure the clock
      axil_wr(CSR_CTRL, 32'h1);
      axil_rd(CSR_STATUS, rd);
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
        sram_en[0] <= 1'b1; sram_we[0] <= 1'b1; sram_addr[0] <= 32'h777; sram_wdata[0] <= 32'hDEAD_1234;
        hades_mem_write(0, 32'h777, 32'hDEAD_1234);
        @(negedge port_clk);
        sram_en[0] <= 1'b1; sram_we[0] <= 1'b0; sram_addr[0] <= 32'h777;
        hades_read_expect(0, pcycle + 1 + cur_lat, 32'h777);
        @(negedge port_clk);
        sram_en[0] <= 1'b0;
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
        sram_en[0] <= 1'b1; sram_we[0] <= 1'b0; sram_addr[0] <= 32'h300 + k;
        hades_read_expect_late(0, pcycle + 1 + 2);
        @(negedge port_clk);
        sram_en[0] <= 1'b0;
        @(negedge port_clk);
      end
      drain();
      expect_sentinel = 0;
      hades_check_eq("T14 static: sentinel stat_err[5] set", stat_err[5], 1);
`else
      csr_enable(1, 64'h1);   // L=1: tightest response window
      expect_sentinel = 1;
      sram_write(0, 32'h300, 32'h5AFE_0001);
      for (int k = 0; k < 3; k++) begin
        @(negedge port_clk);
        sram_en[0] <= 1'b1; sram_we[0] <= 1'b0; sram_addr[0] <= 32'h300 + k;
        hades_read_expect_late(0, pcycle + 1 + cur_lat);
        @(negedge port_clk);
        sram_en[0] <= 1'b0;
        @(negedge port_clk);
      end
      drain();
      expect_sentinel = 0;
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T14: ERR_STATUS.bit5 sentinel set", rd & 32'h20, 32'h20);
      hades_check_eq("T14: first-error port = 0", (rd >> 8) & 32'hFF, 0);
      axil_wr(CSR_ERR_STATUS, 32'h20);   // W1C
      axil_rd(CSR_ERR_STATUS, rd);
      hades_check_eq("T14: bit5 W1C clears", rd & 32'h3F, 0);
      axil_wr(CSR_CTRL, 32'h0);
`endif
    end
  endtask

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
      force sram_addr  = 'x;
      force sram_wdata = 'x;
      repeat (3) @(posedge port_clk);
      release sram_addr;
      release sram_wdata;

      // X on the internal quasi-static slot data while idle: the shaper must
      // never sample it (no release pending)
      force dut.g_ports[0].u_port.slot_data_u = 'x;
      repeat (3) @(posedge port_clk);
      release dut.g_ports[0].u_port.slot_data_u;

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
    do_reset();

    if (test == "all" || test == "all_csr" || test == "all_static") begin
`ifdef CSR_STATIC
      test_static();
      hades_phase_init();
      test_t3();
`else
      test_t6_csr();
      hades_phase_init();
      test_t1(n_ops);
      hades_phase_init();
      test_t2();
      hades_phase_init();
      test_t3();
      hades_phase_init();
      test_t13a();
`endif
    end else if (test == "t6_csr")        test_t6_csr();
    else if (test == "t1") begin calib_done = 1'b1; test_t1(n_ops); end
    else if (test == "t2") begin calib_done = 1'b1; test_t2();      end
    else if (test == "t3") begin calib_done = 1'b1; test_t3();      end
    else if (test == "t14") begin                    test_t14();    end
    else if (test == "t13a") begin calib_done = 1'b1; test_t13a();  end
    else if (test == "static_smoke")     test_static();
    else $display("[HADES-TB] unknown TEST=%s", test);

    hades_report();
    if (hades_err_count() == 0) $display("HADES_TEST_PASS");
    else                        $display("HADES_TEST_FAIL");
    $finish;
  end

  // watchdog (t1 at 1e5 ops needs ~200 ms of simulated time)
  initial begin
    #600_000_000;   // 600 ms
    $display("HADES_TEST_FAIL: watchdog timeout");
    $finish;
  end

`ifdef DEBUG_T1
  // temporary debug probe (M2 bring-up); not part of the test suite
  always @(posedge ui_clk) begin
    if (dut.g_ports[0].u_port.rsp_vld)
      $display("RSP0 t=%0t wrp=%0d vld=%b", $time,
               dut.g_ports[0].u_port.slot_wr_ptr_u, dut.g_ports[0].u_port.slot_vld_u);
    if (dut.g_ports[0].u_port.rel_fire_u)
      $display("CLR0 t=%0t clr=%0d vld=%b", $time,
               dut.g_ports[0].u_port.rel_slot_u, dut.g_ports[0].u_port.slot_vld_u);
    if (|dut.p_err_slot)
      $display("UIEVT t=%0t slot=%h", $time, dut.p_err_slot);
  end
  always @(posedge port_clk) begin
    #(0.001);
    if (dut.g_ports[0].u_port.sh_rel)
      $display("REL0 t=%0t pcyc=%0d ptr=%0d", $time, pcycle,
               dut.g_ports[0].u_port.sh_rel_slot);
    if (|dut.p_err_window || |dut.p_err_ovf)
      $display("PCEVT t=%0t pcyc=%0d win=%h ovf=%h", $time, pcycle,
               dut.p_err_window, dut.p_err_ovf);
  end
`endif

endmodule

`default_nettype wire
