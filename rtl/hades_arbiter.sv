//-----------------------------------------------------------------------------
// HADES-SRAM — TDMA slot arbiter (spec 3.2).  ui_clk domain; sits between the
// per-port request FIFO heads and hades_mig_if, which it leaves unchanged: it
// only gates rd_vld/wr_vld with per-port eligibility latches.
//
// Slot table (spec 4.3, elaboration-static): port i becomes eligible at
// slot_of(i) = MAINT_SLOTS + FIRST_LAT + CDC_OVHD + i*SLOT_PER_PORT ui cycles
// after the period tick — behind the maintenance window.  Eligibility
// LATCHES until the engine grants the port, so the nominal schedule matches
// the static table exactly while a maintenance/row-conflict stall degrades
// to in-order service instead of losing the period (the static budget's
// MARGIN absorbs the shift; the per-port sentinel is the backstop).
//
// Eligibility requires enable && port_en[i] && i < active_ports; the latches
// are cleared at every tick (one request per port per period by contract, so
// a stale latch must never carry into the next period).
//
// The backdoor does NOT pass through here: it enters mig_if directly as the
// lowest-priority requester, which makes it run exactly in the maintenance
// window and idle slots (no port eligible) for free.
//-----------------------------------------------------------------------------
`default_nettype none

module hades_arbiter
  import hades_pkg::*;
#(
  parameter int N       = N_MAX,
  parameter bit IS_SYNC = 1'b1
) (
  input  wire logic         ui_clk,
  input  wire logic         ui_rst,
  input  wire logic         enable,
  input  wire logic         period_tick,   // maintenance-window head
  input  wire cfg_t         cfg,

  input  wire logic [N-1:0] rd_vld_i,
  input  wire logic [N-1:0] wr_vld_i,
  input  wire logic [N-1:0] rd_gnt,        // engine commit pulses
  input  wire logic [N-1:0] wr_gnt,
  output      logic [N-1:0] rd_vld_o,
  output      logic [N-1:0] wr_vld_o,
  // every slot of the current period has been released (2026-10-21 A4: the
  // refresh scheduler gates on backend idle AND this — the engine idles
  // momentarily BETWEEN slot releases mid-drain, which is too early)
  output      logic         slots_done,
  // ... and only while a refresh fired NOW still drains into the
  // inter-period idle gap (see below)
  output      logic         maint_fire_ok
);

  // ui cycles since the period tick (saturates)
  logic [15:0] per_cnt;
  always_ff @(posedge ui_clk) begin
    if (ui_rst)               per_cnt <= 16'hFFFF;
    else if (period_tick)     per_cnt <= 16'd1;
    else if (per_cnt != 16'hFFFF) per_cnt <= per_cnt + 16'd1;
  end

  localparam clk_mode_e MODE = IS_SYNC ? CLK_MODE_SYNC : CLK_MODE_ASYNC;

  // all of this period's port slots are behind us (a few cycles past the
  // last slot — the active_ports*SLOT_PER_PORT product overshoots the last
  // slot by exactly one slot, which the idle-gap margin absorbs)
  wire logic [15:0] last_slot = 16'(MAINT_SLOTS + FIRST_LAT + cdc_ovhd(MODE))
                                + 16'(cfg.active_ports) * 16'(SLOT_PER_PORT);
  assign slots_done = (per_cnt >= last_slot);

  // Maintenance fire deadline (2026-10-21 A4): a refresh fired late in the
  // period blocks AR past the next period's first slots and shoves the tail
  // ports past L=1 (observed failing at tick+574+, passing at ~450).
  // Firing at F must satisfy F + MAINT_BLOCK_EST <= min_period + first slot,
  // so the block always drains into the inter-period gap.  Dues that miss
  // the window defer to the next period's drain end (the window recurs
  // every period; the free-running debt timer keeps the long-run rate exact
  // and the urgency override bounds the deferral).  Catch-up pairs and
  // refresh+ZQCS chains split across periods automatically: the second op
  // lands past the deadline and waits.
  wire logic [15:0] fire_latest = 16'(cfg.min_period) + 16'(MAINT_SLOTS + FIRST_LAT)
                                  - 16'(MAINT_BLOCK_EST);
  assign maint_fire_ok = slots_done && (per_cnt <= fire_latest);

  logic [N-1:0] rd_open, wr_open;

  for (genvar i = 0; i < N; i++) begin : g_slots
    wire logic slot_hit = (per_cnt == 16'(slot_of(i, MODE)));
    wire logic live     = enable && cfg.port_en[i]
                          && (8'(i) < cfg.active_ports);

    always_ff @(posedge ui_clk) begin
      if (ui_rst) begin
        rd_open[i] <= 1'b0;
        wr_open[i] <= 1'b0;
      end else if (period_tick) begin
        rd_open[i] <= 1'b0;
        wr_open[i] <= 1'b0;
      end else begin
        if (slot_hit && live) begin
          rd_open[i] <= 1'b1;
          wr_open[i] <= 1'b1;
        end
        if (rd_gnt[i]) rd_open[i] <= 1'b0;
        if (wr_gnt[i]) wr_open[i] <= 1'b0;
      end
    end

    assign rd_vld_o[i] = rd_vld_i[i] & rd_open[i];
    assign wr_vld_o[i] = wr_vld_i[i] & wr_open[i];
  end

endmodule

`default_nettype wire
