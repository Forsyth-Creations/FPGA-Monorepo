#!/usr/bin/env bash
set -euo pipefail

# Load .env from monorepo root
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
set -a
source "$REPO_ROOT/.env"
set +a

exec "$VIVADO_ROOT/bin/hw_server" "$@"
