//-----------------------------------------------------------------------------
// HADES-SRAM — port_clk frequency monitor (spec 3.3 MEAS_PERIOD, 4.1
// "port_clk stop or over-frequency is a runtime-detectable error").
// Pure ui_clk domain.
//
// The port_clk period is measured as the average over 4 consecutive periods:
// in ASYNC mode single-period measurements jitter by +/-2 ui_clk cycles
// (sampling a slow asynchronous clock with a fast one), which could trip a
// naive over-frequency compare; averaging cancels the jitter (only the two
// endpoints jitter).  The over_freq interlock additionally has a 4-cycle
// margin (accepts down to 596 cycles = 503.3 KHz against the 500 KHz limit —
// the slot budget at 596 cycles still covers the 546-cycle worst case), while
// any genuinely dangerous clock (e.g. 2 MHz = 150 cycles) is rejected.
//-----------------------------------------------------------------------------
`default_nettype none

module hades_freq_mon #(
  // 1: port_clk is phase-related to ui_clk (SYNC) — sample directly.
  // 0: independent source (ASYNC) — enter via hades_sync2.
  parameter bit CLK_MODE_SYNC = 1'b1,
  // No rising edge for this many ui_clk cycles => clock declared stopped.
  // 16384 cycles ~ 54.6 us @ 300 MHz, comfortably above the longest legal
  // port_clk period (3000 cycles @ 100 KHz).
  parameter int STOP_TIMEOUT = 16384,
  // over_freq compare margin (ui_clk cycles) for sampling jitter
  parameter int OF_MARGIN = 4
) (
  input  wire logic        ui_clk,
  input  wire logic        ui_rst,
  input  wire logic        port_clk,
  input  wire logic [31:0] min_period,   // ui_clk cycles (CFG_MIN_PERIOD)
  output      logic [31:0] meas_period,  // ui_clk cycles, averaged over 4
  output      logic        clk_running,
  output      logic        over_freq
);

  // -- bring port_clk level into the ui_clk domain -------------------------
  logic pc_s;
  generate
    if (CLK_MODE_SYNC) begin : g_direct
      // SYNC: same-source, phase-declared in XDC — a plain timing path.
      always_ff @(posedge ui_clk) begin
        if (ui_rst) pc_s <= 1'b0;
        else        pc_s <= port_clk;
      end
    end else begin : g_sync
      hades_sync2 u_pc_sync (
        .clk (ui_clk),
        .rst (ui_rst),
        .d   (port_clk),
        .q   (pc_s)
      );
    end
  endgenerate

  // -- rising-edge detect ---------------------------------------------------
  logic pc_d;
  wire  pc_rise = pc_s & ~pc_d;

  always_ff @(posedge ui_clk) begin
    if (ui_rst) pc_d <= 1'b0;
    else        pc_d <= pc_s;
  end

  // -- period measurement (4-period average) --------------------------------
  // The first rising edge after reset only starts the measurement (its cnt
  // holds cycles-since-reset, not a real period); the average becomes valid
  // at the 5th rising edge.
  logic [31:0] cnt;        // cycles since the last rising edge
  logic [33:0] acc4;       // accumulated cycles of the current 4-period window
  logic [1:0]  rise_q;     // valid rising edges mod 4
  logic        have_prev;  // seen at least one rising edge since reset

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      cnt         <= 32'd0;
      acc4        <= 34'd0;
      rise_q      <= 2'd0;
      have_prev   <= 1'b0;
      meas_period <= 32'd0;
    end else if (pc_rise) begin
      if (!have_prev) begin
        have_prev <= 1'b1;                 // discard the partial first window
      end else if (rise_q == 2'd3) begin
        meas_period <= 32'((acc4 + cnt) >> 2);
        acc4        <= 34'd0;
        rise_q      <= 2'd0;
      end else begin
        acc4   <= acc4 + 34'(cnt);
        rise_q <= rise_q + 2'd1;
      end
      cnt <= 32'd1;
    end else if (cnt != 32'hFFFF_FFFF) begin
      cnt <= cnt + 32'd1;
    end
  end

  // -- stop detection -------------------------------------------------------
  logic [31:0] since_edge;

  always_ff @(posedge ui_clk) begin
    if (ui_rst)          since_edge <= 32'd0;
    else if (pc_rise)    since_edge <= 32'd0;
    else if (since_edge != 32'hFFFF_FFFF)
                         since_edge <= since_edge + 32'd1;
  end

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      clk_running <= 1'b0;
      over_freq   <= 1'b0;
    end else begin
      clk_running <= (since_edge < 32'(STOP_TIMEOUT)) && (meas_period != 32'd0);
      over_freq   <= clk_running && (meas_period + 32'(OF_MARGIN) < min_period);
    end
  end

endmodule

`default_nettype wire
