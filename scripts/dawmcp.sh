#!/usr/bin/env bash
# CTL-025: starts this checkout's dawmcp (the repo's .mcp.json runs it). Everything is relative to
# the script, so each Patchbay worktree runs its own build (CONV §9). Builds first when the binary
# is missing or older than the sources. stdout belongs to MCP, so build output goes to stderr.
#
#   scripts/dawmcp.sh [dawmcp options…]   build if needed, then exec .build/debug/dawmcp
#   scripts/dawmcp.sh --build-only        build if needed and exit (a fresh worktree's first build
#                                         takes minutes; do it before the MCP client connects)
#
# The server's working directory is the checkout root: relative paths in tool arguments (renders,
# analysis) land in this worktree.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"
bin="$root/.build/debug/dawmcp"

stale() {
    [[ -x "$bin" ]] || return 0
    [[ -n "$(find Package.swift Package.resolved Sources -newer "$bin" -print -quit 2>/dev/null)" ]]
}

if stale; then
    echo "dawmcp: building $root (swift build --product dawmcp)…" >&2
    if ! swift build --product dawmcp >&2; then
        echo "dawmcp: build failed; fix it, or run 'swift build --product dawmcp' in $root to see why" >&2
        exit 1
    fi
    # A source that dawmcp doesn't depend on leaves the binary untouched; mark it current so the
    # next start doesn't run the (no-op) build again.
    touch "$bin"
fi

if [[ "${1:-}" == "--build-only" ]]; then
    exit 0
fi
exec "$bin" "$@"
