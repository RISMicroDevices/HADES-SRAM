//-----------------------------------------------------------------------------
// HADES-SRAM — MIG AXI4 backend interface (spec 3.2).  ui_clk domain only.
//
// - Per-port read/write request FIFO heads arrive here (rd_vld/rd_addr ...,
//   level-held until rd_gnt).  FCFS with fixed lowest-index priority; the
//   TDMA slot gating of spec 3.2 is layered in front of this engine in M4
//   (hades_sram_arbiter) without changing the engine itself.
// - Reads: one 512-bit beat per access, with 16 AXI IDs. Responses are
//   in-order per ID; per-ID tracking carries {port, lane, timestamp, synthetic}
//   for response routing and STAT_MAXLAT.
// - Illegal addresses (>= cfg.port_size[p] >> cfg.wshift[p]) are not issued
//   to AXI; a synthetic tracking entry returns zeros in order and flags
//   ERR_STATUS.bit0.
// - Writes: posted; WSTRB sub-word lane expansion; B tracked per port for
//   SLVERR reporting.
// - Backdoor (M4): an extra lowest-priority requester on both engines
//   (sel = 8'hFF marker), picked only when no port is eligible — i.e. in
//   the maintenance window and idle slots.  Backdoor beats/lanes arrive
//   pre-translated from hades_sram_backdoor; read data returns on bkp_rd_*.
//   Backdoor traffic counts in stat_tot_* but not in per-port stats.
// - Tracking: 16 IDs, eight entries per ID (spec outstanding >= 16).
//-----------------------------------------------------------------------------
`default_nettype none

module hades_sram_mig_if
  import hades_sram_pkg::*;
#(
  parameter int N  = N_MAX,
  // per-port channel width — one AXI beat (v1.1.0).  Individual port widths
  // (1..512) come from cfg (wshift/wbytes/be_en); a port's data is
  // LSB-justified in its channel.
  parameter int DW = 512,
  parameter int AW = AW_DEFAULT
) (
  input  wire logic        ui_clk,
  input  wire logic        ui_rst,
  input  wire cfg_t        cfg,
  input  wire logic        enable,

  // per-port request heads (ui_clk domain, level-held until gnt)
  input  wire logic [N-1:0]          rd_vld,
  input  wire logic [N-1:0][AW-1:0]  rd_addr,
  output          logic [N-1:0]      rd_gnt,
  input  wire logic [N-1:0]          wr_vld,
  input  wire logic [N-1:0][AW-1:0]  wr_addr,
  input  wire logic [N-1:0][DW-1:0]  wr_data,
  input  wire logic [N-1:0][63:0]    wr_be,   // byte enables (per cfg.be_en)
  output          logic [N-1:0]      wr_gnt,

  // per-port read responses (1 ui_clk cycle strobes)
  output          logic [N-1:0]          rsp_vld,
  output          logic [N-1:0][DW-1:0]  rsp_data,

  // AXI4 master (to MIG)
  output          logic [3:0]            m_axi_awid,
  output          logic [AXI_ADDR_W-1:0] m_axi_awaddr,
  output          logic [7:0]            m_axi_awlen,
  output          logic [2:0]            m_axi_awsize,
  output          logic [1:0]            m_axi_awburst,
  output          logic                  m_axi_awvalid,
  input  wire logic                      m_axi_awready,
  output          logic [511:0]          m_axi_wdata,
  output          logic [63:0]           m_axi_wstrb,
  output          logic                  m_axi_wlast,
  output          logic                  m_axi_wvalid,
  input  wire logic                      m_axi_wready,
  input  wire logic [3:0]                m_axi_bid,
  input  wire logic [1:0]                m_axi_bresp,
  input  wire logic                      m_axi_bvalid,
  output          logic                  m_axi_bready,
  output          logic [3:0]            m_axi_arid,
  output          logic [AXI_ADDR_W-1:0] m_axi_araddr,
  output          logic [7:0]            m_axi_arlen,
  output          logic [2:0]            m_axi_arsize,
  output          logic [1:0]            m_axi_arburst,
  output          logic                  m_axi_arvalid,
  input  wire logic                      m_axi_arready,
  input  wire logic [3:0]                m_axi_rid,
  input  wire logic [511:0]              m_axi_rdata,
  input  wire logic [1:0]                m_axi_rresp,
  input  wire logic                      m_axi_rlast,
  input  wire logic                      m_axi_rvalid,
  output          logic                  m_axi_rready,

  // statistics (ui_clk; cleared by soft_rst)
  output          logic [63:0]           stat_tot_rd,
  output          logic [63:0]           stat_tot_wr,
  output          logic [31:0]           stat_maxlat,
  output          logic [N_MAX-1:0][31:0] port_stat_rd,
  output          logic [N_MAX-1:0][31:0] port_stat_wr,
  output          logic [N_MAX-1:0][31:0] port_stat_err,
  input  wire logic [N-1:0]              st_err,  // selftest error pulses (M5-hw)
  input  wire logic [7:0]                err_clr_port,  // PORT_STAT_ERR W1C
  input  wire logic                      err_clr,
  input  wire logic                      soft_rst,

  // quiescence for the refresh scheduler (A4, 2026-10-21): maintenance may
  // only fire while the backend has no pending work
  output          logic                  backend_idle,

  // error event pulses (CSR latches first-error info)
  output          logic                  err_illegal,   // spec bit0
  output          logic                  err_timeout,   // spec bit1
  output          logic                  err_slverr,    // spec bit3
  output          logic [7:0]            err_port,
  output          logic [31:0]           err_addr,

  // backdoor requester (lowest priority; pre-translated beat/lane)
  input  wire logic                      bkp_rd_req,
  input  wire logic [BASE_W-1:0]         bkp_rd_beat,
  input  wire logic [5:0]                bkp_rd_lane,
  output          logic                  bkp_rd_gnt,
  output          logic                  bkp_rd_done,
  output          logic [31:0]           bkp_rd_data,
  input  wire logic                      bkp_wr_req,
  input  wire logic [BASE_W-1:0]         bkp_wr_beat,
  input  wire logic [5:0]                bkp_wr_lane,
  input  wire logic [31:0]               bkp_wr_data,
  output          logic                  bkp_wr_gnt
);

  localparam logic [7:0] BKP_ID = 8'hFF;   // backdoor marker in tracking FIFOs

  localparam int TRK_D  = 8;              // per-ID outstanding depth (see below)
  localparam int TRK_W  = 6;              // track pointer width (DEPTH>... )
  localparam int TPW    = $clog2(TRK_D);

  // =========================================================================
  // Read engine
  //
  // 300 MHz closure (M5-hw): the arbitration fan-in (64-input mask -> first_set
  // -> illegal/beat) is split across states — RD_IDLE latches the first_set
  // pick (from live requests, ~10 levels), RD_PICK latches the quasi-static
  // port_base/port_size muxes, and RD_PREP derives beat/lane/illegal from
  // REGISTERED operands (a bare 28-bit add + compare).  The R/B AXI channels
  // are registered before use (safe: acceptance is paced by our own
  // rready/bready, so a registered view names exactly the accepted beat).
  // m_axi_arvalid is a register (set on PREP->ISSUE, cleared on accept —
  // cycle-identical to a state decode).  arready/awready/wready are consumed
  // LIVE — registering them would double count AXI acceptances; their
  // consumers are shallow.  Cost: +1 ui_clk cycle of grant latency, inside
  // the slot budget's MARGIN.
  // =========================================================================
  typedef enum logic [2:0] {RD_IDLE, RD_PICK, RD_PREP, RD_ISSUE, RD_SYNTH, RD_POP} rd_state_e;
  rd_state_e rd_state;

  logic [7:0]            rd_sel;
  logic [7:0]            rd_pick_q;   // RD_IDLE: latched first_set pick
  logic [AW-1:0]         rd_addr_q;   // RD_IDLE: latched picked address
  logic [BASE_W-1:0]     rd_base_q;   // RD_PICK: port_base mux (quasi-static)
  logic [31:0]           rd_size_q;   // RD_PICK: port_size mux (quasi-static)
  logic [2:0]            rd_wsh_q;    // RD_PICK: cfg.wshift mux (elaboration-constant)
  logic [N-1:0]          rd_req_masked;
  logic [BASE_W-1:0]     rd_beat;
  logic [5:0]            rd_lane;
  logic                  rd_illegal;

  // ------------------------------------------------------------------
  // Read response tracking, per AXI ID (M5-hw hardware finding): with a
  // single ID the MIG cannot reorder and serializes ~20 ui_clk cycles per
  // 1-beat command — measured 29 Mops/s on the board vs the 32 Mops/s that
  // 64-port @500 KHz full load demands.  16 IDs (port[3:0]) let the MIG
  // interleave/reorder for bank efficiency.  Responses are in-order per ID,
  // so each ID gets its own issue-order tracking FIFO.  Depth 8: per the
  // port contract each port has <= 1 outstanding read per target period, so
  // an ID (4 ports + backdoor) can never exceed 6; the 768-cycle backend
  // timeout bounds it well below 8.
  // ------------------------------------------------------------------
  localparam int NID = 16;
  logic [7:0]   trk_port  [NID][TRK_D];
  logic [5:0]   trk_lane  [NID][TRK_D];
  logic [15:0]  trk_ts    [NID][TRK_D];
  logic         trk_synth [NID][TRK_D];
  logic [TPW-1:0] trk_wptr [NID];
  logic [TPW-1:0] trk_rptr [NID];
  logic [TPW:0]   trk_cnt  [NID];

  logic [15:0] cyc_cnt;   // free-running ui cycle counter for latency stats

  // registered R/B channel view (see the note above)
  logic         rvalid_q, rready_q, rlast_q;
  logic [511:0] rdata_q;
  logic [1:0]   rresp_q;
  logic [3:0]   rid_q;
  logic         bvalid_q;
  logic [1:0]   bresp_q;
  logic [3:0]   bid_q;
  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      rvalid_q <= 1'b0;
      rready_q <= 1'b0;
      rlast_q  <= 1'b0;
      rdata_q  <= '0;
      rresp_q  <= 2'b00;
      rid_q    <= 4'd0;
      bvalid_q <= 1'b0;
      bresp_q  <= 2'b00;
      bid_q    <= 4'd0;
    end else begin
      rvalid_q <= m_axi_rvalid;
      rready_q <= m_axi_rready;
      rlast_q  <= m_axi_rlast;
      rdata_q  <= m_axi_rdata;
      rresp_q  <= m_axi_rresp;
      rid_q    <= m_axi_rid;
      bvalid_q <= m_axi_bvalid;
      bresp_q  <= m_axi_bresp;
      bid_q    <= m_axi_bid;
    end
  end

  // lowest-index set bit
  function automatic logic [7:0] first_set(input logic [N-1:0] v);
    logic [7:0] r;
    r = 8'hFF;
    for (int i = N - 1; i >= 0; i--)
      if (v[i]) r = 8'(i);
    return r;
  endfunction

  // per-lane full flags, maintained cycle-accurately with the counters (the
  // pick path then ANDs each requester with its lane's REGISTERED flag — a
  // per-bit wire, lane = port[3:0] — instead of a live 16:1 counter mux +
  // compare; 300 MHz closure, iter-6/iter-8, 2026-10-21: port-FIFO CDC ->
  // mask -> pick CE was the recurring WNS-critical cone).
  // push and pop update both structures from the same events, so the flag
  // always equals (trk_cnt[l] == TRK_D); push+pop on one lane holds both.
  logic [NID-1:0] lane_full, wl_full;

  // occupancy push/pop lane ids (hoisted: the FSM push indexes by push_id)
  wire logic       rd_push  = ((rd_state == RD_ISSUE) && m_axi_arvalid && m_axi_arready)
                               || (rd_state == RD_SYNTH);
  wire logic [3:0] push_id  = (rd_sel == BKP_ID) ? 4'd0 : rd_sel[3:0];

  for (genvar i = 0; i < N; i++) begin : g_rdmask
    assign rd_req_masked[i] = rd_vld[i] & cfg.port_en[i] & enable;
  end

  // Re-arbitration guard for the fast re-pick in RD_POP (replaces the old
  // full-cycle bubble, 2026-10-21 A4 finding): the grant pulse is high for
  // exactly the POP cycle, and during that cycle the granted port's request
  // still looks live (the arbiter's rd_open latch clears one cycle later,
  // the port FIFO head updates then too) — so mask the CURRENT grant, not a
  // delayed copy.  Every other port may be re-picked immediately.  Cuts the
  // issue spacing under load from 5 to 4 ui cycles per op — the 64-port
  // period drain is 256 cycles, leaving room for a refresh event inside the
  // L=1 window.
  wire logic [N-1:0] rd_req_m      = rd_req_masked & ~rd_gnt;
  wire logic         rd_any_ports  = |rd_req_m;
  wire logic         rd_any  = rd_any_ports | (bkp_rd_req && !bkp_rd_gnt);
  // lane-full eligibility mask (300 MHz closure, iter-8, 2026-10-21): masking
  // each requester by its lane's REGISTERED full flag costs a per-bit wire
  // (lane = port[3:0], constant per bit), so the pick enable is one OR64 —
  // the iter-6 guard ("pick first, then 16:1-mux the picked lane's flag")
  // put a 6-level priority encode + mux + state decode in a single CE cone
  // (iter-7 build: WNS -0.154 on rptr_g -> wr_pick_q/CE, 12 levels).
  // Eligibility also serves the next eligible port (or the backdoor) instead
  // of stalling behind a full-lane low-index port; safety is identical —
  // lane_full is the same registered value the guard read.
  wire logic [N-1:0] rd_req_elig;
  for (genvar i = 0; i < N; i++) begin : g_rdelig
    assign rd_req_elig[i] = rd_req_m[i] & ~lane_full[i % NID];
  end
  wire logic         rd_elig_ports = |rd_req_elig;
  wire logic         rd_start = rd_elig_ports |
                                (bkp_rd_req && !bkp_rd_gnt && !lane_full[4'd0]);
  wire logic [7:0]   rd_pick  = rd_elig_ports ? first_set(rd_req_elig)
                                              : BKP_ID;

  // RD_PREP-stage derivations from REGISTERED operands (300 MHz closure,
  // 2026-10-21): the 64:1 quasi-static base/size muxes get their own cycle
  // (latched in RD_PICK), so this stage is only a 28-bit add + a compare —
  // mux+add in one cycle was the WNS-critical path.  For the backdoor pick
  // the mux output is garbage (index 63) and overridden by bkp_* anyway.
  // v1.1.0: beat/lane/size-in-W-words use the picked port's lane shift
  // (cfg.wshift, elaboration-constant), latched alongside base/size in
  // RD_PICK — a W-word occupies 2^wshift lanes: beat = addr >> (4-wshift),
  // lane group base = (addr & (0xF>>wshift)) << wshift, size compare in
  // W-words = size_words >> wshift.
  wire logic               rd_pickq_bkp = (rd_pick_q == BKP_ID);
  wire logic [31:0]        rd_size_w    = rd_size_q >> rd_wsh_q;
  wire logic               rd_illegal_w = !rd_pickq_bkp &&
                                          (32'(rd_addr_q) >= rd_size_w);
  wire logic [5:0]         rd_lmask_w   = 6'hF >> rd_wsh_q;
  wire logic [BASE_W-1:0]  rd_beat_w = rd_pickq_bkp ? bkp_rd_beat
                                       : rd_base_q + BASE_W'(rd_addr_q >> (4 - rd_wsh_q));
  wire logic [5:0]         rd_lane_w = rd_pickq_bkp ? bkp_rd_lane
                                       : 6'((6'(rd_addr_q) & rd_lmask_w) << rd_wsh_q);

  // -- read FSM (2-process) --
  // arvalid is a REGISTER (300 MHz closure, 2026-10-21): the FSM-decode into
  // the MIG's AR-channel CE cone missed ui_clk.  Set on PREP->ISSUE, cleared
  // on acceptance — cycle-for-cycle identical to the comb decode.
  logic arvalid_q;
  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      arvalid_q <= 1'b0;
    end else begin
      if (rd_state == RD_PREP)
        arvalid_q <= !rd_illegal_w;
      else if ((rd_state == RD_ISSUE) && m_axi_arready)
        arvalid_q <= 1'b0;
    end
  end
  assign m_axi_arvalid = arvalid_q;

  always_comb begin
    m_axi_araddr = {rd_beat, 6'b00_0000};   // beat << 6 = byte address
  end

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      rd_state   <= RD_IDLE;
      rd_sel     <= 8'd0;
      rd_pick_q  <= 8'd0;
      rd_addr_q  <= '0;
      rd_base_q  <= '0;
      rd_size_q  <= '0;
      rd_wsh_q   <= '0;
      rd_beat    <= '0;
      rd_lane    <= 6'd0;
      rd_illegal <= 1'b0;
      rd_gnt     <= '0;
      bkp_rd_gnt <= 1'b0;
      for (int l = 0; l < NID; l++) trk_wptr[l] <= '0;
      // entry arrays carry a sync reset too: an unwritten slot must read
      // defined (0), or rready/acc_* catch X the cycle a late return races a
      // fresh push on an empty lane (iter-9 sim finding, static t14).
      for (int l = 0; l < NID; l++) begin
        for (int e = 0; e < TRK_D; e++) begin
          trk_port [l][e] <= '0;
          trk_lane [l][e] <= '0;
          trk_ts   [l][e] <= '0;
          trk_synth[l][e] <= 1'b0;
        end
      end
    end else begin
      rd_gnt     <= '0;
      bkp_rd_gnt <= 1'b0;
      unique case (rd_state)
        RD_IDLE: begin
          if (rd_start) begin
            rd_pick_q <= rd_pick;
            rd_state  <= RD_PICK;
          end
        end
        RD_PICK: begin
          rd_sel     <= rd_pick_q;
          rd_addr_q  <= rd_pickq_bkp ? '0 : rd_addr[rd_pick_q[5:0]];
          rd_base_q  <= cfg.port_base[rd_pick_q[5:0]];
          rd_size_q  <= cfg.port_size[rd_pick_q[5:0]];
          rd_wsh_q   <= cfg.wshift[rd_pick_q[5:0]];
          rd_state   <= RD_PREP;
        end
        RD_PREP: begin
          rd_illegal <= rd_illegal_w;
          rd_beat    <= rd_beat_w;
          rd_lane    <= rd_lane_w;
          rd_state   <= rd_illegal_w ? RD_SYNTH : RD_ISSUE;
        end
        RD_ISSUE: begin
          if (m_axi_arready) begin
            trk_port [push_id][trk_wptr[push_id]] <= rd_sel;
            trk_lane [push_id][trk_wptr[push_id]] <= rd_lane;
            trk_ts   [push_id][trk_wptr[push_id]] <= cyc_cnt;
            trk_synth[push_id][trk_wptr[push_id]] <= 1'b0;
            trk_wptr[push_id] <= trk_wptr[push_id] + TPW'(1);
            if (rd_sel == BKP_ID) bkp_rd_gnt        <= 1'b1;
            else                  rd_gnt[rd_sel[5:0]] <= 1'b1;
            rd_state            <= RD_POP;
          end
        end
        RD_SYNTH: begin
          // illegal address: no AXI traffic; in-order synthetic response
          trk_port [push_id][trk_wptr[push_id]] <= rd_sel;
          trk_lane [push_id][trk_wptr[push_id]] <= 6'd0;
          trk_ts   [push_id][trk_wptr[push_id]] <= cyc_cnt;
          trk_synth[push_id][trk_wptr[push_id]] <= 1'b1;
          trk_wptr[push_id] <= trk_wptr[push_id] + TPW'(1);
          rd_gnt[rd_sel[5:0]] <= 1'b1;
          rd_state            <= RD_POP;
        end
        // fast re-pick (the granted port is masked by the live grant pulse
        // while its FIFO/arbiter latch settles; all others are fresh — no
        // full-cycle bubble)
        RD_POP: begin
          if (rd_start) begin
            rd_pick_q <= rd_pick;
            rd_state  <= RD_PICK;
          end else begin
            rd_state  <= RD_IDLE;
          end
        end
        // no default: 5 states use 5 of 8 encodings; a unique-case violation
        // in sim flags X/corruption instead of silently resetting
      endcase
    end
  end

  // AXI ID = port[3:0] (16 IDs; backdoor shares lane 0, marked by port=BKP_ID)
  assign m_axi_arid    = (rd_sel == BKP_ID) ? 4'd0 : rd_sel[3:0];
  assign m_axi_arlen   = 8'd0;
  assign m_axi_arsize  = 3'b110;
  assign m_axi_arburst = 2'b01;

  // =========================================================================
  // Write engine (same 300 MHz split as the read engine: WR_IDLE latches
  // first_set + address + data, WR_PICK derives beat/lane/illegal and the
  // 512-bit lane-expanded data/strb — every WR_ISSUE output then comes from
  // a register.  wready/awready are consumed LIVE; see the read-engine note.)
  // =========================================================================
  typedef enum logic [2:0] {WR_IDLE, WR_PICK, WR_PREP, WR_ISSUE, WR_POP} wr_state_e;
  wr_state_e wr_state;

  logic [7:0]   wr_sel;
  logic [7:0]   wr_pick_q;
  logic [AW-1:0] wr_addr_q;
  logic [DW-1:0] wr_data_q;
  logic [BASE_W-1:0] wr_base_q;   // WR_PICK: port_base mux (quasi-static)
  logic [31:0]       wr_size_q;   // WR_PICK: port_size mux (quasi-static)
  logic [2:0]        wr_wsh_q;    // WR_PICK: cfg.wshift mux (elaboration-constant)
  logic [6:0]        wr_wb_q;     // WR_PICK: cfg.wbytes mux (used bytes)
  logic              wr_been_q;   // WR_PICK: cfg.be_en mux
  logic [63:0]       wr_be_q;     // WR_PICK: byte-enable latch
  logic [N-1:0] wr_req_masked;
  logic         aw_done, w_done;

  // WR_PICK-stage registers
  logic               wr_illegal;
  logic [BASE_W-1:0]  wr_beat;
  logic [511:0]       wr_data512;
  logic [63:0]        wr_strb64;

  for (genvar i = 0; i < N; i++) begin : g_wrmask
    assign wr_req_masked[i] = wr_vld[i] & cfg.port_en[i] & enable;
  end

  // same re-arbitration guard as the read engine: mask the LIVE grant pulse
  wire logic [N-1:0] wr_req_m      = wr_req_masked & ~wr_gnt;
  wire logic       wr_any_ports = |wr_req_m;
  wire logic       wr_any  = wr_any_ports | (bkp_wr_req && !bkp_wr_gnt);
  // lane-full eligibility mask — same 300 MHz cut as the read engine
  wire logic [N-1:0] wr_req_elig;
  for (genvar i = 0; i < N; i++) begin : g_wrelig
    assign wr_req_elig[i] = wr_req_m[i] & ~wl_full[i % NID];
  end
  wire logic       wr_elig_ports = |wr_req_elig;
  wire logic       wr_start = wr_elig_ports |
                              (bkp_wr_req && !bkp_wr_gnt && !wl_full[4'd0]);
  wire logic [7:0] wr_pick  = wr_elig_ports ? first_set(wr_req_elig) : BKP_ID;

  // WR_PREP-stage derivations from REGISTERED operands (same 300 MHz split
  // as the read engine: quasi-static base/size muxes latched in WR_PICK).
  // v1.1.0: beat/lane/size use the picked port's lane shift; the WSTRB byte
  // mask comes from cfg.wbytes (partial top lane for odd widths) ANDed with
  // the port's byte enables when cfg.be_en is set.
  wire logic               wr_pickq_bkp = (wr_pick_q == BKP_ID);
  wire logic [31:0]        wr_size_w    = wr_size_q >> wr_wsh_q;
  wire logic               wr_illegal_w = !wr_pickq_bkp &&
                                          (32'(wr_addr_q) >= wr_size_w);
  wire logic [5:0]         wr_lmask_w   = 6'hF >> wr_wsh_q;
  wire logic [5:0]         wr_lane_w = wr_pickq_bkp ? bkp_wr_lane
                                       : 6'((6'(wr_addr_q) & wr_lmask_w) << wr_wsh_q);
  wire logic [BASE_W-1:0]  wr_beat_w = wr_pickq_bkp ? bkp_wr_beat
                                       : wr_base_q + BASE_W'(wr_addr_q >> (4 - wr_wsh_q));
  wire logic [63:0]        wr_wmask_w   = {64{1'b1}} >> (64 - wr_wb_q);
  wire logic [63:0]        wr_bmask_w   = wr_been_q ? wr_be_q : {64{1'b1}};

  // write tracking (for B-channel SLVERR attribution), per AXI ID — the
  // MIG may complete different IDs out of order on B too
  logic [7:0]   wtrk_port [NID][TRK_D];
  logic [TPW-1:0] wtrk_wptr [NID];
  logic [TPW-1:0] wtrk_rptr [NID];
  logic [TPW:0]   wtrk_cnt  [NID];

  // no pending requests, both engines parked, and ALL responses returned —
  // the refresh scheduler's service gate.  The tracking-occupancy term
  // matters: an AR-block fired while reads are still in flight pushes their
  // returns past the period edge and the tail ports miss L=1 (2026-10-21
  // A4-in-sim st_full finding).  The masked *_any views are fine here: a
  // masked port is re-evaluated next cycle, and a refresh fired one cycle
  // early is still inside the idle gap's margin.
  logic [NID-1:0] trk_busy, wtrk_busy;
  for (genvar l = 0; l < NID; l++) begin : g_trk_busy
    assign trk_busy [l] = (trk_cnt [l] != '0);
    assign wtrk_busy[l] = (wtrk_cnt[l] != '0);
  end
  assign backend_idle = (rd_state == RD_IDLE) && (wr_state == WR_IDLE)
                        && !rd_any && !wr_any
                        && !(|trk_busy) && !(|wtrk_busy);

  wire logic [3:0] wr_push_id = (wr_sel == BKP_ID) ? 4'd0 : wr_sel[3:0];

  always_comb begin
    m_axi_awvalid = 1'b0;
    m_axi_wvalid  = 1'b0;
    m_axi_awaddr  = {wr_beat, 6'b00_0000};
    m_axi_wdata   = wr_data512;
    m_axi_wstrb   = wr_strb64;
    m_axi_wlast   = 1'b1;
    if (wr_state == WR_ISSUE) begin
      m_axi_awvalid = ~aw_done & ~wr_illegal;
      m_axi_wvalid  = ~w_done  & ~wr_illegal;
    end
  end

  // write completes when both AW and W have been accepted
  wire logic wr_push = (wr_state == WR_ISSUE) && !wr_illegal &&
                       (aw_done || (m_axi_awvalid && m_axi_awready)) &&
                       (w_done  || (m_axi_wvalid  && m_axi_wready));

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      wr_state   <= WR_IDLE;
      wr_sel     <= 8'd0;
      wr_pick_q  <= 8'd0;
      wr_addr_q  <= '0;
      wr_data_q  <= '0;
      wr_base_q  <= '0;
      wr_size_q  <= '0;
      wr_wsh_q   <= '0;
      wr_wb_q    <= '0;
      wr_been_q  <= 1'b0;
      wr_be_q    <= '0;
      wr_illegal <= 1'b0;
      wr_beat    <= '0;
      wr_data512 <= '0;
      wr_strb64  <= '0;
      aw_done    <= 1'b0;
      w_done     <= 1'b0;
      wr_gnt     <= '0;
      bkp_wr_gnt <= 1'b0;
      for (int l = 0; l < NID; l++) begin
        wtrk_wptr[l] <= '0;
        for (int e = 0; e < TRK_D; e++) wtrk_port[l][e] <= '0;
      end
    end else begin
      wr_gnt     <= '0;
      bkp_wr_gnt <= 1'b0;
      unique case (wr_state)
        WR_IDLE: begin
          if (wr_start) begin
            wr_pick_q <= wr_pick;
            wr_state  <= WR_PICK;
          end
        end
        WR_PICK: begin
          wr_sel     <= wr_pick_q;
          wr_addr_q  <= wr_pickq_bkp ? '0 : wr_addr[wr_pick_q[5:0]];
          wr_data_q  <= wr_pickq_bkp ? {{(DW-32){1'b0}}, bkp_wr_data} : wr_data[wr_pick_q[5:0]];
          wr_base_q  <= cfg.port_base[wr_pick_q[5:0]];
          wr_size_q  <= cfg.port_size[wr_pick_q[5:0]];
          wr_wsh_q   <= cfg.wshift[wr_pick_q[5:0]];
          wr_wb_q    <= wr_pickq_bkp ? 7'd4 : cfg.wbytes[wr_pick_q[5:0]];
          wr_been_q  <= !wr_pickq_bkp && cfg.be_en[wr_pick_q[5:0]];
          wr_be_q    <= wr_pickq_bkp ? {64{1'b1}} : wr_be[wr_pick_q[5:0]];
          wr_state   <= WR_PREP;
        end
        WR_PREP: begin
          wr_illegal <= wr_illegal_w;
          wr_beat    <= wr_beat_w;
          wr_data512 <= wr_data_q << (wr_lane_w * 32);
          wr_strb64  <= (wr_wmask_w & wr_bmask_w) << (wr_lane_w * 4);
          aw_done    <= 1'b0;
          w_done     <= 1'b0;
          wr_state   <= WR_ISSUE;
        end
        WR_ISSUE: begin
          if (wr_illegal) begin
            wr_gnt[wr_sel[5:0]] <= 1'b1;   // discard (posted, no response)
            wr_state            <= WR_POP;
          end else begin
            if (m_axi_awvalid && m_axi_awready) aw_done <= 1'b1;
            if (m_axi_wvalid  && m_axi_wready)  w_done  <= 1'b1;
            if (wr_push) begin
              wtrk_port[wr_push_id][wtrk_wptr[wr_push_id]] <= wr_sel;
              wtrk_wptr[wr_push_id] <= wtrk_wptr[wr_push_id] + TPW'(1);
              if (wr_sel == BKP_ID) bkp_wr_gnt        <= 1'b1;
              else                  wr_gnt[wr_sel[5:0]] <= 1'b1;
              wr_state             <= WR_POP;
            end
          end
        end
        // fast re-pick (granted port masked by the live grant pulse; see
        // the read engine)
        WR_POP: begin
          if (wr_start) begin
            wr_pick_q <= wr_pick;
            wr_state  <= WR_PICK;
          end else begin
            wr_state  <= WR_IDLE;
          end
        end
        // no default: unique-case violation in sim flags X/corruption
      endcase
    end
  end

  assign m_axi_awid    = (wr_sel == BKP_ID) ? 4'd0 : wr_sel[3:0];
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awsize  = 3'b110;
  assign m_axi_awburst = 2'b01;
  assign m_axi_bready  = 1'b1;

  // =========================================================================
  // Read-response routing (per-ID FIFO head; synthetic entries pop first)
  // =========================================================================
  // Backend timeout (spec ERR_STATUS.bit1): a tracking head older than
  // TRK_TIMEOUT ui cycles is popped synthetically (zeros), so the per-port
  // response-slot bookkeeping stays 1:1 with releases and nothing hangs.
  // 768 exceeds the worst CONTRACT-legal backend latency (the L=1 deadline,
  // 600) yet lands before the L=2 release edge at 500 KHz (1200), so a
  // one-shot backend failure degrades to a flagged zero instead of a
  // window violation.  A MIG that returns late-but-alive past the timeout
  // is outside the legal model (per-ID order would desync) — bit1 is the
  // alarm for exactly that.
  localparam int TRK_TIMEOUT = 768;

  // current head of the response ID's lane.  pop_real's data routing does
  // NOT read these live: it uses the acceptance-instant snapshot acc_* below
  // (the live rid -> 16:1 rptr mux -> 8:1 entry mux -> 64-way port decode ->
  // CE cone was WNS-critical, iter-8 build: -0.106 on rid_q ->
  // rsp_data_reg[57]/CE, 8 levels, 75% route).  The live head view remains
  // only for the pop guards and the latency stats (D paths).
  wire logic [3:0]  h_id       = rid_q;
  wire logic [15:0] head_age16 = cyc_cnt - trk_ts[h_id][trk_rptr[h_id]];
  wire logic [31:0] head_age   = 32'(head_age16);
  wire logic        head_synth = trk_synth[h_id][trk_rptr[h_id]];
  wire logic        lane_empty = (trk_cnt[h_id] == 0);

  // Synthetic/timeout pops run through a 2-stage registered pipeline (300 MHz
  // closure, 2026-10-21): the 16-lane x 8-entry head muxes + per-lane age
  // compares + priority encode + pop fanout could not meet ui_clk in one
  // cycle (WNS -2.206, ~17k failing endpoints).  Stage 1 snapshots every
  // lane's head descriptor into hd_*_q; stage 2 registers the priority
  // decision into pop_*_q; the fire then costs a few guard levels instead of
  // the whole cloud.  A fire is vetoed when the snapshot may be stale (any
  // pop on that lane in the previous two cycles) or when the real channel
  // owns/races the same lane; a vetoed decision is re-derived from the next
  // snapshot, so nothing is lost.  Synthetic/timeout pops only fire on
  // faults/illegal addresses — the 2-cycle latency is functionally
  // invisible, and the 768 timeout still lands far before the L=2 edge.
  logic [7:0] hd_port_q  [NID];
  logic       hd_synth_q [NID];
  logic       hd_tmo_q   [NID];
  logic       hd_empty_q [NID];

  always_ff @(posedge ui_clk) begin
    for (int l = 0; l < NID; l++) begin
      hd_port_q [l] <= trk_port [l][trk_rptr[l]];
      hd_synth_q[l] <= trk_synth[l][trk_rptr[l]];
      hd_tmo_q  [l] <= 16'(cyc_cnt - trk_ts[l][trk_rptr[l]]) > 16'(TRK_TIMEOUT);
      hd_empty_q[l] <= (trk_cnt[l] == '0);
    end
  end

  logic [3:0] pop_id_c;
  logic       pop_synth_c, pop_tmo_c;
  always_comb begin
    pop_id_c    = 4'd0;
    pop_synth_c = 1'b0;
    pop_tmo_c   = 1'b0;
    for (int l = NID - 1; l >= 0; l--) begin
      if (!hd_empty_q[l] && hd_synth_q[l]) begin
        pop_id_c    = 4'(l);
        pop_synth_c = 1'b1;
      end else if (!hd_empty_q[l] && hd_tmo_q[l]) begin
        pop_id_c  = 4'(l);
        pop_tmo_c = 1'b1;
      end
    end
  end

  logic [3:0] pop_id_q;
  logic [7:0] pop_port_q;
  logic       pop_synth_q, pop_tmo_q, pop_bkp_q;
  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      pop_id_q    <= 4'd0;
      pop_port_q  <= 8'd0;
      pop_synth_q <= 1'b0;
      pop_tmo_q   <= 1'b0;
      pop_bkp_q   <= 1'b0;
    end else begin
      pop_id_q    <= pop_id_c;
      pop_port_q  <= hd_port_q[pop_id_c];
      pop_synth_q <= pop_synth_c;
      pop_tmo_q   <= pop_tmo_c;
      pop_bkp_q   <= (hd_port_q[pop_id_c] == BKP_ID);
    end
  end

  wire logic pop_real = !lane_empty && !head_synth && rvalid_q && rready_q;

  // Acceptance-instant head snapshot (300 MHz closure, iter-9, 2026-10-21):
  // pop_real must name the accepted beat's tracking entry on the very next
  // cycle; deriving it live (rid -> 16:1 rptr mux -> 8:1 entry mux -> 64-way
  // port decode -> CE) was the iter-8 WNS cone above.  In-order returns per
  // ID make the beat's entry the lane head AT ACCEPTANCE — or head+1 when
  // the previous same-lane beat is consumed in that same cycle (the only pop
  // that can touch the lane between acceptance and consumption: race_live
  // vetoes fire_tmo, a synth head blocks acceptance, and a lane's rptr moves
  // at most one step per cycle) — so this snapshot names exactly the entry
  // the live head mux would name at pop time, but from registers.
  logic [7:0] acc_port_q;
  logic [5:0] acc_lane_q;
  logic       acc_bkp_q;
  wire logic [3:0]     acc_id   = m_axi_rid;
  wire logic           acc_same = pop_real && (acc_id == h_id);
  wire logic [TPW-1:0] acc_rptr = trk_rptr[acc_id] + TPW'(acc_same);

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      acc_port_q <= 8'd0;
      acc_lane_q <= 6'd0;
      acc_bkp_q  <= 1'b0;
    end else begin
      acc_port_q <= trk_port[acc_id][acc_rptr];
      acc_lane_q <= trk_lane[acc_id][acc_rptr];
      acc_bkp_q  <= (trk_port[acc_id][acc_rptr] == BKP_ID);
    end
  end

  // Per-lane acceptance eligibility as 16 independent small cones (300 MHz
  // closure, 2026-10-21): the previous form gathered all 16 lanes' cnt/synth
  // operands inline on the live bus signals (~9 serial levels, MIG-source ->
  // trk_rptr CE was WNS-critical).  Indexing a precomputed 1-bit vector is
  // logically identical: for race_live, rid==pop_id_q makes
  // lane_open[rid] == lane_open[pop_id_q].
  logic [NID-1:0] lane_open;
  for (genvar l = 0; l < NID; l++) begin : g_lane_open
    assign lane_open[l] = (trk_cnt[l] != TRK_D) && !trk_synth[l][trk_rptr[l]];
  end

  // accept a beat only if its lane can hold it AND its head is not
  // synthetic: an accepted beat must be consumable on the next cycle —
  // accepting while a synth head blocks the pop would leave the beat's data
  // overwritten by the next arrival before it is ever consumed (2026-10-20
  // per-ID bring-up bug; the model holds rvalid until rready, so the beat
  // simply waits for the synth head to clear)
  assign m_axi_rready = lane_open[m_axi_rid];

  // Per-lane pop vector + 2-cycle history for the staleness veto.  A fire
  // pops whatever rptr points to when it lands; the snapshot it was derived
  // from described the head two cycles earlier, so any pop on the lane in
  // between invalidates it.
  logic [NID-1:0] popv;
  logic [NID-1:0] popd_q, popd_qq;

  // race_real: the beat consumed this cycle owns the head — pop_real wins.
  // (Impossible for a synth head: rready refuses acceptance while the head
  // is synthetic, so fire_synth needs no such veto.)  race_live: a beat
  // accepted NOW also belongs to the head entry (in-order returns); veto
  // the timeout fire and let pop_real consume it next cycle instead.
  wire logic fire_stale  = popd_q[pop_id_q] || popd_qq[pop_id_q];
  wire logic race_real   = pop_real && (h_id == pop_id_q);
  wire logic race_live   = m_axi_rvalid && lane_open[pop_id_q]
                           && (m_axi_rid == pop_id_q);
  wire logic fire_synth  = pop_synth_q && !fire_stale;
  wire logic fire_tmo    = pop_tmo_q && !fire_stale && !race_real && !race_live;

  always_comb begin
    popv = '0;
    if (pop_real)   popv[h_id]     = 1'b1;
    if (fire_synth) popv[pop_id_q] = 1'b1;
    if (fire_tmo)   popv[pop_id_q] = 1'b1;
  end

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      popd_q  <= '0;
      popd_qq <= '0;
    end else begin
      popd_q  <= popv;
      popd_qq <= popd_q;
    end
  end

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      for (int l = 0; l < NID; l++) trk_rptr[l] <= '0;
      rsp_vld     <= '0;
      rsp_data    <= '0;
      bkp_rd_done <= 1'b0;
      bkp_rd_data <= '0;
    end else begin
      rsp_vld     <= '0;
      bkp_rd_done <= 1'b0;
      // pop_real stays live: the accepted beat's rvalid_q is a 1-cycle
      // window — deferring it would lose the beat forever (lane wedges,
      // then spurious timeouts).  It never collides with the registered
      // fires below: race_real vetoes a same-lane fire_tmo, and a synth
      // head cannot have a beat (rready refused its acceptance).  Pops on
      // different lanes in the same cycle are safe (disjoint rptrs, and
      // port[3:0] identifies the lane so rsp targets never alias; backdoor
      // entries only ever live on lane 0).
      if (pop_real) begin
        trk_rptr[h_id] <= trk_rptr[h_id] + TPW'(1);
        if (acc_bkp_q) begin
          bkp_rd_done <= 1'b1;
          bkp_rd_data <= 32'(rdata_q >> (acc_lane_q * 32));
        end else begin
          rsp_vld [acc_port_q[5:0]] <= 1'b1;
          // full-beat shift, LSB-justified: the port truncates to its own
          // width (v1.1.0) — no per-port mask needed on this (WNS-critical,
          // iter-8) CE path
          rsp_data[acc_port_q[5:0]] <= rdata_q >> (acc_lane_q * 32);
        end
      end
      if (fire_synth) begin
        trk_rptr[pop_id_q] <= trk_rptr[pop_id_q] + TPW'(1);
        rsp_vld [pop_port_q[5:0]] <= 1'b1;
        rsp_data[pop_port_q[5:0]] <= '0;   // illegal-address read returns 0
      end
      if (fire_tmo) begin
        trk_rptr[pop_id_q] <= trk_rptr[pop_id_q] + TPW'(1);
        if (pop_bkp_q) begin
          bkp_rd_done <= 1'b1;
          bkp_rd_data <= '0;
        end else begin
          rsp_vld [pop_port_q[5:0]] <= 1'b1;
          rsp_data[pop_port_q[5:0]] <= '0;   // timeout: synthetic zeros
        end
      end
    end
  end

  // FIFO occupancy counters (push and pop can land on different lanes in
  // the same cycle; same-lane push+pop holds)
  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      for (int l = 0; l < NID; l++) trk_cnt[l] <= '0;
      for (int l = 0; l < NID; l++) wtrk_rptr[l] <= '0;
      for (int l = 0; l < NID; l++) wtrk_cnt[l]  <= '0;
      lane_full <= '0;
      wl_full   <= '0;
    end else begin
      for (int l = 0; l < NID; l++) begin
        if (rd_push && (push_id == 4'(l)) && !popv[l]) begin
          trk_cnt[l] <= trk_cnt[l] + 1'b1;
          if (trk_cnt[l] == (TPW+1)'(TRK_D-1)) lane_full[l] <= 1'b1;
        end else if (popv[l] && !(rd_push && (push_id == 4'(l)))) begin
          trk_cnt[l] <= trk_cnt[l] - 1'b1;
          lane_full[l] <= 1'b0;
        end
      end
      // write tracking: push on AW+W completion, pop on B (registered view)
      if (wr_push && !(bvalid_q && (wr_push_id == bid_q))) begin
        wtrk_cnt[wr_push_id] <= wtrk_cnt[wr_push_id] + 1'b1;
        if (wtrk_cnt[wr_push_id] == (TPW+1)'(TRK_D-1)) wl_full[wr_push_id] <= 1'b1;
      end
      if (bvalid_q && !(wr_push && (wr_push_id == bid_q))) begin
        wtrk_cnt[bid_q] <= wtrk_cnt[bid_q] - 1'b1;
        wl_full[bid_q] <= 1'b0;
      end
      if (bvalid_q)
        wtrk_rptr[bid_q] <= wtrk_rptr[bid_q] + TPW'(1);
    end
  end

  // =========================================================================
  // Statistics and error events
  // =========================================================================
  // Per-port error-count one-hot increment vector, registered before use
  // (300 MHz closure, M5-hw): every error source decodes its port into one
  // hot bit here; port_stat_err increments from the REGISTERED vector, so
  // the counter CE path is two levels.  Same-port same-cycle events from
  // multiple sources collapse to one count — PORT_STAT_ERR only needs
  // 0-vs-nonzero fidelity.  Selftest pulses (st_err) are already 1-cycle
  // ui_clk pulses and fold in as-is.
  logic [N-1:0] stat_err_incr;
  logic [N-1:0] stat_err_incr_q;

  always_comb begin
    stat_err_incr = '0;
    if (rd_state == RD_SYNTH)
      stat_err_incr[rd_sel[5:0]] = 1'b1;                        // illegal read
    if (wr_state == WR_ISSUE && wr_illegal)
      stat_err_incr[wr_sel[5:0]] = 1'b1;                        // illegal write
    if (fire_tmo && !pop_bkp_q)
      stat_err_incr[pop_port_q[5:0]] = 1'b1;                    // backend timeout
    if (pop_real && rresp_q != 2'b00 && !acc_bkp_q)
      stat_err_incr[acc_port_q[5:0]] = 1'b1;                     // read SLVERR
    if (bvalid_q && bresp_q != 2'b00 && wtrk_port[bid_q][wtrk_rptr[bid_q]] != BKP_ID)
      stat_err_incr[wtrk_port[bid_q][wtrk_rptr[bid_q]][5:0]] = 1'b1;  // write SLVERR
    stat_err_incr |= st_err;                                    // selftest (M5-hw)
  end

  always_ff @(posedge ui_clk) begin
    if (ui_rst || soft_rst) stat_err_incr_q <= '0;
    else                    stat_err_incr_q <= stat_err_incr;
  end

  // read/write issue increments through the same registered-one-hot pattern
  // (300 MHz closure, 2026-10-21): the issue-accept cones (live ready
  // handshake + port decode) drove 64 counter CEs directly and missed
  // ui_clk.  Stats are read quiesced via CSR, so a 1-cycle count delay is
  // invisible; a pending increment is dropped on soft_rst with the counters.
  logic [N-1:0] stat_rd_incr, stat_wr_incr, stat_rd_incr_q, stat_wr_incr_q;
  logic         stat_tot_rd_inc, stat_tot_wr_inc;
  logic         stat_tot_rd_inc_q, stat_tot_wr_inc_q;

  always_comb begin
    stat_rd_incr    = '0;
    stat_wr_incr    = '0;
    stat_tot_rd_inc = 1'b0;
    stat_tot_wr_inc = 1'b0;
    if (rd_state == RD_ISSUE && m_axi_arvalid && m_axi_arready) begin
      stat_tot_rd_inc = 1'b1;                       // totals include backdoor
      if (rd_sel != BKP_ID) stat_rd_incr[rd_sel[5:0]] = 1'b1;
    end
    if (wr_push) begin
      stat_tot_wr_inc = 1'b1;
      if (wr_sel != BKP_ID) stat_wr_incr[wr_sel[5:0]] = 1'b1;
    end
  end

  always_ff @(posedge ui_clk) begin
    if (ui_rst || soft_rst) begin
      stat_rd_incr_q    <= '0;
      stat_wr_incr_q    <= '0;
      stat_tot_rd_inc_q <= 1'b0;
      stat_tot_wr_inc_q <= 1'b0;
    end else begin
      stat_rd_incr_q    <= stat_rd_incr;
      stat_wr_incr_q    <= stat_wr_incr;
      stat_tot_rd_inc_q <= stat_tot_rd_inc;
      stat_tot_wr_inc_q <= stat_tot_wr_inc;
    end
  end

  always_ff @(posedge ui_clk) begin
    if (ui_rst || soft_rst) begin
      stat_tot_rd   <= 64'd0;
      stat_tot_wr   <= 64'd0;
      stat_maxlat   <= 32'd0;
      port_stat_rd  <= '{default: 32'd0};
      port_stat_wr  <= '{default: 32'd0};
      port_stat_err <= '{default: 32'd0};
      err_illegal   <= 1'b0;
      err_timeout   <= 1'b0;
      err_slverr    <= 1'b0;
      err_port      <= 8'd0;
      err_addr      <= 32'd0;
      cyc_cnt       <= 16'd0;
    end else begin
      cyc_cnt     <= cyc_cnt + 16'd1;
      err_illegal <= 1'b0;
      err_timeout <= 1'b0;
      err_slverr  <= 1'b0;

      // read/write issue counters increment from the REGISTERED one-hots
      if (stat_tot_rd_inc_q) stat_tot_rd <= stat_tot_rd + 64'd1;
      if (stat_tot_wr_inc_q) stat_tot_wr <= stat_tot_wr + 64'd1;
      for (int p = 0; p < N; p++) begin
        if (stat_rd_incr_q[p]) port_stat_rd[p] <= port_stat_rd[p] + 32'd1;
        if (stat_wr_incr_q[p]) port_stat_wr[p] <= port_stat_wr[p] + 32'd1;
      end
      // illegal read detected: record at synthetic-response injection
      // (sel/illegal/addr all registered -> short path, 300 MHz closure)
      if (rd_state == RD_SYNTH) begin
        err_illegal <= 1'b1;
        err_port    <= rd_sel;
        err_addr    <= 32'({2'b00, rd_sel, rd_addr_q});
      end
      // illegal write detected: record at the discard cycle (all registered)
      if (wr_state == WR_ISSUE && wr_illegal) begin
        err_illegal <= 1'b1;
        err_port    <= wr_sel;
        err_addr    <= 32'({2'b00, wr_sel, wr_addr_q});
      end
      // read response latency
      if (pop_real && head_age > stat_maxlat)
        stat_maxlat <= head_age;
      // backend timeout (head popped synthetically with zeros); the port
      // comes from the registered decision — the pre-pipeline code read
      // head_port here, which misattributed the event whenever the timed-out
      // lane differed from the response channel's
      if (fire_tmo) begin
        err_timeout <= 1'b1;
        err_port    <= pop_port_q;     // err_addr not meaningful: untouched
      end
      // SLVERR on read or write channels (backdoor: port field = 8'hFF)
      if (pop_real && rresp_q != 2'b00) begin
        err_slverr <= 1'b1;
        err_port   <= acc_port_q;
      end
      if (bvalid_q && bresp_q != 2'b00) begin
        err_slverr <= 1'b1;
        err_port   <= wtrk_port[bid_q][wtrk_rptr[bid_q]];
      end
      // per-port error counters: increment from the REGISTERED one-hot
      // vector below (300 MHz closure: the counter CE is 2 levels off a
      // register).  One count per port per cycle even with multiple sources
      // (later non-blocking assignment wins the clear).
      for (int p = 0; p < N; p++)
        if (stat_err_incr_q[p]) port_stat_err[p] <= port_stat_err[p] + 32'd1;
      // per-port error counter clear from CSR indexed window
      if (err_clr && err_clr_port < 8'(N_MAX))
        port_stat_err[err_clr_port[5:0]] <= 32'd0;
    end
  end

endmodule

`default_nettype wire
