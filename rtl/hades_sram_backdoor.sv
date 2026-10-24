//-----------------------------------------------------------------------------
// HADES-SRAM — backdoor channel (spec 3.3; ui_clk domain).  Lets the host
// initialize/verify the emulated SRAM contents without the target ports.
// Commands address 32-bit lanes within the selected port: beat = base +
// offset/16 and lane = offset%16.  This matches frontend addresses at W=32;
// other widths require the lane-group mapping in INTEGRATION_GUIDE.md rather
// than interpreting the offset as a W-bit port-word address.  Requests enter
// hades_sram_mig_if at the lowest priority, only in maintenance windows and
// idle slots, so in-flight target traffic is never delayed beyond the budget.
//
// A command whose port >= N_MAX or address >= port_size[port] completes
// immediately with err=1 and no AXI traffic.  done is a 1-cycle strobe;
// rdata is valid with it.  Commands while busy are ignored (poll BKP_STATUS
// or wait for ack first).
//-----------------------------------------------------------------------------
`default_nettype none

module hades_sram_backdoor
  import hades_sram_pkg::*;
#(
  parameter int DW = DW_DEFAULT,
  parameter int AW = AW_DEFAULT
) (
  input  wire logic        ui_clk,
  input  wire logic        ui_rst,
  input  wire cfg_t        cfg,

  // command strobe interface (ui_clk domain; CSR registers or static pins,
  // muxed by the parent)
  input  wire logic        cmd_rd,      // 1-cycle strobe
  input  wire logic        cmd_wr,      // 1-cycle strobe
  input  wire logic [7:0]  cmd_port,
  input  wire logic [39:0] cmd_addr,    // 32-bit lane offset within the port
  input  wire logic [DW-1:0] cmd_wdata,
  output      logic        busy,
  output      logic        done,        // 1-cycle strobe
  output      logic        err,         // sticky until the next command
  output      logic [DW-1:0] rdata,

  // mig_if requester (lowest priority)
  output      logic               bkp_rd_req,
  output      logic [BASE_W-1:0]  bkp_rd_beat,
  output      logic [5:0]         bkp_rd_lane,
  input  wire logic               bkp_rd_gnt,
  input  wire logic               bkp_rd_done,
  input  wire logic [DW-1:0]      bkp_rd_data,
  output      logic               bkp_wr_req,
  output      logic [BASE_W-1:0]  bkp_wr_beat,
  output      logic [5:0]         bkp_wr_lane,
  output      logic [DW-1:0]      bkp_wr_data,
  input  wire logic               bkp_wr_gnt
);

  localparam int SH = dw_shift(DW);   // addr bits selecting a lane in a beat

  typedef enum logic [2:0] {B_IDLE, B_RD, B_RD_WAIT, B_WR, B_ACCEPT} state_e;
  state_e state;

  // command-cycle snapshot: the command fields and the two config words this
  // command needs are latched on the strobe, so the legality compare and the
  // beat/lane translate run one cycle later on registered values (the 64:1
  // cfg mux -> compare -> request-gating cone does not close at 300 MHz).
  logic                  cmd_wr_q;
  logic                  port_ok_q;
  logic [39:0]           cmd_addr_q;
  logic [DW-1:0]         cmd_wdata_q;
  logic [31:0]           size_sel_q;
  logic [BASE_W-1:0]     base_sel_q;

  wire logic port_ok = (cmd_port < 8'(N_MAX));

  // legality + translate (evaluated in B_ACCEPT on the snapshot)
  wire logic addr_ok = port_ok_q && (cmd_addr_q < {8'b0, size_sel_q});
  wire logic [BASE_W-1:0] cmd_beat = base_sel_q + BASE_W'(cmd_addr_q >> SH);
  wire logic [5:0]        cmd_lane = 6'(cmd_addr_q & 40'((1 << SH) - 1));

  assign busy = (state != B_IDLE);

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      state       <= B_IDLE;
      done        <= 1'b0;
      err         <= 1'b0;
      rdata       <= '0;
      cmd_wr_q    <= 1'b0;
      port_ok_q   <= 1'b0;
      cmd_addr_q  <= '0;
      cmd_wdata_q <= '0;
      size_sel_q  <= '0;
      base_sel_q  <= '0;
      bkp_rd_req  <= 1'b0;
      bkp_rd_beat <= '0;
      bkp_rd_lane <= 6'd0;
      bkp_wr_req  <= 1'b0;
      bkp_wr_beat <= '0;
      bkp_wr_lane <= 6'd0;
      bkp_wr_data <= '0;
    end else begin
      done <= 1'b0;
      unique case (state)
        B_IDLE: begin
          if (cmd_rd || cmd_wr) begin
            err        <= 1'b0;
            cmd_wr_q   <= cmd_wr;
            port_ok_q  <= port_ok;
            cmd_addr_q <= cmd_addr;
            cmd_wdata_q<= cmd_wdata;
            size_sel_q <= cfg.port_size[cmd_port[5:0]];
            base_sel_q <= cfg.port_base[cmd_port[5:0]];
            state      <= B_ACCEPT;
          end
        end
        B_ACCEPT: begin
          if (!addr_ok) begin
            done  <= 1'b1;             // illegal: complete at once, no AXI
            err   <= 1'b1;
            state <= B_IDLE;
          end else if (cmd_wr_q) begin
            bkp_wr_req  <= 1'b1;
            bkp_wr_beat <= cmd_beat;
            bkp_wr_lane <= cmd_lane;
            bkp_wr_data <= cmd_wdata_q;
            state       <= B_WR;
          end else begin
            bkp_rd_req  <= 1'b1;
            bkp_rd_beat <= cmd_beat;
            bkp_rd_lane <= cmd_lane;
            state       <= B_RD;
          end
        end
        B_WR: begin
          if (bkp_wr_gnt) begin        // posted: accepted by the backend
            bkp_wr_req <= 1'b0;
            done       <= 1'b1;
            state      <= B_IDLE;
          end
        end
        B_RD: begin
          if (bkp_rd_gnt) begin
            bkp_rd_req <= 1'b0;
            state      <= B_RD_WAIT;
          end
        end
        B_RD_WAIT: begin
          if (bkp_rd_done) begin
            rdata <= bkp_rd_data;
            done  <= 1'b1;
            state <= B_IDLE;
          end
        end
        // no default: unique-case violation in sim flags X/corruption
      endcase
    end
  end

  // the unused cfg fields belong to the ports/scheduler, not the backdoor
  logic unused;
  assign unused = &{1'b0, cfg.active_ports, cfg.latency, cfg.min_period,
                    cfg.refresh_div, cfg.zq_div, cfg.port_en};

endmodule

`default_nettype wire
