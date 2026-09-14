# Deploy to the board over JTAG, via xsdb (not Vivado's hardware manager).
#
#   yarn deploy      # or: xsdb scripts/deploy.tcl
#
# Programming the bitstream is not enough on a Zynq. FCLK_CLK0 is the only
# clock the PL has, and it comes out of the PS PLLs -- which stay unconfigured
# until ps7_init runs. Program the PL alone and configuration succeeds ("End of
# startup status: HIGH"), then the fabric sits there with a dead clock: the
# counter never counts and the LEDs never light. That is why this script does
# more than the bitstream.
#
# Order matters:
#
#   rst -system       clear the PS and the PL. Must come before `fpga`, since
#                     a system reset would otherwise wipe the configuration
#                     that was just loaded.
#   ps7_init          PLLs, clocks, MIO, DDR. FCLK_CLK0 starts running here.
#   fpga              configure the PL.
#   ps7_post_config   enable the PS-PL level shifters. Has to come last: the
#                     shifters should only open once the PL holds a valid
#                     configuration.

set script_dir [file dirname [file normalize [info script]]]
set fpga_dir   [file normalize "$script_dir/.."]

# Prefer the artifact collected by build_platform; fall back to the raw impl
# run directory under the generated build/ tree.
set candidates [list \
    "$fpga_dir/dist/top.bit" \
    "$fpga_dir/build/project_1.runs/impl_1/top.bit"]

set bit_file ""
foreach candidate $candidates {
    if {[file exists $candidate]} {
        set bit_file $candidate
        break
    }
}
if {$bit_file eq ""} {
    error "Bitstream not found in any of:\n  [join $candidates "\n  "]\nRun 'yarn build_platform' first."
}

# ps7_init.tcl is collected into dist/ by build.tcl and has no counterpart in
# the impl run directory, so it is dist/ or nothing.
set ps7_init_file "$fpga_dir/dist/ps7_init.tcl"
if {![file exists $ps7_init_file]} {
    error "ps7_init.tcl not found at $ps7_init_file\nRun 'yarn build_platform' first."
}

puts "Connecting to hw_server..."
connect

puts "Resetting the system..."
targets -set -nocase -filter {name =~ "*A9*#0"}
rst -system
after 1000

puts "Initializing the PS (clocks, MIO, DDR)..."
targets -set -nocase -filter {name =~ "*A9*#0"}
source $ps7_init_file
ps7_init

puts "Programming the PL with [file tail $bit_file]..."
targets -set -nocase -filter {name =~ "*xc7z*"}
fpga -file $bit_file

puts "Enabling PS-PL level shifters..."
targets -set -nocase -filter {name =~ "*A9*#0"}
ps7_post_config

puts "Deploy complete."
