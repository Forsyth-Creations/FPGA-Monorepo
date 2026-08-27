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

# ps7_init.tcl brings the PS out of reset: PLLs, clocks, MIO and -- critically --
# the DDR controller. xsdb must source and run it before downloading an ELF that
# links into DDR, otherwise `dow` fails with "Cannot access DDR: the controller
# is held in reset". Vivado regenerates it under project_1.gen/ (gitignored), so
# collect it here alongside the other artifacts.
puts "Copying ps7_init.tcl into dist/..."
set ps7_init_glob "$project_dir/project_1.gen/sources_1/bd/*/ip/*_processing_system7_*/ps7_init.tcl"
set ps7_init_files [glob -nocomplain $ps7_init_glob]
if {[llength $ps7_init_files] != 1} {
    error "Expected exactly one ps7_init.tcl matching:\n  $ps7_init_glob\nFound: [llength $ps7_init_files]"
}
set ps7_init_file [lindex $ps7_init_files 0]
file copy -force $ps7_init_file $dist_dir

puts "Build complete. Artifacts in $dist_dir:"
puts "  Bitstream: $dist_dir/[file tail $bit_file]"
puts "  XSA:       $xsa_file"
puts "  PS init:   $dist_dir/ps7_init.tcl"
