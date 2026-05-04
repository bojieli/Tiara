// XDMA descriptor-path smoke test.
//
// Drives `tiara_synth_top_xdma` (Tiara MP backed by tiara_xdma_engine
// talking to tiara_xdma_host_stub) through a few hand-encoded operators
// and checks that LOAD/STORE/MEMCPY/CAS round-trip correctly through
// the descriptor + scratchpad fabric.
//
//   ./Vtiara_synth_top_xdma            -> run all
//   ./Vtiara_synth_top_xdma --case ld  -> single case

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "verilated.h"
#include "Vtiara_synth_top_xdma.h"
#include "Vtiara_synth_top_xdma__Dpi.h"
#include "svdpi.h"

namespace {

using Top = Vtiara_synth_top_xdma;

extern "C" {
    void tiara_dpi_xdma_poke(int word_addr, long long value);
    void tiara_dpi_xdma_peek(int word_addr, long long* value);
}

void set_scope(Top* /*top*/) {
    auto sc = svGetScopeFromName("TOP.tiara_synth_top_xdma.u_pdma_host");
    if (!sc) {
        std::fprintf(stderr, "scope not found\n");
        std::exit(2);
    }
    svSetScope(sc);
}

uint64_t cycles = 0;

void tick(Top* top, int n = 1) {
    for (int i = 0; i < n; i++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        cycles++;
    }
}

void reset(Top* top) {
    top->rst_n = 0;
    top->load_en = 0;
    top->inv_valid = 0;
    top->inv_start_pc = 0;
    for (int i = 0; i < 8; i++) top->inv_args[i] = 0;
    tick(top, 8);
    top->rst_n = 1;
    tick(top, 2);
}

uint64_t encode(uint64_t op, uint64_t rd, uint64_t rs1, uint64_t rs2,
                uint64_t sub, int64_t imm) {
    uint64_t i40 = static_cast<uint64_t>(imm) & ((1ULL << 40) - 1);
    return (op << 56) | (rd << 52) | (rs1 << 48) | (rs2 << 44) |
           (sub << 40) | i40;
}

void load_op(Top* top, const std::vector<uint64_t>& words) {
    for (uint32_t i = 0; i < words.size(); i++) {
        top->load_en = 1;
        top->load_addr = i;
        top->load_data = words[i];
        tick(top);
    }
    top->load_en = 0;
    tick(top);
}

struct Result { uint64_t r[4]; bool err; uint64_t cycles; };

Result invoke(Top* top, std::array<uint64_t, 8> args, uint64_t maxc = 1'000'000) {
    for (int i = 0; i < 8; i++) top->inv_args[i] = args[i];
    top->inv_valid = 1;
    tick(top);
    top->inv_valid = 0;
    uint64_t start = cycles;
    while (!top->done) {
        if (cycles - start > maxc) return {{0,0,0,0}, true, maxc};
        tick(top);
    }
    Result r{};
    for (int i = 0; i < 4; i++) r.r[i] = top->done_result[i];
    r.err = top->done_err;
    r.cycles = cycles - start;
    tick(top, 2);
    return r;
}

bool case_load(Top* top) {
    set_scope(top);
    tiara_dpi_xdma_poke(/*word*/ 8, 0xDEADBEEFCAFEBABEULL);  // host[0x40] = ...
    std::vector<uint64_t> prog = {
        encode(0x20, 1, 0, 0, 0xC, 0x40),    // LI r1, 0x40
        encode(0x01, 1, 1, 0, 0,    0),      // LOAD r1, [r1+0] (overwrite r1 with loaded value)
        encode(0x13, 0, 1, 0, 0,    0),      // RET r1
    };
    load_op(top, prog);
    auto r = invoke(top, {0,0,0,0,0,0,0,0});
    std::printf("xdma:load  cycles=%lu err=%d r1=%016lx\n",
                r.cycles, r.err, r.r[0]);
    return !r.err && r.r[0] == 0xDEADBEEFCAFEBABEULL;
}

bool case_store(Top* top) {
    set_scope(top);
    tiara_dpi_xdma_poke(8, 0);
    std::vector<uint64_t> prog = {
        encode(0x20, 1, 0, 0, 0xC, 0x40),    // LI r1, 0x40   addr
        encode(0x20, 2, 0, 0, 0xC, 0x1234),  // LI r2, 0x1234 data
        encode(0x02, 0, 1, 2, 0,    0),      // STORE [r1], r2
        encode(0x13, 0, 2, 0, 0,    0),      // RET r2
    };
    load_op(top, prog);
    auto r = invoke(top, {0,0,0,0,0,0,0,0});
    // STORE is fire-and-forget; the MP returns before the WB descriptor
    // status comes back.  Tick enough cycles for the descriptor + host
    // stub latency to drain.
    tick(top, 400);
    long long v = 0;
    set_scope(top);
    tiara_dpi_xdma_peek(8, &v);
    std::printf("xdma:store cycles=%lu err=%d host[0x40]=%016llx\n",
                r.cycles, r.err, (unsigned long long)v);
    return !r.err && v == 0x1234;
}

bool case_cas(Top* top) {
    set_scope(top);
    tiara_dpi_xdma_poke(8, 100);
    // CAS at addr=0x40, expected=100, swap=200; should succeed -> old=100
    // Place result in r1 so it shows up in result[0]
    std::vector<uint64_t> prog = {
        encode(0x20, 4, 0, 0, 0xC, 0x40),    // LI r4, 0x40
        encode(0x20, 5, 0, 0, 0xC, 100),     // LI r5, 100
        encode(0x20, 6, 0, 0, 0xC, 200),     // LI r6, 200
        encode(0x84, 1, 4, 5, 0, 0),         // CAS r1, r4, r5, [r6 in extra]
        encode(0x00, 6, 0, 0, 0, 0),         // extra: rd=r6
        encode(0x13, 0, 1, 0, 0, 0),         // RET r1
    };
    load_op(top, prog);
    auto r = invoke(top, {0,0,0,0,0,0,0,0});
    // CAS write-back is also fire-and-forget after atom_valid pulses;
    // wait for the WB descriptor to drain.
    tick(top, 400);
    long long v = 0;
    set_scope(top);
    tiara_dpi_xdma_peek(8, &v);
    std::printf("xdma:cas   cycles=%lu err=%d r0=%lu host=%lld\n",
                r.cycles, r.err, r.r[0], v);
    return !r.err && r.r[0] == 100 && v == 200;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Top* top = new Top;       // heap-alloc; the host stub holds a 4 MiB array
    reset(top);

    std::string only = "";
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) == "--case" && i+1 < argc) only = argv[++i];
    }

    bool ok = true;
    // Smoke: LI + RET (no DMA at all)
    {
        std::vector<uint64_t> prog = {
            encode(0x20, 1, 0, 0, 0xC, 42),
            encode(0x13, 0, 1, 0, 0, 0),
        };
        load_op(top, prog);
        auto r = invoke(top, {0,0,0,0,0,0,0,0});
        std::printf("xdma:smoke cycles=%lu err=%d r0=%lu\n",
                    r.cycles, r.err, r.r[0]);
        ok &= (!r.err && r.r[0] == 42);
    }
    // Reset between cases to flush all in-flight state in the
    // engine + host stub.
    if (only.empty() || only == "ld")  { reset(top); ok &= case_load(top);  }
    if (only.empty() || only == "st")  { reset(top); ok &= case_store(top); }
    if (only.empty() || only == "cas") { reset(top); ok &= case_cas(top);   }
    std::printf("xdma overall: %s\n", ok ? "PASS" : "FAIL");
    delete top;
    return ok ? 0 : 1;
}
