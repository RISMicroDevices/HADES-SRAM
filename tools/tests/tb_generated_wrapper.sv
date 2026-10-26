`timescale 1ns/1ps
`default_nettype none

interface axi4_if;
  logic [3:0] awid;
  logic [39:0] awaddr;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst;
  logic awvalid, awready;
  logic [511:0] wdata;
  logic [63:0] wstrb;
  logic wlast, wvalid, wready;
  logic [3:0] bid;
  logic [1:0] bresp;
  logic bvalid, bready;
  logic [3:0] arid;
  logic [39:0] araddr;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [1:0] arburst;
  logic arvalid, arready;
  logic [3:0] rid;
  logic [511:0] rdata;
  logic [1:0] rresp;
  logic rlast, rvalid, rready;
endinterface

module tb_generated_wrapper;
  logic ui_clk = 1'b0;
  logic port_clk = 1'b0;
  always #(1.6666667) ui_clk = ~ui_clk;
  always #1000 port_clk = ~port_clk;

  logic ui_rst_n = 1'b0;
  logic port_rst_n = 1'b0;
  logic calib_done = 1'b0;
  logic sram0_en = 1'b0;
  logic sram0_we = 1'b0;
  logic [21:0] sram0_addr = '0;
  logic [39:0] sram0_wdata = '0;
  logic [63:0] sram0_be = '0;
  logic [39:0] sram0_rdata;
  logic sram0_rvalid;
  logic stat_calib_done, stat_ready, stat_refresh_active, stat_zq_active;
  logic [7:0] stat_err;
  logic [31:0] bkp_rdata;
  logic bkp_ack;
  logic app_ref_req, app_ref_ack, app_zq_req, app_zq_ack;
  axi4_if axi();

  `GENERATED_MODULE u_generated (
    .ui_clk(ui_clk), .ui_rst_n(ui_rst_n),
    .port_clk(port_clk), .port_rst_n(port_rst_n), .calib_done(calib_done),
    .sram0_en(sram0_en), .sram0_we(sram0_we), .sram0_addr(sram0_addr),
    .sram0_wdata(sram0_wdata), .sram0_be(sram0_be),
    .sram0_rdata(sram0_rdata), .sram0_rvalid(sram0_rvalid),
    .m_axi_awid(axi.awid), .m_axi_awaddr(axi.awaddr), .m_axi_awlen(axi.awlen),
    .m_axi_awsize(axi.awsize), .m_axi_awburst(axi.awburst),
    .m_axi_awvalid(axi.awvalid), .m_axi_awready(axi.awready),
    .m_axi_wdata(axi.wdata), .m_axi_wstrb(axi.wstrb), .m_axi_wlast(axi.wlast),
    .m_axi_wvalid(axi.wvalid), .m_axi_wready(axi.wready),
    .m_axi_bid(axi.bid), .m_axi_bresp(axi.bresp), .m_axi_bvalid(axi.bvalid),
    .m_axi_bready(axi.bready), .m_axi_arid(axi.arid), .m_axi_araddr(axi.araddr),
    .m_axi_arlen(axi.arlen), .m_axi_arsize(axi.arsize), .m_axi_arburst(axi.arburst),
    .m_axi_arvalid(axi.arvalid), .m_axi_arready(axi.arready),
    .m_axi_rid(axi.rid), .m_axi_rdata(axi.rdata), .m_axi_rresp(axi.rresp),
    .m_axi_rlast(axi.rlast), .m_axi_rvalid(axi.rvalid), .m_axi_rready(axi.rready),
    .app_ref_req(app_ref_req), .app_ref_ack(app_ref_ack),
    .app_zq_req(app_zq_req), .app_zq_ack(app_zq_ack),
    .stat_calib_done(stat_calib_done), .stat_ready(stat_ready),
    .stat_refresh_active(stat_refresh_active), .stat_zq_active(stat_zq_active),
    .stat_err(stat_err), .bkp_req(1'b0), .bkp_we(1'b0), .bkp_port(8'd0),
    .bkp_addr(34'd0), .bkp_wdata(32'd0), .bkp_rdata(bkp_rdata), .bkp_ack(bkp_ack)
  );

  mig_axi4_model u_mig (
    .aclk(ui_clk), .arst(~ui_rst_n),
    .s_axi_awid(axi.awid), .s_axi_awaddr(axi.awaddr), .s_axi_awlen(axi.awlen),
    .s_axi_awsize(axi.awsize), .s_axi_awburst(axi.awburst),
    .s_axi_awvalid(axi.awvalid), .s_axi_awready(axi.awready),
    .s_axi_wdata(axi.wdata), .s_axi_wstrb(axi.wstrb), .s_axi_wlast(axi.wlast),
    .s_axi_wvalid(axi.wvalid), .s_axi_wready(axi.wready),
    .s_axi_bid(axi.bid), .s_axi_bresp(axi.bresp), .s_axi_bvalid(axi.bvalid),
    .s_axi_bready(axi.bready), .s_axi_arid(axi.arid), .s_axi_araddr(axi.araddr),
    .s_axi_arlen(axi.arlen), .s_axi_arsize(axi.arsize), .s_axi_arburst(axi.arburst),
    .s_axi_arvalid(axi.arvalid), .s_axi_arready(axi.arready),
    .s_axi_rid(axi.rid), .s_axi_rdata(axi.rdata), .s_axi_rresp(axi.rresp),
    .s_axi_rlast(axi.rlast), .s_axi_rvalid(axi.rvalid), .s_axi_rready(axi.rready),
    .app_ref_req(app_ref_req), .app_ref_ack(app_ref_ack),
    .app_zq_req(app_zq_req), .app_zq_ack(app_zq_ack)
  );

  task automatic write_word(input logic [21:0] address, input logic [39:0] data,
                            input logic [63:0] byte_enable);
    begin
      @(negedge port_clk);
      sram0_en = 1'b1;
      sram0_we = 1'b1;
      sram0_addr = address;
      sram0_wdata = data;
      sram0_be = byte_enable;
      @(negedge port_clk);
      sram0_en = 1'b0;
      sram0_we = 1'b0;
      sram0_be = '0;
    end
  endtask

  task automatic read_check(input logic [21:0] address, input logic [39:0] expected);
    begin
      @(negedge port_clk);
      sram0_en = 1'b1;
      sram0_we = 1'b0;
      sram0_addr = address;
      @(negedge port_clk);
      sram0_en = 1'b0;
      @(posedge port_clk);
      #1;
      if (sram0_rvalid !== 1'b1)
        $fatal(1, "Generated wrapper: rvalid was not asserted exactly L=1 after request");
      if (sram0_rdata !== expected)
        $fatal(1, "Generated wrapper: read 0x%010h expected 0x%010h", sram0_rdata, expected);
      @(posedge port_clk);
      #1;
      if (sram0_rvalid !== 1'b0)
        $fatal(1, "Generated wrapper: rvalid wider than one port_clk cycle");
    end
  endtask

  initial begin
    repeat (4) @(negedge port_clk);
    ui_rst_n = 1'b1;
    port_rst_n = 1'b1;
    repeat (2) @(negedge port_clk);
    calib_done = 1'b1;
    wait (stat_ready == 1'b1);
    repeat (2) @(negedge port_clk);
    write_word(22'd2, 40'h89ABCDEF12, 64'hFFFF_FFFF_FFFF_FFFF);
    read_check(22'd2, 40'h89ABCDEF12);
    write_word(22'd2, 40'h0123456789, 64'hFFFF_FFFF_FFFF_FF0A);
    read_check(22'd2, 40'h8923CD6712);
    if (stat_err !== 8'd0)
      $fatal(1, "Generated wrapper: unexpected stat_err=0x%02h", stat_err);
    $display("HADES_GENERATED_WRAPPER_PASS");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "Generated wrapper smoke watchdog expired");
  end
endmodule

`default_nettype wire
