# AGENTS.md — working agreements for HADES-SRAM

## Source of truth
`/mnt/c/OneDrive/Kimi/HADES-SRAM_PlanMode.md` (spec; DoD = its §7). Deviations are listed in the plan and in `docs/integration_guide.md`.

## Toolchain (this host, WSL2)
- VCS: `/home/kumon/Synopsys/vcs/X-2025.06/bin/vcs` (license `LM_LICENSE_FILE=27080@KUMON-S1-HALO` — usually already in env; WSL2 kernel warning is benign)
- Vivado 2024.1: `/home/kumon/Xilinx/Vivado/2024.1/bin` (`xvlog/xelab/xsim`, `hw_server`); VCU1525 board files present (`xcvu9p-fsgd2104-2`)
- **No cocotb, no Verilator** (user decision). Testbench = SystemVerilog + DPI-C C++.

## Standard commands
- `make -C sim` — run test suite with VCS (default); `SIM=xsim` for Vivado simulator
- `make -C sim lint` — Vivado elaboration gate for both CSR_EN variants
- `make -C sim check_bounds` — static slot-budget assertion spot-checks (T11 preview)

## Design rules (spec §4, do not violate)
- Two clock domains: `ui_clk` (300 MHz) and `port_clk` (100–500 KHz); `CLK_MODE ∈ {SYNC(default), ASYNC}`
- ASYNC CDC only via whitelist in `rtl/hades_cdc.sv` (`hades_sync2`, `hades_qs_bus`, `hades_rst_sync`) — no bare cross-domain wires
- `CSR_EN ∈ {1(default), 0}`: CSR-configurable vs static hard-wired (params `P_*`, incl. flat per-port `P_PORT_BASE`/`P_PORT_SIZE` vectors); both produce the same internal `cfg_t`
- Slot budget static assertion in `hades_sram_top` must pass for any shipped parameter set
- Style: SV-2012, `` `default_nettype none ``, synchronous resets, no latches, 2-process FSMs, `for generate` for port arrays
- No `TODO/FIXME/XXX` in `rtl/` (spec §7 DoD)

## TODO-list discipline (user-mandated)
Keep the session TODO list live: exactly one `in_progress`, mark `done` immediately on completion, split tasks into finer sub-steps as work unfolds, add newly discovered work when discovered.
