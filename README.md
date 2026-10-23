# HADES-SRAM

**H**ybrid **A**ccelerated and **D**istributed **E**mulation **S**ystem — **HADES-SRAM** is the SRAM-emulation sub-project of HADES: an FPGA IP core that emulates many (up to 64, architecturally 128) independent, deterministic-latency SRAM ports on a **single AMD/Xilinx MIG DDR4 channel** (VCU1525, C0).

- Target board: **VCU1525** (XCVU9P, DDR4-2400, `ui_clk` = 300 MHz)
- Emulated SRAM ports: `port_clk` = 100–500 KHz, read latency L ∈ {1, 2} `port_clk` cycles (exact, not statistical), posted writes
- Clock modes: `CLK_MODE=SYNC` (default, same-source clocks) / `CLK_MODE=ASYNC` (independent clocks, whitelist CDC)
- Config variants: `CSR_EN=1` (default, AXI4-Lite CSR; reached via JTAG-AXI on the VCU1525 build) / `CSR_EN=0` (static hard-wired, all config from parameters incl. per-port base/size)
- Full spec: `HADES-SRAM_PlanMode.md` (project source of truth); register map: `csr/csr_regmap.md`; integration: `docs/integration_guide.md`

## Repository layout

```
rtl/            synthesizable SystemVerilog-2012 (hades_sram_top + submodules)
constraints/    hades_sram_clocks_{sync,async}.xdc (per-CLK_MODE, shipped with the IP)
csr/            csr_regmap.md (+ SystemRDL source, later milestone)
sim/            VCS/xsim testbench: SV harness + DPI-C C++ (stimulus, scoreboard)
fpga/vcu1525/   build.tcl (SYNC+ASYNC), board top RTL, JTAG-AXI host scripts, spike/
sw/             (host control = fpga/vcu1525/host/*.tcl via JTAG-AXI; no PCIe driver)
ip/             package_ip.tcl (Vivado IP packager; catalog-verified)
docs/           integration_guide.md, pipelining_study.md
```

## Quick start

```sh
make -C sim              # T6-basic CSR test + static-variant smoke, SIM=vcs (default)
make -C sim SIM=xsim     # same tests under Vivado xsim
make -C sim lint         # xvlog/xelab elaboration gate (both CSR_EN variants)
```

Milestone status: **M5-hw done — VCU1525 board acceptance A1–A10 complete on both builds (SYNC @ WNS +0.039, ASYNC/MMCM @ +0.020); campaign record in `docs/integration_guide.md` §12**

## Toolchain

- VCS X-2025.06 (`/home/kumon/Synopsys/vcs/X-2025.06/bin`) — primary simulator
- Vivado 2024.1 (`/home/kumon/Xilinx/Vivado/2024.1/bin`) — xsim secondary simulator, synthesis, bitstream
- g++ — DPI-C compilation
