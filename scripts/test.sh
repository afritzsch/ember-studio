#!/usr/bin/env bash
# BUILD-007: the single test entry point, for agents and CI alike. Runs every stage, prints a
# summary, and exits non-zero if any stage failed.
#
#   scripts/test.sh            all stages
#   scripts/test.sh --no-xcode skip the app build (quicker loop while working on packages)
#
# Build outputs stay inside the worktree (.build/, CONV §9). Logs: .build/test-logs/.
set -uo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)

run_xcode=1
for arg in "$@"; do
    case "$arg" in
        --no-xcode) run_xcode=0 ;;
        *) echo "usage: scripts/test.sh [--no-xcode]" >&2; exit 2 ;;
    esac
done

logs="$root/.build/test-logs"
mkdir -p "$logs"
xcode_derived="$root/.build/xcode"

failed=()
passed=()

# step <name> <command...>: run a stage, log its output, record the result.
step() {
    local name=$1; shift
    local log="$logs/$name.log"
    echo "==> $name"
    if "$@" >"$log" 2>&1; then
        passed+=("$name")
    else
        failed+=("$name")
        echo "    FAILED (last lines of $log):"
        tail -n 30 "$log" | sed 's/^/    | /'
    fi
}

# no_warnings <log>: CONV §5.1, builds must be warning-free. appintentsmetadataprocessor prints a
# "warning:" log line for apps without App Intents; that is a tool notice, not a diagnostic.
no_warnings() {
    if grep -E 'warning:' "$1" | grep -v 'appintentsmetadataprocessor' | sort -u | grep .; then
        echo "build produced warnings (see above)"
        return 1
    fi
}

swift_build() {
    local config=$1 log="$logs/swift-build-$1.raw.log"
    swift build -c "$config" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    (( rc == 0 )) || return "$rc"
    no_warnings "$log"
}

# BUILD-001/002/003: the manifest declares the layout from 01-build-layout.
check_manifest() {
    swift package dump-package | python3 -I -c '
import json, sys

pkg = json.load(sys.stdin)
errors = []
def check(cond, msg):
    if not cond:
        errors.append(msg)

targets = {t["name"]: t for t in pkg["targets"]}
def deps(t):
    return [list(d.values())[0][0] for d in targets[t]["dependencies"]]
def has_setting(t, tool, kind, value=None):
    for s in targets[t]["settings"]:
        if s["tool"] == tool and kind in s["kind"]:
            if value is None or s["kind"][kind].get("_0") == value:
                return True
    return False

# BUILD-001
check({"platformName": "macos", "version": "15.0", "options": []} in pkg["platforms"], "platform must be .macOS(.v15)")
check(pkg.get("cxxLanguageStandard") == "c++20", "cxxLanguageStandard must be .cxx20")
for name, kind in [("DAWEngine", "regular"), ("DAWModel", "regular"), ("DAWControl", "regular"),
                   ("dawctl", "executable"), ("dawmcp", "executable"), ("PluginScanner", "executable"),
                   ("DAWEngineTests", "test"), ("DAWModelTests", "test"), ("DAWControlTests", "test"),
                   ("GoldenTests", "test")]:
    check(targets.get(name, {}).get("type") == kind, f"missing {kind} target {name}")
# 01-build-layout Interfaces: product names.
products = {p["name"]: list(p["type"].keys())[0] for p in pkg["products"]}
for name, kind in [("DAWEngine", "library"), ("DAWModel", "library"), ("DAWControl", "library"),
                   ("dawctl", "executable"), ("dawmcp", "executable"), ("PluginScanner", "executable")]:
    check(products.get(name) == kind, f"missing {kind} product {name}")

# BUILD-002: every Swift target that reaches DAWEngine enables C++ interop.
def reaches_engine(t, seen=()):
    return any(d == "DAWEngine" or (d not in seen and reaches_engine(d, seen + (d,))) for d in deps(t))
for name in targets:
    if name not in ("DAWEngine", "VST3SDK") and reaches_engine(name):
        check(has_setting(name, "swift", "interoperabilityMode", "Cxx"), f"{name} needs .interoperabilityMode(.Cxx)")

# BUILD-003: DAWEngine links the vendored SDK.
check("VST3SDK" in targets, "missing target VST3SDK")
check("VST3SDK" in deps("DAWEngine"), "DAWEngine must depend on VST3SDK")

# BUILD-005: trap on in Debug, off in Release; Release is -O3.
check(has_setting("DAWEngine", "cxx", "define", "DAW_RT_TRAP=1"), "DAWEngine must define DAW_RT_TRAP=1 in debug")
check(has_setting("DAWEngine", "cxx", "define", "DAW_RT_TRAP=0"), "DAWEngine must define DAW_RT_TRAP=0 in release")
check(any(s["kind"].get("unsafeFlags", {}).get("_0") == ["-O3"] and s.get("condition", {}).get("config") == "release"
          for s in targets["DAWEngine"]["settings"]), "DAWEngine release must build with -O3")

for e in errors:
    print("manifest:", e)
sys.exit(1 if errors else 0)
'
}

# BUILD-003: the SDK gitlink is checked out at the pinned commit.
check_submodule() {
    local status
    status=$(git submodule status -- Vendor/vst3sdk)
    echo "$status"
    [[ "$status" == " "* ]]
}

# BUILD-003/005: VST3 code is linked into DAWEngine; the RT trap marker (Sources/DAWEngine/
# BuildConfig.cpp) is present in Debug and absent in Release.
check_engine_objects() {
    local debug release
    debug=$(swift build -c debug --show-bin-path) || return 1
    release=$(swift build -c release --show-bin-path) || return 1
    # Symbols are captured first: `nm | grep -q` would fail under pipefail when grep exits early.
    local debug_syms release_syms ok=0
    debug_syms=$(nm "$debug/libDAWEngine.a") || return 1
    release_syms=$(nm "$release/libDAWEngine.a") || return 1
    if grep -q 'Steinberg' <<<"$debug_syms"; then
        echo "BUILD-003: libDAWEngine.a contains VST3 SDK symbols"
    else
        echo "BUILD-003: no VST3 SDK symbols in libDAWEngine.a"; ok=1
    fi
    if grep -q '_daw_build_rt_trap_enabled' <<<"$debug_syms"; then
        echo "BUILD-005: RT trap compiled into Debug"
    else
        echo "BUILD-005: RT trap marker missing from Debug"; ok=1
    fi
    if grep -q '_daw_build_rt_trap_enabled' <<<"$release_syms"; then
        echo "BUILD-005: RT trap marker present in Release"; ok=1
    else
        echo "BUILD-005: RT trap compiled out of Release"
    fi
    return $ok
}

# BUILD-008: every binary we produce is arm64 only.
check_arch() {
    local ok=0 bin archs
    local bins=()
    for config in debug release; do
        local dir
        dir=$(swift build -c "$config" --show-bin-path) || return 1
        bins+=("$dir/dawctl" "$dir/dawmcp" "$dir/PluginScanner")
    done
    if (( run_xcode )); then
        bins+=("$xcode_derived/Build/Products/Debug/Ember Studio.app/Contents/MacOS/Ember Studio")
    fi
    for bin in "${bins[@]}"; do
        archs=$(lipo -archs "$bin" 2>&1)
        echo "$bin: $archs"
        [[ "$archs" == "arm64" ]] || ok=1
    done
    return $ok
}

# BUILD-004: app target builds; bundle carries the mic usage string, hardened runtime and the
# audio-input + disable-library-validation entitlements.
xcode_build() {
    local log="$logs/xcodebuild.raw.log"
    xcodebuild -project App/EmberStudio.xcodeproj -scheme EmberStudio -configuration Debug \
        -derivedDataPath "$xcode_derived" build 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    (( rc == 0 )) || return "$rc"
    no_warnings "$log"
}

check_app_bundle() {
    local app="$xcode_derived/Build/Products/Debug/Ember Studio.app" ok=0
    # T-086: the bundle carries the product identity (bundle ID, menu-bar and Finder name).
    local key want got
    for key in CFBundleIdentifier=dev.emberstudio.EmberStudio CFBundleName="Ember Studio" \
        CFBundleDisplayName="Ember Studio"; do
        want=${key#*=} key=${key%%=*}
        got=$(plutil -extract "$key" raw "$app/Contents/Info.plist" 2>&1)
        if [[ "$got" == "$want" ]]; then
            echo "app: $key = $got"
        else
            echo "app: $key is '$got', expected '$want'"; ok=1
        fi
    done
    if plutil -extract NSMicrophoneUsageDescription raw "$app/Contents/Info.plist"; then
        echo "BUILD-004: NSMicrophoneUsageDescription present"
    else
        echo "BUILD-004: NSMicrophoneUsageDescription missing"; ok=1
    fi
    if [[ "$(codesign -dv "$app" 2>&1)" =~ flags=[^[:space:]]*runtime ]]; then
        echo "BUILD-004: hardened runtime enabled"
    else
        echo "BUILD-004: hardened runtime missing"; ok=1
    fi
    local entitlements="$logs/app-entitlements.plist"
    codesign -d --entitlements - --xml "$app" >"$entitlements" 2>/dev/null || return 1
    for key in com.apple.security.device.audio-input com.apple.security.cs.disable-library-validation; do
        # PlistBuddy, because plutil key paths treat the dots in entitlement names as separators.
        if [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" 2>/dev/null)" == "true" ]]; then
            echo "BUILD-004: $key"
        else
            echo "BUILD-004: entitlement $key missing"; ok=1
        fi
    done
    return $ok
}

# TEST-001/002: golden fixtures run inside the GoldenTests target under `swift test`. Until the
# harness lands (T-019) there are none, which is not a failure.
report_goldens() {
    local count
    count=$(find Tests/GoldenTests/fixtures -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
    echo "golden fixtures: $count (run by GoldenTests under swift test)"
}

step bootstrap scripts/bootstrap.sh
step manifest check_manifest
step submodule check_submodule
step swift-build-debug swift_build debug
step swift-test swift test
step goldens report_goldens
step swift-build-release swift_build release
step engine-objects check_engine_objects
if (( run_xcode )); then
    step xcodebuild xcode_build
    step app-bundle check_app_bundle
fi
step arch check_arch

echo
echo "passed: ${#passed[@]}  failed: ${#failed[@]}"
if (( ${#failed[@]} )); then
    printf '  failed: %s\n' "${failed[@]}"
    exit 1
fi
