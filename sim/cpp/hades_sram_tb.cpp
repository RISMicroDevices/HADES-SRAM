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
#include <array>
#include <queue>
#include <unordered_map>

namespace {

constexpr int kMaxPorts = 64;

int      g_err   = 0;
int      g_check = 0;
uint64_t g_base[kMaxPorts];
uint32_t g_size[kMaxPorts];
uint32_t g_width[kMaxPorts];   // bits per port word (v1.1.0), default 32
uint32_t g_wshift[kMaxPorts];  // log2 lane count, pow2(ceil(W/32))
uint32_t g_wbytes[kMaxPorts];  // ceil(W/8)

// expected SRAM contents: key = (port << 32) | word_addr (in W-bit words);
// value = the full 512-bit channel image, LSB-justified
using Word = std::array<uint32_t, 16>;
std::unordered_map<uint64_t, Word> g_mem;

// per-port expected read releases, in request order
struct ExpRd {
  uint64_t due_cycle;
  Word     data;
  bool     late;   // T14: data arrives late; rvalid on schedule, data don't-care
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
    g_width[i] = 32;
    g_wshift[i] = 0;
    g_wbytes[i] = 4;
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

// reset-recovery tests: suppress the due-cycle checks while a reset wipes
// in-flight traffic (their expectations are then dropped by phase_init)
int g_suspend = 0;
void hades_suspend_checks(int on) { g_suspend = on; }

// ---------------------------------------------------------------- models ---

long long hades_exp_id() { return 0xADE50110LL; }

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

// per-port width in bits (v1.1.0): 1..512, elaboration-fixed
void hades_set_port_width(int port, int bits) {
  if (port < 0 || port >= kMaxPorts) return;
  g_width[port]  = (uint32_t)bits;
  uint32_t lc = ((uint32_t)bits + 31) / 32;   // lane count, then pow2
  g_wshift[port] = lc <= 1 ? 0 : lc <= 2 ? 1 : lc <= 4 ? 2 : lc <= 8 ? 3 : 4;
  g_wbytes[port] = ((uint32_t)bits + 7) / 8;
}

long long hades_exp_base(int port) { return (long long)g_base[port & (kMaxPorts - 1)]; }
int       hades_exp_size(int port) { return (int)g_size[port & (kMaxPorts - 1)]; }

// ------------------------------------------------- expected memory model ---

void hades_mem_write(int port, int addr, const svBitVecVal* data) {
  Word w;
  for (int i = 0; i < 16; i++) w[i] = data[i];
  g_mem[((uint64_t)port << 32) | (uint32_t)addr] = w;
}

// byte-enabled write (v1.1.0 BE): merge only enabled bytes of the word
void hades_mem_write_be(int port, int addr, const svBitVecVal* data, long long be) {
  Word& cur = g_mem[((uint64_t)port << 32) | (uint32_t)addr];
  uint32_t nb = g_wbytes[port & (kMaxPorts - 1)];
  for (uint32_t b = 0; b < nb; b++) {
    if ((be >> b) & 1LL) {
      uint32_t from = ((uint32_t)data[b / 4] >> ((b % 4) * 8)) & 0xFFu;
      cur[b / 4] = (cur[b / 4] & ~(0xFFu << ((b % 4) * 8))) | (from << ((b % 4) * 8));
    }
  }
}

// a read issued to `port` for `addr` must release exactly at `due_cycle`
void hades_read_expect(int port, long long due_cycle, int addr) {
  uint64_t k = ((uint64_t)port << 32) | (uint32_t)addr;
  auto it = g_mem.find(k);
  ExpRd e;
  e.due_cycle = (uint64_t)due_cycle;
  e.late = false;
  if (it == g_mem.end()) e.data.fill(0u);
  else                   e.data = it->second;
  g_exp[port & (kMaxPorts - 1)].push(e);
}

// a read to an illegal address returns 0 on schedule (synthetic response)
void hades_read_expect0(int port, long long due_cycle) {
  ExpRd e;
  e.due_cycle = (uint64_t)due_cycle;
  e.late = false;
  e.data.fill(0u);
  g_exp[port & (kMaxPorts - 1)].push(e);
}

// T14 fault injection: the response is expected to arrive late, so the data
// released on schedule is don't-care — but rvalid must still assert exactly
// at `due_cycle` (the cycle-level contract stays observable, spec 4.3)
void hades_read_expect_late(int port, long long due_cycle) {
  ExpRd e;
  e.due_cycle = (uint64_t)due_cycle;
  e.late = true;
  e.data.fill(0u);
  g_exp[port & (kMaxPorts - 1)].push(e);
}

// called for every port at every port_clk edge (post-edge sample):
// rvalid must be 1 iff the head of the port's queue is due this cycle
void hades_port_edge(int port, long long cycle, int rvalid, const svBitVecVal* rdata) {
  if (g_suspend) return;   // reset-recovery window: in-flight state wiped
  int p = port & (kMaxPorts - 1);
  auto& q = g_exp[p];
  if (!q.empty() && q.front().due_cycle == (uint64_t)cycle) {
    g_check++;
    if (!rvalid) {
      g_err++;
      printf("[HADES-TB] FAIL: port %d missing rvalid at cycle %lld (T2 violation)\n",
             p, cycle);
    } else if (!q.front().late) {
      uint32_t nb = g_width[p];
      for (uint32_t b = 0; b < nb; b++) {
        int got = (rdata[b / 32] >> (b % 32)) & 1;
        int exp = (q.front().data[b / 32] >> (b % 32)) & 1;
        if (got != exp) {
          g_err++;
          printf("[HADES-TB] FAIL: port %d cycle %lld data bit %u got=%d exp=%d\n",
                 p, cycle, b, got, exp);
          printf("[HADES-TB]   got  w0=%08x w1=%08x w2=%08x w3=%08x\n",
                 rdata[0], rdata[1], rdata[2], rdata[3]);
          printf("[HADES-TB]   exp  w0=%08x w1=%08x w2=%08x w3=%08x\n",
                 q.front().data[0], q.front().data[1], q.front().data[2], q.front().data[3]);
          break;
        }
      }
    }
    q.pop();
  } else if (rvalid) {
    g_err++;
    printf("[HADES-TB] FAIL: port %d unexpected/early rvalid at cycle %lld (T2 violation)\n",
           p, cycle);
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
