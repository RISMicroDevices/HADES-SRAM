// =============================================================================
// HADES-SRAM HW spike - top-level wrapper with VIO observability
//
// Instantiates the (build-time patched) MIG example design `example_top_had`
// and a VIO core so calibration status can be read over JTAG without relying
// on board LEDs:
//   probe_in0: c0_init_calib_complete (1 = DDR4 calibration passed)
//   probe_in1: c0_data_compare_error  (0 = traffic generator clean)
//   probe_in2: 32-bit heartbeat counter on ui_clk (must change between reads)
// LED outputs are kept as well.
// =============================================================================
`timescale 1ps/1ps
`default_nettype none

module spike_top (
    input  wire        sys_rst,
    output wire        c0_init_calib_complete,
    output wire        c0_data_compare_error,
    input  wire        c0_sys_clk_p,
    input  wire        c0_sys_clk_n,
    output wire        c0_ddr4_act_n,
    output wire [16:0] c0_ddr4_adr,
    output wire [1:0]  c0_ddr4_ba,
    output wire [1:0]  c0_ddr4_bg,
    output wire [0:0]  c0_ddr4_cke,
    output wire [0:0]  c0_ddr4_odt,
    output wire [0:0]  c0_ddr4_cs_n,
    output wire [0:0]  c0_ddr4_ck_t,
    output wire [0:0]  c0_ddr4_ck_c,
    output wire        c0_ddr4_reset_n,
    output wire        c0_ddr4_parity,
    inout  wire [71:0] c0_ddr4_dq,
    inout  wire [17:0] c0_ddr4_dqs_t,
    inout  wire [17:0] c0_ddr4_dqs_c
);

  wire ui_clk;
  wire calib;
  wire cmperr;

  assign c0_init_calib_complete = calib;
  assign c0_data_compare_error  = cmperr;

  // MIG sys_rst is ACTIVE_HIGH, but VCU1525 CPU_RESET is an active-low button
  // (idles high) -> wiring them directly holds the MIG in reset forever.
  // Drive reset from a VIO output instead; observe the raw pin on probe_in3.
  wire rst_pin = sys_rst;
  wire rst_drv;

  example_top_had u_example (
    .sys_rst                 (rst_drv),
    .c0_init_calib_complete  (calib),
    .c0_data_compare_error   (cmperr),
    .c0_ui_clk               (ui_clk),
    .c0_sys_clk_p            (c0_sys_clk_p),
    .c0_sys_clk_n            (c0_sys_clk_n),
    .c0_ddr4_act_n           (c0_ddr4_act_n),
    .c0_ddr4_adr             (c0_ddr4_adr),
    .c0_ddr4_ba              (c0_ddr4_ba),
    .c0_ddr4_bg              (c0_ddr4_bg),
    .c0_ddr4_cke             (c0_ddr4_cke),
    .c0_ddr4_odt             (c0_ddr4_odt),
    .c0_ddr4_cs_n            (c0_ddr4_cs_n),
    .c0_ddr4_ck_t            (c0_ddr4_ck_t),
    .c0_ddr4_ck_c            (c0_ddr4_ck_c),
    .c0_ddr4_reset_n         (c0_ddr4_reset_n),
    .c0_ddr4_parity          (c0_ddr4_parity),
    .c0_ddr4_dq              (c0_ddr4_dq),
    .c0_ddr4_dqs_t           (c0_ddr4_dqs_t),
    .c0_ddr4_dqs_c           (c0_ddr4_dqs_c)
  );

  // ui_clk heartbeat - proves the MIG user clock is alive
  reg [31:0] hb = 32'h0;
  always @(posedge ui_clk) hb <= hb + 1'b1;

  vio_0 u_vio (
    .clk        (ui_clk),
    .probe_in0  (calib),
    .probe_in1  (cmperr),
    .probe_in2  (hb),
    .probe_in3  (rst_pin),
    .probe_out0 (rst_drv)
  );

endmodule
`default_nettype wire
