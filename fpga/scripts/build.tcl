# Build the PL: create the Vivado project from scratch, synthesize, implement,
# and write the bitstream.
#
#   yarn build_platform      # or: vivado -mode batch -source scripts/build.tcl
#
# Nothing about the Vivado project is checked in. The sources of truth are:
#
#   rtl/*.v                 hand-written Verilog, `top` is the top level
#   constraints/*.xdc       pin and timing constraints
#   bd/design_1.tcl         the block design, exported as a Tcl proc
#
# Everything under build/ is generated and disposable -- deleting it costs a
# rebuild and nothing else. That is the point: the build is reproducible from
# a clean checkout, and there is no .xpr or .bd blob to diff.

set script_dir  [file dirname [file normalize [info script]]]
set fpga_dir    [file normalize "$script_dir/.."]
set build_dir   "$fpga_dir/build"
set dist_dir    "$fpga_dir/dist"
set rtl_dir     "$fpga_dir/rtl"
set constr_dir  "$fpga_dir/constraints"
set bd_script   "$fpga_dir/bd/design_1.tcl"

set part        "xc7z020clg400-1"
set top_module  "top"
set bd_name     "design_1"

file mkdir $dist_dir

# --- Fresh project ------------------------------------------------------------
# Recreated every build so a stale project can never mask a source change.
if {[file exists $build_dir]} {
    puts "Removing previous build directory..."
    file delete -force $build_dir
}
file mkdir $build_dir

puts "Creating project (part $part)..."
create_project project_1 $build_dir -part $part -force

# --- Sources ------------------------------------------------------------------
set rtl_files [lsort [glob -nocomplain "$rtl_dir/*.v" "$rtl_dir/*.sv"]]
if {[llength $rtl_files] == 0} {
    error "No RTL found in $rtl_dir"
}
puts "Adding [llength $rtl_files] RTL file(s):"
foreach f $rtl_files { puts "  [file tail $f]" }
add_files -norecurse -fileset [get_filesets sources_1] $rtl_files

set constr_files [lsort [glob -nocomplain "$constr_dir/*.xdc"]]
if {[llength $constr_files] == 0} {
    error "No constraints found in $constr_dir"
}
puts "Adding [llength $constr_files] constraint file(s):"
foreach f $constr_files { puts "  [file tail $f]" }
add_files -norecurse -fileset [get_filesets constrs_1] $constr_files

# --- Block design -------------------------------------------------------------
# Our own packaged IP (ip/*/component.xml, written by ip/package_*.tcl, which
# scripts/build.sh runs first). Must be in the catalog before design_1.tcl's
# IP check runs.
set_property ip_repo_paths "$fpga_dir/ip" [current_project]
update_ip_catalog
puts "Rebuilding block design from [file tail $bd_script]..."
source $bd_script
cr_bd_design_1 ""
set bd_file [get_files "$bd_name.bd"]
# Out-of-context per-IP synthesis, matching how the IP integrator runs it.
set_property SYNTH_CHECKPOINT_MODE Hierarchical $bd_file
generate_target all $bd_file

# The BD is instantiated by rtl/top.v, so no generated wrapper is needed or
# wanted -- top.v is the top module.
update_compile_order -fileset sources_1
set_property top $top_module [get_filesets sources_1]
update_compile_order -fileset sources_1

if {[get_property top [get_filesets sources_1]] ne $top_module} {
    error "Top module is [get_property top [get_filesets sources_1]], expected $top_module"
}
puts "Top module: $top_module"

# --- Synthesis ----------------------------------------------------------------
puts "Launching synthesis (synth_1)..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed -- see $build_dir/project_1.runs/synth_1/"
}

# --- Implementation + bitstream -----------------------------------------------
puts "Launching implementation and bitstream write (impl_1)..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation/bitstream failed -- see $build_dir/project_1.runs/impl_1/"
}

# --- Collect artifacts into dist/ ---------------------------------------------
set bit_file "$build_dir/project_1.runs/impl_1/$top_module.bit"
set xsa_file "$dist_dir/$top_module.xsa"

puts "Exporting hardware platform (XSA)..."
write_hw_platform -fixed -include_bit -force -file $xsa_file

puts "Copying bitstream into dist/..."
file copy -force $bit_file $dist_dir

# ps7_init.tcl brings the PS out of reset: PLLs, clocks, MIO and -- critically --
# the DDR controller. xsdb must source and run it before downloading an ELF that
# links into DDR, otherwise `dow` fails with "Cannot access DDR: the controller
# is held in reset".
puts "Copying ps7_init.tcl into dist/..."
set ps7_init_glob "$build_dir/project_1.gen/sources_1/bd/*/ip/*_processing_system7_*/ps7_init.tcl"
set ps7_init_files [glob -nocomplain $ps7_init_glob]
if {[llength $ps7_init_files] != 1} {
    error "Expected exactly one ps7_init.tcl matching:\n  $ps7_init_glob\nFound: [llength $ps7_init_files]"
}
file copy -force [lindex $ps7_init_files 0] $dist_dir

# --- Address map for Rust binding generation ----------------------------------
#
# libs/xil_bindings/build.rs turns this into base-address constants. Emitted
# here rather than parsed out of the XSA's design_1.hwh because the HWH stores
# only per-IP parameters -- the resolved master-space offsets live in the block
# design's address segments, which is what gets queried below.
#
# get_bd_addr_segs on a cell returns that cell's own segments. A slave segment
# (e.g. /axi_gpio_0/S_AXI/Reg) has an empty OFFSET; the mapping into the PS
# address space is a separate segment, reachable via -addressing.
puts "Exporting address map..."
open_bd_design $bd_file
set address_map_file "$dist_dir/address_map.json"
set entries {}
foreach cell [get_bd_cells] {
    foreach seg [get_bd_addr_segs -quiet -of_objects $cell] {
        if {[get_property -quiet OFFSET $seg] ne ""} { continue }
        foreach mapped [get_bd_addr_segs -quiet -addressing -of_objects $seg] {
            set offset [get_property -quiet OFFSET $mapped]
            if {$offset eq ""} { continue }
            lappend entries [format {  {"instance": "%s", "vlnv": "%s", "offset": "%s", "range": "%s", "access": "%s", "usage": "%s"}} \
                [string trimleft $cell "/"] \
                [get_property -quiet VLNV $cell] \
                $offset \
                [get_property -quiet RANGE $mapped] \
                [get_property -quiet ACCESS $mapped] \
                [get_property -quiet USAGE $mapped]]
        }
    }
}
if {[llength $entries] == 0} {
    error "Address map is empty -- libs/xil_bindings has nothing to generate from"
}
set fh [open $address_map_file w]
puts $fh "\["
puts $fh [join $entries ",\n"]
puts $fh "\]"
close $fh
puts "Wrote [llength $entries] peripheral(s) to $address_map_file"

puts "\nBuild complete. Artifacts in $dist_dir:"
puts "  Bitstream: $dist_dir/[file tail $bit_file]"
puts "  XSA:       $xsa_file"
puts "  PS init:   $dist_dir/ps7_init.tcl"
puts "  Addr map:  $address_map_file"
