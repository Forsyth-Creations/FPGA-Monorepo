# Build script: synthesize, implement, and generate bitstream for project_1
# Run from the fpga/ directory:
#   vivado -mode batch -source scripts/build.tcl

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize "$script_dir/../project_1"]
set dist_dir    [file normalize "$script_dir/../dist"]
set xpr_file    "$project_dir/project_1.xpr"
set bit_file    "$project_dir/project_1.runs/impl_1/design_1_wrapper.bit"
set xsa_file    "$dist_dir/design_1_wrapper.xsa"

file mkdir $dist_dir

puts "Opening project: $xpr_file"
open_project $xpr_file

# --- Synthesis ---
puts "Launching synthesis (synth_1)..."
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed"
}

# --- Implementation + bitstream ---
puts "Launching implementation and bitstream write (impl_1)..."
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation/bitstream failed"
}

# --- Collect artifacts into dist/ ---
puts "Exporting hardware platform (XSA)..."
write_hw_platform -fixed -include_bit -force -file $xsa_file

puts "Copying bitstream into dist/..."
file copy -force $bit_file $dist_dir

puts "Build complete. Artifacts in $dist_dir:"
puts "  Bitstream: $dist_dir/[file tail $bit_file]"
puts "  XSA:       $xsa_file"
