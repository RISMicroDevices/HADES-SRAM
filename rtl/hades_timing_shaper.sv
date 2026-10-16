//-----------------------------------------------------------------------------
// HADES-SRAM — per-port timing shaper (spec 4.2: function/timing separation).
// Pure port_clk domain.  Decides on which port_clk edge rdata/rvalid are
// released: exactly the L-th edge after the request edge, every time,
// independent of when the backend actually delivered the data (the response
// hold slots are quasi-static by then).  Supports back-to-back reads on
// consecutive port edges (shift pipeline, inflight <= L).
//
// Sentinel (spec 4.3 second line of defense): if the response slot is not
// valid at the release edge, err_window pulses (to ERR_STATUS.bit5) — this
// must never happen; rvalid is still asserted on schedule to keep the
// cycle-level contract observable.
//-----------------------------------------------------------------------------
`default_nettype none

module hades_timing_shaper #(
  parameter int DW = 32
) (
  input  wire logic           port_clk,
  input  wire logic           port_rst,   // synchronous, active high
  input  wire logic           rd_req,     // read captured at this port edge
  input  wire logic [1:0]     lat,        // L: 1 or 2 (quasi-static config)

  // quasi-static response hold slots (written in ui_clk domain; sampled only
  // here, at release edges, when they have been stable for microseconds).
  // 4 slots: with 1 request/period and release L periods later, slot j is
  // rewritten 4 periods after its last write — comfortably after the
  // consumption flag has crossed back to ui_clk and freed it.
  input  wire logic [3:0]     slot_vld,
  input  wire logic [3:0][DW-1:0] slot_data,

  output      logic           rvalid,
  output      logic [DW-1:0]  rdata,
  output      logic           rel,        // release pulse (1 port cycle)
  output      logic [1:0]     rel_slot,   // slot popped at this release
  output      logic           err_window  // 1-cycle pulse: data late (sentinel)
);

  // pipe[0] = request seen at the most recent edge; pipe[1] = one edge older
  logic [1:0] pipe;
  logic [1:0] slot_ptr;                   // next slot to pop (arrival order)

  // release condition evaluated against pre-edge pipe contents:
  //   L=1: release one edge after the request  -> use pipe[0]
  //   L=2: release two edges after the request -> use pipe[1]
  wire logic rel_w = (lat == 2'd1) ? pipe[0] : pipe[1];

  always_ff @(posedge port_clk) begin
    if (port_rst) begin
      pipe       <= 2'b00;
      rvalid     <= 1'b0;
      rdata      <= '0;
      rel        <= 1'b0;
      rel_slot   <= 2'b00;
      err_window <= 1'b0;
      slot_ptr   <= 2'b00;
    end else begin
      pipe  <= {pipe[0], rd_req};
      rel   <= rel_w;
      if (rel_w) begin
        rvalid     <= 1'b1;
        rdata      <= slot_data[slot_ptr];
        rel_slot   <= slot_ptr;
        err_window <= ~slot_vld[slot_ptr];   // sentinel: must never fire
        slot_ptr   <= slot_ptr + 2'd1;
      end else begin
        rvalid     <= 1'b0;
        err_window <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
