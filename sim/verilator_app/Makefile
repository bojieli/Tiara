ROOT     := $(abspath $(CURDIR)/../..)
RTL_TIA  := $(ROOT)/rtl/tiara_nic
RTL_INC  := $(ROOT)/rtl/include
RTL_INT  := $(ROOT)/integration/corundum_app/rtl
COSIM    := $(ROOT)/sim/cosim_app
BUILD    := $(CURDIR)/build

VERILATOR ?= verilator
VFLAGS := --cc --exe --build -O3 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
          -Wno-DECLFILENAME -Wno-PINMISSING -Wno-MULTIDRIVEN \
          --top-module tiara_datapath_top --trace --trace-structs \
          -I$(RTL_INC) -I$(RTL_TIA) -I$(RTL_INT) \
          -CFLAGS "-O2 -std=c++17 -I$(COSIM)" \
          --Mdir $(BUILD)

RTL_SRCS := $(RTL_TIA)/tiara_alu.sv \
            $(RTL_TIA)/tiara_regfile.sv \
            $(RTL_TIA)/tiara_istore.sv \
            $(RTL_TIA)/tiara_loop_stack.sv \
            $(RTL_TIA)/tiara_mem_if.sv \
            $(RTL_TIA)/tiara_mem_simple.sv \
            $(RTL_TIA)/tiara_mp.sv \
            $(RTL_TIA)/tiara_dispatcher.sv \
            $(RTL_TIA)/tiara_synth_top.sv \
            $(RTL_TIA)/tiara_op_table.sv \
            $(RTL_INT)/tiara_rx_filter.sv \
            $(RTL_INT)/tiara_tx_resp.sv \
            $(RTL_INT)/tiara_tx_arb.sv \
            $(RTL_INT)/tiara_datapath_top.sv

CXX_SRCS := $(COSIM)/sim_app.cpp

all: $(BUILD)/Vtiara_datapath_top

$(BUILD)/Vtiara_datapath_top: $(RTL_SRCS) $(CXX_SRCS) $(RTL_INC)/tiara_pkg.svh
	$(VERILATOR) $(VFLAGS) $(RTL_SRCS) $(CXX_SRCS)

run: all
	$(BUILD)/Vtiara_datapath_top --selftest

clean:
	rm -rf $(BUILD)
