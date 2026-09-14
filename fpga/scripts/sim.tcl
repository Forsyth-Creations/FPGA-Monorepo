# xsim driver, used for both the batch and the GUI run (scripts/sim.sh).
#
# Waves are logged either way, so a batch run leaves a .wdb behind that can be
# opened later with `xsim --gui <snapshot>.wdb` without re-running anything.

log_wave -recursive *
run all

# In GUI mode leave the session open on the populated waveform; in batch mode
# the run is over, so return xsim's exit status to the shell.
if {![info exists ::env(SIM_GUI)]} {
    quit
}
