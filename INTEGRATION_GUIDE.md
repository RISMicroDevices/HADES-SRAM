# HADES-SRAM Integration Guide

HADES-SRAM is part of **HADES (Hybrid Accelerated and Distributed Emulation System)**. The core presents independent synchronous-SRAM interfaces in the `port_clk` domain and shares one AMD/Xilinx MIG DDR4 channel through an AXI4 backend.

For the complete interface, register, design-flow, testbench, example-design, verification, and debugging reference, see the [IP Product Guide](docs/hades_sram_product_guide.md) ([PDF](docs/hades_sram_product_guide.pdf)).

## 1. Core capabilities

- 1–64 separated ports (`N_MAX=64`), default `N=1`.
- Per-port widths `W0`–`W63`, any integer 1–512 bits; non-powers of two are supported.
- Per-port byte-enable switches `BE0_EN`–`BE63_EN`.
- Exact read latency `L ∈ {1,2}` `port_clk` cycles and posted writes. Requests can be accepted on consecutive `port_clk` edges.
- Shared `port_clk` at 100–500 KHz and `ui_clk` at 300 MHz.
- `IS_SYNC=1` for phase-related clocks or `IS_SYNC=0` for independent clocks.
- AXI4-Lite CSR (`CSR_EN=1`) or static parameter configuration (`CSR_EN=0`).
- Optional per-port self-test for 32/64-bit physical ports and low-priority backdoor access.

Physical port count, widths, byte-enable switches, address width, and clock mode are **elaboration-time settings**. CSR cannot create physical ports, change their widths, or enable byte enables at runtime. Runtime port masks, latency, address windows, and refresh settings do not change the physical interface.

## 2. Build and use the Vivado IP

Generate and verify the catalog package:

```sh
vivado -mode batch -source ip/package_ip.tcl
```

This creates `ip/hades_sram_1.0/` as a generated Vivado work product. The core VLNV is `rismd.cn:hades:hades_sram:1.1`; the directory name is not the core version. Maintained sources remain in `rtl/`, `constraints/`, `csr/`, `ip/xgui/`, `tools/`, and `docs/`. The packaged documentation and `tools/` directories are generated staging copies.

Register that directory in a Vivado project:

```tcl
set_property ip_repo_paths [list /path/to/HADES-SRAM/ip/hades_sram_1.0] [current_project]
update_ip_catalog
create_ip -name hades_sram -vendor rismd.cn -library hades -version 1.1 \
  -module_name hades_sram_0
```

To open an empty scratch project and the configurator:

```sh
vivado -source ip/open_ip_gui.tcl
```

The GUI has General, SRAM Ports, Maintenance, and Static Addressing pages. Ports are grouped in pages of eight, with expandable per-port groups, width fields, and byte-enable checkboxes. Each `sram<i>` block-diagram interface is an expandable tag containing its request, response, address, data, and byte-enable signals.

The GUI helper creates the IP instance before opening the customization dialog after GUI initialization. Do not invoke `start_ip_gui` during Vivado startup and then immediately exit the session; allow the deferred dialog to open.

## 2.1 Configuration code generator

Use the shared-kernel CLI or native HADES-Wizard Eclipse application to validate parameters and generate direct-RTL or packaged-IP wrappers:

```sh
./tools/hades-sram-gen init --output config.json
./tools/hades-sram-gen analyze --config config.json
./tools/hades-sram-gen generate --config config.json --output generated/hades_sram
./tools/hades-sram-gen gui --config config.json --output generated/hades_sram
```

The native launcher checks `HADES_WIZARD`, `HADES_WIZARD_HOME`, then the sibling HADES-Wizard product. The app requires Python 3.11+ for the backend and includes its Java runtime in packaged Linux and Windows products. Run `make -C sim check_wizard_windows` to build and exercise the native Windows application and its packaged Automatic/Manual GUI workflows.

Generation copies the complete integration payload by default: maintained RTL, both clock-mode constraints, and integration/CSR references, plus all configuration-specific artifacts. Use CLI `--no-full-copy` or clear the native **Copy complete integration sources** checkbox to omit maintained-source copies. Generated and copied RTL is under `logical/`; analytical reports are under `report/`. Root `wrapper.f` lists the generated package/wrapper, while full-copy `static_rtl.f` separately lists unchanging core RTL in compile order. Run filelist-based tools from the generated root.

Every configured physical port has `constraints/sram<i>_strict.xdc`, independently of runtime enables and full-copy selection. Each file applies explicit maximum/minimum input and output delays to all SRAM pins against `port_clk`, including byte-enable pins. Its conservative 0 ns external-delay baseline is an editable integration budget, not a board measurement. Define the actual clocks before loading these files, review the budgets for the external logic, and use them together with the selected SYNC/ASYNC constraints; they add no false-path, clock-group, or multicycle exceptions and do not prove timing closure.

The five native pages cover Integration, SRAM Ports, Clock & Latency, Maintenance & Self-Test, and Review & Generate. The shared left-hand **Module Port Preview** is also present in the main window. It supports drag-to-pan, bounded zoom, fit/reset, expandable per-SRAM and AXI/AXI-Lite groups, and a synchronized accessible tree. Successful Finish displays a generation-complete dialog. Native plots and read-only artifact previews use the same backend analysis as the CLI; preview performs no writes and is invalidated on edits.

See [Code Generator Guide](docs/hades_sram_generator.md) for complete CLI flags, filelist examples, launch/product commands, the provider/protocol boundary, and safe generation. Generated analysis is not post-route timing closure or hardware qualification. Static enable masks must be contiguous from port zero; use CSR for sparse masks. Self-test inclusion is limited to 32/64-bit physical ports.

## 3. SRAM interfaces

Every port `i` has these separate signals in the `port_clk` domain:

| Signal | Direction | Meaning |
|---|---|---|
| `sram<i>_en` | Input | Accept a request when high and the port is enabled |
| `sram<i>_we` | Input | 1 = posted write, 0 = read |
| `sram<i>_addr[AW-1:0]` | Input | Word address in units of `W<i>` bits |
| `sram<i>_wdata[W<i>-1:0]` | Input | Write data |
| `sram<i>_be[63:0]` | Input | Optional byte mask; only the low `ceil(W<i>/8)` bits are used |
| `sram<i>_rdata[W<i>-1:0]` | Output | Read data |
| `sram<i>_rvalid` | Output | Read response valid exactly `L` `port_clk` edges after acceptance |

When `BE<i>_EN=0`, the `be` input is ignored and writes affect the complete port word. When it is 1, only enabled bytes are written. Unused high `be` bits have no effect. Width and byte-enable settings do not alter the latency contract.

## 4. Address and lane model

The AXI backend transfers one 64-byte beat per port operation. Each width maps to a power-of-two number of consecutive 32-bit lanes:

```
LC = 2^ceil(log2(ceil(W/32)))
s  = log2(LC)
```

`LC` is 1, 2, 4, 8, or 16. A group never straddles a beat; non-power-of-two widths leave tail lanes unused. Data is LSB-justified in its lane group.

For a port word address `addr`:

```
beat       = PORT_BASE + floor(addr / (16 / LC))
lane_group = (addr mod (16 / LC)) * LC
```

`PORT_BASE` and `P_PORT_BASE` are in 64-byte-beat units. `PORT_SIZE` and `P_PORT_SIZE` are **32-bit lane-word counts**, not `W`-bit port-word counts. Legal frontend addresses satisfy:

```
0 <= addr < floor(PORT_SIZE / LC)
```

Read `PORT_WIDTH` at CSR offset `0x3C` to obtain the selected port's width and calculate `LC`.

Defaults per port:

- Base: `i * 2^18` beats, giving 16 MiB of address spacing.
- Size: `2^22` 32-bit lane words.
- At `W=32`, `LC=1`, this is `2^22` port words = 16 MiB.
- At `W=64`, `LC=2`, this is `2^21` port words = 16 MiB.
- At `W=40`, `LC=2`, this is `2^21` port words = 10 MiB because each 64-bit group has only 40 useful bits.

Widths do not automatically resize the address map in the RTL or raw JSON schema. Adjust bases and sizes when changing the desired capacity or avoiding overlap. The backend applies the used-byte mask and optional byte enables without writing unused tail bytes.

### Native frontend-depth allocation

Both native wizard address modes accept depth in frontend `W`-bit words and use `size_lanes = depth * LC`. Automatic allocation includes every physical port, including runtime-disabled ports, and assigns:

```
base[0]   = 0
base[i+1] = base[i] + ceil(size_lanes[i] / 16)
```

Manual mode permits base edits without relocation; an explicit depth/width edit changes only that port's size and preserves every base and unedited port. Existing files open in Manual mode. Raw legacy size tails are preserved until an explicit depth/width edit or confirmed Automatic allocation. The UI mode is not a schema, RTL, CSR, or runtime setting. CLI users can express either map directly with `--port-base-beats` and `--port-size-lanes`; see the Code Generator Guide.

## 5. Clocks, resets, and CDC

- `ui_clk` is 300 MHz for backend logic, CSR, and the MIG user interface.
- All emulated ports share one `port_clk`, 100–500 KHz.
- `ui_rst_n` and `port_rst_n` are active-low external reset inputs. Each domain uses asynchronous assertion and synchronous release through its reset synchronizer; functional logic uses synchronous internal resets. Hold the datapath in reset until MIG calibration is stable.

### SYNC (`IS_SYNC=1`)

Use clocks from one source with a fixed, statically declared phase relationship. Do not use spread-spectrum or runtime-drifting sources. Define the generated clocks and let normal timing analysis cover the domain crossings. Violating the same-source assumption is an integration error.

### ASYNC (`IS_SYNC=0`)

Use independent clocks. CDC is contained in `rtl/hades_sram_cdc.sv`: two-flop synchronizers, quasi-static bus holds, reset synchronizers, and Gray-pointer asynchronous FIFOs. Do not add bare cross-domain buses or combinational crossings.

The generated IP loads `hades_sram_clocks_sync.xdc` automatically. For an ASYNC build, remove that SYNC constraint and use `doc/hades_sram_clocks_async.xdc` instead; ASYNC constraints are not selected automatically by the packager. Review `report_cdc`. The VCU1525 flow supplies reviewed dispositions in `fpga/vcu1525/cdc_waivers.tcl` and requires zero unwaived Critical/Warning findings; equivalent review is required in another integration.

## 6. Configuration

### CSR (`CSR_EN=1`)

The AXI4-Lite CSR is in the `ui_clk` domain. The VCU1525 reference build maps it at `0x0000_0000`; board-control registers are at `0x0001_0000`.

Recommended sequence:

1. Wait for `STATUS.CALIB_DONE` and check `MEAS_PERIOD` against the intended gear. At 300 MHz, expect 600 cycles for 500 KHz and 3000 for 100 KHz.
2. Set `CFG_PORTS` no greater than elaborated `N` and set `PORT_EN_LO/HI` for the desired runtime subset. These controls cannot expose additional physical ports.
3. For each active port, select it with `PORT_SEL`, then configure `PORT_BASE`, `PORT_BASE_HI`, and `PORT_SIZE`. Read `PORT_WIDTH` when lane calculations are needed.
4. Set `CFG_LATENCY`, `CFG_MIN_PERIOD`, `CFG_REFRESH_DIV`, and `CFG_ZQ_DIV`.
5. Set `CTRL.ENABLE` and poll `STATUS.READY`.
6. Before disabling or reconfiguring, stop traffic and allow at least 16 `port_clk` periods to drain, then issue `SOFT_RESET`.

`CFG_LATENCY` takes effect on the next ENABLE 0-to-1 transition. `PORT_WIDTH` and byte-enable settings are compile-time values, not runtime CSR settings. See `csr/csr_regmap.md` for every register.

### Static (`CSR_EN=0`)

No CSR bus or boot sequence is needed. The core uses parameters directly and auto-enables after calibration with a healthy clock:

- `P_L`, `P_PORT_EN`, `P_MIN_PERIOD`, `P_REFRESH_DIV`, and `P_ZQ_DIV`.
- Flat `P_PORT_BASE` and `P_PORT_SIZE` vectors, sliced independently per port.
- `N`, `AW`, `IS_SYNC`, `SELFTEST_EN`, `SELFTEST_BLK`, `TARGET_PERIOD_CYCLES`, `W0`–`W63`, and `BE0_EN`–`BE63_EN`.

Status is available on `stat_calib_done`, `stat_ready`, `stat_refresh_active`, `stat_zq_active`, and `stat_err[7:0]`. Content access uses the pin-level `bkp_*` channel. Static self-test engines run automatically when enabled, but their per-port counters have no CSR readout.

## 7. Backdoor access

The backdoor initializes or reads memory without driving frontend ports. It has the lowest arbitration priority, uses maintenance windows and idle slots, and can run while the core is disabled.

**Backdoor addresses are 32-bit lane offsets**, and data is 32 bits per command. At `W=32`, lane offsets equal frontend word addresses. At other widths, use the lane-group mapping in §4; a backdoor lane offset is not generally a `W`-bit frontend word address. The legality check is `BKP_ADDR < PORT_SIZE` for the selected port.

For CSR operation, write `BKP_PORT`, `BKP_ADDR`, `BKP_ADDR_HI`, and `BKP_WDATA`, trigger `BKP_CMD`, poll `BKP_STATUS.done`, then read `BKP_RDATA`. In the static variant, hold `bkp_port`, `bkp_addr`, `bkp_wdata`, and `bkp_we` stable with `bkp_req` asserted until `bkp_ack`.

A full 64-port, 1 GiB initialization is about 16.8 million backend beats, roughly 56 ms of backend bus time before arbitration overhead. Allow approximately 0.1–0.2 seconds of chip time in an otherwise idle system. JTAG-AXI is a control-plane path: at approximately 10^3–10^4 32-bit words/s, a full 1 GiB host-driven traversal takes hours. Use sparse content checks or the on-chip self-test for full-rate verification instead.

## 8. MIG and VCU1525 checklist

- Use C0, DDR4-2400, 72-bit RDIMM, AXI4 with 512-bit data, and `ui_clk=300 MHz`.
- Enable **User Refresh and ZQCS Input**. The core drives `app_ref_req` and `app_zq_req` and expects their acknowledgments.
- ECC is disabled in the reference configuration. The fitted RDIMM/board routing provides no DM/DBI pins, so partial-beat writes incur MIG read-modify-write overhead.
- MIG `sys_rst` is active-high. The board's `CPU_RESETn` signal is inverted before use. Connect `init_calib_complete` to `calib_done`.
- The reference part is `xcvu9p-fsgd2104-2L-e`.
- The MIG C0 controller and PHY are board-fixed in SLR0. Do not add a ranged user pblock that conflicts with the MIG-generated placement constraints. HADES AXI boundaries and backend response channels are registered, keeping SLR crossings FF-to-FF; close timing with `report_timing`.
- The host control plane is JTAG-AXI, not PCIe/XDMA.

Build the reference image with:

```sh
vivado -mode batch -source fpga/vcu1525/build.tcl -tclargs SYNC|ASYNC [PCIE|MMCM]
```

The SYNC build divides `ui_clk` to form `port_clk`. The ASYNC/MMCM build uses another MMCM and boots at a conservative gear until the host selects the target gear. Build gates include nonnegative setup/hold WNS, DRC checks, and ASYNC CDC review.

Board scripts are in `fpga/vcu1525/host/`; arguments are documented in each file header. They cover initialization, latency, sustained load, refresh, frequency gears, configuration, endurance, and clock stop/start. For ASYNC/MMCM tests, set `HADES_SRC_UI_RATIO=3` because the frequency monitor counts `ui_clk` cycles while the divider counts the 100 MHz MMCM source cycles. Associate the matching `.ltx` probes file through `HADES_LTX` when using ILA.

For sustained or long on-board tests, enable the built-in checkers and require all selected `PORT_STAT_ERR` counters and `ERR_STATUS` to remain zero. `a5_soak`, `a9_soak`, and `a10_clock` provide sustained-load, endurance, and clock stop/start coverage. Use the documented quiesce sequence before stopping or reprogramming.

## 9. Slot budget and error handling

Elaboration checks the static bound:

```
MAINT_SLOTS + FIRST_LAT + CDC_OVHD + N_ACTIVE*SLOT_PER_PORT + MARGIN
  < TARGET_PERIOD_CYCLES
```

At 500 KHz (600 cycles), 64 ports fit; 128 do not. At 100 KHz (3000 cycles), 128 fit. The current physical interface supports at most 64 ports. Width does not change this budget because every operation uses one beat.

An illegal address produces an error record instead of an AXI access. A backend read unanswered for 768 `ui_clk` cycles completes with synthetic zeros and sets `ERR_STATUS.bit1`; treat that as a fatal backend alarm. `ERR_STATUS.bit5` reports a missed response window and must remain zero in a legal configuration.

## 10. Limitations

- All ports share `port_clk`; read latency is global across ports.
- Only C0 is used. C1–C3 are expansion options, not current implementations.
- No caching, prefetching, or write coalescing is implemented.
- Static self-test counters have no bus readout.
- Non-32-bit-width ports require care when translating backdoor lane addresses.
- On the VCU1525 reference platform, full read+write traffic is practical up to 56 ports at the default 32-bit width; read-only traffic reaches 64. Partial-beat write overhead is the limiting factor.
- `BOARD_DIV_DEFAULT` is not consumed by the board RTL; use the host gear-setting sequence to select the operating frequency.
