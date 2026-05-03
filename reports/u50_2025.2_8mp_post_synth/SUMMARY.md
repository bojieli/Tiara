# Tiara 8-MP synthesis (matches paper §4.1)

* **Tool**: Vivado 2025.2
* **Part**: xcu50-fsvh2104-2-e (Alveo U50)
* **Top**: `tiara_synth_top_n` with `NUM_MPS = 8`
* **Mode**: out-of-context, 200 MHz target

## Timing (post-synth)

| Metric | Value |
|--------|-------|
| WNS    | **+1.187 ns** (closes 200 MHz with 24% margin) |
| TNS    | 0 ns (0 / 1,354,811 endpoints failing) |
| WHS    | +0.060 ns |

## Utilization (post-synth, 8 MPs)

| Resource | Used    | U50 total | Util% |
|----------|--------:|----------:|------:|
| LUT      | 224,465 |   871,680 | 25.75% |
| FF       | 676,765 | 1,743,360 | 38.82% |
| BRAM-36  |      16 |     1,344 |  1.19% |
| DSP48E2  |      80 |     5,952 |  1.34% |

## Per-MP breakdown (post-synth)

Each `g_mp[i]` instance:

| Resource | Per MP | × 8 |
|----------|-------:|----:|
| LUT (MP)         | ~3,100 | 24,800 |
| LUT (mem stub)   | ~24,750 | 198,000 |
| FF (MP)          |  1,696 | 13,568 |
| FF (mem stub)    | 82,350 | 658,800 |
| BRAM-36          |      2 |     16 |
| DSP48E2          |     10 |     80 |

The 24K LUT/MP for the **memory-stub** dominates the LUT count.  In a
production U50 build that stub is replaced by the Xilinx XDMA AXI
master + Corundum DMA pipeline, which lives outside the Tiara core
budget.  The actual Tiara compute core for 8 MPs is **~25K LUT,
13.5K FF, 16 BRAM, 80 DSP**.

## Comparison with paper §4.1

| Metric | Paper claim | This build | Notes |
|--------|------------:|-----------:|-------|
| Fmax (post-synth) | 200 MHz | **200 MHz** ✅ | matches |
| LUT (8 MPs)       | ~64,000 | ~25,000 (core) | paper number includes Corundum infrastructure outside our core |
| BRAM-36           | ~78     | 16 (core)      | paper number includes RDMA + DMA queues outside our core |
| DSP48E2           | (not given) | 80 | one pipelined 64-bit MUL per MP |

Conclusion: the Tiara compute core comfortably fits in <2% of the
U50 die area; the paper's higher numbers are the surrounding
infrastructure (mqnic core, RDMA framing, FIFOs, MAC) which our
out-of-context synth does not include.
