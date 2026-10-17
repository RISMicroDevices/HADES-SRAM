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
  output      logic [N-1:0] wr_vld_o
);

  // ui cycles since the period tick (saturates)
  logic [15:0] per_cnt;
  always_ff @(posedge ui_clk) begin
    if (ui_rst)               per_cnt <= 16'hFFFF;
    else if (period_tick)     per_cnt <= 16'd1;
    else if (per_cnt != 16'hFFFF) per_cnt <= per_cnt + 16'd1;
  end

  localparam clk_mode_e MODE = IS_SYNC ? CLK_MODE_SYNC : CLK_MODE_ASYNC;

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
