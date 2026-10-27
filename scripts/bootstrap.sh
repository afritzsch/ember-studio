#!/usr/bin/env bash
# BUILD-006: prepare a clone for building. Safe to run any number of times.
#   - checks the host and toolchain (Apple Silicon, Xcode >= 16, Swift >= 6)
#   - checks out Vendor/vst3sdk at the pinned commit, with only the SDK parts we compile
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "bootstrap: $*" >&2; exit 1; }

# D-23 / BUILD-008: Apple Silicon only.
[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required"
[[ "$(uname -m)" == "arm64" ]] || fail "Apple Silicon (arm64) is required, found $(uname -m)"

command -v xcodebuild >/dev/null || fail "xcodebuild not found; install Xcode 16 or later"
command -v swift >/dev/null || fail "swift not found; install Xcode 16 or later"

xcode_version=$(xcodebuild -version 2>/dev/null | awk '/^Xcode / { print $2; exit }')
[[ -n "$xcode_version" ]] || fail "could not read the Xcode version (is xcode-select pointing at Xcode.app?)"
(( ${xcode_version%%.*} >= 16 )) || fail "Xcode >= 16 required, found $xcode_version"

swift_version=$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | head -n 1)
[[ -n "$swift_version" ]] || fail "could not read the Swift version"
(( ${swift_version%%.*} >= 6 )) || fail "Swift >= 6 required, found $swift_version"

# BUILD-003: the SDK is pinned by the superproject's gitlink. Of its nested submodules only the
# hosting sources are needed (see Package.swift); VSTGUI, docs and tutorials are skipped.
git submodule sync --quiet -- Vendor/vst3sdk
git submodule update --init -- Vendor/vst3sdk
git -C Vendor/vst3sdk submodule sync --quiet -- base pluginterfaces public.sdk
git -C Vendor/vst3sdk submodule update --init -- base pluginterfaces public.sdk

status=$(git submodule status -- Vendor/vst3sdk)
[[ "$status" == " "* ]] || fail "Vendor/vst3sdk is not at the pinned commit: $status"

echo "bootstrap: ok (Xcode $xcode_version, Swift $swift_version, vst3sdk $(git -C Vendor/vst3sdk describe --tags --exact-match 2>/dev/null || git -C Vendor/vst3sdk rev-parse --short HEAD))"
