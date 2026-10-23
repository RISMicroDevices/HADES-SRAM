//-----------------------------------------------------------------------------
// HADES-SRAM — on-chip self-test engine (spec 6.2), one per emulated port,
// present only when hades_sram_port is built with SELFTEST_EN=1.  Pure port_clk
// domain.  Acceptance aid for the VCU1525 builds: the host cannot observe 64
// ports at pin bandwidth, so each port generates and checks its own traffic
// and reports errors into PORT_STAT_ERR (toggle -> ui_clk edge detect ->
// hades_sram_mig_if per-port error counter).
//
// While running, the engine drives the port's request inputs (hades_sram_port
// muxes them over the integrator pins) in an endless loop of
//   WR:    BLK writes,  word i <- pat(i, pass)
//   RD:    BLK reads of the same words
//   DRAIN: idle until every expected release has been checked
// pat() is a xorshift mix of {address, pass, PORT_ID}: every port hammers a
// different sequence, and a dropped write reads back as the previous pass's
// (different) word.  Checks, evaluated at every port_clk edge:
//   phase: rvalid must equal exp_rvalid, a registered copy of the timing
//          shaper's own release condition fed by the same request stream
//   data:  on a release, rdata must equal pat() of the request issued
//          exactly L edges earlier
// Any violation flips err_tog once.  Violations on one port are >= 1 target
// period apart (one request per period), so no toggle event can be lost.
//
// The engine only advances while its requests are accepted (port_live): a
// port_clk stop or an enable drop freezes the cycle-accurate contract
// together with the clock — checks are in port_clk cycles, so stop/start is
// transparent (spec A10).  run is a ui_clk-domain level, synced here; a
// falling run mid-read drains the in-flight releases before idling.  IDLE is
// unchecked and a quiet timer waits out pre-selftest pin traffic before the
// engine takes the port.
//-----------------------------------------------------------------------------
`default_nettype none

module hades_sram_selftest #(
  parameter int AW      = 22,
  parameter int DW      = 32,
  parameter int PORT_ID = 0,
  parameter int BLK     = 256    // words written+read per pass
) (
  input  wire logic          port_clk,
  input  wire logic          port_rst,   // synchronous, active high
  input  wire logic          run,        // ui_clk-domain level (synced here)
  input  wire logic          port_live,  // cfg_en & enabled (quasi-static)
  input  wire logic [1:0]    lat,        // L (quasi-static)

  output      logic          active,     // engine is driving the port
  output      logic          req_en,
  output      logic          req_we,
  output      logic [AW-1:0] req_addr,
  output      logic [DW-1:0] req_wdata,

  input  wire logic          chk_rd_req, // read accepted at this edge (rd_req_p)
  input  wire logic          rvalid,
  input  wire logic [DW-1:0] rdata,

  output      logic          err_tog     // flips once per error event
);

  localparam int CW = (BLK > 1) ? $clog2(BLK) : 1;

  // phase decorrelation (2026-10-20 hardware finding): all engines start
  // their WR/RD phases in lockstep, so the 64 write bursts collide and the
  // backend's write path (RMV-paced on this RDIMM) overflows high-index
  // ports' request FIFOs.  Stagger the first pass by PORT_ID*BLK port
  // cycles at run start; phases then stay decorrelated by the drift.
  localparam int SDLY = PORT_ID * BLK;
  localparam int SCW  = (SDLY > 1) ? $clog2(SDLY) : 1;

  typedef enum logic [1:0] {ST_IDLE, ST_WR, ST_RD, ST_DRAIN} st_e;

  st_e           state;
  logic [CW-1:0] cnt;
  logic [SCW-1:0] start_dly;
  logic [7:0]    pass_r;
  logic [2:0]    quiet_cnt;
  logic          run_p;

  // shadow of the timing shaper's release pipeline + request history
  logic [1:0]    st_pipe;
  logic [AW-1:0] hist_addr [2];
  logic [7:0]    hist_pass [2];
  logic          exp_rvalid;
  logic [DW-1:0] exp_data;

  hades_sram_sync2 u_run_sync (.clk(port_clk), .rst(port_rst), .d(run), .q(run_p));

  // word pattern: xorshift32 mix of address, pass and port index
  function automatic logic [DW-1:0] st_pat(input logic [AW-1:0] a,
                                           input logic [7:0]    p);
    logic [31:0] x;
    logic [DW-1:0] r;
    x = 32'(a) ^ {8'hA5, p, 8'(PORT_ID), 8'h5A};
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    if (DW <= 32) begin
      r = DW'(x);
    end else begin
      r[31:0] = x;
      x = x ^ 32'h9E37_79B9;                    // decorrelate the upper word
      x ^= x << 13; x ^= x >> 17; x ^= x << 5;
      r[63:32] = x;
    end
    return r;
  endfunction

  // Requests are driven combinationally from state+counter and only issued
  // while the port would accept them (port_live); a stopped clock or a
  // dropped enable freezes issue and check alike — no false errors.
  assign active    = (state != ST_IDLE);
  assign req_en    = active & (state != ST_DRAIN) & port_live & run_p;
  assign req_we    = (state == ST_WR);
  assign req_addr  = AW'(cnt);
  assign req_wdata = st_pat(AW'(cnt), pass_r);

  // registered copy of the shaper's release condition (same inputs => the
  // exp_rvalid register must equal the rvalid register at every edge)
  wire logic rel_exp_w = (lat == 2'd1) ? st_pipe[0] : st_pipe[1];

  wire logic check_en = active;   // IDLE unchecked: pin traffic may be draining

  always_ff @(posedge port_clk) begin
    if (port_rst) begin
      state        <= ST_IDLE;
      cnt          <= '0;
      start_dly    <= SCW'(SDLY);
      pass_r       <= 8'd0;
      quiet_cnt    <= 3'd4;
      st_pipe      <= 2'b00;
      hist_addr[0] <= '0;
      hist_addr[1] <= '0;
      hist_pass[0] <= 8'd0;
      hist_pass[1] <= 8'd0;
      exp_rvalid   <= 1'b0;
      exp_data     <= '0;
      err_tog      <= 1'b0;
    end else begin
      // ---- shadow pipeline / request history (cleared while idle) ----
      if (state == ST_IDLE) begin
        st_pipe    <= 2'b00;
        exp_rvalid <= 1'b0;
      end else begin
        st_pipe      <= {st_pipe[0], chk_rd_req};
        hist_addr[0] <= req_addr;
        hist_pass[0] <= pass_r;
        hist_addr[1] <= hist_addr[0];
        hist_pass[1] <= hist_pass[0];
        exp_rvalid   <= rel_exp_w;
        if (rel_exp_w)
          exp_data <= st_pat((lat == 2'd1) ? hist_addr[0] : hist_addr[1],
                             (lat == 2'd1) ? hist_pass[0] : hist_pass[1]);
      end

      // ---- checks (at most one error event per edge) ----
      if (check_en && (rvalid !== exp_rvalid))
        err_tog <= ~err_tog;                                     // phase
      else if (check_en && exp_rvalid && rvalid && (rdata !== exp_data))
        err_tog <= ~err_tog;                                     // data

      // ---- stimulus FSM ----
      unique case (state)
        ST_IDLE: begin
          if (run_p && port_live && (start_dly != '0))
            start_dly <= start_dly - SCW'(1);
          if (rvalid)               quiet_cnt <= 3'd4;
          else if (quiet_cnt != 3'd0) quiet_cnt <= quiet_cnt - 3'd1;
          if (run_p && port_live && (quiet_cnt == 3'd0) && !rvalid
              && (start_dly == '0)) begin
            state  <= ST_WR;
            cnt    <= '0;
            pass_r <= pass_r + 8'd1;
          end
        end
        ST_WR: begin
          if (!run_p) begin
            state <= ST_IDLE;        // no reads in flight: stop immediately
          end else if (req_en) begin
            if (cnt == CW'(BLK - 1)) begin
              state <= ST_RD;
              cnt   <= '0;
            end else begin
              cnt <= cnt + CW'(1);
            end
          end
        end
        ST_RD: begin
          if (!run_p) begin
            state <= ST_DRAIN;       // let in-flight reads check out first
          end else if (req_en) begin
            if (cnt == CW'(BLK - 1)) begin
              state <= ST_DRAIN;
              cnt   <= '0;
            end else begin
              cnt <= cnt + CW'(1);
            end
          end
        end
        ST_DRAIN: begin
          if ((st_pipe == 2'b00) && !exp_rvalid) begin
            if (run_p && port_live) begin
              state  <= ST_WR;
              cnt    <= '0;
              pass_r <= pass_r + 8'd1;
            end else begin
              state <= ST_IDLE;
            end
          end
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
