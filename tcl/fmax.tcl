###########################################################################
# Tiara Fmax probe: synthesize + place + route the standard single-MP
# build (tiara_synth_top, same flow as tcl/synth.tcl + tcl/impl.tcl --
# NO floorplan, NO pblock) at a swept clock period, and report whether
# it closes timing with zero negative slack (setup AND hold).
#
#   TIARA_PERIOD=4.348 vivado -mode batch -source tcl/fmax.tcl   # 230 MHz
#
# The point: find the highest clock at which the design as we actually
# build it is fully synthesizable and loadable -- WNS >= 0, 0 failing
# endpoints -- so we can quote it as a clean, conservative Fmax without
# any RTL pipelining.
###########################################################################

set ROOT     [file normalize [pwd]]
set RTL_DIR  $ROOT/rtl/tiara_nic
set INC_DIR  $ROOT/rtl/include

set PERIOD 4.348
if {[info exists ::env(TIARA_PERIOD)]} { set PERIOD $::env(TIARA_PERIOD) }
set MHZ [format %.1f [expr {1000.0/$PERIOD}]]
set OUT  $ROOT/fmax_${MHZ}
file mkdir $OUT
puts "FMAX-PROBE: period=$PERIOD ns  (${MHZ} MHz)  out=$OUT"

set PART xcu50-fsvh2104-2-e
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

# Same constraint shape as constraints/tiara.xdc, only the period swept.
create_clock -name clk -period $PERIOD [get_ports clk]
set_false_path -from [get_ports rst_n]
set_input_delay  -clock clk -max 1.000 [get_ports load_en]
set_input_delay  -clock clk -max 1.000 [get_ports {load_addr[*]}]
set_input_delay  -clock clk -max 1.000 [get_ports {load_data[*]}]
set_input_delay  -clock clk -max 1.000 [get_ports inv_valid]
set_input_delay  -clock clk -max 1.000 [get_ports {inv_args[*][*]}]
set_output_delay -clock clk -max 1.000 [get_ports inv_busy]
set_output_delay -clock clk -max 1.000 [get_ports done]
set_output_delay -clock clk -max 1.000 [get_ports {done_result[*][*]}]
set_output_delay -clock clk -max 1.000 [get_ports done_err]
set_output_delay -clock clk -max 1.000 [get_ports {instr_retired[*]}]

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -file $OUT/timing_summary.rpt -warn_on_violation

# Machine-readable verdict line.
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
set setup_fail [llength [get_timing_paths -delay_type max -slack_lesser_than 0 -max_paths 99999]]
set hold_fail  [llength [get_timing_paths -delay_type min -slack_lesser_than 0 -max_paths 99999]]
puts "FMAX-VERDICT period=$PERIOD MHz=$MHZ WNS=$wns WHS=$whs setup_fail=$setup_fail hold_fail=$hold_fail"
if {$wns >= 0 && $whs >= 0} {
  puts "FMAX-RESULT: CLEAN at ${MHZ} MHz (fully synthesizable, no negative slack)"
} else {
  puts "FMAX-RESULT: FAILS at ${MHZ} MHz (WNS=$wns WHS=$whs)"
}
puts "FMAX-DONE: $OUT"
