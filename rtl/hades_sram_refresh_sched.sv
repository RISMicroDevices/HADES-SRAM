//-----------------------------------------------------------------------------
// HADES-SRAM — refresh/ZQCS scheduler (spec 3.2: User Refresh and ZQCS Input
// mode; ui_clk domain).  The IP owns all DDR4 maintenance: the MIG never
// auto-refreshes in this mode, so dues must never be dropped (data loss).
//
// Timing model:
//   - period tick: port_clk sampled through a 2FF synchronizer, rising-edge
//     detected (<= 2 ui_clk jitter in ASYNC, absorbed by the slot margin).
//     The arbiter's slot table keeps port service behind a MAINT_SLOTS head
//     window (spec 3.2).
//   - refresh: a free-running ui_clk timer pends one debt every
//     CFG_REFRESH_DIV cycles.  While enabled, debts are serviced when the
//     backend is ENGINE-IDLE (no pending requests, engines in IDLE) — the
//     per-period idle gap behind the drain absorbs the ~tRFC AR blocking so
//     maintenance never delays a port slot (A4, 2026-10-21: window-head
//     service collided with the 64-port drain on the real MIG, whose
//     refresh blocks AR far longer than tRFC alone).  A debt >= 4 (insane
//     config, clock stutter, or a load with no idle gaps) overrides the
//     idle gate — a mid-drain refresh beats losing DRAM contents.  While
//     disabled the gate is open (no port contract exists), so memory stays
//     alive across DISABLE/ENABLE reconfiguration.  The free-running timer
//     (never restarted by service) keeps the long-run issue rate exactly
//     1/div (A6: STAT_REFCNT vs configured rate, +-1%).
//   - ZQCS: a tick counter pends a due every CFG_ZQ_DIV target periods;
//     serviced after any pending refresh, under the same idle gate.
//
// JEDEC compliance at the extremes: 100 KHz worst-case refresh spacing =
// refresh_div + one target period = 7 us + 10 us = 17 us << 9 x tREFI
// (70.2 us postponement limit); average rate is exact (debt gearing).
//-----------------------------------------------------------------------------
`default_nettype none

module hades_sram_refresh_sched
  import hades_sram_pkg::*;
(
  input  wire logic        ui_clk,
  input  wire logic        ui_rst,       // synchronous (top passes ui_rst_soft)
  input  wire logic        calib_done,   // MIG up: schedule only past calibration
  input  wire logic        enable,       // effective datapath enable
  input  wire logic        engine_idle,  // mig_if quiescent (no requests, engines
                                         // in IDLE): service maintenance here
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

  hades_sram_sync2 u_tick_sync (.clk(ui_clk), .rst(ui_rst), .d(port_clk), .q(pclk_u));

  always_ff @(posedge ui_clk) begin
    if (ui_rst) pclk_d <= 1'b0;
    else        pclk_d <= pclk_u;
  end

  assign period_tick = pclk_u & ~pclk_d;

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
  // issue FSM: refresh first, then ZQCS, gated to engine idle (2026-10-21
  // A4 finding: a refresh inside a 64-port full-load drain blocks AR for
  // ~120-285 ui cycles and pushes the tail ports past the L=1 window; the
  // per-period idle gap after the drain absorbs single refreshes AND
  // catch-up pairs with zero port impact.  Debt/urgency unchanged, so the
  // long-run rate stays exact and pathological backlogs still force
  // service mid-load.)
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {S_IDLE, S_REF, S_ZQ} state_e;
  state_e state;

  wire logic urgency   = (ref_debt >= 4'd4);
  wire logic ref_allow = (ref_debt != 4'd0)
                         && (urgency || !enable || engine_idle);
  wire logic zq_allow  = zq_due && (!enable || engine_idle);

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
        // no default: unique-case violation in sim flags X/corruption
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
