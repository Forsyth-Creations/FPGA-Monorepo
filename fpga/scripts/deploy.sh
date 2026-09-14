#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/xilinx-env.sh"

# xsdb, not vivado: the deploy has to run ps7_init to start the PS clocks
# before the PL has anything to run on. See the comment in deploy.tcl.
exec "$VITIS_ROOT/bin/xsdb" "$SCRIPT_DIR/deploy.tcl"
