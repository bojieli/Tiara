###########################################################################
# Tiara + Corundum app-block OOC synthesis check.
#
# Synthesizes `mqnic_app_block` (the Corundum application slot, with
# Tiara wired into the AXI-Lite control region) standalone, on
# xcu50-fsvh2104-2-e.  This proves the integration elaborates and
# matches Corundum's app-block port contract — the next step
# (`make bitstream`) drops it into Corundum's AU50 25g build.
#
# Usage:
#   vivado -mode batch -source tcl/synth_app.tcl
###########################################################################

set ROOT     [file normalize [pwd]]
set RTL_TIA  $ROOT/rtl/tiara_nic
set RTL_INC  $ROOT/rtl/include
set RTL_INT  $ROOT/integration/corundum_app/rtl
set CORUNDUM $ROOT/vendor/corundum
set OUT      $ROOT/synth_app
file mkdir   $OUT

set PART  xcu50-fsvh2104-2-e

create_project -in_memory -part $PART

# Tiara core
read_verilog -sv $RTL_INC/tiara_pkg.svh
read_verilog -sv $RTL_TIA/tiara_mem_if.sv
read_verilog -sv $RTL_TIA/tiara_alu.sv
read_verilog -sv $RTL_TIA/tiara_regfile.sv
read_verilog -sv $RTL_TIA/tiara_istore.sv
read_verilog -sv $RTL_TIA/tiara_loop_stack.sv
read_verilog -sv $RTL_TIA/tiara_mp.sv
read_verilog -sv $RTL_TIA/tiara_dispatcher.sv
read_verilog -sv $RTL_TIA/tiara_mem_simple.sv
read_verilog -sv $RTL_TIA/tiara_synth_top.sv

# Tiara <-> Corundum app integration
read_verilog -sv $RTL_INT/tiara_axil_slave.sv
read_verilog -sv $RTL_INT/tiara_rx_filter.sv
read_verilog -sv $RTL_INT/tiara_tx_resp.sv
read_verilog -sv $RTL_INT/tiara_tx_arb.sv
read_verilog -sv $RTL_INT/mqnic_app_block.v

read_xdc $ROOT/constraints/tiara.xdc

synth_design -top mqnic_app_block \
             -part  $PART \
             -include_dirs $RTL_INC \
             -mode out_of_context \
             -flatten_hierarchy rebuilt \
             -directive default

write_checkpoint -force $OUT/app.dcp
report_utilization     -file $OUT/util_post_synth.rpt
report_utilization     -hierarchical -file $OUT/util_hier_post_synth.rpt
report_timing_summary  -file $OUT/timing_post_synth.rpt -warn_on_violation
puts "TIARA-APP-SYNTH-DONE: $OUT"
