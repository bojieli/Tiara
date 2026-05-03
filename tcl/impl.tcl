###########################################################################
# Tiara implementation (place + route) script.
#
# Usage:
#   vivado -mode batch -source tcl/impl.tcl
#
# Reads synth/tiara.dcp produced by tcl/synth.tcl, runs opt -> place ->
# route, and emits utilization + timing reports.
###########################################################################

set ROOT [file normalize [pwd]]
set OUT  $ROOT/synth

if {![file exists $OUT/tiara.dcp]} {
    error "post-synth checkpoint not found: run tcl/synth.tcl first"
}

open_checkpoint $OUT/tiara.dcp
opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force $OUT/tiara_routed.dcp
report_utilization      -file $OUT/util_post_route.rpt
report_utilization      -hierarchical -file $OUT/util_hier_post_route.rpt
report_timing_summary   -file $OUT/timing_post_route.rpt -warn_on_violation \
                        -delay_type min_max -input_pins -no_header
report_clocks           -file $OUT/clocks_post_route.rpt
report_drc -ruledecks {default opt_checks placer_checks router_checks} \
           -file $OUT/drc_post_route.rpt
report_methodology      -file $OUT/methodology_post_route.rpt

puts "TIARA-IMPL-DONE: $OUT"
