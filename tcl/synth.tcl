###########################################################################
# Tiara synthesis script (out-of-context, Alveo U50)
#
# Usage:
#   vivado -mode batch -source tcl/synth.tcl
#
# Outputs:
#   synth/tiara.dcp                — post-synth checkpoint
#   synth/util_post_synth.rpt      — utilization report
#   synth/timing_post_synth.rpt    — timing summary
###########################################################################

set ROOT     [file normalize [pwd]]
set RTL_DIR  $ROOT/rtl/tiara_nic
set INC_DIR  $ROOT/rtl/include
set XDC      $ROOT/constraints/tiara.xdc
set OUT      $ROOT/synth
file mkdir   $OUT

# Target part and board
set PART  xcu50-fsvh2104-2-e

create_project -in_memory -part $PART
catch { set_property board_part_repo_paths [list $ROOT/board_files] [current_project] }
catch { set_property board_part xilinx.com:au50:part0:1.3 [current_project] }

# Read RTL.  Order matters for SV packages/interfaces: package first,
# then interface, then leaf modules, then top.
read_verilog -sv $INC_DIR/tiara_pkg.svh
read_verilog -sv $RTL_DIR/tiara_mem_if.sv
read_verilog -sv $RTL_DIR/tiara_alu.sv
read_verilog -sv $RTL_DIR/tiara_regfile.sv
read_verilog -sv $RTL_DIR/tiara_istore.sv
read_verilog -sv $RTL_DIR/tiara_loop_stack.sv
read_verilog -sv $RTL_DIR/tiara_pcie_dma.sv
read_verilog -sv $RTL_DIR/tiara_rdma_engine.sv
read_verilog -sv $RTL_DIR/tiara_memory_subsystem.sv
read_verilog -sv $RTL_DIR/tiara_mp.sv
read_verilog -sv $RTL_DIR/tiara_dispatcher.sv
read_verilog -sv $RTL_DIR/tiara_nic_top.sv

# Constraints
read_xdc $XDC

# Synthesize.
synth_design -top tiara_nic_top \
             -part  $PART \
             -include_dirs $INC_DIR \
             -verilog_define SYNTHESIS=1 \
             -mode out_of_context \
             -flatten_hierarchy rebuilt \
             -directive default

write_checkpoint -force $OUT/tiara.dcp
report_utilization     -file $OUT/util_post_synth.rpt
report_utilization     -hierarchical -file $OUT/util_hier_post_synth.rpt
report_timing_summary  -file $OUT/timing_post_synth.rpt -warn_on_violation
report_clocks          -file $OUT/clocks.rpt
report_drc -ruledecks {default} -file $OUT/drc_post_synth.rpt

puts "TIARA-SYNTH-DONE: $OUT"
