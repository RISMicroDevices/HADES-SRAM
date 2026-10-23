//-----------------------------------------------------------------------------
// HADES-SRAM VCU1525 — minimal AXI4-Lite 1->2 crossbar (M5-hw), ui_clk.
// The JTAG-AXI master is single-outstanding in both directions
// (RD/WR_TXN_QUEUE_LENGTH=1), so one transaction per direction is tracked.
// Decode: address bit 16 — 0x0000_0000..0x0000_FFFF -> M0 (HADES IP CSR),
// 0x0001_0000 -> M1 (board_ctrl).  AW/W may arrive in either order: a W that
// shows up before its AW is stalled until the AW decodes.  Slaves see plain
// AXI4-Lite with addresses' low 16 bits.
//-----------------------------------------------------------------------------
`default_nettype none

module board_axil_xbar (
  input  wire logic        ui_clk,
  input  wire logic        ui_rst,

  input  wire logic [31:0] s_axil_awaddr,
  input  wire logic        s_axil_awvalid,
  output      logic        s_axil_awready,
  input  wire logic [31:0] s_axil_wdata,
  input  wire logic [3:0]  s_axil_wstrb,
  input  wire logic        s_axil_wvalid,
  output      logic        s_axil_wready,
  output      logic [1:0]  s_axil_bresp,
  output      logic        s_axil_bvalid,
  input  wire logic        s_axil_bready,
  input  wire logic [31:0] s_axil_araddr,
  input  wire logic        s_axil_arvalid,
  output      logic        s_axil_arready,
  output      logic [31:0] s_axil_rdata,
  output      logic [1:0]  s_axil_rresp,
  output      logic        s_axil_rvalid,
  input  wire logic        s_axil_rready,

  output      logic [15:0] m0_axil_awaddr,
  output      logic        m0_axil_awvalid,
  input  wire logic        m0_axil_awready,
  output      logic [31:0] m0_axil_wdata,
  output      logic [3:0]  m0_axil_wstrb,
  output      logic        m0_axil_wvalid,
  input  wire logic        m0_axil_wready,
  input  wire logic [1:0]  m0_axil_bresp,
  input  wire logic        m0_axil_bvalid,
  output      logic        m0_axil_bready,
  output      logic [15:0] m0_axil_araddr,
  output      logic        m0_axil_arvalid,
  input  wire logic        m0_axil_arready,
  input  wire logic [31:0] m0_axil_rdata,
  input  wire logic [1:0]  m0_axil_rresp,
  input  wire logic        m0_axil_rvalid,
  output      logic        m0_axil_rready,

  output      logic [15:0] m1_axil_awaddr,
  output      logic        m1_axil_awvalid,
  input  wire logic        m1_axil_awready,
  output      logic [31:0] m1_axil_wdata,
  output      logic [3:0]  m1_axil_wstrb,
  output      logic        m1_axil_wvalid,
  input  wire logic        m1_axil_wready,
  input  wire logic [1:0]  m1_axil_bresp,
  input  wire logic        m1_axil_bvalid,
  output      logic        m1_axil_bready,
  output      logic [15:0] m1_axil_araddr,
  output      logic        m1_axil_arvalid,
  input  wire logic        m1_axil_arready,
  input  wire logic [31:0] m1_axil_rdata,
  input  wire logic [1:0]  m1_axil_rresp,
  input  wire logic        m1_axil_rvalid,
  output      logic        m1_axil_rready
);

  // ------------------------------------------------------------------
  // write direction
  // ------------------------------------------------------------------
  logic wr_dst;        // latched target of the in-flight write (0=M0, 1=M1)
  logic wr_busy;       // AW accepted, B not yet completed

  wire logic aw_sel1   = s_axil_awaddr[16];
  wire logic aw_to_m1  = wr_busy ? wr_dst : aw_sel1;

  assign s_axil_awready = aw_sel1 ? m1_axil_awready : m0_axil_awready;
  assign m0_axil_awvalid = s_axil_awvalid & ~aw_sel1;
  assign m1_axil_awvalid = s_axil_awvalid &  aw_sel1;
  assign m0_axil_awaddr  = s_axil_awaddr[15:0];
  assign m1_axil_awaddr  = s_axil_awaddr[15:0];

  // W channel: route by the latched destination once AW is accepted; if AW
  // is being presented this cycle use its decode; otherwise stall
  wire logic w_known = wr_busy | s_axil_awvalid;
  assign m0_axil_wvalid  = s_axil_wvalid & w_known & ~aw_to_m1;
  assign m1_axil_wvalid  = s_axil_wvalid & w_known &  aw_to_m1;
  assign s_axil_wready   = w_known & (aw_to_m1 ? m1_axil_wready : m0_axil_wready);
  assign m0_axil_wdata   = s_axil_wdata;
  assign m1_axil_wdata   = s_axil_wdata;
  assign m0_axil_wstrb   = s_axil_wstrb;
  assign m1_axil_wstrb   = s_axil_wstrb;

  assign s_axil_bvalid   = wr_dst ? m1_axil_bvalid : m0_axil_bvalid;
  assign s_axil_bresp    = wr_dst ? m1_axil_bresp  : m0_axil_bresp;
  assign m0_axil_bready  = s_axil_bready & ~wr_dst;
  assign m1_axil_bready  = s_axil_bready &  wr_dst;

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      wr_dst  <= 1'b0;
      wr_busy <= 1'b0;
    end else begin
      if (s_axil_awvalid && s_axil_awready) begin
        wr_dst  <= aw_sel1;
        wr_busy <= 1'b1;
      end
      if (s_axil_bvalid && s_axil_bready)
        wr_busy <= 1'b0;
    end
  end

  // ------------------------------------------------------------------
  // read direction
  // ------------------------------------------------------------------
  logic rd_dst;
  logic rd_busy;

  wire logic ar_sel1 = s_axil_araddr[16];

  assign s_axil_arready  = ar_sel1 ? m1_axil_arready : m0_axil_arready;
  assign m0_axil_arvalid = s_axil_arvalid & ~ar_sel1;
  assign m1_axil_arvalid = s_axil_arvalid &  ar_sel1;
  assign m0_axil_araddr  = s_axil_araddr[15:0];
  assign m1_axil_araddr  = s_axil_araddr[15:0];

  assign s_axil_rvalid   = rd_dst ? m1_axil_rvalid : m0_axil_rvalid;
  assign s_axil_rdata    = rd_dst ? m1_axil_rdata  : m0_axil_rdata;
  assign s_axil_rresp    = rd_dst ? m1_axil_rresp  : m0_axil_rresp;
  assign m0_axil_rready  = s_axil_rready & ~rd_dst;
  assign m1_axil_rready  = s_axil_rready &  rd_dst;

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      rd_dst  <= 1'b0;
      rd_busy <= 1'b0;
    end else begin
      if (s_axil_arvalid && s_axil_arready) begin
        rd_dst  <= ar_sel1;
        rd_busy <= 1'b1;
      end
      if (s_axil_rvalid && s_axil_rready)
        rd_busy <= 1'b0;
    end
  end

  logic unused;
  assign unused = &{1'b0, rd_busy, s_axil_awaddr[31:17], s_axil_araddr[31:17]};

endmodule

`default_nettype wire
