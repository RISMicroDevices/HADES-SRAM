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
//   +MAINT_STRESS=1      T3 worst case: every refresh drags a periodic-read
//                        block into the same maintenance window
//   +RD_LAT_ADD=n        T14 fault injection: stretch every read latency by n
//   +DROP_RD_BEAT=h      T8: the first read to this 512-bit beat never
//                        returns (backend timeout path)
//   +DROP_RD_BEAT2=h     T8: ditto, second independent one-shot (used for
//                        the backdoor timeout leg)
//   +SLVERR_RD_BEAT=h    T8: the first read to this beat returns rresp=SLVERR
//   +SLVERR_WR_BEAT=h    T8: the first write to this beat gets bresp=SLVERR
//   +AR_STALL_LEN=n      T-ovf: arready held 0 for n ui cycles starting at
//                        the first ARVALID (port request-FIFO overflow path)
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
  longint unsigned drop_beat, slv_rd_beat, slv_wr_beat, drop_beat2;
  int unsigned ar_stall_len;
  bit drop_en, slv_rd_en, slv_wr_en, drop2_en;
  bit drop_done, slv_rd_done, slv_wr_done, drop2_done;   // 2-state: default 0
  bit stall_started;                        // 2-state: default 0
  int  ref_block_eff, zq_block_eff;         // runtime-overridable blocks
  longint unsigned stall_until;
  initial begin
    rd_lat_add   = 0;
    maint_stress = 0;
    ar_stall_len = 0;
    ref_block_eff = REF_BLOCK;
    zq_block_eff  = ZQ_BLOCK;
    void'($value$plusargs("RD_LAT_ADD=%d", rd_lat_add));
    void'($value$plusargs("MAINT_STRESS=%d", maint_stress));
    void'($value$plusargs("AR_STALL_LEN=%d", ar_stall_len));
    void'($value$plusargs("REF_BLOCK=%d", ref_block_eff));
    void'($value$plusargs("ZQ_BLOCK=%d", zq_block_eff));
    drop_en   = $value$plusargs("DROP_RD_BEAT=%h", drop_beat);
    drop2_en  = $value$plusargs("DROP_RD_BEAT2=%h", drop_beat2);
    slv_rd_en = $value$plusargs("SLVERR_RD_BEAT=%h", slv_rd_beat);
    slv_wr_en = $value$plusargs("SLVERR_WR_BEAT=%h", slv_wr_beat);
    if (rd_lat_add != 0)
      $display("[MIG-MODEL] RD_LAT_ADD=%0d (T14 latency-stretch fault)", rd_lat_add);
    if (maint_stress != 0)
      $display("[MIG-MODEL] MAINT_STRESS=1 (T3 worst-case maintenance)");
    if (ar_stall_len != 0)
      $display("[MIG-MODEL] AR_STALL_LEN=%0d (overflow fault)", ar_stall_len);
    if (ref_block_eff != REF_BLOCK || zq_block_eff != ZQ_BLOCK)
      $display("[MIG-MODEL] REF_BLOCK=%0d ZQ_BLOCK=%0d (pessimistic maintenance)",
               ref_block_eff, zq_block_eff);
    if (drop_en)
      $display("[MIG-MODEL] DROP_RD_BEAT=%h (T8 timeout fault)", drop_beat);
    if (drop2_en)
      $display("[MIG-MODEL] DROP_RD_BEAT2=%h (T8 timeout fault)", drop_beat2);
    if (slv_rd_en)
      $display("[MIG-MODEL] SLVERR_RD_BEAT=%h (T8 SLVERR fault)", slv_rd_beat);
    if (slv_wr_en)
      $display("[MIG-MODEL] SLVERR_WR_BEAT=%h (T8 SLVERR fault)", slv_wr_beat);
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
      busy_until <= ((cyc > busy_until) ? cyc : busy_until) + ref_block_eff
                    + (maint_stress != 0 ? PRD_BLOCK : 0);
    end else if (zq_ack_rise) begin
      busy_until <= ((cyc > busy_until) ? cyc : busy_until) + zq_block_eff;
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
  // (ids echoed: the DUT tracks responses per AXI ID since M5-hw)
  // ------------------------------------------------------------------
  typedef struct packed { longint unsigned due; logic [39:0] addr;
                          logic [1:0] resp; logic [3:0] id; } rd_ent_t;
  rd_ent_t rd_q[$];

  // registered ready/accept flags (queue size() is not legal in continuous
  // assignments)
  always_ff @(posedge aclk) begin
    if (arst) begin
      s_axi_arready <= 1'b0;
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      stall_started <= 1'b0;
    end else begin
      if (ar_stall_len != 0 && !stall_started && s_axi_arvalid) begin
        stall_started <= 1'b1;
        stall_until   <= cyc + ar_stall_len;
        $display("[MIG-MODEL] AR stall starts at cycle %0d (%0d cycles)",
                 cyc, ar_stall_len);
      end
      s_axi_arready <= !maint && (rd_q.size() < MAX_OUT)
                       && !(stall_started && cyc < stall_until);
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
      longint unsigned beat;
      beat = s_axi_araddr >> 6;
      if (drop_en && !drop_done && beat == drop_beat) begin
        // swallowed by the backend: no queue entry, never returns
        drop_done <= 1'b1;
        $display("[MIG-MODEL] T8: dropped read beat 0x%h at cycle %0d", beat, cyc);
      end else if (drop2_en && !drop2_done && beat == drop_beat2) begin
        drop2_done <= 1'b1;
        $display("[MIG-MODEL] T8: dropped read beat2 0x%h at cycle %0d", beat, cyc);
      end else begin
        lat = RD_LAT_TYP + (m_rnd(99) < ROW_HIT_PROB_PCT ? ROW_LAT : 0)
              + m_rnd(RD_JITTER) + rd_lat_add;
        e.due  = cyc + lat;
        e.addr = s_axi_araddr;
        e.id   = s_axi_arid;
        e.resp = (slv_rd_en && !slv_rd_done && beat == slv_rd_beat) ? 2'b10
                                                                     : 2'b00;
        if (e.resp != 2'b00) begin
          slv_rd_done <= 1'b1;
          $display("[MIG-MODEL] T8: SLVERR on read beat 0x%h at cycle %0d",
                   beat, cyc);
        end
        rd_q.push_back(e);
      end
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
        logic [511:0] mdata;
        e = rd_q.pop_front();
        beat = e.addr >> 6;
        mdata = mem.exists(beat) ? mem[beat] : 512'd0;
        s_axi_rdata  <= mdata;
        s_axi_rvalid <= 1'b1;
        s_axi_rlast  <= 1'b1;
        s_axi_rid    <= e.id;
        s_axi_rresp  <= e.resp;
        r_held       <= 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------
  // write channel: AW queue, W applies on wlast, B after WR_LAT
  // ------------------------------------------------------------------
  typedef struct packed { logic [39:0] addr; logic [3:0] id; } aw_ent_t;
  aw_ent_t aw_q[$];
  typedef struct packed { longint unsigned due; logic [1:0] resp;
                          logic [3:0] id; } b_ent_t;
  b_ent_t b_due_q[$];

  always_ff @(posedge aclk) begin
    if (arst) begin
      aw_q.delete();
      b_due_q.delete();
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        aw_ent_t ae;
        ae.addr = s_axi_awaddr;
        ae.id   = s_axi_awid;
        aw_q.push_back(ae);
      end
      if (s_axi_wvalid && s_axi_wready && s_axi_wlast) begin
        longint unsigned beat;
        logic [511:0] cur;
        b_ent_t be;
        aw_ent_t ae;
        ae = aw_q.pop_front();
        beat = ae.addr >> 6;
        cur  = mem.exists(beat) ? mem[beat] : 512'd0;
        for (int b = 0; b < 64; b++)
          if (s_axi_wstrb[b]) cur[b*8 +: 8] = s_axi_wdata[b*8 +: 8];
        mem[beat] = cur;
        be.due  = cyc + WR_LAT;
        be.id   = ae.id;
        be.resp = (slv_wr_en && !slv_wr_done && beat == slv_wr_beat) ? 2'b10
                                                                      : 2'b00;
        if (be.resp != 2'b00) begin
          slv_wr_done <= 1'b1;
          $display("[MIG-MODEL] T8: SLVERR on write beat 0x%h at cycle %0d",
                   beat, cyc);
        end
        b_due_q.push_back(be);
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
      else if (!s_axi_bvalid && b_due_q.size() > 0 && b_due_q[0].due <= cyc) begin
        b_ent_t be;
        be = b_due_q.pop_front();
        s_axi_bvalid <= 1'b1;
        s_axi_bid    <= be.id;
        s_axi_bresp  <= be.resp;
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
