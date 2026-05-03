###########################################################################
# Tiara 8-MP synthesis (matches paper §4.1).
#
# Out-of-context synthesis on Alveo U50.  Confirms the 8-MP design fits
# and closes 200 MHz, mirroring the paper's resource claim
# (~64K LUTs, ~78 BRAMs).
###########################################################################

set ROOT     [file normalize [pwd]]
set RTL_DIR  $ROOT/rtl/tiara_nic
set INC_DIR  $ROOT/rtl/include
set XDC      $ROOT/constraints/tiara.xdc
set OUT      $ROOT/synth_8mp
file mkdir   $OUT

set PART  xcu50-fsvh2104-2-e

create_project -in_memory -part $PART
catch { set_property board_part_repo_paths [list $ROOT/board_files] [current_project] }
catch { set_property board_part xilinx.com:au50:part0:1.3 [current_project] }

read_verilog -sv $INC_DIR/tiara_pkg.svh
read_verilog -sv $RTL_DIR/tiara_mem_if.sv
read_verilog -sv $RTL_DIR/tiara_alu.sv
read_verilog -sv $RTL_DIR/tiara_regfile.sv
read_verilog -sv $RTL_DIR/tiara_istore.sv
read_verilog -sv $RTL_DIR/tiara_loop_stack.sv
read_verilog -sv $RTL_DIR/tiara_mp.sv
read_verilog -sv $RTL_DIR/tiara_mem_simple.sv
read_verilog -sv $RTL_DIR/tiara_dispatcher_n.sv
read_verilog -sv $RTL_DIR/tiara_mp_array.sv
read_verilog -sv $RTL_DIR/tiara_synth_top_n.sv

read_xdc $XDC

synth_design -top tiara_synth_top_n \
             -part  $PART \
             -include_dirs $INC_DIR \
             -mode out_of_context \
             -flatten_hierarchy rebuilt \
             -directive default \
             -generic NUM_MPS=8 \
             -generic LOCAL_MEM_DEPTH=1024 \
             -generic PEER_MEM_DEPTH=256

write_checkpoint -force $OUT/tiara_8mp.dcp
report_utilization     -file $OUT/util_post_synth.rpt
report_utilization     -hierarchical -file $OUT/util_hier_post_synth.rpt
report_timing_summary  -file $OUT/timing_post_synth.rpt -warn_on_violation
puts "TIARA-8MP-SYNTH-DONE: $OUT"
