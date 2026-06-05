###########################################################################
# Tiara timing-closure experiment at the Corundum/Alveo native datapath
# clock of 322.265625 MHz (period 3.103 ns), single MP.
#
# Goal: determine the true Fmax of the Tiara *core* (MP + dispatcher).
# The OOC self-containment memory stub (`tiara_mem_simple`) is replaced
# by the Corundum XDMA DMA pipeline in a real build, so we report the
# core WNS (u_mp + u_disp paths) separately from the wrapper WNS.
#
# Usage:
#   vivado -mode batch -source tcl/synth_322.tcl
###########################################################################

set ROOT     [file normalize [pwd]]
set RTL_DIR  $ROOT/rtl/tiara_nic
set INC_DIR  $ROOT/rtl/include
set OUT      $ROOT/synth_322
file mkdir   $OUT

set PART  xcu50-fsvh2104-2-e
set PERIOD 3.103   ;# 322.265625 MHz

create_project -in_memory -part $PART

read_verilog -sv $INC_DIR/tiara_pkg.svh
read_verilog -sv $RTL_DIR/tiara_mem_if.sv
read_verilog -sv $RTL_DIR/tiara_alu.sv
read_verilog -sv $RTL_DIR/tiara_regfile.sv
read_verilog -sv $RTL_DIR/tiara_istore.sv
read_verilog -sv $RTL_DIR/tiara_loop_stack.sv
read_verilog -sv $RTL_DIR/tiara_mp.sv
read_verilog -sv $RTL_DIR/tiara_dispatcher.sv
read_verilog -sv $RTL_DIR/tiara_mem_simple.sv
read_verilog -sv $RTL_DIR/tiara_synth_top.sv

synth_design -top tiara_synth_top \
             -part  $PART \
             -include_dirs $INC_DIR \
             -mode out_of_context \
             -flatten_hierarchy rebuilt \
             -directive default \
             -generic LOCAL_MEM_DEPTH=1024 \
             -generic PEER_MEM_DEPTH=256

# Constrain at the 322 MHz target.
create_clock -name clk -period $PERIOD [get_ports clk]
set_false_path   -from [get_ports rst_n]
set_input_delay  -clock clk -max 0.500 [get_ports load_en]
set_input_delay  -clock clk -max 0.500 [get_ports {load_addr[*]}]
set_input_delay  -clock clk -max 0.500 [get_ports {load_data[*]}]
set_input_delay  -clock clk -max 0.500 [get_ports inv_valid]
set_input_delay  -clock clk -max 0.500 [get_ports {inv_args[*][*]}]
set_output_delay -clock clk -max 0.500 [get_ports inv_busy]
set_output_delay -clock clk -max 0.500 [get_ports done]
set_output_delay -clock clk -max 0.500 [get_ports {done_result[*][*]}]
set_output_delay -clock clk -max 0.500 [get_ports done_err]
set_output_delay -clock clk -max 0.500 [get_ports {instr_retired[*]}]

# Place + route.
opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force $OUT/tiara_322_routed.dcp
report_timing_summary -file $OUT/timing_post_route_322.rpt -warn_on_violation
report_utilization    -file $OUT/util_post_route_322.rpt

# --- Core-only WNS (exclude the throwaway u_mem stub) ------------------
# Worst register-to-register path that both starts and ends inside the
# Tiara core (MP or dispatcher).  This is the number that matters for
# the paper: the core's true Fmax, independent of the OOC mem stub.
set core_cells [get_cells -hierarchical -filter {NAME =~ *u_mp/* || NAME =~ *u_disp/*}]
report_timing -from $core_cells -to $core_cells \
              -max_paths 10 -nworst 10 \
              -file $OUT/timing_core_only_322.rpt

# Also report the single overall worst path so the stub's contribution
# is visible for comparison.
report_timing -max_paths 5 -file $OUT/timing_worst_overall_322.rpt

puts "TIARA-322-DONE: $OUT"
