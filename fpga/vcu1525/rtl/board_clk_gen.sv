//-----------------------------------------------------------------------------
// HADES-SRAM VCU1525 — board port_clk generator (M5-hw).
//
// port_clk is a fabric-divided square wave from a source clock:
//   SYNC build: src_clk = ui_clk (300 MHz, MIG user clock — same-source,
//               integer relation, XDC-declared as generated clock)
//   ASYNC build: src_clk = independent oscillator path (MMCM output; the
//               XDC puts the two domains in asynchronous clock groups)
//
// The divider value and the gate come from board_ctrl (ui_clk domain).
// A new divider value is only applied through a commit toggle: the src_clk
// side loads the shadow at a counter wrap after the toggle crosses, so a
// swept divider never tears a multi-bit value mid-period (every port_clk
// period has an exact integer length — the frequency monitor never sees a
// phantom over/under-frequency during an A10b sweep).  Gate = BUFGCE clock
// enable (glitchless by construction); stopping holds port_clk low.
//-----------------------------------------------------------------------------
`default_nettype none

module board_clk_gen (
  input  wire logic        src_clk,
  input  wire logic        src_rst,    // synchronous, active high
  input  wire logic [15:0] div,        // src_clk cycles per port_clk period
  input  wire logic        div_commit, // toggle: load div at next wrap
  input  wire logic        gate,       // 1 = run, 0 = stop (port_clk low)
  output wire logic        port_clk,
  output      logic [15:0] div_active  // divider currently in use (src_clk)
);

  // cross the quasi-static controls into the source domain (same-clock in
  // the SYNC build — harmless two-stage latency)
  logic        commit_sync;
  logic        gate_sync;
  logic [15:0] div_s;
  hades_sync2 u_commit (.clk(src_clk), .rst(src_rst), .d(div_commit), .q(commit_sync));
  hades_sync2 u_gate   (.clk(src_clk), .rst(src_rst), .d(gate),       .q(gate_sync));
  for (genvar b = 0; b < 16; b++) begin : g_div_sync
    hades_sync2 u_div (.clk(src_clk), .rst(src_rst), .d(div[b]), .q(div_s[b]));
  end

  logic [15:0] cnt;
  logic        half;        // toggling reg -> BUFGCE
  logic        commit_applied;  // commit level last consumed at a wrap

  always_ff @(posedge src_clk) begin
    if (src_rst) begin
      cnt            <= 16'd0;
      half           <= 1'b0;
      div_active     <= 16'd600;      // 500 KHz from 300 MHz
      commit_applied <= 1'b0;
    end else begin
      // reload-point: wrap the half-period counter; consume a pending commit
      // exactly here so the divider never changes mid-period.  The commit is
      // a toggle LEVEL held until consumed — sampling a 1-cycle pulse only at
      // wraps drops it ~(div/2-1)/div of the time (2026-10-22: set_gear had
      // never actually changed the gear on board; caught by A7's sweep).
      if (cnt >= {1'b0, div_active[15:1]} - 16'd1) begin
        cnt  <= 16'd0;
        half <= ~half;
        if (commit_sync != commit_applied) begin
          div_active     <= div_s;
          commit_applied <= commit_sync;
        end
      end else begin
        cnt <= cnt + 16'd1;
      end
    end
  end

  // glitchless enable; gate_sync is stable for whole port_clk periods in
  // practice (host-driven), and BUFGCE tolerates asynchronous CE anyway
  BUFGCE u_bufgce (
    .I  (half),
    .CE (gate_sync),
    .O  (port_clk)
  );

endmodule

`default_nettype wire
