# HADES-SRAM

**H**igh-density **A**XI4-**D**DR4-backed **E**mulated **SRAM** — an FPGA IP core that emulates many (up to 64, architecturally 128) independent, deterministic-latency SRAM ports on a **single AMD/Xilinx MIG DDR4 channel** (VCU1525, C0).

- Target board: **VCU1525** (XCVU9P, DDR4-2400, `ui_clk` = 300 MHz)
- Emulated SRAM ports: `port_clk` = 100–500 KHz, read latency L ∈ {1, 2} `port_clk` cycles (exact, not statistical), posted writes
- Clock modes: `CLK_MODE=SYNC` (default, same-source clocks) / `CLK_MODE=ASYNC` (independent clocks, whitelist CDC)
- Config variants: `CSR_EN=1` (default, AXI4-Lite CSR via XDMA BAR) / `CSR_EN=0` (static hard-wired, all config from parameters incl. per-port base/size)
- Full spec: `HADES-SRAM_PlanMode.md` (project source of truth); register map: `csr/csr_regmap.md`; integration: `docs/integration_guide.md`

## Repository layout

```
rtl/            synthesizable SystemVerilog-2012 (hades_sram_top + submodules)
constraints/    hades_clocks.xdc (SYNC / ASYNC variants)
csr/            csr_regmap.md (+ SystemRDL source, later milestone)
sim/            VCS/xsim testbench: SV harness + DPI-C C++ (stimulus, scoreboard)
fpga/vcu1525/   reference Vivado project Tcl (MIG C0, XDMA, SLR2 pblock)
sw/             host driver (C, XDMA BAR mmap + indexed-window helpers)
ip/             package_ip.tcl (Vivado IP packager)
docs/           integration_guide.md
```

## Quick start

```sh
make -C sim              # T6-basic CSR test + static-variant smoke, SIM=vcs (default)
make -C sim SIM=xsim     # same tests under Vivado xsim
make -C sim lint         # xvlog/xelab elaboration gate (both CSR_EN variants)
```

Milestone status: **M1 (skeleton)** — see `docs/integration_guide.md` roadmap section.

## Toolchain

- VCS X-2025.06 (`/home/kumon/Synopsys/vcs/X-2025.06/bin`) — primary simulator
- Vivado 2024.1 (`/home/kumon/Xilinx/Vivado/2024.1/bin`) — xsim secondary simulator, synthesis, bitstream
- g++ — DPI-C compilation
