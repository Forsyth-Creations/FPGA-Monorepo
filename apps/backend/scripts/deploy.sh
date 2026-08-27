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

"$VITIS_ROOT/bin/xsdb" << EOF
connect
targets -set -filter {name =~ "APU*"}
rst
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
dow {$ELF}
con
EOF
