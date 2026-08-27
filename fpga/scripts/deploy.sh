#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/xilinx-env.sh"

exec "$VIVADO_ROOT/bin/vivado" -mode batch -source "$SCRIPT_DIR/deploy.tcl"
