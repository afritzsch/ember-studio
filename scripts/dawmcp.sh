#!/usr/bin/env bash
# CTL-025: starts this checkout's dawmcp (the repo's .mcp.json runs it). Everything is relative to
# the script, so each Patchbay worktree runs its own build (CONV §9). Builds first when the binary
# is missing or older than the sources. stdout belongs to MCP, so build output goes to stderr.
#
#   scripts/dawmcp.sh [dawmcp options…]   build if needed, then exec .build/debug/dawmcp
#   scripts/dawmcp.sh --build-only        build if needed and exit (a fresh worktree's first build
#                                         takes minutes; do it before the MCP client connects)
#   scripts/dawmcp.sh --help              this text
#
# The server's working directory is the checkout root: relative paths in tool arguments (renders,
# analysis) land in this worktree.
#
# A running dawmcp keeps the build it started with (DW-147/151, T-098): after a rebuild (this script,
# or `swift build`), every tool result carries the warning "stale: dawmcp binary rebuilt since
# launch; restart the MCP server". It doesn't restart itself (the session's project would be lost);
# restart the server from the MCP client (Claude Code: /mcp) to load the new build.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
    exit 0
fi

cd "$root"
bin="$root/.build/debug/dawmcp"
# When the last build check ran. A build that changes nothing leaves the binary's date alone, so a
# running dawmcp doesn't see itself as stale (T-098); this stamp keeps the next start from
# running that no-op build again.
stamp="$root/.build/debug/dawmcp.stamp"
scanner="$root/.build/debug/PluginScanner"

stale() {
    [[ -x "$bin" && -e "$stamp" ]] || return 0
    [[ -n "$(find Package.swift Package.resolved Sources -newer "$stamp" -print -quit 2>/dev/null)" ]]
}

if stale; then
    echo "dawmcp: building $root (swift build --product dawmcp)…" >&2
    if ! swift build --product dawmcp >&2; then
        echo "dawmcp: build failed; fix it, or run 'swift build --product dawmcp' in $root to see why" >&2
        exit 1
    fi
    # DW-016 (T-098): daw_plugins_* run the scanner next to dawmcp. Optional: the server starts without it.
    if [[ -d Sources/PluginScanner ]] && { [[ ! -x "$scanner" ]] ||
        [[ -n "$(find Sources/PluginScanner -newer "$scanner" -print -quit 2>/dev/null)" ]]; }; then
        swift build --product PluginScanner >&2 || echo "dawmcp: PluginScanner didn't build; daw_plugins_scan will fail" >&2
    fi
    touch "$stamp"
fi

if [[ "${1:-}" == "--build-only" ]]; then
    exit 0
fi
exec "$bin" "$@"
