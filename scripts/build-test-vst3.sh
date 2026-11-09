#!/usr/bin/env bash
# T-062 (PLUG-011): builds the test plugins as real .vst3 bundles from Vendor/vst3sdk, with clang++
# only (no CMake), into .build/test-plugins/ (per worktree, CONV §9):
#   again.vst3      the SDK's `again` sample, unmodified (VSTGUI replaced by the stubs in
#                   Tests/VST3TestPlugin/vstgui-shim, since bootstrap doesn't fetch vstgui4)
#   EmberTest.vst3  Tests/VST3TestPlugin/EmberTestPlugin.cpp (latency, sidechain, transport probes)
# Called by scripts/test.sh and, when a bundle is missing or stale, by the tests. Safe to run
# concurrently: one builder at a time holds the lock, the others wait and find nothing left to do.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)
sdk="$root/Vendor/vst3sdk"
out="$root/.build/test-plugins"
objdir="$out/obj"
again="$sdk/public.sdk/samples/vst/again/source"
ember="$root/Tests/VST3TestPlugin"
script="$root/scripts/build-test-vst3.sh"

[[ -f "$sdk/public.sdk/source/vst/vstaudioeffect.cpp" ]] || { echo "build-test-vst3: run scripts/bootstrap.sh first" >&2; exit 1; }

sdk_common=(
    "$sdk/pluginterfaces/base/conststringtable.cpp"
    "$sdk/pluginterfaces/base/coreiids.cpp"
    "$sdk/pluginterfaces/base/funknown.cpp"
    "$sdk/pluginterfaces/base/ustring.cpp"
    "$sdk/base/source/baseiids.cpp"
    "$sdk/base/source/fbuffer.cpp"
    "$sdk/base/source/fdebug.cpp"
    "$sdk/base/source/fobject.cpp"
    "$sdk/base/source/fstreamer.cpp"
    "$sdk/base/source/fstring.cpp"
    "$sdk/base/source/updatehandler.cpp"
    "$sdk/base/thread/source/flock.cpp"
    "$sdk/public.sdk/source/common/commoniids.cpp"
    "$sdk/public.sdk/source/common/commonstringconvert.cpp"
    "$sdk/public.sdk/source/common/pluginview.cpp"
    "$sdk/public.sdk/source/main/macmain.cpp"
    "$sdk/public.sdk/source/main/moduleinit.cpp"
    "$sdk/public.sdk/source/main/pluginfactory.cpp"
    "$sdk/public.sdk/source/vst/utility/stringconvert.cpp"
    "$sdk/public.sdk/source/vst/vstaudioeffect.cpp"
    "$sdk/public.sdk/source/vst/vstbus.cpp"
    "$sdk/public.sdk/source/vst/vstcomponent.cpp"
    "$sdk/public.sdk/source/vst/vstcomponentbase.cpp"
    "$sdk/public.sdk/source/vst/vsteditcontroller.cpp"
    "$sdk/public.sdk/source/vst/vstinitiids.cpp"
    "$sdk/public.sdk/source/vst/vstparameters.cpp"
)
again_sources=("$again/again.cpp" "$again/againcontroller.cpp" "$again/againentry.cpp" "$again/againsidechain.cpp")
ember_sources=("$ember/EmberTestPlugin.cpp")

newest() { # prints the newest mtime (epoch seconds) of the given files
    local newest=0 f m
    for f in "$@"; do
        [[ -e "$f" ]] || continue
        m=$(stat -f %m "$f")
        (( m > newest )) && newest=$m
    done
    echo "$newest"
}

up_to_date() { # <bundle> <inputs…>
    local bundle=$1; shift
    [[ -x "$bundle/Contents/MacOS/$(basename "$bundle" .vst3)" ]] || return 1
    local built
    built=$(stat -f %m "$bundle/Contents/Info.plist")
    (( built >= $(newest "$@" "$script") ))
}

shim_headers=("$ember"/vstgui-shim/*.h "$ember"/vstgui-shim/vstgui/*.h "$ember"/vstgui-shim/vstgui/*/*.h)
if up_to_date "$out/again.vst3" "${again_sources[@]}" "${shim_headers[@]}" &&
   up_to_date "$out/EmberTest.vst3" "${ember_sources[@]}" "$ember/ember_test.exp"; then
    exit 0
fi

mkdir -p "$out"
lock="$out/.lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited > 600 )); then
        echo "build-test-vst3: lock $lock held for 10 minutes; remove it if no build is running" >&2
        exit 1
    fi
done
trap 'rm -rf "$out"/.tmp-*; rmdir "$lock" 2>/dev/null || true' EXIT

mkdir -p "$objdir"
cxx=(xcrun clang++ -std=c++17 -arch arm64 -w -O1 -g -fPIC -fvisibility=hidden -DRELEASE=1
     -isystem "$sdk" -I "$ember/vstgui-shim")

object_for() { echo "$objdir/$(echo "$1" | shasum | cut -c1-16)-$(basename "$1").o"; }

compile_all() { # compiles the given sources into $objdir (only stale ones), in parallel
    local src obj jobs=()
    for src in "$@"; do
        obj=$(object_for "$src")
        if [[ ! -e "$obj" || "$src" -nt "$obj" || "$script" -nt "$obj" ]]; then
            jobs+=("$src" "$obj")
        fi
    done
    (( ${#jobs[@]} )) || return 0
    printf '%s\0' "${jobs[@]}" | xargs -0 -n 2 -P "$(sysctl -n hw.ncpu)" \
        bash -c "$(printf '%q ' "${cxx[@]}") -c \"\$1\" -o \"\$2\"" _
}

objects_for() {
    local src
    for src in "$@"; do object_for "$src"; done
}

make_bundle() { # <name> <exports file> <sources…>
    local name=$1 exports=$2; shift 2
    compile_all "$@"
    local tmp="$out/.tmp-$name-$$"
    rm -rf "$tmp"
    mkdir -p "$tmp/Contents/MacOS"
    # shellcheck disable=SC2046
    xcrun clang++ -arch arm64 -bundle -exported_symbols_list "$exports" \
        -framework CoreFoundation -framework Foundation \
        -o "$tmp/Contents/MacOS/$name" $(objects_for "$@")
    cat >"$tmp/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>dev.emberstudio.tests.$name</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
</dict></plist>
PLIST
    rm -rf "$out/$name.vst3"
    mv "$tmp" "$out/$name.vst3"
}

make_bundle again "$sdk/public.sdk/source/main/macexport.exp" "${sdk_common[@]}" "${again_sources[@]}"
make_bundle EmberTest "$ember/ember_test.exp" "${sdk_common[@]}" "${ember_sources[@]}"
echo "build-test-vst3: built $out/again.vst3 and $out/EmberTest.vst3"
