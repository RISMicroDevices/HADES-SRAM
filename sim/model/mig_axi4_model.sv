//-----------------------------------------------------------------------------
// HADES-SRAM simulation model — MIG AXI4 behavioral stand-in (spec 6.1).
// 512-bit AXI4 slave with:
//   - typical read latency RD_LAT_TYP ui_clk cycles, +ROW_LAT with
//     ROW_HIT_PROB_PCT probability (row conflict), +0..RD_JITTER jitter
//   - request-driven maintenance dead time (M3): with User Refresh and ZQCS
//     Input mode the MIG never auto-refreshes — each app_ref_ack blocks the
//     bus for REF_BLOCK (~tRFC), each app_zq_ack for ZQ_BLOCK (~tZQCS);
//     overlapping requests concatenate (busy-until accounting).  The PHY
//     periodic read stays autonomous (PRD_PERIOD/PRD_BLOCK, not user-
//     schedulable).  All block AR/AW/W and pause R, modeling MIG dead time
//     (worst case must stay <= 600 ns)
//   - sparse 64-bit-byte-addressable memory (associative), WSTRB honored
//   - strictly in-order read returns (DUT uses a single AXI ID)
// Run-time knobs (plusargs):
//   +MAINT_STRESS=1  T3 worst case: every refresh drags a periodic-read
//                    block into the same maintenance window
//   +RD_LAT_ADD=n    T14 fault injection: stretch every read latency by n
// SLVERR/timeout fault injection arrives with T8 in M5.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module mig_axi4_model #(
  parameter int RD_LAT_TYP       = 36,
  parameter int ROW_HIT_PROB_PCT = 10,
  parameter int ROW_LAT          = 40,
  parameter int RD_JITTER        = 4,
  parameter int WR_LAT           = 20,
  parameter int REF_BLOCK        = 105,    // ~tRFC 350 ns (per app_ref_ack)
  parameter int PRD_PERIOD       = 997,    // PHY periodic read cadence
  parameter int PRD_BLOCK        = 12,
  parameter int ZQ_BLOCK         = 32,     // tZQCS ~ 128 CK ~ 32 ui cycles
  parameter int MAX_OUT          = 32
) (
  input  wire logic        aclk,
  input  wire logic        arst,      // synchronous, active high

  input  wire logic [3:0]  s_axi_awid,
  input  wire logic [39:0] s_axi_awaddr,
  input  wire logic [7:0]  s_axi_awlen,
  input  wire logic [2:0]  s_axi_awsize,
  input  wire logic [1:0]  s_axi_awburst,
  input  wire logic        s_axi_awvalid,
  output      logic        s_axi_awready,
  input  wire logic [511:0] s_axi_wdata,
  input  wire logic [63:0] s_axi_wstrb,
  input  wire logic        s_axi_wlast,
  input  wire logic        s_axi_wvalid,
  output      logic        s_axi_wready,
  output      logic [3:0]  s_axi_bid,
  output      logic [1:0]  s_axi_bresp,
  output      logic        s_axi_bvalid,
  input  wire logic        s_axi_bready,
  input  wire logic [3:0]  s_axi_arid,
  input  wire logic [39:0] s_axi_araddr,
  input  wire logic [7:0]  s_axi_arlen,
  input  wire logic [2:0]  s_axi_arsize,
  input  wire logic [1:0]  s_axi_arburst,
  input  wire logic        s_axi_arvalid,
  output      logic        s_axi_arready,
  output      logic [3:0]  s_axi_rid,
  output      logic [511:0] s_axi_rdata,
  output      logic [1:0]  s_axi_rresp,
  output      logic        s_axi_rlast,
  output      logic        s_axi_rvalid,
  input  wire logic        s_axi_rready,

  input  wire logic        app_ref_req,
  output      logic        app_ref_ack,
  input  wire logic        app_zq_req,
  output      logic        app_zq_ack
);

  // ------------------------------------------------------------------
  // cycle counter + maintenance dead time
  // ------------------------------------------------------------------
  longint unsigned cyc;

  always_ff @(posedge aclk) begin
    if (arst) cyc <= 0;
    else      cyc <= cyc + 1;
  end

  // run-time fault/stress knobs (see file header)
  int unsigned rd_lat_add;
  int unsigned maint_stress;
  initial begin
    rd_lat_add   = 0;
    maint_stress = 0;
    void'($value$plusargs("RD_LAT_ADD=%d", rd_lat_add));
    void'($value$plusargs("MAINT_STRESS=%d", maint_stress));
    if (rd_lat_add != 0)
      $display("[MIG-MODEL] RD_LAT_ADD=%0d (T14 latency-stretch fault)", rd_lat_add);
    if (maint_stress != 0)
      $display("[MIG-MODEL] MAINT_STRESS=1 (T3 worst-case maintenance)");
  end

  // request-driven maintenance (ref/ZQ acks), busy-until accounting so
  // overlapping maintenance concatenates (worst case); the PHY periodic
  // read remains autonomous — it is not user-schedulable in the real MIG
  longint unsigned busy_until;
  logic            ref_ack_d, zq_ack_d;

  always_ff @(posedge aclk) begin
    if (arst) begin
      ref_ack_d <= 1'b0;
      zq_ack_d  <= 1'b0;
    end else begin
      ref_ack_d <= app_ref_ack;
      zq_ack_d  <= app_zq_ack;
    end
  end

  wire logic ref_ack_rise = app_ref_ack & ~ref_ack_d;
  wire logic zq_ack_rise  = app_zq_ack  & ~zq_ack_d;

  always_ff @(posedge aclk) begin
    if (arst) begin
      busy_until <= 0;
    end else if (ref_ack_rise) begin
      // MAINT_STRESS (T3): a periodic read lands in the same window,
      // concatenated right behind the refresh block
      busy_until <= ((cyc > busy_until) ? cyc : busy_until) + REF_BLOCK
                    + (maint_stress != 0 ? PRD_BLOCK : 0);
    end else if (zq_ack_rise) begin
      busy_until <= ((cyc > busy_until) ? cyc : busy_until) + ZQ_BLOCK;
    end
  end

  wire logic maint = (cyc < busy_until) ||
                     (((cyc + 500) % PRD_PERIOD) < PRD_BLOCK);

  // ------------------------------------------------------------------
  // sparse memory, beat-addressed (64 B)
  // ------------------------------------------------------------------
  logic [511:0] mem [longint unsigned];

  // ------------------------------------------------------------------
  // read channel: accept -> due-cycle queue -> in-order return
  // ------------------------------------------------------------------
  typedef struct packed { longint unsigned due; logic [39:0] addr; } rd_ent_t;
  rd_ent_t rd_q[$];

  // registered ready/accept flags (queue size() is not legal in continuous
  // assignments)
  always_ff @(posedge aclk) begin
    if (arst) begin
      s_axi_arready <= 1'b0;
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
    end else begin
      s_axi_arready <= !maint && (rd_q.size() < MAX_OUT);
      s_axi_awready <= !maint;
      s_axi_wready  <= !maint && (aw_q.size() > 0);
    end
  end

  // portable PRNG (xorshift32, static state) — identical stream on VCS/xsim
  function longint unsigned m_rnd(input int unsigned hi);
    static logic [31:0] s = 32'hACE1_0001;
    logic [31:0] x;
    x = s;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    s = x;
    return x % (hi + 1);
  endfunction

  always_ff @(posedge aclk) begin
    if (arst) begin
      rd_q.delete();
    end else if (s_axi_arvalid && s_axi_arready) begin
      rd_ent_t e;
      longint unsigned lat;
      lat = RD_LAT_TYP + (m_rnd(99) < ROW_HIT_PROB_PCT ? ROW_LAT : 0)
            + m_rnd(RD_JITTER) + rd_lat_add;
      e.due  = cyc + lat;
      e.addr = s_axi_araddr;
      rd_q.push_back(e);
    end
  end

  logic r_held;
  always_ff @(posedge aclk) begin
    if (arst) begin
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
      s_axi_rlast  <= 1'b0;
      s_axi_rid    <= 4'd0;
      s_axi_rresp  <= 2'b00;
      r_held       <= 1'b0;
    end else begin
      if (r_held && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
        r_held       <= 1'b0;
      end else if (!r_held && !maint && rd_q.size() > 0 && rd_q[0].due <= cyc) begin
        rd_ent_t e;
        longint unsigned beat;
        e = rd_q.pop_front();
        beat = e.addr >> 6;
        s_axi_rdata  <= mem.exists(beat) ? mem[beat] : 512'd0;
        s_axi_rvalid <= 1'b1;
        s_axi_rlast  <= 1'b1;
        s_axi_rid    <= 4'd0;
        s_axi_rresp  <= 2'b00;
        r_held       <= 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------
  // write channel: AW queue, W applies on wlast, B after WR_LAT
  // ------------------------------------------------------------------
  logic [39:0] aw_q[$];
  longint unsigned b_due_q[$];

  always_ff @(posedge aclk) begin
    if (arst) begin
      aw_q.delete();
      b_due_q.delete();
    end else begin
      if (s_axi_awvalid && s_axi_awready)
        aw_q.push_back(s_axi_awaddr);
      if (s_axi_wvalid && s_axi_wready && s_axi_wlast) begin
        longint unsigned beat;
        logic [511:0] cur;
        beat = aw_q.pop_front() >> 6;
        cur  = mem.exists(beat) ? mem[beat] : 512'd0;
        for (int b = 0; b < 64; b++)
          if (s_axi_wstrb[b]) cur[b*8 +: 8] = s_axi_wdata[b*8 +: 8];
        mem[beat] = cur;
        b_due_q.push_back(cyc + WR_LAT);
      end
    end
  end

  always_ff @(posedge aclk) begin
    if (arst) begin
      s_axi_bvalid <= 1'b0;
      s_axi_bid    <= 4'd0;
      s_axi_bresp  <= 2'b00;
    end else begin
      if (s_axi_bvalid && s_axi_bready)
        s_axi_bvalid <= 1'b0;
      else if (!s_axi_bvalid && b_due_q.size() > 0 && b_due_q[0] <= cyc) begin
        void'(b_due_q.pop_front());
        s_axi_bvalid <= 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------
  // user refresh / ZQCS handshake responders (request honored after 3 cycles)
  // ------------------------------------------------------------------
  logic [2:0] ref_ack_pipe, zq_ack_pipe;

  always_ff @(posedge aclk) begin
    if (arst) begin
      ref_ack_pipe <= 3'b000;
      zq_ack_pipe  <= 3'b000;
    end else begin
      ref_ack_pipe <= {ref_ack_pipe[1:0], app_ref_req};
      zq_ack_pipe  <= {zq_ack_pipe[1:0],  app_zq_req};
    end
  end
  assign app_ref_ack = ref_ack_pipe[2] & app_ref_req;
  assign app_zq_ack  = zq_ack_pipe[2]  & app_zq_req;

  // Randomness comes from m_rnd (xorshift32, static state): xsim supports
  // neither $urandom(seed) nor $urandom_range in all contexts; the fixed
  // seed makes both simulators reproducible.

endmodule

`default_nettype wire
