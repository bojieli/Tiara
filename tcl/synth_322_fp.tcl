###########################################################################
# Tiara core Fmax at 322.265625 MHz WITH a compact floorplan.
#
# The free-OOC 322 run failed almost entirely on routing sprawl: the
# worst paths are ~80% route / ~0.8 ns logic because a tiny core is
# spread across a huge die and pushed apart by the throwaway memory
# stub.  A real integrated build is floorplanned.  Here we confine the
# whole design to a 2-column clock-region pblock so the router cannot
# sprawl, isolating the core's true logic-limited Fmax.
#
#   vivado -mode batch -source tcl/synth_322_fp.tcl
###########################################################################

set ROOT     [file normalize [pwd]]
set RTL_DIR  $ROOT/rtl/tiara_nic
set INC_DIR  $ROOT/rtl/include
set OUT      $ROOT/synth_322_fp
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

synth_design -top tiara_synth_top -part $PART -include_dirs $INC_DIR \
             -mode out_of_context -flatten_hierarchy rebuilt -directive default \
             -generic LOCAL_MEM_DEPTH=1024 -generic PEER_MEM_DEPTH=256

create_clock -name clk -period $PERIOD [get_ports clk]
set_false_path -from [get_ports rst_n]
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

# --- Compact floorplan: confine the whole design to a 2-column clock
# region strip (contains ample CLB/BRAM/DSP, but forbids die-wide sprawl).
catch {
  create_pblock pb_core
  add_cells_to_pblock pb_core [get_cells -hierarchical -filter {PRIMITIVE_LEVEL==LEAF}]
  resize_pblock pb_core -add CLOCKREGION_X2Y0:X3Y3
}

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force $OUT/tiara_322_fp_routed.dcp
report_timing_summary -file $OUT/timing_post_route_322_fp.rpt -warn_on_violation
report_utilization    -file $OUT/util_322_fp.rpt

set core_cells [get_cells -hierarchical -filter {NAME =~ *u_mp/* || NAME =~ *u_disp/*}]
report_timing -from $core_cells -to $core_cells -max_paths 10 -nworst 10 \
              -file $OUT/timing_core_only_322_fp.rpt
report_timing -max_paths 5 -file $OUT/timing_worst_overall_322_fp.rpt

puts "TIARA-322-FP-DONE: $OUT"
