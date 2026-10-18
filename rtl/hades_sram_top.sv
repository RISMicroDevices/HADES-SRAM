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
// M2: full single/multi-port datapath — hades_port (CDC + shaper) array ->
// hades_mig_if (FCFS engine, AXI4, outstanding).  M3: hades_refresh_sched
// (user refresh/ZQCS, maintenance window at the slot-table head).
// M4: hades_arbiter (TDMA static slot gating in front of mig_if) +
// hades_backdoor (CSR/pin host channel, lowest-priority requester).
//-----------------------------------------------------------------------------
`default_nettype none

module hades_sram_top
  import hades_pkg::*;
#(
  parameter int  N                    = N_MAX,   // active ports (<= N_MAX)
  parameter int  DW                   = DW_DEFAULT,
  parameter int  AW                   = AW_DEFAULT,
  parameter bit  IS_SYNC              = 1'b1,    // CLK_MODE: 1=SYNC, 0=ASYNC
  parameter bit  CSR_EN               = 1'b1,
  parameter bit  SELFTEST_EN          = 1'b0,
  parameter int  TARGET_PERIOD_CYCLES = TARGET_PERIOD_500K,
  // static-variant (CSR_EN=0) configuration — all user-overridable
  parameter logic [1:0]  P_L              = 2'd2,
  parameter logic [N_MAX-1:0] P_PORT_EN   = {N_MAX{1'b1}},
  parameter logic [31:0] P_MIN_PERIOD     = 32'(TARGET_PERIOD_500K),
  parameter logic [31:0] P_REFRESH_DIV    = 32'd2100,
  parameter logic [31:0] P_ZQ_DIV         = 32'd32000,
  parameter logic [N_MAX*BASE_W-1:0] P_PORT_BASE = dflt_base_flat(),
  parameter logic [N_MAX*32-1:0]     P_PORT_SIZE = dflt_size_flat(DW)
) (
  input  wire logic ui_clk,
  input  wire logic ui_rst_n,
  input  wire logic port_clk,
  input  wire logic port_rst_n,
  input  wire logic calib_done,      // MIG init_calib_complete

  // ---- emulated SRAM ports (port_clk domain) ----
  input  wire logic [N-1:0]           sram_en,
  input  wire logic [N-1:0]           sram_we,
  input  wire logic [N-1:0][AW-1:0]   sram_addr,
  input  wire logic [N-1:0][DW-1:0]   sram_wdata,
  output          logic [N-1:0][DW-1:0] sram_rdata,
  output          logic [N-1:0]       sram_rvalid,

  // ---- AXI4 master to MIG (512-bit data, 4-bit ID, 40-bit byte address) ----
  output          logic [3:0]         m_axi_awid,
  output          logic [AXI_ADDR_W-1:0] m_axi_awaddr,
  output          logic [7:0]         m_axi_awlen,
  output          logic [2:0]         m_axi_awsize,
  output          logic [1:0]         m_axi_awburst,
  output          logic               m_axi_awvalid,
  input  wire logic                   m_axi_awready,
  output          logic [511:0]       m_axi_wdata,
  output          logic [63:0]        m_axi_wstrb,
  output          logic               m_axi_wlast,
  output          logic               m_axi_wvalid,
  input  wire logic                   m_axi_wready,
  input  wire logic [3:0]             m_axi_bid,
  input  wire logic [1:0]             m_axi_bresp,
  input  wire logic                   m_axi_bvalid,
  output          logic               m_axi_bready,
  output          logic [3:0]         m_axi_arid,
  output          logic [AXI_ADDR_W-1:0] m_axi_araddr,
  output          logic [7:0]         m_axi_arlen,
  output          logic [2:0]         m_axi_arsize,
  output          logic [1:0]         m_axi_arburst,
  output          logic               m_axi_arvalid,
  input  wire logic                   m_axi_arready,
  input  wire logic [3:0]             m_axi_rid,
  input  wire logic [511:0]           m_axi_rdata,
  input  wire logic [1:0]             m_axi_rresp,
  input  wire logic                   m_axi_rlast,
  input  wire logic                   m_axi_rvalid,
  output          logic               m_axi_rready,

  // ---- MIG user refresh / ZQCS (spec 3.2) — driven by hades_refresh_sched ----
  output          logic               app_ref_req,
  input  wire logic                   app_ref_ack,
  output          logic               app_zq_req,
  input  wire logic                   app_zq_ack,

  // ---- CSR AXI4-Lite slave (CSR_EN=1) ----
  input  wire logic [15:0]            s_axil_awaddr,
  input  wire logic                   s_axil_awvalid,
  output          logic               s_axil_awready,
  input  wire logic [31:0]            s_axil_wdata,
  input  wire logic [3:0]             s_axil_wstrb,
  input  wire logic                   s_axil_wvalid,
  output          logic               s_axil_wready,
  output          logic [1:0]         s_axil_bresp,
  output          logic               s_axil_bvalid,
  input  wire logic                   s_axil_bready,
  input  wire logic [15:0]            s_axil_araddr,
  input  wire logic                   s_axil_arvalid,
  output          logic               s_axil_arready,
  output          logic [31:0]        s_axil_rdata,
  output          logic [1:0]         s_axil_rresp,
  output          logic               s_axil_rvalid,
  input  wire logic                   s_axil_rready,

  // ---- static-variant pins (CSR_EN=0) ----
  output          logic               stat_calib_done,
  output          logic               stat_ready,
  output          logic               stat_refresh_active,
  output          logic               stat_zq_active,
  output          logic [7:0]         stat_err,      // mirrors ERR_STATUS[5:0]

  // ---- pin-level backdoor (CSR_EN=0; CSR_EN=1 uses the BKP_* registers) ----
  input  wire logic                   bkp_req,
  input  wire logic                   bkp_we,
  input  wire logic [7:0]             bkp_port,
  input  wire logic [BASE_W-1:0]      bkp_addr,
  input  wire logic [DW-1:0]          bkp_wdata,
  output          logic [DW-1:0]      bkp_rdata,
  output          logic               bkp_ack
);

  // ------------------------------------------------------------------
  // Spec 4.3 static slot-budget assertion (T11 guard)
  // ------------------------------------------------------------------
  if (!budget_ok(N, TARGET_PERIOD_CYCLES, IS_SYNC ? CLK_MODE_SYNC : CLK_MODE_ASYNC))
  begin : g_budget_violation
    HADES_SLOT_BUDGET_EXCEEDED__reduce_N_or_lower_target_frequency u_forced_error();
`ifndef SYNTHESIS
    initial $error("HADES-SRAM: slot budget exceeded (N=%0d, target=%0d ui_clk cycles)",
                   N, TARGET_PERIOD_CYCLES);
`endif
  end

  // ------------------------------------------------------------------
  // Resets
  // ------------------------------------------------------------------
  logic ui_rst, port_rst;
  hades_rst_sync u_rst_ui   (.clk(ui_clk),   .arst_n(ui_rst_n),   .srst(ui_rst));
  hades_rst_sync u_rst_port (.clk(port_clk), .arst_n(port_rst_n), .srst(port_rst));

  // ------------------------------------------------------------------
  // Frequency monitor
  // ------------------------------------------------------------------
  logic [31:0] meas_period;
  logic        clk_running, over_freq;

  cfg_t        cfg_eff;
  logic        enable_eff;

  hades_freq_mon #(
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
  logic        tmo_stky_u, slv_stky_u, ill_stky_u;  // static-mirror stickies
  logic        mig_err_illegal, mig_err_timeout, mig_err_slverr;
  logic [7:0]  mig_err_port;
  logic [31:0] mig_err_addr;
  logic        soft_port;                // stretched soft reset, port_clk dom.
  logic        clr_tog_u;                // ui_clk: toggles per err_clr pulse
  logic [7:0]  clr_port_u;
  logic        clr_tog_p, clr_tog_pd;    // port_clk domain
  wire  logic  clr_edge_p = clr_tog_p ^ clr_tog_pd;

  // backdoor command interface (from CSR registers or static pins) + engine
  logic                  bkp_cmd_rd, bkp_cmd_wr;
  logic [7:0]            bkp_cmd_port;
  logic [39:0]           bkp_cmd_addr;
  logic [DW-1:0]         bkp_cmd_wdata;
  logic                  bkp_busy, bkp_done, bkp_err;
  logic [DW-1:0]         bkp_rdata_eng;

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
      hades_sync2 u_soft_back (.clk(ui_clk), .rst(ui_rst),
                               .d(soft_port), .q(soft_port_u));

      hades_csr #(
        .IS_SYNC (IS_SYNC),
        .DW      (DW)
      ) u_csr (
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
        .calib_done      (calib_done),
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
      assign bkp_cmd_wdata = DW'(c_bkp_wdata);   // DW>32: upper bits read 0

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
                                     P_PORT_BASE, P_PORT_SIZE);
      assign enable_eff = calib_done & clk_running & ~over_freq;

      assign soft_reset_stb = 1'b0;
      assign port_err_clr   = 1'b0;
      assign port_sel       = 8'd0;

      // pin-level backdoor drive: req synced; the integrator holds the
      // fields stable while req is high; ack = done pulse (above)
      logic bkp_req_u, bkp_req_d;
      hades_sync2 u_bkp_req_sync (.clk(ui_clk), .rst(ui_rst),
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

      assign stat_calib_done     = calib_done;
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

  hades_sync2 u_soft_sync (.clk(port_clk), .rst(port_rst), .d(soft_lvl), .q(soft_port));
  wire logic port_rst_eff = port_rst | soft_port;
  wire logic ui_rst_soft  = ui_rst | soft_reset_stb;

  // ------------------------------------------------------------------
  // Backend engine: TDMA slot gating (M4: hades_arbiter) in front of the
  // FCFS engine; backdoor enters mig_if as the lowest-priority requester.
  // ------------------------------------------------------------------
  logic [N-1:0]          pr_rd_vld;  // port FIFO heads (raw)
  logic [N-1:0][AW-1:0]  p_rd_addr;
  logic [N-1:0]          pr_wr_vld;
  logic [N-1:0][AW-1:0]  p_wr_addr;
  logic [N-1:0][DW-1:0]  p_wr_data;
  logic [N-1:0]          p_rd_vld;   // arbiter-gated, to mig_if
  logic [N-1:0]          p_wr_vld;
  logic [N-1:0]          p_rd_gnt;
  logic [N-1:0]          p_wr_gnt;
  logic [N-1:0]          p_rsp_vld;
  logic [N-1:0][DW-1:0]  p_rsp_data;

  // backdoor engine <-> mig_if
  logic                  bk_rd_req, bk_rd_gnt, bk_rd_done;
  logic [BASE_W-1:0]     bk_rd_beat;
  logic [5:0]            bk_rd_lane;
  logic [DW-1:0]         bk_rd_data;
  logic                  bk_wr_req, bk_wr_gnt;
  logic [BASE_W-1:0]     bk_wr_beat;
  logic [5:0]            bk_wr_lane;
  logic [DW-1:0]         bk_wr_data;

  hades_arbiter #(
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
    .wr_vld_o    (p_wr_vld)
  );

  hades_mig_if #(
    .N  (N),
    .DW (DW),
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
    .err_clr_port  (port_sel),
    .err_clr       (port_err_clr),
    .soft_rst      (soft_reset_stb),
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

  hades_backdoor #(
    .DW (DW),
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

  for (genvar i = 0; i < N; i++) begin : g_ports
    hades_port #(
      .AW      (AW),
      .DW      (DW),
      .IS_SYNC (IS_SYNC)
    ) u_port (
      .port_clk   (port_clk),
      .port_rst   (port_rst_eff),
      .en         (sram_en[i]),
      .we         (sram_we[i]),
      .addr       (sram_addr[i]),
      .wdata      (sram_wdata[i]),
      .rdata      (sram_rdata[i]),
      .rvalid     (sram_rvalid[i]),
      .cfg_en     (cfg_eff.port_en[i]),
      .cfg_lat    (cfg_eff.latency),
      .enabled    (enable_eff),
      .ui_clk     (ui_clk),
      .ui_rst     (ui_rst_soft),
      .rd_vld     (pr_rd_vld[i]),
      .rd_addr    (p_rd_addr[i]),
      .rd_gnt     (p_rd_gnt[i]),
      .wr_vld     (pr_wr_vld[i]),
      .wr_addr    (p_wr_addr[i]),
      .wr_data    (p_wr_data[i]),
      .wr_gnt     (p_wr_gnt[i]),
      .rsp_vld    (p_rsp_vld[i]),
      .rsp_data   (p_rsp_data[i]),
      .err_win_tog  (win_tog_p[i]),
      .err_ovf_tog  (ovf_tog_p[i]),
      .err_win_stky (win_stky[i]),
      .err_ovf_stky (ovf_stky[i]),
      .err_slot     (p_err_slot[i]),
      .err_clr      (clr_edge_p && clr_port_u == 8'(i))
    );
  end

  // ------------------------------------------------------------------
  // Error-event plumbing
  //  - window/overflow records are kept per port inside hades_port (sticky
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

  hades_sync2 u_clr_sync (.clk(port_clk), .rst(port_rst), .d(clr_tog_u), .q(clr_tog_p));

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
    hades_sync2 u_win_evt (.clk(ui_clk), .rst(ui_rst_soft),
                           .d(win_tog_p[i]), .q(win_lvl_u[i]));
    hades_sync2 u_ovf_evt (.clk(ui_clk), .rst(ui_rst_soft),
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

  // quasi-static views of the port_clk stickies for the ui_clk domain
  logic [N-1:0] win_stky_q, ovf_stky_q;
  for (genvar i = 0; i < N; i++) begin : g_stky_qs
    hades_qs_bus #(.WIDTH(2), .DST_SYNC_STAGES(0)) u_stky_qs (
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
  logic [13:0] evt_blk;
  always_ff @(posedge ui_clk) begin
    if (ui_rst)                    evt_blk <= 14'd0;
    else if (soft_reset_stb)       evt_blk <= 14'd10000;
    else if (evt_blk != 14'd0)     evt_blk <= evt_blk - 14'd1;
  end
  wire logic evt_en = (evt_blk == 14'd0);

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
  hades_refresh_sched u_refresh_sched (
    .ui_clk         (ui_clk),
    .ui_rst         (ui_rst_soft),
    .calib_done     (calib_done),
    .enable         (enable_eff),
    .port_clk       (port_clk),
    .refresh_div    (cfg_eff.refresh_div),
    .zq_div         (cfg_eff.zq_div),
    .period_tick    (period_tick),
    .app_ref_req    (app_ref_req),
    .app_ref_ack    (app_ref_ack),
    .app_zq_req     (app_zq_req),
    .app_zq_ack     (app_zq_ack),
    .refresh_active (refresh_active),
    .zq_active      (zq_active),
    .stat_refcnt    (stat_refcnt)
  );

  // ------------------------------------------------------------------
  // consume not-yet-used inputs
  // ------------------------------------------------------------------
  logic unused;
  assign unused = &{1'b0,
                    meas_period[31] /* MEAS read by CSR only when CSR_EN */,
                    SELFTEST_EN};                         // M5

endmodule

`default_nettype wire
