//-----------------------------------------------------------------------------
// HADES-SRAM testbench — C++ side (DPI-C).
// Owns "test intent": expected-value models (ID/PARAMS, indexed-window
// register model), per-port expected SRAM contents, per-port due-cycle
// queues for exact read-latency checking (T2), pass/fail accounting.
// Pin-level protocol lives in sim/tb/tb_hades_top.sv.
// Compiles for both VCS and Vivado xsim.
//-----------------------------------------------------------------------------
#include "svdpi.h"
#include <cstdint>
#include <cstdio>
#include <queue>
#include <unordered_map>

namespace {

constexpr int kMaxPorts = 64;

int      g_err   = 0;
int      g_check = 0;
uint64_t g_base[kMaxPorts];
uint32_t g_size[kMaxPorts];

// expected SRAM contents: key = (port << 32) | word_addr
std::unordered_map<uint64_t, uint32_t> g_mem;

// per-port expected read releases, in request order
struct ExpRd {
  uint64_t due_cycle;
  uint32_t data;
};
std::queue<ExpRd> g_exp[kMaxPorts];

void fail(const char* what, long long a, long long b) {
  g_err++;
  printf("[HADES-TB] FAIL: %s (0x%llx vs 0x%llx)\n", what,
         (unsigned long long)a, (unsigned long long)b);
}

}  // namespace

extern "C" {

void hades_init() {
  g_err = 0;
  g_check = 0;
  for (int i = 0; i < kMaxPorts; i++) {
    g_base[i] = 0;
    g_size[i] = 0;
    while (!g_exp[i].empty()) g_exp[i].pop();
  }
  g_mem.clear();
  printf("[HADES-TB] C++ model initialized\n");
}

// between test phases: drop pending expectations (DUT contents persist,
// like real DDR); error/check accounting keeps accumulating
void hades_phase_init() {
  for (int i = 0; i < kMaxPorts; i++)
    while (!g_exp[i].empty()) g_exp[i].pop();
}

// ---------------------------------------------------------------- models ---

long long hades_exp_id() { return 0xADE50100LL; }

// PARAMS word: bit31=CLK_MODE(1=SYNC), [30:20]=ui_mhz, [19:12]=port_mib,
// [11:8]=dw/8, [7:0]=n_max
long long hades_exp_params(int is_sync, int ui_mhz, int port_mib, int dw, int n_max) {
  uint32_t v = ((uint32_t)(is_sync & 0x1) << 31) | (((uint32_t)ui_mhz & 0x7FF) << 20) |
               (((uint32_t)port_mib & 0xFF) << 12) | (((uint32_t)(dw / 8) & 0xF) << 8) |
               ((uint32_t)n_max & 0xFF);
  return (long long)(uint64_t)v;   // zero-extended: SV register reads are unsigned
}

void hades_set_port_cfg(int port, long long base, int size) {
  if (port >= 0 && port < kMaxPorts) {
    g_base[port] = (uint64_t)base;
    g_size[port] = (uint32_t)size;
  }
}

long long hades_exp_base(int port) { return (long long)g_base[port & (kMaxPorts - 1)]; }
int       hades_exp_size(int port) { return (int)g_size[port & (kMaxPorts - 1)]; }

// ------------------------------------------------- expected memory model ---

void hades_mem_write(int port, int addr, int data) {
  g_mem[((uint64_t)port << 32) | (uint32_t)addr] = (uint32_t)data;
}

// a read issued to `port` for `addr` must release exactly at `due_cycle`
void hades_read_expect(int port, long long due_cycle, int addr) {
  uint64_t k = ((uint64_t)port << 32) | (uint32_t)addr;
  auto it = g_mem.find(k);
  g_exp[port & (kMaxPorts - 1)].push(
      {(uint64_t)due_cycle, it == g_mem.end() ? 0u : it->second});
}

// a read to an illegal address returns 0 on schedule (synthetic response)
void hades_read_expect0(int port, long long due_cycle) {
  g_exp[port & (kMaxPorts - 1)].push({(uint64_t)due_cycle, 0u});
}

// called for every port at every port_clk edge (post-edge sample):
// rvalid must be 1 iff the head of the port's queue is due this cycle
void hades_port_edge(int port, long long cycle, int rvalid, int rdata) {
  auto& q = g_exp[port & (kMaxPorts - 1)];
  if (!q.empty() && q.front().due_cycle == (uint64_t)cycle) {
    g_check++;
    if (!rvalid) {
      g_err++;
      printf("[HADES-TB] FAIL: port %d missing rvalid at cycle %lld (T2 violation)\n",
             port, cycle);
    } else if ((uint32_t)rdata != q.front().data) {
      g_err++;
      printf("[HADES-TB] FAIL: port %d cycle %lld data got=0x%08x exp=0x%08x\n",
             port, cycle, (uint32_t)rdata, q.front().data);
    }
    q.pop();
  } else if (rvalid) {
    g_err++;
    printf("[HADES-TB] FAIL: port %d unexpected/early rvalid at cycle %lld (T2 violation)\n",
           port, cycle);
  }
}

// ------------------------------------------------------------ check helpers ---

void hades_check_eq(const char* what, long long got, long long exp) {
  g_check++;
  if ((uint64_t)got != (uint64_t)exp) fail(what, got, exp);
  else printf("[HADES-TB] ok:   %-28s = 0x%llx\n", what, (unsigned long long)got);
}

void hades_check_range(const char* what, long long got, long long lo, long long hi) {
  g_check++;
  if (got < lo || got > hi) {
    g_err++;
    printf("[HADES-TB] FAIL: %-28s got=%lld, want [%lld, %lld]\n", what, got, lo, hi);
  } else {
    printf("[HADES-TB] ok:   %-28s = %lld in [%lld, %lld]\n", what, got, lo, hi);
  }
}

void hades_fail(const char* msg) {
  g_err++;
  printf("[HADES-TB] FAIL: %s\n", msg);
}

void hades_log(const char* msg) { printf("[HADES-TB] %s\n", msg); }

int  hades_err_count() { return g_err; }

void hades_report() {
  printf("[HADES-TB] checks=%d errors=%d\n", g_check, g_err);
}

}  // extern "C"
