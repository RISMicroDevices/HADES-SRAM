# HADES-SRAM simulation entry point.
#   make            -> SIM=vcs (default): T6-basic + static smoke + param-override
#   make SIM=xsim   -> same tests under Vivado xsim
#   make lint       -> xvlog/xelab elaboration gate, both CSR_EN variants
#   make check_bounds -> static slot-budget assertion spot-checks (T11 preview)
#   make clean

SIM      ?= vcs
VCS      := /home/kumon/Synopsys/vcs/X-2025.06/bin/vcs
VIVADO   := /home/kumon/Xilinx/Vivado/2024.1
VIVADO_BIN := $(VIVADO)/bin
BUILD    := build

RTL := ../rtl/hades_pkg.sv ../rtl/hades_cdc.sv ../rtl/hades_freq_mon.sv \
       ../rtl/hades_csr.sv ../rtl/hades_port.sv ../rtl/hades_sram_top.sv
TB  := tb/tb_hades_top.sv
CPP := cpp/hades_tb.cpp

RTL_ABS := $(abspath $(RTL))
TB_ABS  := $(abspath $(TB))
CPP_ABS := $(abspath $(CPP))

.PHONY: test test-vcs test-xsim lint check_bounds clean
test: test-$(SIM)

# ---------------------------------------------------------------- VCS ------
# Variants: csr (CSR_EN=1) / static (CSR_EN=0) / ovrd (CSR_EN=0 + param override)
VCS_COMMON := -full64 -sverilog -timescale=1ns/1ps -top tb_hades_top

$(BUILD)/vcs_csr/simv: $(RTL) $(TB) $(CPP)
	@mkdir -p $(@D)
	cd $(@D) && $(VCS) $(VCS_COMMON) $(RTL_ABS) $(TB_ABS) $(CPP_ABS) -o simv > compile.log 2>&1 \
	  || { echo "VCS compile FAILED ($@)"; tail -30 $(@D)/compile.log; exit 1; }

$(BUILD)/vcs_static/simv: $(RTL) $(TB) $(CPP)
	@mkdir -p $(@D)
	cd $(@D) && $(VCS) $(VCS_COMMON) +define+CSR_STATIC $(RTL_ABS) $(TB_ABS) $(CPP_ABS) -o simv > compile.log 2>&1 \
	  || { echo "VCS compile FAILED ($@)"; tail -30 $(@D)/compile.log; exit 1; }

$(BUILD)/vcs_ovrd/simv: $(RTL) $(TB) $(CPP)
	@mkdir -p $(@D)
	cd $(@D) && $(VCS) $(VCS_COMMON) +define+CSR_STATIC+PARAM_OVRD $(RTL_ABS) $(TB_ABS) $(CPP_ABS) -o simv > compile.log 2>&1 \
	  || { echo "VCS compile FAILED ($@)"; tail -30 $(@D)/compile.log; exit 1; }

test-vcs: $(BUILD)/vcs_csr/simv $(BUILD)/vcs_static/simv $(BUILD)/vcs_ovrd/simv
	@fail=0; \
	for cfg in "csr t6_csr" "static static_smoke" "ovrd static_smoke"; do \
	  set -- $$cfg; \
	  echo "=== VCS $$1 TEST=$$2 ==="; \
	  ./$(BUILD)/vcs_$$1/simv +TEST=$$2 > $(BUILD)/vcs_$$1/run.log 2>&1; \
	  grep -E "HADES-TB\] (FAIL|checks)" $(BUILD)/vcs_$$1/run.log | tail -5; \
	  grep -q HADES_TEST_PASS $(BUILD)/vcs_$$1/run.log \
	    && echo "VCS $$1: PASS" || { echo "VCS $$1: FAIL (see $(BUILD)/vcs_$$1/run.log)"; fail=1; }; \
	done; \
	[ $$fail -eq 0 ] && echo "ALL VCS TESTS PASS" || exit 1

# ---------------------------------------------------------------- xsim -----
XSIM_DEF_csr    :=
XSIM_DEF_static := --define CSR_STATIC
XSIM_DEF_ovrd   := --define CSR_STATIC --define PARAM_OVRD

$(BUILD)/xsim_%/snap: $(RTL) $(TB) $(CPP)
	@mkdir -p $(@D)
	cd $(@D) && $(VIVADO_BIN)/xvlog --sv $(XSIM_DEF_$*) $(RTL_ABS) $(TB_ABS) > compile.log 2>&1 \
	  || { echo "xvlog FAILED ($@)"; tail -30 $(@D)/compile.log; exit 1; }
	cd $(@D) && g++ -shared -fPIC -I$(VIVADO)/data/xsim/include $(CPP_ABS) -o hadesdpi.so >> compile.log 2>&1
	cd $(@D) && $(VIVADO_BIN)/xelab --timescale 1ns/1ps -top tb_hades_top -snapshot snap -sv_root . -sv_lib hadesdpi >> compile.log 2>&1 \
	  || { echo "xelab FAILED ($@)"; tail -30 $(@D)/compile.log; exit 1; }

test-xsim: $(BUILD)/xsim_csr/snap $(BUILD)/xsim_static/snap $(BUILD)/xsim_ovrd/snap
	@fail=0; \
	for cfg in "csr t6_csr" "static static_smoke" "ovrd static_smoke"; do \
	  set -- $$cfg; \
	  echo "=== xsim $$1 TEST=$$2 ==="; \
	  cd $(BUILD)/xsim_$$1 && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=$$2 > run.log 2>&1; cd ../..; \
	  grep -E "HADES-TB\] (FAIL|checks)" $(BUILD)/xsim_$$1/run.log | tail -5; \
	  grep -q HADES_TEST_PASS $(BUILD)/xsim_$$1/run.log \
	    && echo "xsim $$1: PASS" || { echo "xsim $$1: FAIL (see $(BUILD)/xsim_$$1/run.log)"; fail=1; }; \
	done; \
	[ $$fail -eq 0 ] && echo "ALL XSIM TESTS PASS" || exit 1

# ---------------------------------------------------------------- gates ----
lint:
	@mkdir -p $(BUILD)/lint_csr $(BUILD)/lint_static
	cd $(BUILD)/lint_csr    && $(VIVADO_BIN)/xvlog --sv $(RTL_ABS) > compile.log 2>&1 \
	  && $(VIVADO_BIN)/xelab --timescale 1ns/1ps hades_sram_top -generic_top "CSR_EN=1" >> compile.log 2>&1 \
	  && echo "lint csr:    ELAB OK" || { echo "lint csr FAILED"; tail -20 compile.log; exit 1; }
	cd $(BUILD)/lint_static && $(VIVADO_BIN)/xvlog --sv $(RTL_ABS) > compile.log 2>&1 \
	  && $(VIVADO_BIN)/xelab --timescale 1ns/1ps hades_sram_top -generic_top "CSR_EN=0" >> compile.log 2>&1 \
	  && echo "lint static: ELAB OK" || { echo "lint static FAILED"; tail -20 compile.log; exit 1; }

check_bounds:
	@mkdir -p $(BUILD)/bounds
	@echo "--- N=128 @500KHz must FAIL elaboration ---"
	@if cd $(BUILD)/bounds && $(VCS) -full64 -sverilog -timescale=1ns/1ps $(RTL_ABS) \
	    -top hades_sram_top -pvalue+hades_sram_top.N=128 -o nb_fail > nb_fail.log 2>&1; \
	  then echo "FAIL: budget assertion did not fire (VCS)"; exit 1; \
	  else echo "PASS: VCS rejected N=128@500KHz"; fi
	@if cd $(BUILD)/bounds && $(VIVADO_BIN)/xvlog --sv $(RTL_ABS) > nb_xfail.log 2>&1 \
	    && $(VIVADO_BIN)/xelab --timescale 1ns/1ps hades_sram_top -generic_top "N=128" >> nb_xfail.log 2>&1; \
	  then echo "FAIL: budget assertion did not fire (xelab)"; exit 1; \
	  else echo "PASS: xelab rejected N=128@500KHz"; fi
	@echo "--- N=128 @100KHz must PASS elaboration ---"
	@cd $(BUILD)/bounds && $(VCS) -full64 -sverilog -timescale=1ns/1ps $(RTL_ABS) \
	    -top hades_sram_top -pvalue+hades_sram_top.N=128 \
	    -pvalue+hades_sram_top.TARGET_PERIOD_CYCLES=3000 -o nb_pass > nb_pass.log 2>&1 \
	  && echo "PASS: VCS accepted N=128@100KHz" || { echo "FAIL: N=128@100KHz should elaborate"; exit 1; }

clean:
	rm -rf $(BUILD)
