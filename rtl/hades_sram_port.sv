//-----------------------------------------------------------------------------
// HADES-SRAM — one emulated SRAM port (spec 3.1), containing its whole
// cross-domain structure (spec 3.1: internal to hades_sram_port, transparent to
// the integrator):
//
//   port_clk domain                          ui_clk domain
//   --------------                           -------------
//   request capture -> hades_sram_afifo (Gray ptrs + quasi-static entries) -->
//   timing shaper  <-- 2 response hold slots (quasi-static, qs_bus S=0) ---
//
// The same structure serves SYNC and ASYNC: in SYNC the crossings are plain
// timed paths and the whitelist CDC below is a legal superset (spec 4.1).
//
// Throughput/latency budget (spec 1/4.3): <= 1 request per port per target
// period; response lands in its hold slot within one period; request-FIFO
// depth 8 absorbs the Gray-pointer round trip (~2 port_clk cycles) for
// sustained back-to-back accesses on consecutive port edges.
//-----------------------------------------------------------------------------
`default_nettype none

module hades_sram_port
  import hades_sram_pkg::*;
#(
  parameter int AW      = AW_DEFAULT,
  parameter int DW      = DW_DEFAULT,
  parameter bit IS_SYNC = 1'b1,
  // M5-hw on-chip self-test (spec 6.2): 0 = absent (default), 1 = hades_sram_selftest
  // engine instantiated; it drives the request inputs while st_run is active
  parameter bit SELFTEST_EN  = 1'b0,
  parameter int PORT_ID      = 0,     // PRBS seed discriminator
  parameter int SELFTEST_BLK = 256    // words written+read per pass
) (
  // ---- target domain (port_clk) ----
  input  wire logic           port_clk,
  input  wire logic           port_rst,   // synchronous, active high
  input  wire logic           en,
  input  wire logic           we,         // 1=write, 0=read
  input  wire logic [AW-1:0]  addr,       // DW-word address
  input  wire logic [DW-1:0]  wdata,
  output          logic [DW-1:0] rdata,
  output          logic          rvalid,

  // ---- config (ui_clk domain registers; quasi-static during operation) ----
  input  wire logic           cfg_en,     // this port enabled
  input  wire logic [1:0]     cfg_lat,    // L
  input  wire logic           enabled,    // global effective enable

  // ---- on-chip self-test (used only when SELFTEST_EN=1) ----
  input  wire logic           st_run,     // run level (ui_clk domain; synced inside)
  output      logic           err_st_tog, // toggle per selftest error event

  // ---- host domain (ui_clk): request/response handshake with mig_if ----
  input  wire logic           ui_clk,
  input  wire logic           ui_rst,
  output          logic       rd_vld,     // request FIFO not empty
  output          logic [AW-1:0] rd_addr, // FIFO head (quasi-static)
  input  wire logic           rd_gnt,     // 1 ui_clk cycle: head consumed
  output          logic       wr_vld,
  output          logic [AW-1:0]  wr_addr,
  output          logic [DW-1:0]  wr_data,
  input  wire logic           wr_gnt,     // 1 ui_clk cycle: head consumed
  input  wire logic           rsp_vld,    // 1 ui_clk cycle: read response
  input  wire logic [DW-1:0]  rsp_data,

  // ---- error records (port_clk domain): sticky levels (static pin mirror)
  //      + event toggles (one flip per violation; the ui_clk side edge-
  //      detects, same scheme as the release events).  err_clr is the
  //      per-port clear pulse from the shared CSR-indexed clear crossing.
  //      Violations on one port are >= 1 target period apart, so no toggle
  //      event can be lost.
  output      logic       err_win_tog,   // toggle per window sentinel event
  output      logic       err_ovf_tog,   // toggle per request-FIFO overflow
  output      logic       err_win_stky,  // sticky level (port reset / err_clr)
  output      logic       err_ovf_stky,
  output      logic       err_slot,      // 1 ui_clk cycle: response slot overflow
  input  wire logic       err_clr        // 1 port_clk cycle: clear stickies
);

  // ------------------------------------------------------------------
  // declarations (hoisted: no use-before-declare anywhere)
  // ------------------------------------------------------------------
  logic        accept, rd_req_p, wr_req_p;
  logic        rd_vld_n, wr_vld_n;
  logic        rd_full, wr_full;
  logic        rd_ovf, wr_ovf;
  logic [3:0]  slot_vld_u;                  // ui_clk: slot valid flags
  logic [3:0][DW-1:0] slot_data_u;          // ui_clk: slot data
  logic [1:0]  slot_wr_ptr_u;
  logic [3:0]  slot_vld_q;                  // quasi-static view (port_clk reads)
  logic [3:0][DW-1:0] slot_data_q;
  logic        sh_rel;
  logic [1:0]  sh_rel_slot;
  logic        sh_err_window;
  logic        rel_lvl_u;                   // release toggle synced to ui_clk
  logic [1:0]  rel_slot_u;                  // released slot, quasi-static
  logic        rel_d_u;
  logic        rel_fire_u;                  // 1 ui_clk cycle per release

  // self-test stimulus mux (SELFTEST_EN builds): while the engine is active
  // it drives the request inputs instead of the integrator pins
  logic        st_active;
  logic        st_req_en, st_req_we;
  logic [AW-1:0] st_req_addr;
  logic [DW-1:0] st_req_wdata;
  logic        req_en, req_we;
  logic [AW-1:0] req_addr;
  logic [DW-1:0] req_wdata;

  assign req_en    = st_active ? st_req_en    : en;
  assign req_we    = st_active ? st_req_we    : we;
  assign req_addr  = st_active ? st_req_addr  : addr;
  assign req_wdata = st_active ? st_req_wdata : wdata;

  // request accepted only when the port is live
  assign accept   = req_en & cfg_en & enabled;
  assign rd_req_p = accept & ~req_we;
  assign wr_req_p = accept &  req_we;

  // =========================================================================
  // Read request FIFO (port_clk -> ui_clk), depth 8
  // =========================================================================
  hades_sram_afifo #(.WIDTH(AW), .DEPTH(8)) u_rd_fifo (
    .wclk   (port_clk),
    .wrst   (port_rst),
    .wpush  (rd_req_p),
    .wdata  (req_addr),
    .wfull  (rd_full),
    .rclk   (ui_clk),
    .rrst   (ui_rst),
    .rpop   (rd_gnt),
    .rdata  (rd_addr),
    .rempty (rd_vld_n)
  );
  assign rd_vld = ~rd_vld_n;

  // =========================================================================
  // Write request FIFO (port_clk -> ui_clk), depth 8 (spec minimum 2)
  // =========================================================================
  hades_sram_afifo #(.WIDTH(AW+DW), .DEPTH(8)) u_wr_fifo (
    .wclk   (port_clk),
    .wrst   (port_rst),
    .wpush  (wr_req_p),
    .wdata  ({req_addr, req_wdata}),
    .wfull  (wr_full),
    .rclk   (ui_clk),
    .rrst   (ui_rst),
    .rpop   (wr_gnt),
    .rdata  ({wr_addr, wr_data}),
    .rempty (wr_vld_n)
  );
  assign wr_vld = ~wr_vld_n;

  // overflow sentinels (must never fire under the slot budget)
  always_ff @(posedge port_clk) begin
    if (port_rst) begin
      rd_ovf <= 1'b0;
      wr_ovf <= 1'b0;
    end else begin
      rd_ovf <= rd_req_p & rd_full;
      wr_ovf <= wr_req_p & wr_full;
    end
  end

  // ------------------------------------------------------------------
  // error records: sticky levels + event toggles (see port list notes)
  // ------------------------------------------------------------------
  logic win_stky_r, ovf_stky_r;
  logic win_tog_r,  ovf_tog_r;
  wire  logic ovf_evt = rd_ovf | wr_ovf;

  always_ff @(posedge port_clk) begin
    if (port_rst) begin
      win_stky_r <= 1'b0;
      ovf_stky_r <= 1'b0;
      win_tog_r  <= 1'b0;
      ovf_tog_r  <= 1'b0;
    end else begin
      if (sh_err_window) begin
        win_stky_r <= 1'b1;
        win_tog_r  <= ~win_tog_r;
      end
      if (ovf_evt) begin
        ovf_stky_r <= 1'b1;
        ovf_tog_r  <= ~ovf_tog_r;
      end
      if (err_clr) begin
        win_stky_r <= 1'b0;
        ovf_stky_r <= 1'b0;
      end
    end
  end

  assign err_win_tog  = win_tog_r;
  assign err_ovf_tog  = ovf_tog_r;
  assign err_win_stky = win_stky_r;
  assign err_ovf_stky = ovf_stky_r;

  // =========================================================================
  // Response hold slots (ui_clk writes; port_clk shaper samples quasi-static)
  // 4 slots: slot j is rewritten 4 target periods after its last write —
  // always after the consumption flag has crossed back and freed it.
  // =========================================================================
  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      slot_wr_ptr_u <= 2'b00;
      slot_vld_u    <= 4'b0000;
      slot_data_u   <= '0;
      err_slot      <= 1'b0;
    end else begin
      err_slot <= 1'b0;
      if (rsp_vld) begin
        if (slot_vld_u[slot_wr_ptr_u]) err_slot <= 1'b1;  // never by budget
        slot_data_u[slot_wr_ptr_u] <= rsp_data;
        slot_vld_u [slot_wr_ptr_u] <= 1'b1;
        slot_wr_ptr_u              <= slot_wr_ptr_u + 2'd1;
      end
      // consumption returns from port_clk; one toggle flip per release
      if (rel_fire_u)
        slot_vld_u[rel_slot_u] <= 1'b0;
    end
  end

  // quasi-static view for the shaper (stable microseconds before sampling)
  for (genvar s = 0; s < 4; s++) begin : g_slot_qs
    hades_sram_qs_bus #(.WIDTH(DW+1), .DST_SYNC_STAGES(0)) u_slot_qs (
      .src_clk   (1'b0), .src_rst (1'b0),
      .src_data  ({slot_vld_u[s], slot_data_u[s]}),
      .src_upd   (1'b1),
      .dst_clk   (1'b0), .dst_rst (1'b0),
      .dst_data  ({slot_vld_q[s], slot_data_q[s]}),
      .dst_valid ()
    );
  end

  // =========================================================================
  // Timing shaper (port_clk domain; spec 4.2)
  // =========================================================================
  hades_sram_timing_shaper #(.DW(DW)) u_shaper (
    .port_clk   (port_clk),
    .port_rst   (port_rst),
    .rd_req     (rd_req_p),
    .lat        (cfg_lat),
    .slot_vld   (slot_vld_q),
    .slot_data  (slot_data_q),
    .rvalid     (rvalid),
    .rdata      (rdata),
    .rel        (sh_rel),
    .rel_slot   (sh_rel_slot),
    .err_window (sh_err_window)
  );

  // release *events* return to ui_clk as a toggle (one flip per release).
  // A level + edge-detect would collapse back-to-back releases (rel stays
  // high for the whole burst); the toggle preserves every event.  The slot
  // index is captured INTO the same port_clk register set at the toggle edge,
  // so it travels with the event (sampling the live shaper register a period
  // later would return the NEXT release's slot during back-to-back bursts).
  logic rel_tog_p;
  logic [1:0] rel_slot_p;
  always_ff @(posedge port_clk) begin
    if (port_rst) begin
      rel_tog_p  <= 1'b0;
      rel_slot_p <= 2'b00;
    end else if (sh_rel) begin
      rel_tog_p  <= ~rel_tog_p;
      rel_slot_p <= sh_rel_slot;
    end
  end

  hades_sram_sync2 u_rel_sync (.clk(ui_clk), .rst(ui_rst), .d(rel_tog_p), .q(rel_lvl_u));
  hades_sram_qs_bus #(.WIDTH(2), .DST_SYNC_STAGES(0)) u_rel_slot_qs (
    .src_clk   (1'b0), .src_rst (1'b0),
    .src_data  (rel_slot_p),
    .src_upd   (1'b1),
    .dst_clk   (1'b0), .dst_rst (1'b0),
    .dst_data  (rel_slot_u),
    .dst_valid ()
  );

  always_ff @(posedge ui_clk) begin
    if (ui_rst) rel_d_u <= 1'b0;
    else        rel_d_u <= rel_lvl_u;
  end
  // rel_lvl_u carries the toggle; an event fires on any change
  assign rel_fire_u = rel_lvl_u ^ rel_d_u;

  // IS_SYNC is carried for constraints/CDC_OVHD accounting; the structure is
  // identical for both CLK_MODEs (the whitelist is a superset of SYNC needs).

  // =========================================================================
  // On-chip self-test (M5-hw, spec 6.2).  Only elaborated when SELFTEST_EN=1;
  // otherwise the request mux selects the integrator pins and the error
  // toggle ties off — zero functional and timing difference.
  // =========================================================================
  if (SELFTEST_EN) begin : g_selftest
    hades_sram_selftest #(
      .AW      (AW),
      .DW      (DW),
      .PORT_ID (PORT_ID),
      .BLK     (SELFTEST_BLK)
    ) u_selftest (
      .port_clk   (port_clk),
      .port_rst   (port_rst),
      .run        (st_run),
      .port_live  (cfg_en & enabled),
      .lat        (cfg_lat),
      .active     (st_active),
      .req_en     (st_req_en),
      .req_we     (st_req_we),
      .req_addr   (st_req_addr),
      .req_wdata  (st_req_wdata),
      .chk_rd_req (rd_req_p),
      .rvalid     (rvalid),
      .rdata      (rdata),
      .err_tog    (err_st_tog)
    );
  end else begin : g_no_selftest
    assign st_active    = 1'b0;
    assign st_req_en    = 1'b0;
    assign st_req_we    = 1'b0;
    assign st_req_addr  = '0;
    assign st_req_wdata = '0;
    assign err_st_tog   = 1'b0;
    logic unused_st;
    assign unused_st = &{1'b0, st_run};
  end

endmodule

`default_nettype wire
