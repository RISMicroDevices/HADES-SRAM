//-----------------------------------------------------------------------------
// HADES-SRAM — backdoor channel (spec 3.3; ui_clk domain).  Lets the host
// initialize/verify the emulated SRAM contents without the target ports:
// a command (port, word address, optional wdata) is translated exactly like
// a port access (beat = port_base[port] + addr/lanes-per-beat, lane from the
// low address bits) and handed to hades_mig_if as the lowest-priority
// requester — it runs in the maintenance window and idle slots only, so
// in-flight target traffic is never delayed beyond the slot budget (T9).
//
// A command whose port >= N_MAX or address >= port_size[port] completes
// immediately with err=1 and no AXI traffic.  done is a 1-cycle strobe;
// rdata is valid with it.  Commands while busy are ignored (poll BKP_STATUS
// or wait for ack first).
//-----------------------------------------------------------------------------
`default_nettype none

module hades_backdoor
  import hades_pkg::*;
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
  input  wire logic [39:0] cmd_addr,    // DW-word address within the port
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

  typedef enum logic [1:0] {B_IDLE, B_RD, B_RD_WAIT, B_WR} state_e;
  state_e state;

  // legality (evaluated in the command cycle)
  wire logic port_ok = (cmd_port < 8'(N_MAX));
  wire logic addr_ok = port_ok &&
      (cmd_addr < {8'b0, cfg.port_size[cmd_port[5:0]]});

  wire logic [BASE_W-1:0] cmd_beat =
      cfg.port_base[cmd_port[5:0]] + BASE_W'(cmd_addr >> SH);
  wire logic [5:0]        cmd_lane = 6'(cmd_addr & 40'((1 << SH) - 1));

  assign busy = (state != B_IDLE);

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      state       <= B_IDLE;
      done        <= 1'b0;
      err         <= 1'b0;
      rdata       <= '0;
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
            err <= 1'b0;
            if (!addr_ok) begin
              done <= 1'b1;            // illegal: complete at once, no AXI
              err  <= 1'b1;
            end else if (cmd_wr) begin
              bkp_wr_req  <= 1'b1;
              bkp_wr_beat <= cmd_beat;
              bkp_wr_lane <= cmd_lane;
              bkp_wr_data <= cmd_wdata;
              state       <= B_WR;
            end else begin
              bkp_rd_req  <= 1'b1;
              bkp_rd_beat <= cmd_beat;
              bkp_rd_lane <= cmd_lane;
              state       <= B_RD;
            end
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
