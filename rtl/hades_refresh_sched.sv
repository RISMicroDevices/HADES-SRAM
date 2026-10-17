//-----------------------------------------------------------------------------
// HADES-SRAM — refresh/ZQCS scheduler (spec 3.2: User Refresh and ZQCS Input
// mode; ui_clk domain).  The IP owns all DDR4 maintenance: the MIG never
// auto-refreshes in this mode, so dues must never be dropped (data loss).
//
// Timing model:
//   - period tick: port_clk sampled through a 2FF synchronizer, rising-edge
//     detected (<= 2 ui_clk jitter in ASYNC, absorbed by the slot margin).
//     The maintenance window is the first MAINT_SLOTS ui cycles after a tick
//     (slot-table head, spec 3.2); port service slots begin later.
//   - refresh: a free-running ui_clk timer pends one debt every
//     CFG_REFRESH_DIV cycles.  While enabled, debts are serviced ONLY inside
//     the maintenance window (zero jitter to the emulated domain, A6), at
//     most 2 per window (covers 100 KHz, where tREFI needs ~1.43 per period);
//     a debt >= 4 (insane config or clock stutter) overrides the window gate
//     — a mid-period refresh beats losing DRAM contents.  While disabled the
//     window gate is open (no port contract exists), so memory stays alive
//     across DISABLE/ENABLE reconfiguration.  The free-running timer (never
//     restarted by service) keeps the long-run issue rate exactly 1/div
//     (A6: STAT_REFCNT vs configured rate, +-1%).
//   - ZQCS: a tick counter pends a due every CFG_ZQ_DIV target periods;
//     serviced after any pending refresh in the same window.
//
// JEDEC compliance at the extremes: 100 KHz worst-case refresh spacing =
// refresh_div + one target period = 7 us + 10 us = 17 us << 9 x tREFI
// (70.2 us postponement limit); average rate is exact (debt gearing).
//-----------------------------------------------------------------------------
`default_nettype none

module hades_refresh_sched
  import hades_pkg::*;
(
  input  wire logic        ui_clk,
  input  wire logic        ui_rst,       // synchronous (top passes ui_rst_soft)
  input  wire logic        calib_done,   // MIG up: schedule only past calibration
  input  wire logic        enable,       // effective datapath enable
  input  wire logic        port_clk,     // target clock (sampled as data)
  input  wire logic [31:0] refresh_div,  // ui_clk cycles between refresh dues
  input  wire logic [31:0] zq_div,       // target periods between ZQCS dues

  output      logic        period_tick,  // 1 ui cycle: maintenance-window head
  output      logic        app_ref_req,
  input  wire logic        app_ref_ack,
  output      logic        app_zq_req,
  input  wire logic        app_zq_ack,
  output      logic        refresh_active,  // refresh handshake in flight
  output      logic        zq_active,       // ZQCS handshake in flight
  output      logic [31:0] stat_refcnt      // refreshes issued (ack count)
);

  // ------------------------------------------------------------------
  // period tick: port_clk rising edge, ui_clk domain
  // ------------------------------------------------------------------
  logic pclk_u, pclk_d;

  hades_sync2 u_tick_sync (.clk(ui_clk), .rst(ui_rst), .d(port_clk), .q(pclk_u));

  always_ff @(posedge ui_clk) begin
    if (ui_rst) pclk_d <= 1'b0;
    else        pclk_d <= pclk_u;
  end

  assign period_tick = pclk_u & ~pclk_d;

  // ------------------------------------------------------------------
  // maintenance-window gate: open for MAINT_SLOTS ui cycles after a tick
  // ------------------------------------------------------------------
  logic [15:0] win_cnt;

  always_ff @(posedge ui_clk) begin
    if (ui_rst)            win_cnt <= 16'hFFFF;
    else if (period_tick)  win_cnt <= 16'd1;
    else if (win_cnt != 16'hFFFF) win_cnt <= win_cnt + 16'd1;
  end

  wire logic win_open = (win_cnt < 16'(MAINT_SLOTS));

  // ------------------------------------------------------------------
  // refresh due timer (free-running) + debt (saturating)
  // ------------------------------------------------------------------
  logic [31:0] ref_timer;
  logic [3:0]  ref_debt;
  logic        ref_ack_fire, zq_ack_fire;

  wire logic due_inc = calib_done && (refresh_div != 32'd0)
                       && (ref_timer >= refresh_div - 32'd1);

  always_ff @(posedge ui_clk) begin
    if (ui_rst || !calib_done) begin
      ref_timer <= 32'd0;
      ref_debt  <= 4'd0;
    end else begin
      if (refresh_div != 32'd0)
        ref_timer <= due_inc ? 32'd0 : ref_timer + 32'd1;
      unique case ({due_inc, ref_ack_fire})
        2'b10:   ref_debt <= (ref_debt == 4'd15) ? 4'd15 : ref_debt + 4'd1;
        2'b01:   ref_debt <= ref_debt - 4'd1;   // > 0: service started on debt
        default: ;                              // 00: hold; 11: replace
      endcase
    end
  end

  // ------------------------------------------------------------------
  // ZQCS due: count target periods (ticks) — runs whenever calibrated, so
  // ZQ continues across DISABLE intervals as long as port_clk runs
  // ------------------------------------------------------------------
  logic [31:0] zq_ticks;
  logic        zq_due;

  always_ff @(posedge ui_clk) begin
    if (ui_rst || !calib_done) begin
      zq_ticks <= 32'd0;
      zq_due   <= 1'b0;
    end else begin
      if (zq_ack_fire)
        zq_due <= 1'b0;
      if (period_tick) begin
        if (zq_div != 32'd0 && zq_ticks >= zq_div - 32'd1) begin
          zq_ticks <= 32'd0;
          zq_due   <= 1'b1;
        end else begin
          zq_ticks <= zq_ticks + 32'd1;
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // issue FSM: refresh first, then ZQCS, handshakes inside the window
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {S_IDLE, S_REF, S_ZQ} state_e;
  state_e state;

  logic [1:0] refs_this_win;

  always_ff @(posedge ui_clk) begin
    if (ui_rst)            refs_this_win <= 2'd0;
    else if (period_tick)  refs_this_win <= 2'd0;
    else if (ref_ack_fire) refs_this_win <= refs_this_win + 2'd1;
  end

  wire logic urgency   = (ref_debt >= 4'd4);
  wire logic ref_allow = (ref_debt != 4'd0)
                         && (urgency || !enable
                             || (win_open && refs_this_win < 2'd2));
  wire logic zq_allow  = zq_due && (!enable || win_open);

  assign ref_ack_fire = (state == S_REF) && app_ref_ack;
  assign zq_ack_fire  = (state == S_ZQ)  && app_zq_ack;

  always_ff @(posedge ui_clk) begin
    if (ui_rst || !calib_done) begin
      state       <= S_IDLE;
      stat_refcnt <= 32'd0;
    end else begin
      if (ref_ack_fire)
        stat_refcnt <= stat_refcnt + 32'd1;
      unique case (state)
        S_IDLE: begin
          if (ref_allow)     state <= S_REF;
          else if (zq_allow) state <= S_ZQ;
        end
        S_REF:   if (app_ref_ack) state <= S_IDLE;
        S_ZQ:    if (app_zq_ack)  state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

  always_comb begin
    app_ref_req    = (state == S_REF);
    app_zq_req     = (state == S_ZQ);
    refresh_active = (state == S_REF);
    zq_active      = (state == S_ZQ);
  end

endmodule

`default_nettype wire
