//-----------------------------------------------------------------------------
// HADES-SRAM — CDC whitelist (spec 4.1, ASYNC mode)
// The ONLY legal cross-domain structures when CLK_MODE=ASYNC.  No bare
// cross-domain wires anywhere else in the IP.
//   (a) hades_sync2   — single-bit 2-flop synchronizer
//   (b) hades_qs_bus  — quasi-static multi-bit bus + synchronized update flag
//   (c) hades_rst_sync— async-assert / sync-deassert reset, one per domain
// All resets here are the destination-domain synchronous resets produced by
// hades_rst_sync.  Under `SYNTHESIS` the simulation X-propagation aids
// vanish; T13a relies on them.
//-----------------------------------------------------------------------------
`default_nettype none

// ---------------------------------------------------------------------------
// (a) single-bit 2-flop synchronizer.
// Requirement on the source: any pulse must be >= 1 dst period + 2 dst flops
// worth of setup; used for req/ack handshakes and the period-tick detector.
// ---------------------------------------------------------------------------
module hades_sync2 (
  input  wire logic clk,   // destination clock
  input  wire logic rst,   // destination synchronous reset
  input  wire logic d,     // source-domain signal
  output      logic q
);
  (* ASYNC_REG = "TRUE" *) logic s1, s2;

  always_ff @(posedge clk) begin
    if (rst) begin
      s1 <= 1'b0;
      s2 <= 1'b0;
    end else begin
      s1 <= d;
      s2 <= s1;
    end
  end

`ifndef SYNTHESIS
  // T13a: never swallow an X on the source line — propagate it so testbenches
  // observe contamination instead of a silently cleaned-up 0/1.
  always @(d) if ($isunknown(d)) force q = 1'bx; else release q;
`endif

  assign q = s2;
endmodule

// ---------------------------------------------------------------------------
// (b) quasi-static bus crossing.  Legal only because the source holds src_data
// unchanged for >= 1 dst period + margin around src_upd (HADES guarantee:
// >= 1.37 us at 500 KHz).  dst_data is sampled combinationally across the
// domain boundary — this is the whitelist exception to "no bare bus wires",
// valid solely under the quasi-static hold contract.  dst_valid pulses one
// dst_clk when new data has been latched.
// ---------------------------------------------------------------------------
module hades_qs_bus #(
  parameter int WIDTH = 32
) (
  input  wire logic             src_clk,
  input  wire logic             src_rst,
  input  wire logic [WIDTH-1:0] src_data,
  input  wire logic             src_upd,   // 1 src_clk pulse, data stable
  input  wire logic             dst_clk,
  input  wire logic             dst_rst,
  output      logic [WIDTH-1:0] dst_data,
  output      logic             dst_valid
);
  // toggle handshake carries "new data" across
  logic tog_src;
  always_ff @(posedge src_clk) begin
    if (src_rst)      tog_src <= 1'b0;
    else if (src_upd) tog_src <= ~tog_src;
  end

  logic tog_dst;
  hades_sync2 u_upd_sync (
    .clk (dst_clk),
    .rst (dst_rst),
    .d   (tog_src),
    .q   (tog_dst)
  );

  logic tog_dst_d;
  always_ff @(posedge dst_clk) begin
    if (dst_rst) begin
      tog_dst_d <= 1'b0;
      dst_data  <= '0;
      dst_valid <= 1'b0;
    end else begin
      tog_dst_d <= tog_dst;
      dst_valid <= tog_dst ^ tog_dst_d;
      if (tog_dst ^ tog_dst_d)
        dst_data <= src_data;   // quasi-static: stable long before this edge
    end
  end
endmodule

// ---------------------------------------------------------------------------
// (c) reset synchronizer: asynchronous assert, synchronous deassert.
// One instance per clock domain; the active-high srst output is the
// domain's synchronous reset.
// ---------------------------------------------------------------------------
module hades_rst_sync #(
  parameter bit ARST_ACTIVE_HIGH = 1'b0   // 0: arst_n input is active-low
) (
  input  wire logic clk,
  input  wire logic arst_n,   // asynchronous reset input (polarity param)
  output      logic srst      // synchronous reset, active high
);
  logic arst_a;  // normalized active-high async assert
  assign arst_a = ARST_ACTIVE_HIGH ? arst_n : ~arst_n;

  (* ASYNC_REG = "TRUE" *) logic [1:0] s;
  always_ff @(posedge clk or posedge arst_a) begin
    if (arst_a) s <= 2'b11;
    else        s <= {1'b0, s[1]};
  end
  assign srst = s[0];
endmodule

`default_nettype wire
