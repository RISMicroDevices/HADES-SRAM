# HADES-SRAM Code Generator Guide

## 1. Overview

The HADES-SRAM code generator creates validated parameters and integration wrappers for `rismd.cn:hades:hades_sram:1.1`. The command-line interface and native HADES-Wizard Eclipse application share the same Python 3.11+ backend for validation, depth/address operations, frequency/timing analysis, plots, previews, and generated files.

Maintained backend sources and `hades_sram_wizard.json` are in `tools/`. The maintained native UI is the sibling `HADES-Wizard` project. The Vivado packager places generated copies of the backend and descriptor in `ip/hades_sram_1.0/tools/`; do not edit generated copies. Generated timing, frequency, slot, memory, and bandwidth results are analytical configuration results, not implementation or board signoff.

The backend uses only the Python standard library. CLI and protocol use are headless and require no Java. The packaged native Linux and Windows applications include their pinned Java runtime; using them does not require a separate Java installation. Python 3.11 or newer remains required for the backend and can be selected with the application's `--python` argument. Linux and Windows product packages are built by HADES-Wizard. Separate native Windows build, UI, and packaged-GUI verification is available through `make -C sim check_wizard_windows`.

## 2. Quick start

Run these commands from the HADES-SRAM source root:

```sh
./tools/hades-sram-gen init --output config.json
./tools/hades-sram-gen validate --config config.json
./tools/hades-sram-gen analyze --config config.json
./tools/hades-sram-gen analyze --config config.json --json
./tools/hades-sram-gen generate --config config.json --output generated/hades_sram
```

The default is one 32-bit port, `AW=22`, SYNC clocking, CSR configuration, a 500 KHz frontend clock, 600-cycle target/minimum periods, read latency two, and self-test disabled.

Generation refuses to overwrite managed artifacts without explicit `--force`:

```sh
./tools/hades-sram-gen generate --config config.json --output generated/hades_sram --force
```

Compare the current configuration with all managed files, including stale files from an earlier configuration, without writing:

```sh
./tools/hades-sram-gen generate --config config.json --output generated/hades_sram --check
```

Open the source configuration in the native application and optionally set its initial output directory:

```sh
./tools/hades-sram-gen gui --config config.json --output generated/hades_sram
```

After `vivado -mode batch -source ip/package_ip.tcl`, the packaged backend is also available as `./ip/hades_sram_1.0/tools/hades-sram-gen`.

## 3. Native HADES-Wizard application

### Launch resolution

`hades-sram-gen gui` launches the native executable directly, waits for it, and returns its exit status. It starts no browser, HTTP server, or shell. Resolution order is:

1. `HADES_WIZARD`: full path to `hades-wizard` or `hades-wizard.exe`.
2. `HADES_WIZARD_HOME`: product directory containing `hades-wizard` or `hades-wizard.exe`.
3. The sibling staged Linux or Windows product under `../HADES-Wizard/products/cn.rismd.hades.wizard.product/target/products/cn.rismd.hades.wizard.product/`.

The launcher forwards absolute paths for `--provider`, `--python`, optional `--config`, and optional `--output`. It uses the current adjacent `tools/hades_sram_wizard.json` and the current Python executable, not a stale provider copy. An unavailable executable produces `E_WIZARD_NOT_FOUND` with configuration guidance. On WSL, the launcher selects `GDK_BACKEND=x11` when no backend was explicitly selected; an existing `GDK_BACKEND` value is preserved. For a direct product launch on WSL, use `GDK_BACKEND=x11` explicitly.

A direct Linux product launch is equivalent to:

```sh
../HADES-Wizard/products/cn.rismd.hades.wizard.product/target/products/cn.rismd.hades.wizard.product/linux/gtk/x86_64/hades-wizard \
  --provider /absolute/path/HADES-SRAM/tools/hades_sram_wizard.json \
  --python /absolute/path/python3 \
  --config /absolute/path/config.json \
  --output /absolute/path/generated/hades_sram
```

On Windows, run `hades-wizard.exe` from `win32/win32/x86_64` with the same arguments and Windows paths, for example:

```bat
hades-wizard.exe --provider C:\work\HADES-SRAM\tools\hades_sram_wizard.json --python C:\Python311\python.exe --config C:\work\config.json --output C:\work\generated
```

`--config` and `--output` are optional. Packaged products can instead use their installed `provider/provider.json`. The native application bundles Java; the backend still requires Python 3.11+. Linux tests do not replace the native Windows verification provided by `make -C sim check_wizard_windows`.

### Five-page workflow

1. **Integration:** target, module/IP identifiers, CSR/static configuration, physical port count, and address width.
2. **SRAM Ports:** per-port width, frontend depth, base, byte enable, runtime enable, and Automatic/Manual addressing.
3. **Clock & Latency:** clock relationship, requested port frequency, exact read latency, and the **Advanced period control** group for automatic or explicit target/minimum periods. Readouts distinguish requested frequency, exact UI:port ratio, integer cycle-model rate, period, latency, budget, and headroom.
4. **Maintenance & Self-Test:** self-test selection/capacity and the **Advanced maintenance** group for refresh and ZQ intervals. Refresh is in `ui_clk` cycles; ZQ is in requested `port_clk` periods.
5. **Review & Generate:** diagnostics, configuration summary, native Timing, Slot Budget, Memory Map, and Bandwidth plots, raw analysis values, read-only artifact preview, output directory, managed-overwrite control, and the default-on **Copy complete integration sources** checkbox.

The shared **Module Port Preview** stays on the left of every page and the main application window. Its native diagram supports left-button drag-to-pan, Ctrl+mouse-wheel and keyboard zoom, **Zoom In**, **Zoom Out**, **Fit**, and **Reset**. Expand or collapse individual SRAM port groups and the AXI4, AXI4-Lite, maintenance, clock/reset, or mode-dependent static groups. The accessible tree tab presents the same groups, directions, widths, and clock domains for keyboard navigation. Expansion, pan, and zoom survive configuration refreshes; loading, invalid, and empty states remain explicit. The reusable implementation is the provider-neutral `cn.rismd.hades.wizard.modulepreview` bundle in HADES-Wizard.

Every edit invalidates prior artifact-preview data and refreshes module metadata. Artifact preview is read-only and performs no filesystem writes; changing full-copy selection also invalidates it. Finish revalidates the current snapshot and writes only through the shared managed-output path. A **Generation Complete** dialog appears only after confirmed successful generation and reports the destination and managed-file count. Invalid configurations, nonzero generation status, and cancellation do not show a success dialog. Save writes canonical JSON only after structural and semantic validation. Existing files require explicit overwrite permission.

### Provider and protocol boundary

`tools/hades_sram_wizard.json` declares the five pages and presentation fields. Java does not duplicate lane arithmetic, address allocation, timing derivation, semantic validation, or the module's signal declarations. It launches the backend as `[python, hades-sram-gen, protocol]` and uses persistent bounded UTF-8 NDJSON on stdin/stdout, with protocol version 1, monotonic positive request IDs, a 2 MiB request cap, and a 32 MiB response cap. No HTTP or socket transport is involved.

Service operations cover schema, analysis, raw-text analysis, period derivation, resize, depth edits, automatic allocation, preview, save, generate, and check. Analysis responses carry canonical configuration, diagnostics, `analysis.ports[]` values such as `capacity_words`, lane count, tail lanes and backend window padding, and a `module` object containing grouped port metadata for the shared preview. Protocol `preview` and `generate` accept an optional boolean `full_copy`, defaulting to true. Protocol/configuration errors remain structured responses; stdout is reserved for protocol frames.

For sibling build, test, product, and provider-package details, see `../HADES-Wizard/README.md`. The SRAM integration entry points are:

```sh
cd ../HADES-Wizard
export JAVA_HOME="$PWD/.toolchain/jdk-21.0.9+10-linux-x64"
export PATH="$JAVA_HOME/bin:$PATH"
./mvnw clean verify -Phades-sram-integration \
  -Dhades.sram.descriptor=/absolute/path/HADES-SRAM/tools/hades_sram_wizard.json \
  -Dhades.sram.python=python3
./scripts/package-provider.sh /absolute/path/HADES-SRAM/tools/hades_sram_wizard.json
```

From HADES-SRAM, `make -C sim check_wizard` runs the same integration and provider-package flow with the pinned sibling JDK. Set `WIZARD=/path/to/HADES-Wizard` to override the sibling location. `make -C sim check_wizard_windows` invokes `scripts/verify-windows.ps1` through Windows PowerShell, creates a disposable Windows-local source/build stage, runs the native core and SWT suites, and exercises packaged Automatic and Manual GUI workflows. Override `WIZARD_POWERSHELL` or `WIZARD_WINDOWS_PYTHON` if those executables have different names; no mapped drive or Java lock workaround is used.

## 4. Configuration schema

The input is a JSON object with `schema_version` 1. Unknown fields, duplicate keys, incorrect types, and booleans used as integers are rejected. Missing fields receive documented defaults; generated `config.json` contains the complete canonical configuration.

| Field | Meaning and validation |
|---|---|
| `schema_version` | Must be 1. |
| `target` | `rtl` for direct core instantiation or `ip` for a configured catalog IP instance. |
| `module_name` | Generated consumer-wrapper module name; portable, nonreserved SystemVerilog identifier. |
| `ip_name` | Vivado IP instance name for the `ip` target; also a valid identifier. |
| `port_count` | Physical separated interfaces, 1–64. Default 1. |
| `address_width` | Common frontend `AW`, 1–32 bits. |
| `clock_mode` | `SYNC` for same-source/static-phase clocks or `ASYNC` for independent clocks. |
| `configuration_mode` | `CSR` for runtime AXI4-Lite configuration or `STATIC` for parameter-only auto-enable. |
| `port_clock_hz` | Requested external shared frontend clock, 100000–500000 Hz. |
| `target_period_cycles` | Analytical TDMA target in `ui_clk` cycles. If omitted, derived as `floor(300000000 / port_clock_hz)`. |
| `min_period_cycles` | Runtime monitor minimum in `ui_clk` cycles. If omitted, uses the same derived value; must be consistent with target and requested clock. |
| `read_latency` | Exact frontend response latency, 1 or 2 `port_clk` cycles. |
| `selftest_enabled` | Include self-test engines. Every physical port must be 32 or 64 bits. |
| `selftest_block_words` | Positive frontend-word count; must fit every runtime-enabled port's capacity. |
| `refresh_cycles` | Nonzero unsigned 32-bit refresh interval in `ui_clk` cycles. |
| `zq_periods` | Nonzero unsigned 32-bit ZQ interval in requested `port_clk` periods. |
| `ports` | Exactly `port_count` records in ascending physical-port order. |

Each port record contains:

| Field | Meaning and validation |
|---|---|
| `width` | Independent data width, any integer 1–512 bits. |
| `byte_enable` | Boolean elaboration-time BE switch. |
| `enabled` | Boolean runtime enable. CSR permits sparse masks; STATIC requires a contiguous prefix from port zero. |
| `base_beats` | Unsigned 34-bit backend base in 64-byte beats. |
| `size_lanes` | Unsigned 32-bit size in 32-bit lanes, not frontend words. Enabled ports require nonzero size. |

## 5. Complete CLI overrides

The `init`, `validate`, `analyze`, and `generate` commands share all configuration overrides. `--config` is optional on each: without it, resolution starts from built-in defaults and omission-sensitive derivation, so validation, analysis, and generation need no JSON file. `init` still requires `--output FILE`; `generate` requires `--output DIR`.

### Global options

| Option | Value / units |
|---|---|
| `--schema-version VERSION` | Configuration schema; supported value 1. |
| `--target TARGET` | `rtl` or `ip`. |
| `--module-name IDENTIFIER` | Wrapper module identifier. |
| `--ip-name IDENTIFIER` | Catalog IP instance identifier. |
| `--port-count N` | Physical ports, 1–64. |
| `--address-width BITS` | Frontend address width, 1–32. |
| `--clock-mode MODE` | `SYNC` or `ASYNC`. |
| `--configuration-mode MODE` | `CSR` or `STATIC`. |
| `--port-clock-hz HZ` | Requested port clock, 100000–500000 Hz. |
| `--target-period-cycles CYCLES` | Positive signed 32-bit target in `ui_clk` cycles. |
| `--min-period-cycles CYCLES` | Nonzero unsigned 32-bit monitor minimum in `ui_clk` cycles. |
| `--read-latency CYCLES` | 1 or 2 `port_clk` cycles. |
| `--selftest-enabled` / `--no-selftest-enabled` | Explicitly enable/disable self-test; the switches conflict. |
| `--selftest-block-words WORDS` | Positive signed 32-bit frontend-word count. |
| `--refresh-cycles CYCLES` | Nonzero unsigned 32-bit refresh interval in `ui_clk` cycles. |
| `--zq-periods CYCLES` | Nonzero unsigned 32-bit ZQ interval in requested `port_clk` periods. |

### Indexed per-port options

Indices are zero-based and must be below the resolved `port_count`. Repeat options for different ports or fields.

| Option | Value |
|---|---|
| `--port-width INDEX=BITS` | Width 1–512 bits. |
| `--port-byte-enable INDEX=true\|false` | Elaboration-time byte-enable switch. |
| `--port-enabled INDEX=true\|false` | Runtime enable. |
| `--port-base-beats INDEX=BEATS` | Base in unsigned 34-bit 64-byte-beat units. |
| `--port-size-lanes INDEX=LANES` | Raw size in unsigned 32-bit 32-bit-lane units. |

Per-port booleans accept only lowercase `true` or `false`. Integer forms are decimal `INDEX=VALUE`. Malformed forms, unknown options, conflicting top-level switches, invalid indices, and invalid semantics fail nonzero before output writes.

### Precedence and sparse derivation

Resolution is independent of argument order:

1. Built-in defaults and omission-sensitive derivation.
2. Strict raw JSON from `--config`, before `Config` decoding.
3. Explicit global CLI overrides.
4. `--port-count` resize, retaining old records and applying canonical defaults to new records.
5. Indexed per-port overrides.
6. One structural decode followed by semantic validation.

Because raw documents merge before decoding, sparse timing derivation is preserved:

```sh
./tools/hades-sram-gen init --output config.json --port-clock-hz 100000
```

With both cycle fields omitted, this writes 3000 for each. Explicit values in the source JSON or CLI are retained. Starting from a canonical default JSON is not required.

A complete CLI-only configuration can be generated directly, for example:

```sh
./tools/hades-sram-gen generate --output generated/cli_only \
  --port-count 2 --address-width 12 --port-clock-hz 100000 \
  --target rtl --configuration-mode CSR --clock-mode SYNC \
  --port-width 0=32 --port-base-beats 0=0 --port-size-lanes 0=16 \
  --port-width 1=64 --port-base-beats 1=1 --port-size-lanes 1=32
```

CLI `generate` also accepts mutually exclusive `--full-copy` and `--no-full-copy`; the default is `--full-copy`. These generation-only switches do not alter configuration precedence or appear in canonical JSON. The native Review checkbox and protocol `full_copy` field select the same output behavior.

`--force` atomically replaces managed artifacts and removes stale files named by the previous manifest. `--check` reports missing, changed, or stale managed files without repairing them. Invalid configurations never produce output. The native Save and Finish operations use the same canonical-write and managed-output safeguards.

## 6. Depth and address operations

Both native address modes use **frontend depth in `W`-bit words**. For width `W`:

```text
LC = 2^ceil(log2(ceil(W/32)))
size_lanes = depth * LC
```

`LC` is 1, 2, 4, 8, or 16. Raw analysis still exposes `size_lanes`, `capacity_words=floor(size_lanes/LC)`, tail lanes, and backend window padding.

**Automatic addressing** allocates every physical port, including runtime-disabled ports:

```text
base[0] = 0
base[i+1] = base[i] + ceil(size_lanes[i] / 16)
```

This produces ascending, nonoverlapping 64-byte-beat windows. Confirming Automatic allocation replaces both bases and sizes from the current depths.

**Manual addressing** keeps bases editable and never relocates ports. Explicit depth or width edits normalize only the affected port's `size_lanes`; other ports and every base remain unchanged. Base-only edits analyze the raw map without depth normalization.

New configurations start in Automatic mode. Existing files open in Manual mode to preserve their exact raw map. Switching the displayed mode alone does not add a configuration field or rewrite the file. Legacy lane tails remain until an explicit depth/width edit or confirmed Automatic allocation. The mode is UI-only: there is no new schema, RTL, CSR, or runtime address-mode setting. The CLI can reproduce any automatic or manual map directly with `--port-base-beats` and `--port-size-lanes`.

## 7. Generated artifacts

Generation defaults to `--full-copy`. This includes every maintained core RTL file, both clock-mode constraints, and the integration/CSR references in addition to the configuration-specific artifacts. Use `--no-full-copy` on CLI `generate`, or clear **Copy complete integration sources** in the native Review page, to omit maintained-source copies. The setting affects generation/preview only; it is not stored in `config.json` and does not change the hardware configuration.

| Artifact | Purpose |
|---|---|
| `config.json` | Canonical accepted hardware configuration. |
| `logical/hades_sram_config_pkg.sv` | Parameters, all width/BE values, and flattened static vectors. |
| `logical/<module_name>.sv` | Separated-port consumer wrapper. |
| `logical/hades_sram_*.sv` | Full-copy maintained core sources, exact copies of `rtl/*.sv`. |
| `wrapper.f` | Output-root-relative generated package/wrapper filelist. Always emitted. |
| `static_rtl.f` | Separate ordered filelist of unchanging core RTL. Emitted with full copy; use the direct-RTL flow only. |
| `configure_ip.tcl` | For `ip`; creates/configures the catalog IP with readbacks. |
| `csr_init.tcl` | For CSR; bus-independent initialization and health checks. |
| `report/analysis.json` | Machine-readable clock, timing, address, capacity, bandwidth, and integration data. |
| `report/summary.txt` | Human-readable configuration report. |
| `report/report.html` | Self-contained report with inline generated graphs. |
| `report/overview.svg` | Clock-domain and integration diagram. |
| `report/timing.svg` | Exact-L request/response timing. |
| `report/slot_budget.svg` | TDMA budget and nominal eligibility offsets. |
| `report/memory_map.svg` | Backend beat windows and lane allocation. |
| `report/bandwidth.svg` | Payload and allocated backend demand. |
| `constraints/sram<i>_strict.xdc` | Strict frontend I/O timing for every physical port, including runtime-disabled ports. Always emitted. |
| `constraints/hades_sram_clocks_{sync,async}.xdc` | Full-copy maintained clock-mode/CDC constraints. |
| `docs/INTEGRATION_GUIDE.md`, `docs/csr_regmap.md` | Full-copy integration and register references. |
| `manifest.json` | Managed files, full-copy selection, and SHA-256 hashes used by check/force. |

CLI generation, native preview, and native generation use identical artifact bytes for the same canonical configuration and full-copy selection. Preview is in memory and performs no writes. Changing the selection invalidates old preview data. Forced regeneration removes stale managed files, including copied sources and `static_rtl.f` when switching to generated-only output; unrelated files are not deleted. Missing full-copy inputs are errors rather than a silent partial copy.

### Per-port interface timing

Each `constraints/sram<i>_strict.xdc` constrains `sram<i>_en`, `we`, `addr`, `wdata`, `be`, `rdata`, and `rvalid` against the existing `port_clk` using explicit maximum and minimum input/output delays. The generated 0 ns external-delay baseline is deliberately conservative and is exposed through named Tcl variables for editing to the actual upstream/downstream interface budget. Disabled byte-enable inputs remain constrained because their physical pins still exist.

Define the real `ui_clk` and `port_clk` clocks before reading these files. The per-port files complement the selected SYNC/ASYNC constraints and contain no false-path, clock-group, or multicycle exceptions. They are not XPR project files, do not create a clock, and do not establish timing signoff by themselves. Review external delays and run implementation timing/CDC checks on the final integration.

## 8. Direct RTL integration

Set `target` to `rtl`. The default full-copy output contains all sources needed by the wrapper, which instantiates `hades_sram_top` with parameter overrides. From the generated output root, use the two filelists separately with the selected simulator, for example:

```sh
vcs -full64 -sverilog -f static_rtl.f -f wrapper.f -top hades_sram_user
xvlog --sv -f static_rtl.f -f wrapper.f
```

Paths are relative to the generated output root. `static_rtl.f` is absent when full copy is disabled; in that mode reference maintained RTL separately and use `wrapper.f` for the generated sources. For packaged-IP targets, use `wrapper.f` rather than compiling another copy of the core.

- Active `sram<i>` interfaces expose configured widths; higher ports are tied off internally.
- CSR mode exposes AXI4-Lite; static mode exposes status and pin-level backdoor signals.
- Mode-inapplicable inputs are tied off safely.
- Do not overwrite maintained core, board, or testbench sources.

The generator does not create clocks or a MIG. Connect a 300 MHz MIG user interface, shared frontend clock, calibration, resets, AXI4, refresh, and ZQ signals as described in `INTEGRATION_GUIDE.md`.

## 9. Packaged Vivado IP integration

Set `target` to `ip` and first run:

```sh
vivado -mode batch -source ip/package_ip.tcl
```

In an open consumer project:

```tcl
set HADES_SRAM_NO_AUTO_CONFIGURE 1
source /path/to/generated/hades_sram/configure_ip.tcl
hades_sram_configure_ip /path/to/HADES-SRAM/ip/hades_sram_1.0
unset HADES_SRAM_NO_AUTO_CONFIGURE
add_files /path/to/generated/hades_sram/logical/hades_sram_config_pkg.sv
add_files /path/to/generated/hades_sram/logical/hades_sram_user.sv
set_property top hades_sram_user [current_fileset]
update_compile_order -fileset sources_1
```

The procedure adds the repository without replacing other paths, applies dependent parameters in order, checks readbacks, and runs `generate_target all`. It does not delete/recreate the project or replace an existing same-name IP. The consumer wrapper instantiates the configured Vivado module without overriding its parameters.

## 10. CSR and static configuration

For CSR, source `csr_init.tcl` after reset or a documented quiesce. Sourcing only defines procedures and performs no hardware access:

```tcl
hades_sram_init <write32-command> <read32-command> ?base-address? ?timeout-ms?
```

The procedure checks ID, disables the core, writes/reads latency, masks, maps, maintenance, and widths, waits for calibration and a healthy clock, enables the core, and requires READY without errors. Sparse CSR masks are supported. It does not start self-test or replace traffic quiescence.

Static mode places `P_L`, `P_PORT_EN`, `P_MIN_PERIOD`, `P_REFRESH_DIV`, `P_ZQ_DIV`, `P_PORT_BASE`, and `P_PORT_SIZE` directly in parameters. No CSR boot bus is required. Static enabled ports must form a contiguous prefix from port zero; use CSR for a sparse mask.

## 11. Frequency, timing, and plots

- `ui_clk` is 300 MHz; `port_clk` is user-supplied at 100–500 KHz. Configuration does not create a physical clock.
- The exact ratio is `300000000 / port_clock_hz`: 600:1 at 500 KHz and 3000:1 at 100 KHz. Non-integral ratios report physical and integer-cycle-model rates separately.
- The strict budget is `150 + 36 + CDC_OVHD + 4*N + 100 < TARGET_PERIOD_CYCLES`, with CDC overhead 4 SYNC or 12 ASYNC. Equality fails and physical N is used regardless of runtime enables.
- Reads return exactly L=1 or L=2 frontend cycles after acceptance; writes are posted. Slot offsets are nominal eligibility, not guaranteed MIG completion.
- Refresh time is `refresh_cycles / 300 MHz`; ZQ time is `zq_periods × requested port_clk period`.

The native Timing, Slot Budget, Memory Map, and Bandwidth plots and generated HTML/SVG plots use the same analytical values. **None is post-route WNS/TNS, CDC signoff, measured MIG latency, measured throughput, or board qualification.** Run implementation, timing/CDC review, and hardware tests separately.

## 12. Validation and diagnostics

Generation stops on errors and reports stable codes and field paths. Warnings remain visible. Checks cover types/ranges, identifiers, slot budget, clock/target/minimum consistency, address overflow/overlap/reach, lane tails, maintenance, self-test capacity/widths, and CSR/static masks. The self-test pattern generator supports 32/64-bit physical ports only, including runtime-disabled physical ports.

Common diagnostics:

- `E_OUTPUT_EXISTS`: choose another output or explicitly force replacement.
- `E_WIZARD_NOT_FOUND`: configure the native executable/product path or build the sibling products.
- `E_STATIC_MASK`: use a contiguous static prefix or CSR.
- `E_TARGET_OPTIMISTIC`, `E_MIN_BELOW_TARGET`, `E_MIN_PERIOD_CLOCK`: make clock and period controls consistent.
- `E_DEPTH_*`, `E_AUTO_MAP_OVERFLOW`: correct frontend depths or the aggregate automatic map.
- `E_ADDRESS_OVERLAP`, `E_BACKEND_OVERFLOW`, `E_AW_REACH`: adjust bases, sizes, or AW using the reported units.

## 13. Verification commands

From the source root:

```sh
python3 -m unittest discover -s tools/tests -v
make -C sim check_generator
make -C sim check_wizard
make -C sim check_wizard_windows
vivado -mode batch -source ip/package_ip.tcl
make -C sim check_generator_ip
```

`check_generator` runs backend/CLI/protocol/native-launcher tests and generated RTL smoke. `check_wizard` runs the real sibling native integration workflow and packages the provider for Linux and Windows products. `check_wizard_windows` performs native Windows core/SWT tests and packaged Automatic/Manual GUI workflows through Windows-local staging. `check_generator_ip` requires the generated catalog package. None of these commands programs a board.
