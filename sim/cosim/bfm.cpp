// Tiara simulator BFM — implementation.

#include "bfm.h"

#include <cassert>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <stdexcept>

#include "Vtiara_nic_top.h"
#include "Vtiara_nic_top__Dpi.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

namespace tiara_sim {

Simulator::Simulator(const std::string& trace_path)
    : top_(new Vtiara_nic_top), trace_path_(trace_path) {
    if (!trace_path_.empty()) {
        Verilated::traceEverOn(true);
        vcd_ = new VerilatedVcdC;
        top_->trace(vcd_, 99);
        vcd_->open(trace_path_.c_str());
    }
    top_->clk     = 0;
    top_->rst_n   = 0;
    top_->load_en = 0;
    top_->load_addr = 0;
    top_->load_data = 0;
    top_->inv_valid = 0;
    for (int i = 0; i < 8; i++) top_->inv_args[i] = 0;
    reset();
}

Simulator::~Simulator() {
    if (vcd_) {
        vcd_->close();
        delete vcd_;
    }
    delete top_;
}

void Simulator::tick(int n) {
    for (int i = 0; i < n; i++) {
        top_->clk = 0;
        top_->eval();
        if (vcd_) vcd_->dump(static_cast<vluint64_t>(cycles_ * 10));
        top_->clk = 1;
        top_->eval();
        if (vcd_) vcd_->dump(static_cast<vluint64_t>(cycles_ * 10 + 5));
        cycles_++;
    }
}

void Simulator::reset() {
    top_->rst_n = 0;
    tick(8);
    top_->rst_n = 1;
    tick(2);
}

void Simulator::load_operator(const std::vector<uint64_t>& words) {
    for (uint32_t i = 0; i < words.size(); i++) {
        top_->load_en   = 1;
        top_->load_addr = i;
        top_->load_data = words[i];
        tick(1);
    }
    top_->load_en = 0;
    tick(1);
}

void Simulator::load_operator_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open " + path);
    std::vector<char> bytes((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
    if (bytes.size() % 8) {
        throw std::runtime_error(path + " size not multiple of 8");
    }
    std::vector<uint64_t> words(bytes.size() / 8);
    for (size_t i = 0; i < words.size(); i++) {
        uint64_t v = 0;
        for (int b = 0; b < 8; b++) {
            v |= (static_cast<uint64_t>(static_cast<uint8_t>(bytes[i * 8 + b]))
                  << (8 * b));
        }
        words[i] = v;
    }
    load_operator(words);
}

InvocationResult Simulator::invoke(const std::array<uint64_t, 8>& args,
                                   uint64_t max_cycles) {
    for (int i = 0; i < 8; i++) top_->inv_args[i] = args[i];
    top_->inv_valid = 1;
    tick(1);
    top_->inv_valid = 0;

    InvocationResult r;
    uint64_t start = cycles_;
    while (!top_->done) {
        if (cycles_ - start > max_cycles) {
            r.err = true;
            r.cycles = cycles_ - start;
            return r;
        }
        tick(1);
    }
    r.cycles = cycles_ - start;
    for (int i = 0; i < 4; i++) r.result[i] = top_->done_result[i];
    r.err = top_->done_err;
    r.instr_retired = top_->instr_retired;
    tick(2);
    return r;
}

}  // namespace tiara_sim

// ---------------------------------------------------------------------
// DPI bridge.  The SV side exports `tiara_dpi_dma_*` and
// `tiara_dpi_rdma_*` task functions.  We need to set the SV scope so
// Verilator dispatches them to the right module instance, then call the
// generated extern-C symbols.
// ---------------------------------------------------------------------
#include "svdpi.h"

extern "C" {
    void tiara_dpi_dma_poke (int word_addr, long long value);
    void tiara_dpi_dma_peek (int word_addr, long long* value);
    void tiara_dpi_rdma_poke(int dev, int word_addr, long long value);
    void tiara_dpi_rdma_peek(int dev, int word_addr, long long* value);
}

namespace tiara_sim {

namespace {
struct ScopedScope {
    explicit ScopedScope(const char* path) {
        prev_ = svGetScope();
        sc_   = svGetScopeFromName(path);
        if (sc_) svSetScope(sc_);
    }
    ~ScopedScope() { if (prev_) svSetScope(prev_); }
    svScope sc_ {};
    svScope prev_ {};
};
}  // namespace

void Simulator::dma_poke(uint32_t word_addr, uint64_t value) {
    ScopedScope s("TOP.tiara_nic_top.u_mem.u_pdma");
    tiara_dpi_dma_poke(static_cast<int>(word_addr),
                       static_cast<long long>(value));
}

uint64_t Simulator::dma_peek(uint32_t word_addr) {
    ScopedScope s("TOP.tiara_nic_top.u_mem.u_pdma");
    long long v = 0;
    tiara_dpi_dma_peek(static_cast<int>(word_addr), &v);
    return static_cast<uint64_t>(v);
}

void Simulator::rdma_poke(uint16_t dev, uint32_t word_addr, uint64_t value) {
    ScopedScope s("TOP.tiara_nic_top.u_mem.u_rdma");
    tiara_dpi_rdma_poke(static_cast<int>(dev),
                        static_cast<int>(word_addr),
                        static_cast<long long>(value));
}

uint64_t Simulator::rdma_peek(uint16_t dev, uint32_t word_addr) {
    ScopedScope s("TOP.tiara_nic_top.u_mem.u_rdma");
    long long v = 0;
    tiara_dpi_rdma_peek(static_cast<int>(dev),
                        static_cast<int>(word_addr), &v);
    return static_cast<uint64_t>(v);
}

}  // namespace tiara_sim
