//-----------------------------------------------------------------------------
// HADES-SRAM — MIG AXI4 backend interface (spec 3.2).  ui_clk domain only.
//
// - Per-port read/write request FIFO heads arrive here (rd_vld/rd_addr ...,
//   level-held until rd_gnt).  FCFS with fixed lowest-index priority; the
//   TDMA slot gating of spec 3.2 is layered in front of this engine in M4
//   (hades_arbiter) without changing the engine itself.
// - Reads: one 512-bit beat per access (DW <= 64), single AXI ID 0 so MIG
//   returns strictly in issue order; a tracking FIFO carries {port, lane,
//   timestamp, synthetic} for response routing and STAT_MAXLAT.
// - Illegal addresses (>= cfg.port_size[p]) are not issued to AXI; a
//   synthetic tracking entry returns zeros in order and flags
//   ERR_STATUS.bit0.
// - Writes: posted; WSTRB sub-word lane expansion; B tracked per port for
//   SLVERR reporting.
// - Backdoor (M4): an extra lowest-priority requester on both engines
//   (sel = 8'hFF marker), picked only when no port is eligible — i.e. in
//   the maintenance window and idle slots.  Backdoor beats/lanes arrive
//   pre-translated from hades_backdoor; read data returns on bkp_rd_*.
//   Backdoor traffic counts in stat_tot_* but not in per-port stats.
// - Outstanding depth 32 (spec: >= 16).
//-----------------------------------------------------------------------------
`default_nettype none

module hades_mig_if
  import hades_pkg::*;
#(
  parameter int N  = N_MAX,
  parameter int DW = DW_DEFAULT,
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
  input  wire logic [7:0]                err_clr_port,  // PORT_STAT_ERR W1C
  input  wire logic                      err_clr,
  input  wire logic                      soft_rst,

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
  output          logic [DW-1:0]         bkp_rd_data,
  input  wire logic                      bkp_wr_req,
  input  wire logic [BASE_W-1:0]         bkp_wr_beat,
  input  wire logic [5:0]                bkp_wr_lane,
  input  wire logic [DW-1:0]             bkp_wr_data,
  output          logic                  bkp_wr_gnt
);

  localparam logic [7:0] BKP_ID = 8'hFF;   // backdoor marker in tracking FIFOs

  localparam int SH     = dw_shift(DW);   // addr bits selecting a lane
  localparam int TRK_D  = 32;             // outstanding depth (spec >= 16)
  localparam int TRK_W  = 6;              // track pointer width (DEPTH>... )
  localparam int TPW    = $clog2(TRK_D);

  // =========================================================================
  // Read engine
  // =========================================================================
  typedef enum logic [1:0] {RD_IDLE, RD_ISSUE, RD_SYNTH, RD_POP} rd_state_e;
  rd_state_e rd_state;

  logic [7:0]            rd_sel;
  logic [N-1:0]          rd_req_masked;
  logic [BASE_W-1:0]     rd_beat;
  logic                  rd_illegal;

  // tracking FIFO (issue order; single AXI ID 0 => in-order returns)
  logic [7:0]   trk_port  [TRK_D];
  logic [5:0]   trk_lane  [TRK_D];
  logic [15:0]  trk_ts    [TRK_D];
  logic         trk_synth [TRK_D];
  logic [TPW-1:0] trk_wptr, trk_rptr;
  logic [TPW:0]   trk_cnt;
  wire logic trk_full  = (trk_cnt == TRK_D);
  wire logic trk_empty = (trk_cnt == 0);

  logic [15:0] cyc_cnt;   // free-running ui cycle counter for latency stats

  // lowest-index set bit
  function automatic logic [7:0] first_set(input logic [N-1:0] v);
    logic [7:0] r;
    r = 8'hFF;
    for (int i = N - 1; i >= 0; i--)
      if (v[i]) r = 8'(i);
    return r;
  endfunction

  for (genvar i = 0; i < N; i++) begin : g_rdmask
    assign rd_req_masked[i] = rd_vld[i] & cfg.port_en[i] & enable;
  end

  wire logic        rd_any_ports = |rd_req_masked;
  wire logic        rd_any  = rd_any_ports | bkp_rd_req;
  wire logic [7:0]  rd_pick = rd_any_ports ? first_set(rd_req_masked) : BKP_ID;
  wire logic        rd_pick_bkp = (rd_pick == BKP_ID);
  wire logic [31:0] rd_size_sel = cfg.port_size[rd_pick[5:0]];
  wire logic        rd_pick_illegal = !rd_pick_bkp &&
                                      (32'(rd_addr[rd_pick[5:0]]) >= rd_size_sel);

  // -- read FSM (2-process) --
  always_comb begin
    m_axi_arvalid = 1'b0;
    m_axi_araddr  = '0;
    unique case (rd_state)
      RD_IDLE:   ;
      RD_ISSUE:  begin
        m_axi_arvalid = 1'b1;
        m_axi_araddr  = {rd_beat, 6'b00_0000};   // beat << 6 = byte address
      end
      RD_SYNTH:  ;
      default:   ;
    endcase
  end

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      rd_state   <= RD_IDLE;
      rd_sel     <= 8'd0;
      rd_beat    <= '0;
      rd_illegal <= 1'b0;
      rd_gnt     <= '0;
      bkp_rd_gnt <= 1'b0;
      trk_wptr   <= '0;
    end else begin
      rd_gnt     <= '0;
      bkp_rd_gnt <= 1'b0;
      unique case (rd_state)
        RD_IDLE: begin
          if (rd_any && !trk_full) begin
            rd_sel     <= rd_pick;
            rd_illegal <= rd_pick_illegal;
            rd_beat    <= rd_pick_bkp ? bkp_rd_beat
                          : cfg.port_base[rd_pick[5:0]]
                            + BASE_W'(rd_addr[rd_pick[5:0]] >> SH);
            rd_state   <= rd_pick_illegal ? RD_SYNTH : RD_ISSUE;
          end
        end
        RD_ISSUE: begin
          if (m_axi_arready) begin
            trk_port [trk_wptr] <= rd_sel;
            trk_lane [trk_wptr] <= (rd_sel == BKP_ID) ? bkp_rd_lane
                                   : 6'(rd_addr[rd_sel[5:0]] & {{(AW-SH){1'b0}}, {SH{1'b1}}});
            trk_ts   [trk_wptr] <= cyc_cnt;
            trk_synth[trk_wptr] <= 1'b0;
            trk_wptr            <= trk_wptr + TPW'(1);
            if (rd_sel == BKP_ID) bkp_rd_gnt        <= 1'b1;
            else                  rd_gnt[rd_sel[5:0]] <= 1'b1;
            rd_state            <= RD_POP;
          end
        end
        RD_SYNTH: begin
          // illegal address: no AXI traffic; in-order synthetic response
          trk_port [trk_wptr] <= rd_sel;
          trk_lane [trk_wptr] <= 6'd0;
          trk_ts   [trk_wptr] <= cyc_cnt;
          trk_synth[trk_wptr] <= 1'b1;
          trk_wptr            <= trk_wptr + TPW'(1);
          rd_gnt[rd_sel[5:0]] <= 1'b1;
          rd_state            <= RD_POP;
        end
        // one bubble: let the port FIFO pop settle (rempty re-evaluates)
        // before arbitrating again — otherwise the same head is granted twice
        RD_POP: rd_state <= RD_IDLE;
        // no default: all 4 encodings are valid states; a unique-case
        // violation in sim flags X/corruption instead of silently resetting
      endcase
    end
  end

  assign m_axi_arid    = 4'd0;
  assign m_axi_arlen   = 8'd0;
  assign m_axi_arsize  = 3'b110;
  assign m_axi_arburst = 2'b01;

  // =========================================================================
  // Write engine
  // =========================================================================
  typedef enum logic [1:0] {WR_IDLE, WR_ISSUE, WR_POP} wr_state_e;
  wr_state_e wr_state;

  logic [7:0]   wr_sel;
  logic [N-1:0] wr_req_masked;
  logic         aw_done, w_done;

  for (genvar i = 0; i < N; i++) begin : g_wrmask
    assign wr_req_masked[i] = wr_vld[i] & cfg.port_en[i] & enable;
  end

  wire logic       wr_any_ports = |wr_req_masked;
  wire logic       wr_any  = wr_any_ports | bkp_wr_req;
  wire logic [7:0] wr_pick = wr_any_ports ? first_set(wr_req_masked) : BKP_ID;
  wire logic       wr_pick_bkp = (wr_pick == BKP_ID);
  wire logic       wr_pick_illegal = !wr_pick_bkp &&
                                     (32'(wr_addr[wr_pick[5:0]]) >= cfg.port_size[wr_pick[5:0]]);

  // lane expansion for the selected write (backdoor supplies its own)
  wire logic               wr_is_bkp = (wr_sel == BKP_ID);
  wire logic [5:0]         wr_lane  = wr_is_bkp ? bkp_wr_lane
                                      : 6'(wr_addr[wr_sel[5:0]] & {{(AW-SH){1'b0}}, {SH{1'b1}}});
  wire logic [DW-1:0]      wr_dsel  = wr_is_bkp ? bkp_wr_data : wr_data[wr_sel[5:0]];
  wire logic [511:0]       wr_data512 = 512'(wr_dsel) << (wr_lane * DW);
  wire logic [63:0]        wr_strb64  = (64'({64{1'b1}}) >> (64 - DW/8)) << (wr_lane * (DW/8));
  wire logic [BASE_W-1:0]  wr_beat  = wr_is_bkp ? bkp_wr_beat
                                      : cfg.port_base[wr_sel[5:0]]
                                        + BASE_W'(wr_addr[wr_sel[5:0]] >> SH);
  wire logic               wr_illegal;

  // write tracking (for B-channel SLVERR attribution)
  logic [7:0]   wtrk_port [TRK_D];
  logic [TPW-1:0] wtrk_wptr, wtrk_rptr;
  logic [TPW:0]   wtrk_cnt;
  wire logic wtrk_full = (wtrk_cnt == TRK_D);

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

  assign wr_illegal = (wr_sel != BKP_ID) &&
                      (32'(wr_addr[wr_sel[5:0]]) >= cfg.port_size[wr_sel[5:0]]);

  // write completes when both AW and W have been accepted
  wire logic wr_push = (wr_state == WR_ISSUE) && !wr_illegal &&
                       (aw_done || (m_axi_awvalid && m_axi_awready)) &&
                       (w_done  || (m_axi_wvalid  && m_axi_wready));

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      wr_state   <= WR_IDLE;
      wr_sel     <= 8'd0;
      aw_done    <= 1'b0;
      w_done     <= 1'b0;
      wr_gnt     <= '0;
      bkp_wr_gnt <= 1'b0;
      wtrk_wptr  <= '0;
    end else begin
      wr_gnt     <= '0;
      bkp_wr_gnt <= 1'b0;
      unique case (wr_state)
        WR_IDLE: begin
          if (wr_any && !wtrk_full) begin
            wr_sel  <= wr_pick;
            aw_done <= 1'b0;
            w_done  <= 1'b0;
            wr_state <= WR_ISSUE;
          end
        end
        WR_ISSUE: begin
          if (wr_illegal) begin
            wr_gnt[wr_sel[5:0]] <= 1'b1;   // discard (posted, no response)
            wr_state            <= WR_POP;
          end else begin
            if (m_axi_awvalid && m_axi_awready) aw_done <= 1'b1;
            if (m_axi_wvalid  && m_axi_wready)  w_done  <= 1'b1;
            if (wr_push) begin
              wtrk_port[wtrk_wptr] <= wr_sel;
              wtrk_wptr            <= wtrk_wptr + TPW'(1);
              if (wr_is_bkp) bkp_wr_gnt        <= 1'b1;
              else           wr_gnt[wr_sel[5:0]] <= 1'b1;
              wr_state             <= WR_POP;
            end
          end
        end
        // one bubble: let the port FIFO pop settle before arbitrating again
        WR_POP: wr_state <= WR_IDLE;
        // no default: unique-case violation in sim flags X/corruption
      endcase
    end
  end

  assign m_axi_awid    = 4'd0;
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awsize  = 3'b110;
  assign m_axi_awburst = 2'b01;
  assign m_axi_bready  = 1'b1;

  // =========================================================================
  // Read-response routing (track FIFO head; synthetic entries pop immediately)
  // =========================================================================
  // Backend timeout (spec ERR_STATUS.bit1): the tracking head older than
  // TRK_TIMEOUT ui cycles is popped synthetically (zeros), so the per-port
  // response-slot bookkeeping stays 1:1 with releases and nothing hangs.
  // 768 exceeds the worst legal backend latency (~580 at full load incl.
  // maintenance) yet lands before the L=2 release edge at 500 KHz, so a
  // one-shot backend failure degrades to a flagged zero instead of a
  // window violation.  A MIG that returns late-but-alive past the timeout
  // is outside the legal model (in-order returns would desync) — the bit1
  // flag is the alarm for exactly that.
  localparam int TRK_TIMEOUT = 768;

  wire logic [7:0]  head_port  = trk_port[trk_rptr];
  wire logic [5:0]  head_lane  = trk_lane[trk_rptr];
  // modular 16-bit age: wrap-safe for ages < 32768 (legal max ~136 cycles;
  // the 768-cycle timeout and every legal latency sit far below the wrap)
  wire logic [15:0] head_age16 = cyc_cnt - trk_ts[trk_rptr];
  wire logic [31:0] head_age   = 32'(head_age16);
  wire logic        head_synth = trk_synth[trk_rptr];
  wire logic        head_bkp   = (head_port == BKP_ID);
  wire logic        pop_synth  = !trk_empty && head_synth;
  wire logic        pop_real   = !trk_empty && !head_synth && m_axi_rvalid;
  wire logic        pop_tmo    = !trk_empty && !head_synth && !m_axi_rvalid
                                 && (head_age > 32'(TRK_TIMEOUT));

  assign m_axi_rready = !trk_empty && !head_synth;

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      trk_rptr    <= '0;
      rsp_vld     <= '0;
      rsp_data    <= '0;
      bkp_rd_done <= 1'b0;
      bkp_rd_data <= '0;
    end else begin
      rsp_vld     <= '0;
      bkp_rd_done <= 1'b0;
      if (pop_synth) begin
        trk_rptr <= trk_rptr + TPW'(1);
        rsp_vld [head_port[5:0]] <= 1'b1;
        rsp_data[head_port[5:0]] <= '0;   // illegal-address read returns 0
      end else if (pop_real) begin
        trk_rptr <= trk_rptr + TPW'(1);
        if (head_bkp) begin
          bkp_rd_done <= 1'b1;
          bkp_rd_data <= DW'(m_axi_rdata >> (head_lane * DW));
        end else begin
          rsp_vld [head_port[5:0]] <= 1'b1;
          rsp_data[head_port[5:0]] <= DW'(m_axi_rdata >> (head_lane * DW));
        end
      end else if (pop_tmo) begin
        trk_rptr <= trk_rptr + TPW'(1);
        if (head_bkp) begin
          bkp_rd_done <= 1'b1;
          bkp_rd_data <= '0;
        end else begin
          rsp_vld [head_port[5:0]] <= 1'b1;
          rsp_data[head_port[5:0]] <= '0;   // timeout: synthetic zeros
        end
      end
    end
  end

  // FIFO occupancy counters
  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      trk_cnt   <= '0;
      wtrk_rptr <= '0;
      wtrk_cnt  <= '0;
    end else begin
      // read tracking: push on AR accept or synthetic inject; pop on response
      unique case ({(rd_state == RD_ISSUE) && m_axi_arvalid && m_axi_arready,
                    (rd_state == RD_SYNTH),
                    (pop_synth || pop_real || pop_tmo)})
        3'b100, 3'b010: trk_cnt <= trk_cnt + 1'b1;
        3'b001:         trk_cnt <= trk_cnt - 1'b1;
        default:        ;                        // push+pop: unchanged
      endcase
      // write tracking: push on AW+W completion, pop on B
      unique case ({wr_push, m_axi_bvalid})
        2'b10:   wtrk_cnt <= wtrk_cnt + 1'b1;
        2'b01:   wtrk_cnt <= wtrk_cnt - 1'b1;
        default: ;
      endcase
      if (m_axi_bvalid)
        wtrk_rptr <= wtrk_rptr + TPW'(1);
    end
  end

  // =========================================================================
  // Statistics and error events
  // =========================================================================
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

      // read issue (totals include the backdoor; per-port stats exclude it)
      if (rd_state == RD_ISSUE && m_axi_arvalid && m_axi_arready) begin
        stat_tot_rd <= stat_tot_rd + 64'd1;
        if (rd_sel != BKP_ID)
          port_stat_rd[rd_sel[5:0]] <= port_stat_rd[rd_sel[5:0]] + 32'd1;
      end
      // illegal read detected at arbitration
      if (rd_state == RD_IDLE && rd_any && !trk_full && rd_pick_illegal) begin
        err_illegal <= 1'b1;
        err_port    <= rd_pick;
        err_addr    <= 32'({2'b00, rd_pick, rd_addr[rd_pick[5:0]]});
        port_stat_err[rd_pick[5:0]] <= port_stat_err[rd_pick[5:0]] + 32'd1;
      end
      // write issue / illegal write
      if (wr_state == WR_ISSUE && !wr_illegal &&
          (aw_done || (m_axi_awvalid && m_axi_awready)) &&
          (w_done  || (m_axi_wvalid  && m_axi_wready))) begin
        stat_tot_wr <= stat_tot_wr + 64'd1;
        if (wr_sel != BKP_ID)
          port_stat_wr[wr_sel[5:0]] <= port_stat_wr[wr_sel[5:0]] + 32'd1;
      end
      if (wr_state == WR_ISSUE && wr_illegal) begin
        err_illegal <= 1'b1;
        err_port    <= wr_sel;
        err_addr    <= 32'({2'b00, wr_sel, wr_addr[wr_sel[5:0]]});
        port_stat_err[wr_sel[5:0]] <= port_stat_err[wr_sel[5:0]] + 32'd1;
      end
      // read response latency
      if (pop_real && head_age > stat_maxlat)
        stat_maxlat <= head_age;
      // backend timeout (head popped synthetically with zeros)
      if (pop_tmo) begin
        err_timeout <= 1'b1;
        err_port    <= head_port;      // err_addr not meaningful: untouched
        if (!head_bkp)
          port_stat_err[head_port[5:0]] <= port_stat_err[head_port[5:0]] + 32'd1;
      end
      // SLVERR on read or write channels (backdoor: port field = 8'hFF)
      if (pop_real && m_axi_rresp != 2'b00) begin
        err_slverr <= 1'b1;
        err_port   <= head_port;
        if (!head_bkp)
          port_stat_err[head_port[5:0]] <= port_stat_err[head_port[5:0]] + 32'd1;
      end
      if (m_axi_bvalid && m_axi_bresp != 2'b00) begin
        err_slverr <= 1'b1;
        err_port   <= wtrk_port[wtrk_rptr];
        if (wtrk_port[wtrk_rptr] != BKP_ID)
          port_stat_err[wtrk_port[wtrk_rptr][5:0]] <=
              port_stat_err[wtrk_port[wtrk_rptr][5:0]] + 32'd1;
      end
      // per-port error counter clear from CSR indexed window
      if (err_clr && err_clr_port < 8'(N_MAX))
        port_stat_err[err_clr_port[5:0]] <= 32'd0;
    end
  end

endmodule

`default_nettype wire
