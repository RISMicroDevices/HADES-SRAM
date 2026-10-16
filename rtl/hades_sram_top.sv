//-----------------------------------------------------------------------------
// HADES-SRAM — top level (spec 3.x).  N emulated SRAM ports (port_clk
// domain) backed by one MIG AXI4 channel (ui_clk domain).
//
// Build-time variants:
//   CLK_MODE (IS_SYNC): 1=SYNC (default; same-source clocks, XDC-declared
//                       phase) / 0=ASYNC (independent clocks; whitelist CDC)
//   CSR_EN:   1 = AXI4-Lite CSR-configurable (default, spec 3.3)
//             0 = static hard-wired; all configuration from parameters
//                 (P_L, P_PORT_EN, P_MIN_PERIOD, P_REFRESH_DIV, P_ZQ_DIV and
//                 the per-port flat vectors P_PORT_BASE / P_PORT_SIZE, which
//                 are fully user-overridable), auto-enable, pin-level status
//                 and backdoor port instead of a bus.
//
// M1 skeleton: CSR + frequency monitor + empty per-port datapath; AXI4
// master and user-refresh/ZQCS handshake tied off (M2/M3).
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
  parameter logic [N_MAX*32-1:0]     P_PORT_SIZE = dflt_size_flat()
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

  // ---- AXI4 master to MIG (512-bit data, 4-bit ID) — M2; tied off in M1 ----
  output          logic [3:0]         m_axi_awid,
  output          logic [BASE_W-1:0]  m_axi_awaddr,
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
  output          logic [BASE_W-1:0]  m_axi_araddr,
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

  // ---- MIG user refresh / ZQCS (spec 3.2) — M3; tied off in M1 ----
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

  // ---- pin-level backdoor (CSR_EN=0) — M4; inactive in M1 ----
  input  wire logic                   bkp_req,
  input  wire logic                   bkp_we,
  input  wire logic [7:0]             bkp_port,
  input  wire logic [BASE_W-1:0]      bkp_addr,
  input  wire logic [DW-1:0]          bkp_wdata,
  output          logic [DW-1:0]      bkp_rdata,
  output          logic               bkp_ack
);

  // ------------------------------------------------------------------
  // Spec 4.3 static slot-budget assertion (T11 guard): elaboration must
  // fail for an infeasible (N, frequency, maintenance) combination.
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
  // Resets (async-assert / sync-deassert per domain; active-high internal)
  // ------------------------------------------------------------------
  logic ui_rst, port_rst;
  hades_rst_sync u_rst_ui   (.clk(ui_clk),   .arst_n(ui_rst_n),   .srst(ui_rst));
  hades_rst_sync u_rst_port (.clk(port_clk), .arst_n(port_rst_n), .srst(port_rst));

  // ------------------------------------------------------------------
  // Frequency monitor: MEAS_PERIOD + clock-running + over-freq interlock
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
  generate
    if (CSR_EN) begin : g_csr
      logic soft_reset_stb;  // M2+ datapath reset; unused in M1
      logic port_err_clr;    // M2+ per-port err counter clear; unused in M1

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
        .refresh_active  (1'b0),        // M3
        .zq_active       (1'b0),        // M3
        .err_in          (5'b0),        // M2-M5
        .err_in_port     (8'd0),
        .err_in_addr     (32'd0),
        .stat_maxlat     (32'd0),       // M2
        .stat_refcnt     (32'd0),       // M3
        .stat_tot_rd     (64'd0),       // M2
        .stat_tot_wr     (64'd0),       // M2
        .port_stat_rd    ('0),          // M2
        .port_stat_wr    ('0),          // M2
        .port_stat_err   ('0),          // M2
        .cfg             (cfg_eff),
        .enable          (enable_eff),
        .soft_reset_stb  (soft_reset_stb),
        .port_err_clr    (port_err_clr),
        .port_sel_o      ()
      );

      // static-variant pins inactive
      assign stat_calib_done     = 1'b0;
      assign stat_ready          = 1'b0;
      assign stat_refresh_active = 1'b0;
      assign stat_zq_active      = 1'b0;
      assign stat_err            = 8'd0;

    end else begin : g_static
      assign cfg_eff    = static_cfg(P_L, P_PORT_EN, P_MIN_PERIOD,
                                     P_REFRESH_DIV, P_ZQ_DIV,
                                     P_PORT_BASE, P_PORT_SIZE);
      assign enable_eff = calib_done & clk_running & ~over_freq;

      assign stat_calib_done     = calib_done;
      assign stat_ready          = enable_eff;
      assign stat_refresh_active = 1'b0;   // M3
      assign stat_zq_active      = 1'b0;   // M3
      // level-style mirror of ERR_STATUS semantics; bit4 = enable withheld
      assign stat_err            = {2'b00, 1'b0, ~(clk_running & ~over_freq), 4'b0000};

      // CSR pins inactive
      assign s_axil_awready = 1'b0;
      assign s_axil_wready  = 1'b0;
      assign s_axil_bresp   = 2'b00;
      assign s_axil_bvalid  = 1'b0;
      assign s_axil_arready = 1'b0;
      assign s_axil_rdata   = 32'd0;
      assign s_axil_rresp   = 2'b00;
      assign s_axil_rvalid  = 1'b0;
    end
  endgenerate

  // ------------------------------------------------------------------
  // Emulated port array — for generate, no hand-copied instances
  // ------------------------------------------------------------------
  logic [N-1:0]          req_valid;
  logic [N-1:0]          req_we;
  logic [N-1:0][AW-1:0]  req_addr;
  logic [N-1:0][DW-1:0]  req_wdata;
  logic [N-1:0]          req_gnt;    // M4 arbiter grant; 0 in M1
  logic [N-1:0]          rsp_valid;  // M2 response; 0 in M1
  logic [N-1:0][DW-1:0]  rsp_data;

  assign req_gnt  = '0;
  assign rsp_valid = '0;
  assign rsp_data  = '0;

  for (genvar i = 0; i < N; i++) begin : g_ports
    hades_port #(
      .AW      (AW),
      .DW      (DW),
      .IS_SYNC (IS_SYNC)
    ) u_port (
      .port_clk  (port_clk),
      .port_rst  (port_rst),
      .en        (sram_en[i]),
      .we        (sram_we[i]),
      .addr      (sram_addr[i]),
      .wdata     (sram_wdata[i]),
      .rdata     (sram_rdata[i]),
      .rvalid    (sram_rvalid[i]),
      .ui_clk    (ui_clk),
      .ui_rst    (ui_rst),
      .req_valid (req_valid[i]),
      .req_we    (req_we[i]),
      .req_addr  (req_addr[i]),
      .req_wdata (req_wdata[i]),
      .req_gnt   (req_gnt[i]),
      .rsp_valid (rsp_valid[i]),
      .rsp_data  (rsp_data[i])
    );
  end

  // ------------------------------------------------------------------
  // M1 tie-offs: AXI4 master, user refresh/ZQCS, backdoor
  // ------------------------------------------------------------------
  assign m_axi_awid    = 4'd0;
  assign m_axi_awaddr  = '0;
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awsize  = 3'b110;   // 64 bytes
  assign m_axi_awburst = 2'b01;    // INCR
  assign m_axi_awvalid = 1'b0;
  assign m_axi_wdata   = '0;
  assign m_axi_wstrb   = '0;
  assign m_axi_wlast   = 1'b0;
  assign m_axi_wvalid  = 1'b0;
  assign m_axi_bready  = 1'b1;
  assign m_axi_arid    = 4'd0;
  assign m_axi_araddr  = '0;
  assign m_axi_arlen   = 8'd0;
  assign m_axi_arsize  = 3'b110;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arvalid = 1'b0;
  assign m_axi_rready  = 1'b1;

  assign app_ref_req = 1'b0;
  assign app_zq_req  = 1'b0;

  assign bkp_rdata = '0;
  assign bkp_ack   = 1'b0;

  // M1: consume not-yet-used inputs so lint stays quiet
  logic unused;
  assign unused = &{1'b0, m_axi_awready, m_axi_wready, m_axi_bid, m_axi_bresp,
                    m_axi_bvalid, m_axi_arready, m_axi_rid, m_axi_rdata,
                    m_axi_rresp, m_axi_rlast, m_axi_rvalid,
                    app_ref_ack, app_zq_ack,
                    bkp_req, bkp_we, bkp_port, bkp_addr, bkp_wdata,
                    req_valid, req_we, req_addr, req_wdata,
                    cfg_eff.latency, cfg_eff.port_en, cfg_eff.active_ports,
                    cfg_eff.refresh_div, cfg_eff.zq_div, cfg_eff.port_base,
                    cfg_eff.port_size, enable_eff, SELFTEST_EN};

endmodule

`default_nettype wire
