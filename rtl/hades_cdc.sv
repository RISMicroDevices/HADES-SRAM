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
// unchanged for >= 1 dst period + margin around the update (HADES guarantee:
// >= 1.37 us at 500 KHz).
//   DST_SYNC_STAGES=2 (default): toggle handshake; dst_valid pulses one dst_clk
//     after the synchronized update arrives.  For slow/config paths.
//   DST_SYNC_STAGES=0: no synchronizer at all — dst_data/dst_valid are the
//     source signals directly; the destination samples them only at
//     protocol-guaranteed-stable times (the read-response hold registers are
//     this: written in ui_clk domain, sampled by the port_clk timing shaper
//     at the L-th port edge, stable for >= 1.37 us by then).  src_upd is a
//     LEVEL in this mode.  src_clk/src_rst/dst_clk/dst_rst are unused.
// ---------------------------------------------------------------------------
module hades_qs_bus #(
  parameter int WIDTH = 32,
  parameter int DST_SYNC_STAGES = 2
) (
  input  wire logic             src_clk,
  input  wire logic             src_rst,
  input  wire logic [WIDTH-1:0] src_data,
  input  wire logic             src_upd,   // STAGES=2: 1 src_clk pulse;
                                           // STAGES=0: level (valid)
  input  wire logic             dst_clk,
  input  wire logic             dst_rst,
  output      logic [WIDTH-1:0] dst_data,
  output      logic             dst_valid
);
  generate
    if (DST_SYNC_STAGES == 0) begin : g_direct
      assign dst_data  = src_data;
      assign dst_valid = src_upd;
    end else begin : g_sync
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
    end
  endgenerate
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

// ---------------------------------------------------------------------------
// Small asynchronous FIFO for request crossings (port_clk -> ui_clk).
// Whitelist composition: per-bit hades_sync2 on Gray-coded pointers (spec 4.1
// forbids direct sampling of *non-Gray* counters; Gray is the sanctioned
// exception) + per-entry quasi-static data hold (entry written at push,
// stable long before the read side observes it via the synchronized pointer).
// Depth must be a power of two and >= 4.  Read data is combinational from mem.
// ---------------------------------------------------------------------------
module hades_afifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 4
) (
  input  wire logic             wclk,
  input  wire logic             wrst,     // sync reset, wclk domain
  input  wire logic             wpush,
  input  wire logic [WIDTH-1:0] wdata,
  output      logic             wfull,

  input  wire logic             rclk,
  input  wire logic             rrst,     // sync reset, rclk domain
  input  wire logic             rpop,
  output      logic [WIDTH-1:0] rdata,
  output      logic             rempty
);
  localparam int AW_F = $clog2(DEPTH);
  localparam int PW   = AW_F + 1;   // pointer width (extra wrap bit)

  logic [WIDTH-1:0] mem [DEPTH];
  logic [PW-1:0]    wptr_b, wptr_g, rptr_b, rptr_g;
  logic [PW-1:0]    rptr_g_w;  // read pointer, synced to wclk
  logic [PW-1:0]    wptr_g_r;  // write pointer, synced to rclk

  function automatic logic [PW-1:0] b2g(input logic [PW-1:0] b);
    return b ^ (b >> 1);
  endfunction
  function automatic logic [PW-1:0] g2b(input logic [PW-1:0] g);
    logic [PW-1:0] b;
    b[PW-1] = g[PW-1];
    for (int i = PW-2; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  // -- write side --
  wire logic [PW-1:0] wptr_b_n = wptr_b + PW'(1);
  assign wfull = (b2g(wptr_b_n) == {~rptr_g_w[PW-1 -: 2], rptr_g_w[PW-3:0]});

  always_ff @(posedge wclk) begin
    if (wrst) begin
      wptr_b <= '0;
      wptr_g <= '0;
    end else if (wpush && !wfull) begin
      mem[wptr_b[AW_F-1:0]] <= wdata;
      wptr_b                <= wptr_b_n;
      wptr_g                <= b2g(wptr_b_n);
    end
  end

  // -- read side --
  wire logic [PW-1:0] rptr_b_n = rptr_b + PW'(1);
  assign rempty = (wptr_g_r == rptr_g);
  assign rdata  = mem[rptr_b[AW_F-1:0]];

  always_ff @(posedge rclk) begin
    if (rrst) begin
      rptr_b <= '0;
      rptr_g <= '0;
    end else if (rpop && !rempty) begin
      rptr_b <= rptr_b_n;
      rptr_g <= b2g(rptr_b_n);
    end
  end

  // -- pointer crossings (per-bit sync2; Gray => single-bit change per step) --
  for (genvar i = 0; i < PW; i++) begin : g_ptr_sync
    hades_sync2 u_r2w (.clk(wclk), .rst(wrst), .d(rptr_g[i]),  .q(rptr_g_w[i]));
    hades_sync2 u_w2r (.clk(rclk), .rst(rrst), .d(wptr_g[i]),  .q(wptr_g_r[i]));
  end
endmodule

`default_nettype wire
