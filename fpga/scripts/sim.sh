#!/usr/bin/env bash
# Behavioral simulation of the RTL in rtl/, using xsim in non-project mode.
#
#   yarn simulate                    # run the default testbench, batch
#   yarn simulate --gui              # same, then open the waveform viewer
#   yarn simulate my_other_tb        # pick a different testbench top
#
# No Vivado project is involved: this compiles rtl/ and sim/ straight into a
# throwaway work library under sim_build/. It does not need build_platform to
# have run, and it never touches build/ or dist/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FPGA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/xilinx-env.sh"

export PATH="$VIVADO_ROOT/bin:$PATH"

TOP="rtl_counter_tb"
GUI=0
for arg in "$@"; do
    case "$arg" in
        --gui) GUI=1 ;;
        -*)    echo "sim.sh: unknown option '$arg'" >&2; exit 2 ;;
        *)     TOP="$arg" ;;
    esac
done

# Globbed, not listed, for the same reason build.tcl globs: adding a file to
# rtl/ or sim/ should be the whole of adding a file.
shopt -s nullglob
SOURCES=("$FPGA_DIR"/rtl/*.v "$FPGA_DIR"/rtl/*.sv "$FPGA_DIR"/sim/*.v "$FPGA_DIR"/sim/*.sv)
shopt -u nullglob
if [[ ${#SOURCES[@]} -eq 0 ]]; then
    echo "sim.sh: no sources found in $FPGA_DIR/rtl or $FPGA_DIR/sim" >&2
    exit 1
fi

# xsim's tools scatter logs and a work library across the working directory,
# so give them one of their own. Wiped each run so a stale snapshot can never
# mask a source change -- same rule build.tcl applies to build/.
SIM_DIR="$FPGA_DIR/sim_build"
rm -rf "$SIM_DIR"
mkdir -p "$SIM_DIR"
cd "$SIM_DIR"

echo "Compiling ${#SOURCES[@]} source file(s)..."
for f in "${SOURCES[@]}"; do echo "  ${f#$FPGA_DIR/}"; done
# xvlog parses everything as Verilog-2001 unless told otherwise, and `-sv`
# applies to a whole invocation. So .v and .sv files are compiled in two passes
# into the same work library.
V_SOURCES=(); SV_SOURCES=()
for f in "${SOURCES[@]}"; do
    case "$f" in *.sv) SV_SOURCES+=("$f") ;; *) V_SOURCES+=("$f") ;; esac
done
[[ ${#V_SOURCES[@]}  -gt 0 ]] && xvlog --relax     "${V_SOURCES[@]}"
[[ ${#SV_SOURCES[@]} -gt 0 ]] && xvlog --relax -sv "${SV_SOURCES[@]}"

echo "Elaborating $TOP..."
# The design top must precede -s; xelab otherwise reads the snapshot flag as
# taking both names and reports "No design top(s) specified".
xelab --relax --debug typical --timescale 1ps/1ps "$TOP" -s "$TOP"

if [[ $GUI -eq 1 ]]; then
    echo "Simulating $TOP (GUI)..."
    SIM_GUI=1 exec xsim "$TOP" --gui --tclbatch "$SCRIPT_DIR/sim.tcl"
fi

LOG="$SIM_DIR/xsim_run.log"
echo "Simulating $TOP..."
xsim "$TOP" --tclbatch "$SCRIPT_DIR/sim.tcl" 2>&1 | tee "$LOG"

# xsim exits 0 even when the testbench calls $fatal, so the verdict has to come
# from the log. The contract for a testbench under sim/: print "SIM PASS" once
# every check has held, and report nothing fatal along the way. Without this,
# a failing testbench would look like a passing turbo task.
if grep -qE '^(Fatal|Error|ERROR):' "$LOG"; then
    echo "sim.sh: $TOP reported a fatal error -- see $LOG" >&2
    exit 1
fi
if ! grep -q 'SIM PASS' "$LOG"; then
    echo "sim.sh: $TOP never printed 'SIM PASS' -- see $LOG" >&2
    exit 1
fi
echo "sim.sh: $TOP passed."
