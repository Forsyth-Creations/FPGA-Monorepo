#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
set -a
source "$REPO_ROOT/.env"
set +a

ELF="$REPO_ROOT/target/armv7a-none-eabihf/release/backend"

if [[ ! -f "$ELF" ]]; then
    echo "ELF not found: $ELF" >&2
    echo "Run 'yarn workspace @repo/backend build' first." >&2
    exit 1
fi

# The ELF links into DDR (see memory.x: CODE @ 0x0010_0000), but after a reset
# the PS DDR controller, PLLs, clocks and MIO are all still held in reset.
# ps7_init.tcl is the Vivado-generated register sequence that brings them up;
# without running it, `dow` dies with:
#   Memory write error at 0x100000. Cannot access DDR: the controller is held in reset
# Prefer the copy collected by build_platform, fall back to the generated
# build/ tree.
PS7_INIT=""
for candidate in \
    "$REPO_ROOT/fpga/dist/ps7_init.tcl" \
    "$REPO_ROOT"/fpga/build/project_1.gen/sources_1/bd/*/ip/*_processing_system7_*/ps7_init.tcl
do
    if [[ -f "$candidate" ]]; then
        PS7_INIT="$candidate"
        break
    fi
done

if [[ -z "$PS7_INIT" ]]; then
    echo "ps7_init.tcl not found under $REPO_ROOT/fpga." >&2
    echo "Run 'yarn workspace @repo/fpga build_platform' first." >&2
    exit 1
fi

"$VITIS_ROOT/bin/xsdb" << EOF
connect
source {$PS7_INIT}

# Reset the A9 cores only. A system reset would also wipe the PL configuration
# programmed by @repo/fpga#deploy.
targets -set -filter {name =~ "APU*"}
rst -cores
after 1000

targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
ps7_init
ps7_post_config

configparams force-mem-access 1
dow {$ELF}
configparams force-mem-access 0
con
EOF
