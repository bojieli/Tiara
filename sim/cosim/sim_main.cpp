// Tiara cycle-accurate simulator — entry point.
//
//   ./Vtiara_nic_top --selftest
//   ./Vtiara_nic_top --op <prog.bin> --args a0 a1 ... [--peer 1@<file>] \
//                    [--dma <file>] [--cycles N]
//
// The harness builds a `tiara_sim::Simulator`, loads the assembled
// operator, optionally seeds host DRAM and peer-memory regions, then
// invokes the operator with up to 8 arguments.  Cycle counts and the
// 4-register return value are printed in machine-readable form so the
// eval harness can ingest the output directly.

#include "bfm.h"

#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#include "verilated.h"

namespace {

void usage() {
    std::printf(
        "usage: tiara_sim --op <prog.bin>\n"
        "                 [--args A0,A1,...]\n"
        "                 [--dma <hexfile>]      seed host DRAM, one 64b word per line\n"
        "                 [--peer N@<hexfile>]   seed peer N memory, may repeat\n"
        "                 [--trace <vcd>]\n"
        "                 [--cycles N]\n"
        "                 [--selftest]\n");
}

std::vector<uint64_t> read_hex_words(const std::string& path) {
    std::FILE* f = std::fopen(path.c_str(), "r");
    if (!f) throw std::runtime_error("cannot open " + path);
    std::vector<uint64_t> out;
    char line[64];
    while (std::fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n' || line[0] == 0) continue;
        out.push_back(std::strtoull(line, nullptr, 16));
    }
    std::fclose(f);
    return out;
}

void seed_from(tiara_sim::Simulator& sim, const std::string& path,
               int peer = -1) {
    auto words = read_hex_words(path);
    for (uint32_t i = 0; i < words.size(); i++) {
        if (peer < 0) sim.dma_poke (i, words[i]);
        else          sim.rdma_poke(static_cast<uint16_t>(peer), i, words[i]);
    }
}

int run_selftest() {
    using namespace tiara_sim;
    Simulator sim;
    // Tiny operator: LI r1, 42 ; RET r1
    // OP_COMPUTE | rd=1 | sub=LI(C) | imm=42  | RET rd=0,rs1=1
    auto encode = [](uint64_t op, uint64_t rd, uint64_t rs1, uint64_t rs2,
                     uint64_t sub, int64_t imm) {
        uint64_t i40 = static_cast<uint64_t>(imm) & ((1ULL << 40) - 1);
        return (op << 56) | (rd << 52) | (rs1 << 48) | (rs2 << 44) |
               (sub << 40) | i40;
    };
    std::vector<uint64_t> prog = {
        encode(0x20, 1, 0, 0, 0xC, 42),    // LI r1, 42
        encode(0x13, 0, 1, 0, 0, 0),       // RET r1
    };
    sim.load_operator(prog);
    auto r = sim.invoke({{0, 0, 0, 0, 0, 0, 0, 0}});
    // task_result[0] holds r1, [1]=r2, [2]=r3, [3]=r4
    std::printf("selftest: cycles=%lu  r1=%lu  err=%d  instr_retired=%u\n",
                static_cast<unsigned long>(r.cycles),
                static_cast<unsigned long>(r.result[0]),
                static_cast<int>(r.err),
                r.instr_retired);
    return (r.result[0] == 42 && !r.err) ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string op_path, dma_seed, trace;
    std::array<uint64_t, 8> args{};
    std::vector<std::pair<int, std::string>> peer_seeds;
    uint64_t max_cycles = 1'000'000;
    bool selftest = false;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if      (a == "--selftest")           selftest = true;
        else if (a == "--op"  && i+1 < argc)  op_path  = argv[++i];
        else if (a == "--dma" && i+1 < argc)  dma_seed = argv[++i];
        else if (a == "--trace" && i+1 < argc) trace = argv[++i];
        else if (a == "--cycles" && i+1 < argc) max_cycles = std::strtoull(argv[++i], nullptr, 10);
        else if (a == "--args" && i+1 < argc) {
            std::string s = argv[++i];
            std::size_t pos = 0, j = 0;
            while (pos < s.size() && j < 8) {
                std::size_t comma = s.find(',', pos);
                std::string tok = s.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
                args[j++] = std::strtoull(tok.c_str(), nullptr, 0);
                if (comma == std::string::npos) break;
                pos = comma + 1;
            }
        }
        else if (a == "--peer" && i+1 < argc) {
            std::string s = argv[++i];
            std::size_t at = s.find('@');
            if (at == std::string::npos) { usage(); return 2; }
            peer_seeds.emplace_back(std::atoi(s.substr(0, at).c_str()),
                                     s.substr(at + 1));
        }
        else if (a == "--help" || a == "-h") { usage(); return 0; }
    }

    if (selftest) return run_selftest();
    if (op_path.empty()) { usage(); return 2; }

    tiara_sim::Simulator sim(trace);
    if (!dma_seed.empty()) seed_from(sim, dma_seed);
    for (auto& kv : peer_seeds) seed_from(sim, kv.second, kv.first);

    sim.load_operator_file(op_path);
    auto r = sim.invoke(args, max_cycles);
    std::printf("RESULT cycles=%lu err=%d instr_retired=%u "
                "r0=%016lx r1=%016lx r2=%016lx r3=%016lx\n",
                static_cast<unsigned long>(r.cycles),
                static_cast<int>(r.err),
                r.instr_retired,
                static_cast<unsigned long>(r.result[0]),
                static_cast<unsigned long>(r.result[1]),
                static_cast<unsigned long>(r.result[2]),
                static_cast<unsigned long>(r.result[3]));
    return r.err ? 1 : 0;
}
