//-----------------------------------------------------------------------------
// HADES-SRAM — global package
// Parameters, types (cfg_t), CSR address map, TDMA slot-budget model.
// Spec: HADES-SRAM_PlanMode.md sections 3.3, 4.1, 4.3.
//-----------------------------------------------------------------------------
`default_nettype none

package hades_pkg;

  // ------------------------------------------------------------------
  // Compile-time capacity
  // ------------------------------------------------------------------
  localparam int N_MAX       = 64;   // compile-time port ceiling (arch: 128)
  localparam int DW_DEFAULT  = 32;   // legal values {8,16,32,64}
  localparam int AW_DEFAULT  = 22;   // 16 MiB / 4 B per 32-bit word
  localparam int UI_CLK_MHZ  = 300;

  // Clock-mode encoding — must match CSR PARAMS.bit31 (0=ASYNC, 1=SYNC)
  typedef enum logic { CLK_MODE_ASYNC = 1'b0, CLK_MODE_SYNC = 1'b1 } clk_mode_e;

  // ------------------------------------------------------------------
  // Backend geometry
  // ------------------------------------------------------------------
  localparam int WORD_BYTES  = 64;                      // one 512-bit AXI beat
  localparam int BASE_W      = 34;                      // 512-bit-word address (1 TiB span)
  localparam int PORT_MB_DEFAULT = 16;                  // per-port capacity, MiB
  localparam longint unsigned PORT_WORDS_DEFAULT =
      (64'(PORT_MB_DEFAULT) * 1024 * 1024) / WORD_BYTES;  // 2^18 words

  // ------------------------------------------------------------------
  // Slot budget, ui_clk cycles (spec section 1 and 4.3)
  // ------------------------------------------------------------------
  localparam int MAINT_SLOTS         = 150;   // maintenance window per target period
  localparam int FIRST_LAT           = 36;    // backend first-data latency
  localparam int SLOT_PER_PORT       = 4;     // bus cycles per port service
  localparam int CDC_OVHD_SYNC       = 4;
  localparam int CDC_OVHD_ASYNC      = 12;
  localparam int MARGIN              = 100;   // required residual headroom
  localparam int TARGET_PERIOD_500K  = 600;   // ui_clk cycles @ 500 KHz
  localparam int TARGET_PERIOD_100K  = 3000;  // ui_clk cycles @ 100 KHz

  function automatic int cdc_ovhd(input clk_mode_e m);
    return (m == CLK_MODE_SYNC) ? CDC_OVHD_SYNC : CDC_OVHD_ASYNC;
  endfunction

  // TDMA slot table (spec 3.2): ui_clk offset of port i inside a target period.
  // Elaboration-time, static; no dynamic priority anywhere.
  function automatic int slot_of(input int i, input clk_mode_e m);
    return MAINT_SLOTS + FIRST_LAT + cdc_ovhd(m) + i * SLOT_PER_PORT;
  endfunction

  // Spec 4.3 static bound.  True => the configuration fits one target period.
  function automatic bit budget_ok(input int n_active, input int target_period,
                                   input clk_mode_e m);
    return (MAINT_SLOTS + FIRST_LAT + cdc_ovhd(m) + n_active * SLOT_PER_PORT
            + MARGIN) < target_period;
  endfunction

  // ------------------------------------------------------------------
  // Configuration struct — the single internal representation consumed
  // by arbiter / ports / refresh.  Produced by hades_csr (CSR_EN=1) or by
  // static_cfg() from parameters (CSR_EN=0).
  // ------------------------------------------------------------------
  typedef struct packed {
    logic [1:0]                 latency;      // L, port_clk cycles: 1 or 2
    logic [N_MAX-1:0]           port_en;
    logic [7:0]                 active_ports; // <= N_MAX
    logic [31:0]                min_period;   // ui_clk cycles
    logic [31:0]                refresh_div;  // ui_clk cycles between ref slots
    logic [31:0]                zq_div;       // target periods between ZQCS
    logic [N_MAX-1:0][BASE_W-1:0] port_base;  // per-port base, 512-bit words
    logic [N_MAX-1:0][31:0]       port_size;  // per-port size, words
  } cfg_t;

  // Default flat per-port maps: contiguous equal 16 MiB partitions.
  function automatic logic [N_MAX*BASE_W-1:0] dflt_base_flat();
    logic [N_MAX*BASE_W-1:0] v;
    for (int i = 0; i < N_MAX; i++)
      v[i*BASE_W +: BASE_W] = BASE_W'(PORT_WORDS_DEFAULT) * BASE_W'(i);
    return v;
  endfunction

  function automatic logic [N_MAX*32-1:0] dflt_size_flat();
    logic [N_MAX*32-1:0] v;
    for (int i = 0; i < N_MAX; i++)
      v[i*32 +: 32] = 32'(PORT_WORDS_DEFAULT);
    return v;
  endfunction

  // Build the hard-wired configuration (CSR_EN=0).  Per-port base/size are
  // sliced from the flat parameter vectors — no partition math here.
  function automatic cfg_t static_cfg(
    input logic [1:0]               latency,
    input logic [N_MAX-1:0]         port_en,
    input logic [31:0]              min_period,
    input logic [31:0]              refresh_div,
    input logic [31:0]              zq_div,
    input logic [N_MAX*BASE_W-1:0]  base_flat,
    input logic [N_MAX*32-1:0]      size_flat
  );
    cfg_t c;
    c.latency      = latency;
    c.port_en      = port_en;
    c.active_ports = 8'($countones(port_en));
    c.min_period   = min_period;
    c.refresh_div  = refresh_div;
    c.zq_div       = zq_div;
    for (int i = 0; i < N_MAX; i++) begin
      c.port_base[i] = base_flat[i*BASE_W +: BASE_W];
      c.port_size[i] = size_flat[i*32 +: 32];
    end
    return c;
  endfunction

  // ------------------------------------------------------------------
  // CSR address map (spec 3.3) — AXI4-Lite byte offsets
  // ------------------------------------------------------------------
  localparam logic [15:0] CSR_CTRL            = 16'h0000;
  localparam logic [15:0] CSR_STATUS          = 16'h0004;
  localparam logic [15:0] CSR_CFG_LATENCY     = 16'h0008;
  localparam logic [15:0] CSR_CFG_PORTS       = 16'h000C;
  localparam logic [15:0] CSR_MEAS_PERIOD     = 16'h0010;
  localparam logic [15:0] CSR_PORT_EN_LO      = 16'h0014;
  localparam logic [15:0] CSR_PORT_EN_HI      = 16'h0018;
  localparam logic [15:0] CSR_CFG_MIN_PERIOD  = 16'h001C;
  localparam logic [15:0] CSR_PORT_SEL        = 16'h0020;
  localparam logic [15:0] CSR_PORT_BASE       = 16'h0024;
  localparam logic [15:0] CSR_PORT_BASE_HI    = 16'h0028;
  localparam logic [15:0] CSR_PORT_SIZE       = 16'h002C;
  localparam logic [15:0] CSR_PORT_STAT_RD    = 16'h0030;
  localparam logic [15:0] CSR_PORT_STAT_WR    = 16'h0034;
  localparam logic [15:0] CSR_PORT_STAT_ERR   = 16'h0038;
  localparam logic [15:0] CSR_CFG_REFRESH_DIV = 16'h0040;
  localparam logic [15:0] CSR_CFG_ZQ_DIV      = 16'h0044;
  localparam logic [15:0] CSR_ERR_STATUS      = 16'h0050;
  localparam logic [15:0] CSR_ERR_ADDR        = 16'h0054;
  localparam logic [15:0] CSR_STAT_MAXLAT     = 16'h0058;
  localparam logic [15:0] CSR_STAT_REFCNT     = 16'h005C;
  localparam logic [15:0] CSR_STAT_TOT_RD_LO  = 16'h0060;
  localparam logic [15:0] CSR_STAT_TOT_WR_LO  = 16'h0064;
  localparam logic [15:0] CSR_STAT_TOT_RD_HI  = 16'h0068;
  localparam logic [15:0] CSR_STAT_TOT_WR_HI  = 16'h006C;
  localparam logic [15:0] CSR_ID              = 16'h0080;
  localparam logic [15:0] CSR_PARAMS          = 16'h0084;
  // Backdoor channel (M4; offsets reserved now, documented in csr_regmap.md)
  localparam logic [15:0] CSR_BKP_PORT        = 16'h0090;
  localparam logic [15:0] CSR_BKP_ADDR        = 16'h0094;
  localparam logic [15:0] CSR_BKP_ADDR_HI     = 16'h0098;
  localparam logic [15:0] CSR_BKP_WDATA       = 16'h009C;
  localparam logic [15:0] CSR_BKP_CMD         = 16'h00A0;
  localparam logic [15:0] CSR_BKP_RDATA       = 16'h00A4;
  localparam logic [15:0] CSR_BKP_STATUS      = 16'h00A8;

  // ID / PARAMS constants
  localparam logic [31:0] ID_MAGIC  = 32'hADE5_0100;  // "HADES" v1.0

  // PARAMS layout: bit31=CLK_MODE, [30:20]=ui_clk MHz, [19:12]=port MiB,
  //                [11:8]=DW/8, [7:0]=N_MAX
  function automatic logic [31:0] params_word(input clk_mode_e m, input int ui_mhz,
                                              input int port_mb, input int dw);
    return {m, 11'(ui_mhz), 8'(port_mb), 4'(dw/8), 8'(N_MAX)};
  endfunction

endpackage

`default_nettype wire
