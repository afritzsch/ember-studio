#!/usr/bin/env bash
# TEST-003: regenerate golden references.
#
#   scripts/update-goldens.sh <name> [<name>…]
#
# Renders Tests/GoldenTests/fixtures/<name>.jsonl through GoldenTests (the same in-process
# harness `swift test` uses) and writes the render to Tests/GoldenTests/references/<name>.wav.
# The fixture must still run without errors or RT violations and meet its @expect lines; a
# fixture that fails those leaves the reference alone.
#
# It prints an audio.analyze before/after summary per reference. Paste it into the commit message
# and say why the reference changed. Never regenerate a reference just to make a failing test
# pass (TEST-003, CLAUDE.md).
set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)

if (( $# == 0 )); then
    echo "usage: scripts/update-goldens.sh <fixture name>…" >&2
    exit 2
fi
for name in "$@"; do
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ || ! -f "Tests/GoldenTests/fixtures/$name.jsonl" ]]; then
        echo "update-goldens: no fixture Tests/GoldenTests/fixtures/$name.jsonl" >&2
        exit 2
    fi
done

# Build outputs and summaries stay inside the worktree (CONV §9).
summaries="$root/.build/golden-updates"
mkdir -p "$summaries"
for name in "$@"; do rm -f "$summaries/$name.txt"; done

names=$(IFS=,; echo "$*")
log="$summaries/swift-test.log"
if ! DAW_GOLDEN_UPDATE="$names" DAW_GOLDEN_SUMMARY_DIR="$summaries" \
    swift test --filter 'GoldenTests.GoldenRenderTests' >"$log" 2>&1; then
    tail -n 40 "$log" >&2
    echo "update-goldens: GoldenTests failed; no summary for a fixture means its reference was not written (log: $log)" >&2
    exit 1
fi

missing=0
for name in "$@"; do
    if [[ -f "$summaries/$name.txt" ]]; then
        cat "$summaries/$name.txt"
    else
        echo "update-goldens: $name was not regenerated (log: $log)" >&2
        missing=1
    fi
done
(( missing == 0 )) || exit 1
echo
echo "Paste the summary above into the commit message and say why the reference changed (TEST-003)."
