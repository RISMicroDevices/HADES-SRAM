//-----------------------------------------------------------------------------
// HADES-SRAM — SV testbench harness (M5).
// Pin-level protocol here (dual clocks, resets, AXI4-Lite BFM, SRAM port
// drivers/monitors, MIG model wiring); test intent in sim/cpp/hades_tb.cpp
// via DPI-C (expected memory, exact-latency due-cycle queues, accounting).
//
// Build variants (+define+):
//   (none)                 CSR_EN=1, SYNC    TEST=all_csr
//                          (t6,t1,t2,t3,t4,t5,t7,t9,t12,rst,t13b/c/d,t13a)
//   ASYNC                  CSR_EN=1, ASYNC   TEST=all_csr (t7/t13d walk phase)
//   CSR_STATIC             CSR_EN=0, SYNC    TEST=all_static (static,t3,t9)
//   CSR_STATIC+PARAM_OVRD  CSR_EN=0, SYNC, user P_PORT_BASE/SIZE overrides
// Dedicated runs (not in all_*): TEST=t3 +MAINT_STRESS=1 (worst-case
// maintenance alignment), TEST=t14 +RD_LAT_ADD=1500 (bit5 sentinel fault),
// TEST=t8 +DROP_RD_BEAT/+DROP_RD_BEAT2/+SLVERR_RD_BEAT/+SLVERR_WR_BEAT
// (error paths), TEST=ovf +AR_STALL_LEN=8000 (request-FIFO overflow),
// TEST=t10 +T10_PER=n (long regression; +WDOG_MS raises the watchdog).
//
// Clocks: ui_clk 300 MHz.  SYNC: port_clk derived from ui_clk by integer
// divider (same-source).  ASYNC: independent realtime generator,
// incommensurate 499.983 KHz by default; T7 adds a phase walk (~4.9 deg
// steps) and +-0.5% slow drift.
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
      sram_en[3] <= 1'b1; sram_we[3] <= 1'b0; sram_addr[3] <= 32'h0002_0000;
      hades_read_expect0(3, pcycle + 1 + cur_lat);
      @(negedge port_clk);
      sram_en[3] <= 1'b0;
      drain();
`endif
      // timeout: the dropped read completes as scheduled zeros
      @(negedge port_clk);
      sram_en[0] <= 1'b1; sram_we[0] <= 1'b0; sram_addr[0] <= 32'h0007_7777;
      hades_read_expect0(0, pcycle + 1 + cur_lat);
      @(negedge port_clk);
      sram_en[0] <= 1'b0;
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
      sram_en[0] <= 1'b1; sram_we[0] <= 1'b1; sram_addr[0] <= 32'h0000_2000;
      sram_wdata[0] <= 32'hBAD5_0000;
      @(negedge port_clk);
      sram_en[0] <= 1'b0;
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
      sram_en[0] <= 1'b1; sram_we[0] <= 1'b0; sram_addr[0] <= 32'h0007_7777;
      hades_read_expect0(0, pcycle + 1 + cur_lat);
      @(negedge port_clk);
      sram_en[0] <= 1'b0;
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
        sram_en[0] <= 1'b1; sram_we[0] <= 1'b0; sram_addr[0] <= 32'h800 + 32'(k);
        hades_read_expect_late(0, pcycle + 1 + cur_lat);  // data don't-care
      end
      @(negedge port_clk);
      sram_en[0] <= 1'b0;
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
          sram_en[p]    <= 1'b1;
          sram_we[p]    <= 1'(w[0]);
          sram_addr[p]  <= a;
          sram_wdata[p] <= d;
          if (w[0]) hades_mem_write(p, a, d);
          else      hades_read_expect(p, pcycle + 1 + cur_lat, a);
        end
      end
      @(negedge port_clk);
      for (int p = 0; p < n_ports; p++) sram_en[p] <= 1'b0;
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
          sram_en[p] <= 1'b1; sram_we[p] <= 1'b1;
          sram_addr[p] <= a; sram_wdata[p] <= d;
          hades_mem_write(p, a, d);
        end
        @(negedge port_clk);
        for (int p = 0; p < N_MAX; p++) begin
          a = 32'h0001_0000 + 32'(k);
          sram_en[p] <= 1'b1; sram_we[p] <= 1'b0; sram_addr[p] <= a;
          hades_read_expect(p, pcycle + 1 + cur_lat, a);   // RAW: new data
        end
      end
      @(negedge port_clk);
      for (int p = 0; p < N_MAX; p++) sram_en[p] <= 1'b0;
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
      sram_en[5] <= 1'b1; sram_we[5] <= 1'b0; sram_addr[5] <= 32'h100;
      @(negedge port_clk);
      sram_en[5] <= 1'b0;
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
        sram_en[p] <= 1'b1; sram_we[p] <= 1'b1;
        sram_addr[p] <= a; sram_wdata[p] <= d;
        hades_mem_write(p, a, d);
      end
      // round 1: reads; engines busy when the reset lands right after
      @(negedge port_clk);
      for (int p = 0; p < N_MAX; p++) begin
        a = 32'h0000_5040 + 32'(p);
        sram_en[p] <= 1'b1; sram_we[p] <= 1'b0; sram_addr[p] <= a;
        hades_read_expect(p, pcycle + 1 + cur_lat, a);
      end
      // suppress checks across the wiped in-flight traffic, reset NOW
      // (engines are mid-flight), drop orphaned expectations, resume
      hades_suspend_checks(1);
      for (int p = 0; p < N_MAX; p++) sram_en[p] <= 1'b0;
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
        sram_en[0] <= 1'b1; sram_we[0] <= 1'b0; sram_addr[0] <= 32'h40;
        @(negedge port_clk);
        sram_en[0] <= 1'b0;
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
    else if (test == "t7") begin calib_done = 1'b1; test_t7();      end
    else if (test == "t8") begin calib_done = 1'b1; test_t8();      end
    else if (test == "t9") begin calib_done = 1'b1; test_t9();      end
`ifndef CSR_STATIC
    else if (test == "t12") begin calib_done = 1'b1; test_t12();    end
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
