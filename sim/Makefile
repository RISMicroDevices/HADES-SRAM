# HADES-SRAM simulation entry point.
#   make              -> SIM=vcs (default): all variants + T11 check_bounds
#   make SIM=xsim     -> same tests under Vivado xsim (reduced OPS)
#   make lint         -> xvlog/xelab elaboration gate, both CSR_EN variants
#   make check_bounds -> static slot-budget assertion spot-checks (T11)
#   make clean
#
# Variants:  csr (CSR_EN=1 SYNC) | csr_async (CSR_EN=1 ASYNC) |
#            static (CSR_EN=0 SYNC) | ovrd (CSR_EN=0 SYNC + param override)
# Extra runs per csr/csr_async/static build: T3 with +MAINT_STRESS=1 (worst
# maintenance alignment), T14 with +RD_LAT_ADD=1500 (bit5 sentinel fault).

SIM      ?= vcs
VCS      := /home/kumon/Synopsys/vcs/X-2025.06/bin/vcs
VIVADO   := /home/kumon/Xilinx/Vivado/2024.1
VIVADO_BIN := $(VIVADO)/bin
BUILD    := build

RTL := ../rtl/hades_pkg.sv ../rtl/hades_cdc.sv ../rtl/hades_freq_mon.sv \
       ../rtl/hades_csr.sv ../rtl/hades_port.sv ../rtl/hades_timing_shaper.sv \
       ../rtl/hades_mig_if.sv ../rtl/hades_refresh_sched.sv \
       ../rtl/hades_arbiter.sv ../rtl/hades_backdoor.sv ../rtl/hades_sram_top.sv
TB  := tb/tb_hades_top.sv
MDL := model/mig_axi4_model.sv
CPP := cpp/hades_tb.cpp

RTL_ABS := $(abspath $(RTL))
TB_ABS  := $(abspath $(TB))
MDL_ABS := $(abspath $(MDL))
CPP_ABS := $(abspath $(CPP))

OPS_vcs  := 100000
OPS_xsim := 10000

.PHONY: test test-vcs test-xsim lint check_bounds clean
test: test-$(SIM) check_bounds

# ----------------------------------------------------------------- VCS -----
VCS_COMMON := -full64 -sverilog -timescale=1ns/1ps -top tb_hades_top

DEF_csr       :=
DEF_csr_async := +define+ASYNC
DEF_static    := +define+CSR_STATIC
DEF_ovrd      := +define+CSR_STATIC+PARAM_OVRD

TEST_csr       := all_csr
TEST_csr_async := all_csr
TEST_static    := all_static
TEST_ovrd      := all_static

VCS_VARIANTS := csr csr_async static ovrd

$(BUILD)/vcs_%/simv: $(RTL) $(TB) $(MDL) $(CPP)
	@mkdir -p $(@D)
	cd $(@D) && $(VCS) $(VCS_COMMON) $(DEF_$*) $(RTL_ABS) $(TB_ABS) $(MDL_ABS) $(CPP_ABS) \
	  -o simv > compile.log 2>&1 \
	  || { echo "VCS compile FAILED ($@)"; tail -40 compile.log; exit 1; }

test-vcs: $(foreach v,$(VCS_VARIANTS),$(BUILD)/vcs_$(v)/simv)
	@fail=0; \
	for v in $(VCS_VARIANTS); do \
	  t=$(TEST_csr); [ $$v = csr ] || [ $$v = csr_async ] && t=all_csr || t=all_static; \
	  echo "=== VCS $$v TEST=$$t OPS=$(OPS_vcs) ==="; \
	  ./$(BUILD)/vcs_$$v/simv +TEST=$$t +OPS=$(OPS_vcs) > $(BUILD)/vcs_$$v/run.log 2>&1; \
	  grep -E "HADES-TB\] (FAIL|checks)" $(BUILD)/vcs_$$v/run.log | tail -8; \
	  grep -q HADES_TEST_PASS $(BUILD)/vcs_$$v/run.log \
	    && echo "VCS $$v: PASS" || { echo "VCS $$v: FAIL (see $(BUILD)/vcs_$$v/run.log)"; fail=1; }; \
	done; \
	for v in csr csr_async; do \
	  echo "=== VCS $$v TEST=t3 +MAINT_STRESS=1 ==="; \
	  ./$(BUILD)/vcs_$$v/simv +TEST=t3 +MAINT_STRESS=1 > $(BUILD)/vcs_$$v/run_t3s.log 2>&1; \
	  grep -q HADES_TEST_PASS $(BUILD)/vcs_$$v/run_t3s.log \
	    && echo "VCS $$v t3-stress: PASS" \
	    || { echo "VCS $$v t3-stress: FAIL (see $(BUILD)/vcs_$$v/run_t3s.log)"; fail=1; }; \
	done; \
	for v in csr csr_async static; do \
	  echo "=== VCS $$v TEST=t14 +RD_LAT_ADD=1500 ==="; \
	  ./$(BUILD)/vcs_$$v/simv +TEST=t14 +RD_LAT_ADD=1500 > $(BUILD)/vcs_$$v/run_t14.log 2>&1; \
	  grep -q HADES_TEST_PASS $(BUILD)/vcs_$$v/run_t14.log \
	    && echo "VCS $$v t14: PASS" \
	    || { echo "VCS $$v t14: FAIL (see $(BUILD)/vcs_$$v/run_t14.log)"; fail=1; }; \
	done; \
	[ $$fail -eq 0 ] && echo "ALL VCS TESTS PASS" || exit 1

# ---------------------------------------------------------------- xsim -----
$(BUILD)/xsim_%/snap: $(RTL) $(TB) $(MDL) $(CPP)
	@mkdir -p $(@D)
	cd $(@D) && $(VIVADO_BIN)/xvlog --sv $(XSIM_DEF_$*) $(RTL_ABS) $(TB_ABS) $(MDL_ABS) > compile.log 2>&1 \
	  || { echo "xvlog FAILED ($@)"; tail -30 compile.log; exit 1; }
	cd $(@D) && g++ -shared -fPIC -static-libstdc++ -static-libgcc \
	  -I$(VIVADO)/data/xsim/include $(CPP_ABS) -o hadesdpi.so >> compile.log 2>&1
	cd $(@D) && $(VIVADO_BIN)/xelab --timescale 1ns/1ps -top tb_hades_top -snapshot snap \
	  -sv_root . -sv_lib hadesdpi >> compile.log 2>&1 \
	  || { echo "xelab FAILED ($@)"; tail -30 compile.log; exit 1; }

XSIM_DEF_csr       :=
XSIM_DEF_csr_async := --define ASYNC
XSIM_DEF_static    := --define CSR_STATIC
XSIM_DEF_ovrd      := --define CSR_STATIC --define PARAM_OVRD

XSIM_VARIANTS := csr csr_async static ovrd

test-xsim: $(foreach v,$(XSIM_VARIANTS),$(BUILD)/xsim_$(v)/snap)
	@fail=0; \
	for v in $(XSIM_VARIANTS); do \
	  t=all_static; [ $$v = csr ] || [ $$v = csr_async ] && t=all_csr; \
	  echo "=== xsim $$v TEST=$$t OPS=$(OPS_xsim) ==="; \
	  cd $(BUILD)/xsim_$$v && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=$$t \
	    -testplusarg OPS=$(OPS_xsim) > run.log 2>&1; cd ../..; \
	  grep -E "HADES-TB\] (FAIL|checks)" $(BUILD)/xsim_$$v/run.log | tail -8; \
	  grep -q HADES_TEST_PASS $(BUILD)/xsim_$$v/run.log \
	    && echo "xsim $$v: PASS" || { echo "xsim $$v: FAIL (see $(BUILD)/xsim_$$v/run.log)"; fail=1; }; \
	done; \
	for v in csr csr_async; do \
	  echo "=== xsim $$v TEST=t3 MAINT_STRESS=1 ==="; \
	  cd $(BUILD)/xsim_$$v && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=t3 \
	    -testplusarg MAINT_STRESS=1 > run_t3s.log 2>&1; cd ../..; \
	  grep -q HADES_TEST_PASS $(BUILD)/xsim_$$v/run_t3s.log \
	    && echo "xsim $$v t3-stress: PASS" \
	    || { echo "xsim $$v t3-stress: FAIL (see $(BUILD)/xsim_$$v/run_t3s.log)"; fail=1; }; \
	done; \
	for v in csr csr_async static; do \
	  echo "=== xsim $$v TEST=t14 RD_LAT_ADD=1500 ==="; \
	  cd $(BUILD)/xsim_$$v && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=t14 \
	    -testplusarg RD_LAT_ADD=1500 > run_t14.log 2>&1; cd ../..; \
	  grep -q HADES_TEST_PASS $(BUILD)/xsim_$$v/run_t14.log \
	    && echo "xsim $$v t14: PASS" \
	    || { echo "xsim $$v t14: FAIL (see $(BUILD)/xsim_$$v/run_t14.log)"; fail=1; }; \
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
	@echo "--- N=64 @500KHz must PASS elaboration ---"
	@cd $(BUILD)/bounds && $(VCS) -full64 -sverilog -timescale=1ns/1ps $(RTL_ABS) \
	    -top hades_sram_top -o nb_ok64 > nb_ok64.log 2>&1 \
	  && echo "PASS: VCS accepted N=64@500KHz" \
	  || { echo "FAIL: N=64@500KHz should elaborate"; tail -20 nb_ok64.log; exit 1; }
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
	@cd $(BUILD)/bounds && $(VIVADO_BIN)/xvlog --sv $(RTL_ABS) > nb_xpass.log 2>&1 \
	  && $(VIVADO_BIN)/xelab --timescale 1ns/1ps hades_sram_top -generic_top "N=128" \
	    -generic_top "TARGET_PERIOD_CYCLES=3000" >> nb_xpass.log 2>&1 \
	  && echo "PASS: xelab accepted N=128@100KHz" || { echo "FAIL: N=128@100KHz should elaborate (xelab)"; exit 1; }

clean:
	rm -rf $(BUILD)
