#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/xilinx-env.sh"

# Package our own IP first: the block design instantiates it from ip/, and
# component.xml is generated (never checked in), so it always matches src/.
FPGA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
for pkg in "$FPGA_DIR"/ip/package_*.tcl; do
    "$VIVADO_ROOT/bin/vivado" -mode batch -nojournal -nolog -source "$pkg"
done

exec "$VIVADO_ROOT/bin/vivado" -mode batch -source "$SCRIPT_DIR/build.tcl"
