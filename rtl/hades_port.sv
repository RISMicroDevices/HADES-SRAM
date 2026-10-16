//-----------------------------------------------------------------------------
// HADES-SRAM — one emulated SRAM port (spec 3.1).
// M1 skeleton: final port list, port_clk-domain request capture registers,
// datapath empty (rdata/rvalid held inactive).  The CLK_MODE-parameterized
// CDC structure, write buffer (depth >= 2) and the port_clk-domain timing
// shaper land in M2/M3.
//-----------------------------------------------------------------------------
`default_nettype none

module hades_port
  import hades_pkg::*;
#(
  parameter int AW      = AW_DEFAULT,
  parameter int DW      = DW_DEFAULT,
  parameter bit IS_SYNC = 1'b1
) (
  // ---- target domain (port_clk) ----
  input  wire logic           port_clk,
  input  wire logic           port_rst,   // synchronous, active high
  input  wire logic           en,
  input  wire logic           we,         // 1=write, 0=read
  input  wire logic [AW-1:0]  addr,       // word address
  input  wire logic [DW-1:0]  wdata,
  output          logic [DW-1:0] rdata,
  output          logic          rvalid,

  // ---- host domain (ui_clk), to arbiter / hades_mig_if ----
  input  wire logic           ui_clk,
  input  wire logic           ui_rst,
  output          logic       req_valid,
  output          logic       req_we,
  output          logic [AW-1:0]  req_addr,
  output          logic [DW-1:0]  req_wdata,
  input  wire logic           req_gnt,
  input  wire logic           rsp_valid,
  input  wire logic [DW-1:0]  rsp_data
);

  // port_clk-domain request capture (M1: registers exist, not yet consumed)
  logic           en_q;
  logic           we_q;
  logic [AW-1:0]  addr_q;
  logic [DW-1:0]  wdata_q;

  always_ff @(posedge port_clk) begin
    if (port_rst) begin
      en_q    <= 1'b0;
      we_q    <= 1'b0;
      addr_q  <= '0;
      wdata_q <= '0;
    end else begin
      en_q    <= en;
      we_q    <= we;
      addr_q  <= addr;
      wdata_q <= wdata;
    end
  end

  // empty datapath (spec M1): never responds
  assign rdata     = '0;
  assign rvalid    = 1'b0;
  assign req_valid = 1'b0;
  assign req_we    = 1'b0;
  assign req_addr  = '0;
  assign req_wdata = '0;

  // M1: consume not-yet-used inputs so lint stays quiet
  logic unused;
  assign unused = &{1'b0, en_q, we_q, addr_q, wdata_q,
                    req_gnt, rsp_valid, rsp_data, ui_clk, ui_rst};

endmodule

`default_nettype wire
