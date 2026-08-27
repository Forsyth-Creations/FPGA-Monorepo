#!/usr/bin/env bash
# Shared environment setup for the Vivado/Vitis wrapper scripts.
# Source this, don't execute it.

# Load .env from monorepo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a
source "$REPO_ROOT/.env"
set +a

# Vivado ships distro-specific libraries only for the releases it knows about
# (Ubuntu 18/20/22/24 as of 2025.2). On a newer host its bin/ldlibpath.sh
# matches no version, drops the versioned lib dir from LD_LIBRARY_PATH, and the
# tool dies with `couldn't load file "libxv_commontasks.so": libtinfo.so.5`.
# Fall back to the newest shipped dir that isn't newer than this host.
xilinx_lib_compat() {
    local root="$1"
    local distro version base newest

    [[ -x "$root/bin/ldlibpath.sh" ]] || return 0
    read -r distro version < <("$root/bin/ldlibpath.sh")

    # A non-empty version means Vivado resolved a versioned lib dir on its own.
    if [[ -n "$version" || -z "$distro" ]]; then
        return 0
    fi

    base="$root/lib/lnx64.o/$distro"
    [[ -d "$base" ]] || return 0

    version="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
    newest="$( { ls -1 "$base" | grep -E '^[0-9]+$' | sort -n |
        awk -v host="${version%%.*}" 'host == "" || $1 <= host' | tail -n1; } || true)"
    [[ -n "$newest" ]] || return 0

    echo "$base/$newest"
}

for _xilinx_root in "${VIVADO_ROOT:-}" "${VITIS_ROOT:-}"; do
    [[ -d "$_xilinx_root" ]] || continue
    _compat="$(xilinx_lib_compat "$_xilinx_root")"
    if [[ -n "$_compat" ]]; then
        export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$_compat"
    fi
done
unset _xilinx_root _compat
