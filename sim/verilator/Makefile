# Verilator build for the Tiara NIC testbench.
#
# Targets:
#   make            -> build sim binary at build/Vtiara_sim
#   make run        -> run a default smoke test
#   make clean

ROOT     := $(abspath $(CURDIR)/../..)
RTL_DIR  := $(ROOT)/rtl/tiara_nic
INC_DIR  := $(ROOT)/rtl/include
COSIM    := $(ROOT)/sim/cosim
BUILD    := $(CURDIR)/build

VERILATOR ?= verilator
VFLAGS    := --cc --exe --build -O3 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
             -Wno-DECLFILENAME -Wno-PINMISSING -Wno-MULTIDRIVEN \
             --top-module tiara_nic_top --trace --trace-structs \
             -I$(INC_DIR) -I$(RTL_DIR) -CFLAGS "-O2 -std=c++17 -I$(COSIM)" \
             --Mdir $(BUILD)

RTL_SRCS := \
    $(RTL_DIR)/tiara_alu.sv \
    $(RTL_DIR)/tiara_regfile.sv \
    $(RTL_DIR)/tiara_istore.sv \
    $(RTL_DIR)/tiara_loop_stack.sv \
    $(RTL_DIR)/tiara_mem_if.sv \
    $(RTL_DIR)/tiara_pcie_dma.sv \
    $(RTL_DIR)/tiara_rdma_engine.sv \
    $(RTL_DIR)/tiara_memory_subsystem.sv \
    $(RTL_DIR)/tiara_mp.sv \
    $(RTL_DIR)/tiara_dispatcher.sv \
    $(RTL_DIR)/tiara_nic_top.sv

# XDMA-flavor: descriptor-driven host DMA path (paper §3.4 / ROADMAP item 2).
XDMA_RTL_SRCS := \
    $(RTL_DIR)/tiara_alu.sv \
    $(RTL_DIR)/tiara_regfile.sv \
    $(RTL_DIR)/tiara_istore.sv \
    $(RTL_DIR)/tiara_loop_stack.sv \
    $(RTL_DIR)/tiara_mem_if.sv \
    $(RTL_DIR)/tiara_xdma_engine.sv \
    $(RTL_DIR)/tiara_xdma_host_stub.sv \
    $(RTL_DIR)/tiara_rdma_engine.sv \
    $(RTL_DIR)/tiara_mp.sv \
    $(RTL_DIR)/tiara_dispatcher.sv \
    $(RTL_DIR)/tiara_synth_top_xdma.sv

CXX_SRCS      := $(COSIM)/sim_main.cpp $(COSIM)/bfm.cpp
XDMA_CXX_SRCS := $(COSIM)/sim_xdma.cpp

XDMA_VFLAGS := --cc --exe --build -O3 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
               -Wno-DECLFILENAME -Wno-PINMISSING -Wno-MULTIDRIVEN \
               -Wno-CASEINCOMPLETE -Wno-UNUSED -Wno-UNDRIVEN \
               -Wno-CMPCONST -Wno-SELRANGE \
               --top-module tiara_synth_top_xdma \
               -I$(INC_DIR) -I$(RTL_DIR) -CFLAGS "-O2 -std=c++17 -I$(COSIM)" \
               --Mdir $(BUILD)_xdma

.PHONY: all xdma run run_xdma clean

all: $(BUILD)/Vtiara_nic_top

$(BUILD)/Vtiara_nic_top: $(RTL_SRCS) $(CXX_SRCS) $(INC_DIR)/tiara_pkg.svh
	$(VERILATOR) $(VFLAGS) $(RTL_SRCS) $(CXX_SRCS)

xdma: $(BUILD)_xdma/Vtiara_synth_top_xdma

$(BUILD)_xdma/Vtiara_synth_top_xdma: $(XDMA_RTL_SRCS) $(XDMA_CXX_SRCS) $(INC_DIR)/tiara_pkg.svh
	$(VERILATOR) $(XDMA_VFLAGS) $(XDMA_RTL_SRCS) $(XDMA_CXX_SRCS)

run: all
	$(BUILD)/Vtiara_nic_top --selftest

run_xdma: xdma
	$(BUILD)_xdma/Vtiara_synth_top_xdma

lint: $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall $(RTL_SRCS) -I$(INC_DIR) -I$(RTL_DIR) \
	    --top-module tiara_nic_top || true

clean:
	rm -rf $(BUILD) $(BUILD)_xdma
