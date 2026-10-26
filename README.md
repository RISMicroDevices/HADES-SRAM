# HADES-SRAM

**HADES** means **Hybrid Accelerated and Distributed Emulation System**. HADES-SRAM is the SRAM-emulation sub-project: a synthesizable FPGA IP core that presents many independent, deterministic-latency SRAM interfaces backed by one AMD/Xilinx MIG DDR4 channel.

## Features

- **1–64 separated SRAM ports**, with catalog default `N=1`.
- **Independent width per port**: `W0`–`W63`, any integer from 1 to 512 bits, including non-powers of two.
- **Independent byte-enable switch per port**: `BE0_EN`–`BE63_EN`.
- Exact read latency of 1 or 2 `port_clk` cycles and posted writes. A port accepts a request on every `port_clk` edge.
- `ui_clk` at 300 MHz and shared `port_clk` at 100–500 KHz; synchronous (`IS_SYNC=1`) or asynchronous (`IS_SYNC=0`) integration.
- AXI4-Lite CSR configuration (`CSR_EN=1`) or a parameter-only, no-boot-bus configuration (`CSR_EN=0`).
- Optional on-chip self-test for 32/64-bit ports and a low-priority backdoor for content access.
- Vivado IP packager, Vivado XGUI configurator, and expandable block-diagram interface tags.
- Shared-kernel CLI and native HADES-Wizard Eclipse configuration workflow with depth/address allocation, validated wrappers, analytical timing, and native plots.
- VCU1525 reference build with JTAG-AXI host scripts and on-chip acceptance checking.

## Repository layout

```
rtl/            Synthesizable SystemVerilog-2012 (hades_sram_top + submodules)
constraints/    SYNC and ASYNC clock/CDC constraints
csr/            csr_regmap.md
sim/            VCS/xsim testbench, SystemVerilog + DPI-C C++
fpga/vcu1525/   Board build, board RTL, MIG configuration, and JTAG-AXI scripts
ip/             package_ip.tcl, open_ip_gui.tcl, xgui/
tools/          Generator backend, CLI/protocol, native launcher, descriptor, and tests
docs/           Product Guide, generator guide, manifests, PDF, and figures
INTEGRATION_GUIDE.md  Consumer-facing integration guide
```

The maintained native UI is the sibling `HADES-Wizard` project. `ip/hades_sram_1.0/`, its `tools/` payload, and `ip/work_*/` are generated outputs, not maintained source copies.

## Simulation and checks

```sh
make -C sim                  # Generator + VCS suite, width/BE matrix, bounds, and coverage
make -C sim SIM=xsim         # Generator + Vivado xsim suite with reduced operation counts
make -C sim lint             # Vivado elaboration for CSR and static variants
make -C sim check_bounds     # Static slot-budget assertion checks
make -C sim check_generator  # Backend/CLI/protocol tests and generated RTL smoke
make -C sim check_wizard     # Native Eclipse SRAM integration tests + provider packages
make -C sim check_wizard_windows  # Native Windows tests + packaged GUI workflows
make -C sim check_generator_ip       # Generated Vivado IP and fake-host CSR checks
```

Run `check_generator_ip` after generating the catalog package. Both wizard targets use `WIZARD=../../HADES-Wizard` by default; override `WIZARD` for another checkout. `check_wizard` uses the sibling pinned Linux JDK. `check_wizard_windows` uses Windows-local staging and the sibling pinned Windows JDK to run native tests and the packaged Automatic/Manual GUI workflows. See `../HADES-Wizard/README.md` for native build/test details.

## Vivado IP

```sh
vivado -mode batch -source ip/package_ip.tcl
vivado -source ip/open_ip_gui.tcl
```

The first command packages and verifies `rismd.cn:hades:hades_sram:1.1`. The second opens the separate Vivado XGUI configurator. Its default is one port; select 1–64 and configure each port's width and byte-enable switch independently.

## Configuration code generator

```sh
./tools/hades-sram-gen init --output config.json
./tools/hades-sram-gen validate --config config.json
./tools/hades-sram-gen analyze --config config.json
./tools/hades-sram-gen generate --config config.json --output generated/hades_sram
./tools/hades-sram-gen gui --config config.json --output generated/hades_sram
```

The CLI and native Eclipse wizard share one Python 3.11+ backend. Generation copies the complete integration source payload by default; use `--no-full-copy` or clear **Copy complete integration sources** for configuration-specific artifacts only. Generated and copied RTL is under `logical/`, reports under `report/`, and separate root `wrapper.f`/`static_rtl.f` filelists support direct compilation. Each physical SRAM port also receives a strict `constraints/sram<i>_strict.xdc` interface-timing file.

The native app provides five pages, Automatic/Manual frontend-depth addressing, exact ratio/timing readouts, native plots, and read-only artifact preview. A shared **Module Port Preview** remains on the left throughout the wizard and main window, with drag-to-pan, zoom/fit/reset controls, expandable SRAM/AXI/AXI-Lite groups, and an accessible tree. Successful generation ends with a confirmation dialog. All generated analysis and constraints require integration review; they are not post-route closure or on-board qualification.

The native launcher checks `HADES_WIZARD`, then `HADES_WIZARD_HOME`, then the sibling product. Packaged Linux and Windows apps include Java; Python 3.11+ is still required for the backend. Use `make -C sim check_wizard_windows` for native Windows build, UI, and packaged-GUI verification. See the [Code Generator Guide](docs/hades_sram_generator.md) for complete CLI flags, precedence, address modes, direct product commands, protocol boundary, and safe force/check behavior.

## IP Product Guide

Read the complete Product Guide as [Markdown](docs/hades_sram_product_guide.md) or [PDF](docs/hades_sram_product_guide.pdf). It covers IP facts, product specification, interfaces and registers, integration, design flow, native configuration, testbench, VCU1525 example design, verification, and debugging.

Rebuild it with the sibling **HADES-Doc** project:

```sh
../HADES-Doc/bin/hades-doc render docs/hades_sram_product_guide.toml
../HADES-Doc/bin/hades-doc verify docs/hades_sram_product_guide.pdf
```

HADES-Doc is not an RTL or simulation dependency. The packager copies the guide, manifest, and referenced figures into the generated IP documentation group.

## VCU1525 build

```sh
vivado -mode batch -source fpga/vcu1525/build.tcl -tclargs SYNC|ASYNC [PCIE|MMCM]
```

The board control plane is JTAG-AXI; no PCIe/XDMA host driver is required. See `INTEGRATION_GUIDE.md` for MIG settings, clocking, placement, address mapping, static configuration, and board acceptance flows. CSR details are in `csr/csr_regmap.md`.
