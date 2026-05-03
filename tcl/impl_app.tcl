###########################################################################
# Tiara + Corundum app-block place + route.
###########################################################################

set ROOT [file normalize [pwd]]
set OUT  $ROOT/synth_app

if {![file exists $OUT/app.dcp]} {
    error "post-synth checkpoint not found: run tcl/synth_app.tcl first"
}

open_checkpoint $OUT/app.dcp
opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force $OUT/app_routed.dcp
report_utilization      -file $OUT/util_post_route.rpt
report_utilization      -hierarchical -file $OUT/util_hier_post_route.rpt
report_timing_summary   -file $OUT/timing_post_route.rpt -warn_on_violation
report_clocks           -file $OUT/clocks_post_route.rpt
puts "TIARA-APP-IMPL-DONE: $OUT"
