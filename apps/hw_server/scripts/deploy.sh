#!/usr/bin/env bash
set -euo pipefail

# Load .env from monorepo root
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
set -a
source "$REPO_ROOT/.env"
set +a

if pgrep -f "${VIVADO_ROOT}/bin/hw_server" >/dev/null 2>&1; then
	echo "hardware server is already up"
	exit 0
fi

exec "$VIVADO_ROOT/bin/hw_server" "$@"
