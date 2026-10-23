# AGENTS.md — working agreements for HADES-SRAM

## Source of truth
`/mnt/c/OneDrive/Kimi/HADES-SRAM_PlanMode.md` (spec; DoD = its §7). Deviations are listed in the plan and in `INTEGRATION_GUIDE.md` (working history in `docs/`).

## Toolchain (this host, WSL2)
- VCS: `/home/kumon/Synopsys/vcs/X-2025.06/bin/vcs` (license `LM_LICENSE_FILE=27080@KUMON-S1-HALO` — usually already in env; WSL2 kernel warning is benign)
- Vivado 2024.1: `/home/kumon/Xilinx/Vivado/2024.1/bin` (`xvlog/xelab/xsim`); VCU1525 board files present (part `xcvu9p-fsgd2104-2L-e`); Windows side also has Vivado 2024.1 (`C:\Xilinx\Vivado\2024.1`) used for hw_server/JTAG
- JTAG: Windows hw_server + `connect_hw_server -url <win-host>:3121` from WSL2 (user decision, no usbipd-win); host control path = JTAG-AXI, no PCIe/XDMA (user decision)
- **No cocotb, no Verilator** (user decision). Testbench = SystemVerilog + DPI-C C++.

## Standard commands
- `make -C sim` — run test suite with VCS (default); `SIM=xsim` for Vivado simulator
- `make -C sim lint` — Vivado elaboration gate for both CSR_EN variants
- `make -C sim check_bounds` — static slot-budget assertion spot-checks (T11 preview)
- `vivado -mode batch -source fpga/vcu1525/build.tcl -tclargs SYNC|ASYNC [PCIE|MMCM]` — VCU1525 bitstream (A1)
- `vivado -mode batch -source fpga/vcu1525/host/<script>.tcl -tclargs ...` — board acceptance scripts (A2–A10): a2_init, a4_latency, a5_soak, a6_refresh, a7_dualfreq, a8_config, a9_soak, a10_clock (args in each file header). ASYNC-bitstream legs need env `HADES_SRC_UI_RATIO=3` (MMCM src; the freq monitor counts ui_clk cycles, the divider counts src_clk cycles) and `HADES_LTX=<build/async_MMCM/...ltx>`
- `vivado -mode batch -source ip/package_ip.tcl` — package the Vivado IP (catalog-verified)
- `vivado -source ip/open_ip_gui.tcl` — open the hades_sram IP configurator in the Vivado GUI (scratch project `ip/work_gui/`)

## Design rules (spec §4, do not violate)
- Two clock domains: `ui_clk` (300 MHz) and `port_clk` (100–500 KHz); `CLK_MODE ∈ {SYNC(default), ASYNC}`
- ASYNC CDC only via whitelist in `rtl/hades_sram_cdc.sv` (`hades_sram_sync2`, `hades_sram_qs_bus`, `hades_sram_rst_sync`) — no bare cross-domain wires
- `CSR_EN ∈ {1(default), 0}`: CSR-configurable vs static hard-wired (params `P_*`, incl. flat per-port `P_PORT_BASE`/`P_PORT_SIZE` vectors); both produce the same internal `cfg_t`
- Slot budget static assertion in `hades_sram_top` must pass for any shipped parameter set
- Style: SV-2012, `` `default_nettype none ``, synchronous resets, no latches, 2-process FSMs, `for generate` for port arrays
- No `TODO/FIXME/XXX` in `rtl/` (spec §7 DoD)

## TODO-list discipline (user-mandated)
Keep the session TODO list live: exactly one `in_progress`, mark `done` immediately on completion, split tasks into finer sub-steps as work unfolds, add newly discovered work when discovered.
