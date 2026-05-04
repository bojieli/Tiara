// Tiara simulator BFM (host-side helpers).
//
// Wraps the Verilator-generated top with a C++ API:
//   * load_operator(binary)         — write an assembled program
//   * invoke(args[8])               — run the operator and return
//                                     (cycles, result[0..3], err)
//   * dma/peer poke + peek          — seed and inspect host DRAM
//                                     and per-peer memories
//
// Used by `sim_main.cpp` and by the eval harness in `eval/`.

#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

class Vtiara_nic_top;
class VerilatedVcdC;

namespace tiara_sim {

struct InvocationResult {
    uint64_t cycles      = 0;
    std::array<uint64_t, 4> result{};
    bool     err         = false;
    uint32_t instr_retired = 0;
};

class Simulator {
  public:
    explicit Simulator(const std::string& trace_path = {});
    ~Simulator();

    // Toggle clock until reset is released
    void   reset();

    // Load a `.bin` file produced by the assembler into the MP's
    // instruction store.
    void   load_operator(const std::vector<uint64_t>& words);
    void   load_operator_file(const std::string& path);

    // Run the operator with the given 8 arguments, starting the MP
    // at `start_pc` (default 0 — the istore offset where you loaded
    // the operator).  Returns when the dispatcher signals `done`.
    // Times out after `max_cycles`.
    InvocationResult invoke(const std::array<uint64_t, 8>& args,
                            uint64_t max_cycles = 1'000'000,
                            uint16_t start_pc = 0);

    // Backing-memory access (host DRAM)
    void     dma_poke (uint32_t word_addr, uint64_t value);
    uint64_t dma_peek (uint32_t word_addr);

    // Backing-memory access (peer device DRAM)
    void     rdma_poke(uint16_t dev, uint32_t word_addr, uint64_t value);
    uint64_t rdma_peek(uint16_t dev, uint32_t word_addr);

    uint64_t cycle_count() const { return cycles_; }

  private:
    void tick(int n = 1);

    Vtiara_nic_top* top_  = nullptr;
    VerilatedVcdC*  vcd_  = nullptr;
    uint64_t        cycles_ = 0;
    std::string     trace_path_;
};

}  // namespace tiara_sim
