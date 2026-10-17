//-----------------------------------------------------------------------------
// HADES-SRAM — AXI4-Lite CSR slave (spec 3.3), instantiated only when
// CSR_EN=1.  Port-level registers use the indexed window (PORT_SEL +
// PORT_BASE/PORT_SIZE/PORT_STAT_*) — no per-port flat address space.
// Single ui_clk domain (XDMA AXI-Lite clock is assumed ui_clk-synchronous;
// if an integrator uses a different BAR clock, add CDC — slow path only).
//
// Semantics:
//  - unimplemented bits read 0; writes to RO/undefined offsets are ignored
//  - power-on defaults are safe: ENABLE=0, all ports disabled
//  - CTRL.ENABLE write of 1 is rejected (stays 0, ERR_STATUS.bit4 set) unless
//    calib_done && clk_running && !over_freq
//  - while enabled, losing the clock/going over-freq drops the effective
//    enable and sets ERR_STATUS.bit4; it auto-recovers when the clock is
//    healthy again (spec A10a behavior) without software rewriting CTRL
//  - SOFT_RESET (CTRL.bit1) is a self-clearing strobe: clears ENABLE and
//    error/stat accumulation; configuration registers are retained
//  - CFG_LATENCY takes effect on the next ENABLE 0->1 transition only
//-----------------------------------------------------------------------------
`default_nettype none

module hades_csr
  import hades_pkg::*;
#(
  parameter bit IS_SYNC = 1'b1,   // 1: CLK_MODE SYNC, 0: ASYNC (PARAMS.bit31)
  parameter int DW            = DW_DEFAULT,
  parameter int UI_MHZ        = UI_CLK_MHZ,
  parameter int PORT_MB       = PORT_MB_DEFAULT
) (
  input  wire logic        ui_clk,
  input  wire logic        ui_rst,

  // AXI4-Lite slave
  input  wire logic [15:0] s_axil_awaddr,
  input  wire logic        s_axil_awvalid,
  output      logic        s_axil_awready,
  input  wire logic [31:0] s_axil_wdata,
  input  wire logic [3:0]  s_axil_wstrb,
  input  wire logic        s_axil_wvalid,
  output      logic        s_axil_wready,
  output      logic [1:0]  s_axil_bresp,
  output      logic        s_axil_bvalid,
  input  wire logic        s_axil_bready,
  input  wire logic [15:0] s_axil_araddr,
  input  wire logic        s_axil_arvalid,
  output      logic        s_axil_arready,
  output      logic [31:0] s_axil_rdata,
  output      logic [1:0]  s_axil_rresp,
  output      logic        s_axil_rvalid,
  input  wire logic        s_axil_rready,

  // status inputs
  input  wire logic        calib_done,
  input  wire logic        clk_running,
  input  wire logic        over_freq,
  input  wire logic [31:0] meas_period,
  input  wire logic        refresh_active,
  input  wire logic        zq_active,

  // datapath error/stat inputs.  err_in carries 1-cycle event pulses:
  // err_in[3:0] = spec ERR_STATUS bits 0..3 (illegal addr, timeout, drop,
  // SLVERR); err_in[4] = response-window sentinel (spec bit5).  bit4 is
  // generated internally.  Pulse sources make W1C clears stick (a level
  // source would re-set the bit until the origin is also cleared).
  input  wire logic [4:0]           err_in,
  input  wire logic [7:0]           err_in_port,
  input  wire logic [31:0]          err_in_addr,
  input  wire logic [31:0]          stat_maxlat,
  input  wire logic [31:0]          stat_refcnt,
  input  wire logic [63:0]          stat_tot_rd,
  input  wire logic [63:0]          stat_tot_wr,
  input  wire logic [N_MAX-1:0][31:0] port_stat_rd,
  input  wire logic [N_MAX-1:0][31:0] port_stat_wr,
  input  wire logic [N_MAX-1:0][31:0] port_stat_err,

  // config / control outputs
  output          cfg_t         cfg,
  output          logic         enable,         // effective, interlocked
  output          logic         soft_reset_stb,
  output          logic         port_err_clr,   // 1-cycle pulse, port = port_sel_o
  output          logic [7:0]   port_sel_o,

  // backdoor command channel (M4): registers here, engine in hades_backdoor
  output          logic         bkp_go_rd,      // 1-cycle strobes
  output          logic         bkp_go_wr,
  output          logic [7:0]   bkp_port_o,
  output          logic [39:0]  bkp_addr_o,
  output          logic [31:0]  bkp_wdata_o,
  input  wire logic             bkp_busy,
  input  wire logic             bkp_done,       // 1-cycle strobe from engine
  input  wire logic             bkp_err,
  input  wire logic [31:0]      bkp_rdata_i
);

  localparam logic [1:0] AXI_RESP_OKAY = 2'b00;

  // ------------------------------------------------------------------
  // Register file
  // ------------------------------------------------------------------
  logic                          enable_req;
  logic [1:0]                    cfg_latency;     // shadow
  logic [1:0]                    latency_active;  // applied at ENABLE 0->1
  logic [7:0]                    cfg_ports;
  logic [31:0]                   min_period;
  logic [N_MAX-1:0]              port_en;
  logic [7:0]                    port_sel;
  logic [N_MAX-1:0][BASE_W-1:0]  port_base_q;
  logic [N_MAX-1:0][31:0]        port_size_q;
  logic [31:0]                   refresh_div;
  logic [31:0]                   zq_div;
  logic [5:0]                    err_status;      // bits 0..5
  logic [7:0]                    err_port;        // first-error port
  logic [31:0]                   err_addr_q;      // first-error address
  logic [7:0]                    bkp_port_q;
  logic [39:0]                   bkp_addr_q;
  logic [31:0]                   bkp_wdata_q;
  logic                          bkp_done_stky;   // set by engine, cleared by new cmd

  wire logic freq_ok  = clk_running & ~over_freq;
  wire logic allow_en = calib_done & freq_ok;

  // ------------------------------------------------------------------
  // AXI4-Lite write channel
  // ------------------------------------------------------------------
  logic        aw_v;
  logic [15:0] aw_a;
  logic        w_v;
  logic [31:0] w_d;
  logic [3:0]  w_s;
  logic [15:0] ar_a;

  assign s_axil_awready = ~aw_v & ~s_axil_bvalid;
  assign s_axil_wready  = ~w_v  & ~s_axil_bvalid;
  assign s_axil_bresp   = AXI_RESP_OKAY;

  wire logic wr_fire = aw_v & w_v;

  // ------------------------------------------------------------------
  // AXI4-Lite read channel (address latched, data stable while rvalid)
  // ------------------------------------------------------------------
  assign s_axil_arready = ~s_axil_rvalid;
  assign s_axil_rresp   = AXI_RESP_OKAY;

  wire logic sel_ok = (port_sel < 8'(N_MAX));

  always_comb begin : b_rd_mux
    s_axil_rdata = 32'd0;
    case (ar_a)
      CSR_CTRL:            s_axil_rdata = {30'd0, 1'b0, enable_req};
      CSR_STATUS:          s_axil_rdata = {28'd0, zq_active, refresh_active,
                                           enable, calib_done};
      CSR_CFG_LATENCY:     s_axil_rdata = {24'd0, 6'd0, cfg_latency};
      CSR_CFG_PORTS:       s_axil_rdata = {24'd0, cfg_ports};
      CSR_MEAS_PERIOD:     s_axil_rdata = meas_period;
      CSR_PORT_EN_LO:      s_axil_rdata = port_en[31:0];
      CSR_PORT_EN_HI:      s_axil_rdata = port_en[N_MAX-1:32];
      CSR_CFG_MIN_PERIOD:  s_axil_rdata = min_period;
      CSR_PORT_SEL:        s_axil_rdata = {24'd0, port_sel};
      CSR_PORT_BASE:       s_axil_rdata = sel_ok ? port_base_q[port_sel][31:0]  : 32'd0;
      CSR_PORT_BASE_HI:    s_axil_rdata = sel_ok ? {30'd0, port_base_q[port_sel][BASE_W-1:32]}
                                                 : 32'd0;
      CSR_PORT_SIZE:       s_axil_rdata = sel_ok ? port_size_q[port_sel]        : 32'd0;
      CSR_PORT_STAT_RD:    s_axil_rdata = sel_ok ? port_stat_rd[port_sel]       : 32'd0;
      CSR_PORT_STAT_WR:    s_axil_rdata = sel_ok ? port_stat_wr[port_sel]       : 32'd0;
      CSR_PORT_STAT_ERR:   s_axil_rdata = sel_ok ? port_stat_err[port_sel]      : 32'd0;
      CSR_CFG_REFRESH_DIV: s_axil_rdata = refresh_div;
      CSR_CFG_ZQ_DIV:      s_axil_rdata = zq_div;
      CSR_ERR_STATUS:      s_axil_rdata = {16'd0, err_port, 2'b00, err_status};
      CSR_ERR_ADDR:        s_axil_rdata = err_addr_q;
      CSR_STAT_MAXLAT:     s_axil_rdata = stat_maxlat;
      CSR_STAT_REFCNT:     s_axil_rdata = stat_refcnt;
      CSR_STAT_TOT_RD_LO:  s_axil_rdata = stat_tot_rd[31:0];
      CSR_STAT_TOT_WR_LO:  s_axil_rdata = stat_tot_wr[31:0];
      CSR_STAT_TOT_RD_HI:  s_axil_rdata = stat_tot_rd[63:32];
      CSR_STAT_TOT_WR_HI:  s_axil_rdata = stat_tot_wr[63:32];
      CSR_ID:              s_axil_rdata = ID_MAGIC;
      CSR_PARAMS:          s_axil_rdata = params_word(
                               IS_SYNC ? CLK_MODE_SYNC : CLK_MODE_ASYNC,
                               UI_MHZ, PORT_MB, DW);
      CSR_BKP_PORT:        s_axil_rdata = {24'd0, bkp_port_q};
      CSR_BKP_ADDR:        s_axil_rdata = bkp_addr_q[31:0];
      CSR_BKP_ADDR_HI:     s_axil_rdata = {24'd0, bkp_addr_q[39:32]};
      CSR_BKP_WDATA:       s_axil_rdata = bkp_wdata_q;
      CSR_BKP_CMD:         s_axil_rdata = 32'd0;
      CSR_BKP_RDATA:       s_axil_rdata = bkp_rdata_i;
      CSR_BKP_STATUS:      s_axil_rdata = {29'd0, bkp_err, bkp_done_stky, bkp_busy};
      default:             s_axil_rdata = 32'd0;
    endcase
  end

  // ------------------------------------------------------------------
  // Sequential logic
  // ------------------------------------------------------------------
  integer i;

  always_ff @(posedge ui_clk) begin : p_csr
    logic [N_MAX*BASE_W-1:0] fb;
    if (ui_rst) begin
      aw_v <= 1'b0;            aw_a <= 16'd0;
      ar_a <= 16'd0;
      w_v  <= 1'b0;            w_d  <= 32'd0;  w_s <= 4'd0;
      s_axil_bvalid <= 1'b0;
      s_axil_rvalid <= 1'b0;
      enable_req      <= 1'b0;
      cfg_latency     <= 2'd2;               // safe default L=2
      latency_active  <= 2'd2;
      cfg_ports       <= 8'd0;
      min_period      <= 32'(TARGET_PERIOD_500K);
      port_en         <= '0;                 // all ports disabled (safe)
      port_sel        <= 8'd0;
      refresh_div     <= 32'd2100;           // 7 us @ 300 MHz
      zq_div          <= 32'd32000;          // 64 ms @ 500 KHz target periods
      err_status      <= 6'd0;
      err_port        <= 8'd0;
      err_addr_q      <= 32'd0;
      soft_reset_stb  <= 1'b0;
      port_err_clr    <= 1'b0;
      bkp_go_rd       <= 1'b0;
      bkp_go_wr       <= 1'b0;
      bkp_port_q      <= 8'd0;
      bkp_addr_q      <= 40'd0;
      bkp_wdata_q     <= 32'd0;
      bkp_done_stky   <= 1'b0;
      fb = dflt_base_flat();
      for (i = 0; i < N_MAX; i = i + 1) begin
        port_base_q[i] <= fb[i*BASE_W +: BASE_W];
        port_size_q[i] <= 32'((64'(PORT_MB) * 1024 * 1024) / (DW / 8));  // DW-bit words
      end
    end else begin
      // ---- bus capture ----
      if (s_axil_awvalid && s_axil_awready) begin
        aw_v <= 1'b1; aw_a <= s_axil_awaddr;
      end
      if (s_axil_wvalid && s_axil_wready) begin
        w_v <= 1'b1; w_d <= s_axil_wdata; w_s <= s_axil_wstrb;
      end
      if (wr_fire) begin
        aw_v <= 1'b0; w_v <= 1'b0;
        s_axil_bvalid <= 1'b1;
      end else if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end

      if (s_axil_arvalid && s_axil_arready) begin
        s_axil_rvalid <= 1'b1;
        ar_a          <= s_axil_araddr;
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end

      // ---- pulses default low ----
      soft_reset_stb <= 1'b0;
      port_err_clr   <= 1'b0;
      bkp_go_rd      <= 1'b0;
      bkp_go_wr      <= 1'b0;

      // engine completion latches into a pollable flag; a new command clears it
      if (bkp_done) bkp_done_stky <= 1'b1;

      // ---- register writes ----
      if (wr_fire) begin
        case (aw_a)
          CSR_CTRL: begin
            if (w_s[0]) begin
              if (w_d[0]) begin                 // ENABLE request
                if (allow_en) begin
                  if (!enable_req) latency_active <= cfg_latency;
                  enable_req <= 1'b1;
                end else begin
                  enable_req      <= 1'b0;      // rejected
                  err_status[4]   <= 1'b1;
                end
              end else begin
                enable_req <= 1'b0;
              end
              if (w_d[1]) begin                 // SOFT_RESET
                soft_reset_stb <= 1'b1;
                enable_req     <= 1'b0;
                err_status     <= 6'd0;
                err_port       <= 8'd0;
                err_addr_q     <= 32'd0;
              end
            end
          end
          CSR_CFG_LATENCY: if (w_s[0]) begin
            if (w_d[1:0] == 2'd1 || w_d[1:0] == 2'd2)
              cfg_latency <= w_d[1:0];          // illegal values ignored
          end
          CSR_CFG_PORTS:       if (w_s[0]) cfg_ports <= w_d[7:0];
          CSR_CFG_MIN_PERIOD:  min_period  <= apply_wstrb32(min_period, w_d, w_s);
          CSR_PORT_EN_LO:      port_en[31:0]        <= apply_wstrb32(port_en[31:0], w_d, w_s);
          CSR_PORT_EN_HI:      port_en[N_MAX-1:32]  <= apply_wstrb32(port_en[N_MAX-1:32], w_d, w_s);
          CSR_PORT_SEL:        if (w_s[0]) port_sel <= w_d[7:0];
          CSR_PORT_BASE:       if (sel_ok)
              port_base_q[port_sel][31:0] <= apply_wstrb32(port_base_q[port_sel][31:0], w_d, w_s);
          CSR_PORT_BASE_HI:    if (sel_ok && w_s[0])
              port_base_q[port_sel][BASE_W-1:32] <= w_d[BASE_W-33:0];
          CSR_PORT_SIZE:       if (sel_ok)
              port_size_q[port_sel] <= apply_wstrb32(port_size_q[port_sel], w_d, w_s);
          CSR_PORT_STAT_ERR:   port_err_clr <= 1'b1;   // W1C: clear selected port
          CSR_CFG_REFRESH_DIV: refresh_div <= apply_wstrb32(refresh_div, w_d, w_s);
          CSR_CFG_ZQ_DIV:      zq_div      <= apply_wstrb32(zq_div, w_d, w_s);
          CSR_ERR_STATUS: if (w_s[0]) begin            // W1C bits 0..5
            if ((err_status & ~w_d[5:0]) == 6'd0) begin
              err_status <= 6'd0;                      // all clear: drop info
              err_port   <= 8'd0;
              err_addr_q <= 32'd0;
            end else begin
              err_status <= err_status & ~w_d[5:0];
            end
          end
          CSR_BKP_PORT:    if (w_s[0]) bkp_port_q <= w_d[7:0];
          CSR_BKP_ADDR:    bkp_addr_q[31:0]  <= apply_wstrb32(bkp_addr_q[31:0], w_d, w_s);
          CSR_BKP_ADDR_HI: if (w_s[0]) bkp_addr_q[39:32] <= w_d[7:0];
          CSR_BKP_WDATA:   bkp_wdata_q <= apply_wstrb32(bkp_wdata_q, w_d, w_s);
          CSR_BKP_CMD:     if (w_s[0]) begin
            bkp_go_wr     <= w_d[0];
            bkp_go_rd     <= w_d[1];
            bkp_done_stky <= 1'b0;
          end
          default: ;                                     // illegal writes ignored
        endcase
      end

      // ---- hardware-set error bits (set wins over W1C) ----
      if (|err_in) begin
        if (err_status[5:0] == 6'd0) begin             // first error: latch info
          err_port   <= err_in_port;
          err_addr_q <= err_in_addr;
        end
        err_status[3:0] <= err_status[3:0] | err_in[3:0];
        err_status[5]   <= err_status[5]   | err_in[4];
      end

      // ---- runtime enable interlock (clock lost / over-freq while armed) ----
      if (enable_req && !allow_en)
        err_status[4] <= 1'b1;
    end
  end

  // byte-enable merge helper
  function automatic logic [31:0] apply_wstrb32(input logic [31:0] old_v,
                                                input logic [31:0] new_v,
                                                input logic [3:0]  strb);
    logic [31:0] r;
    for (int b = 0; b < 4; b++)
      r[b*8 +: 8] = strb[b] ? new_v[b*8 +: 8] : old_v[b*8 +: 8];
    return r;
  endfunction

  // ------------------------------------------------------------------
  // Outputs
  // ------------------------------------------------------------------
  assign enable = enable_req & allow_en;

  always_comb begin
    cfg.latency      = latency_active;
    cfg.port_en      = port_en;
    cfg.active_ports = cfg_ports;
    cfg.min_period   = min_period;
    cfg.refresh_div  = refresh_div;
    cfg.zq_div       = zq_div;
    cfg.port_base    = port_base_q;
    cfg.port_size    = port_size_q;
  end

  assign port_sel_o = port_sel;

  assign bkp_port_o  = bkp_port_q;
  assign bkp_addr_o  = bkp_addr_q;
  assign bkp_wdata_o = bkp_wdata_q;

endmodule

`default_nettype wire
