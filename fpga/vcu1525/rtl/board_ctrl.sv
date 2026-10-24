//-----------------------------------------------------------------------------
// HADES-SRAM VCU1525 — board-support CSR (M5-hw).  AXI4-Lite slave on
// ui_clk, reached over JTAG-AXI (address 0x1_0000 on the board interconnect).
// Separate from the HADES IP CSR (address 0x0_0000): these registers control
// the BOARD's port_clk generator, not the emulated-SRAM core.
//
//   0x00 BOARD_ID        RO  32'hB0AD_0110
//   0x04 SCRATCH         RW  read/write loopback (JTAG-AXI path smoke test)
//   0x08 CLK_DIV         RW  src_clk cycles per port_clk period (pending)
//   0x0C CLK_CTRL        RW  bit0 GATE (1=run port_clk, 0=stop low);
//                            bit8 COMMIT (self-clearing strobe: apply CLK_DIV
//                            at the next counter wrap — write div, then commit)
//
// The divider/gate live in board_clk_gen on the SOURCE clock (ui_clk for
// SYNC builds, the PCIe refclk path for ASYNC); values cross with 2-flop
// syncs there.  CLK_DIV readback is the pending (ui_clk-side) value.
//-----------------------------------------------------------------------------
`default_nettype none

module board_ctrl (
  input  wire logic        ui_clk,
  input  wire logic        ui_rst,

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

  output      logic [15:0] clk_div,
  output      logic        clk_gate,
  output      logic        clk_commit   // toggles per commit strobe
);

  logic [31:0] scratch_q;
  logic        commit_tog;
  logic        aw_v, w_v;
  logic [15:0] aw_a, ar_a;
  logic [31:0] w_d;

  // port_clk divider power-on default: 600 for the 300 MHz SYNC source
  // (500 KHz); build.tcl defines BOARD_DIV_DEFAULT for the ASYNC sources
  // (200 for the 100 MHz MMCM2 path, 100 for the 50 MHz PCIe ODIV2 path)
`ifdef BOARD_DIV_DEFAULT
  localparam logic [15:0] DIV_RST = 16'(`BOARD_DIV_DEFAULT);
`else
  localparam logic [15:0] DIV_RST = 16'd600;
`endif

  assign s_axil_awready = ~aw_v & ~s_axil_bvalid;
  assign s_axil_wready  = ~w_v  & ~s_axil_bvalid;
  assign s_axil_bresp   = 2'b00;
  assign s_axil_arready = ~s_axil_rvalid;
  assign s_axil_rresp   = 2'b00;

  wire logic wr_fire = aw_v & w_v;

  always_ff @(posedge ui_clk) begin
    if (ui_rst) begin
      aw_v <= 1'b0; aw_a <= 16'd0;
      w_v  <= 1'b0; w_d  <= 32'd0;
      ar_a <= 16'd0;
      s_axil_bvalid <= 1'b0;
      s_axil_rvalid <= 1'b0;
      scratch_q     <= 32'd0;
      clk_div       <= 16'd600;
      clk_gate      <= 1'b1;
      commit_tog    <= 1'b0;
    end else begin
      if (s_axil_awvalid && s_axil_awready) begin aw_v <= 1'b1; aw_a <= s_axil_awaddr; end
      if (s_axil_wvalid  && s_axil_wready)  begin w_v  <= 1'b1; w_d  <= s_axil_wdata;  end
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

      if (wr_fire) begin
        case (aw_a)
          16'h0004: scratch_q <= w_d;
          16'h0008: clk_div   <= w_d[15:0];
          16'h000C: begin
            clk_gate <= w_d[0];
            if (w_d[8]) commit_tog <= ~commit_tog;
          end
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    case (ar_a)
      16'h0000:  s_axil_rdata = 32'hB0AD_0110;
      16'h0004:  s_axil_rdata = scratch_q;
      16'h0008:  s_axil_rdata = {16'd0, clk_div};
      16'h000C:  s_axil_rdata = {23'd0, 8'd0, clk_gate};
      default:   s_axil_rdata = 32'd0;
    endcase
  end

  assign clk_commit = commit_tog;

  logic unused;
  assign unused = &{1'b0, w_d[31:16], s_axil_wstrb, aw_a[1:0]};

endmodule

`default_nettype wire
