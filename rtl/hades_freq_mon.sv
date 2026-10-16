//-----------------------------------------------------------------------------
// HADES-SRAM — port_clk frequency monitor (spec 3.3 MEAS_PERIOD, 4.1
// "port_clk stop or over-frequency is a runtime-detectable error").
// Measures the port_clk period in ui_clk cycles, detects a stopped clock,
// and flags over-frequency against CFG_MIN_PERIOD.  Pure ui_clk domain.
//-----------------------------------------------------------------------------
`default_nettype none

module hades_freq_mon #(
  // 1: port_clk is phase-related to ui_clk (SYNC) — sample directly.
  // 0: independent source (ASYNC) — enter via hades_sync2.
  parameter bit CLK_MODE_SYNC = 1'b1,
  // No rising edge for this many ui_clk cycles => clock declared stopped.
  // 16384 cycles ~ 54.6 us @ 300 MHz, comfortably above the longest legal
  // port_clk period (3000 cycles @ 100 KHz).
  parameter int STOP_TIMEOUT = 16384
) (
  input  wire logic        ui_clk,
  input  wire logic        ui_rst,
  input  wire logic        port_clk,
  input  wire logic [31:0] min_period,   // ui_clk cycles (CFG_MIN_PERIOD)
  output      logic [31:0] meas_period,  // ui_clk cycles between port_clk rises
  output      logic        clk_running,
  output      logic        over_freq     // running && meas_period < min_period
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

  // -- period measurement ---------------------------------------------------
  logic [31:0] cnt;
  logic [31:0] since_edge;

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      cnt         <= 32'd0;
      meas_period <= 32'd0;
    end else if (pc_rise) begin
      meas_period <= cnt;
      cnt         <= 32'd1;
    end else if (cnt != 32'hFFFF_FFFF) begin
      cnt <= cnt + 32'd1;
    end
  end

  // -- stop detection -------------------------------------------------------
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
      over_freq   <= clk_running && (meas_period < min_period);
    end
  end

endmodule

`default_nettype wire
