#!/usr/bin/env bash
# BUILD-009, TEST-007, TEST-008 (T-084): the CI jobs. .github/workflows/ci.yml calls one job per
# runner; every job runs the same way on a developer machine, without GitHub:
#
#   scripts/ci.sh test   DW-005: clean build (no compiled outputs left over, so the "no warnings"
#                        check sees every file), then scripts/test.sh. Runs on every push to main.
#   scripts/ci.sh asan   TEST-007: the C++ engine tests (DAWEngineTests) with ASan + UBSan.
#   scripts/ci.sh tsan   TEST-007: the engine tests with TSan, then a stress loop over the
#                        snapshot publish/reclaim tests.
#   scripts/ci.sh perf   TEST-008 + DW-241/252: release build; the perf smoke alone, then the
#                        wall-clock tests, all with DAW_PERF_TESTS=1 (strict bounds).
#
# The sanitizer and perf jobs run on workflow_dispatch and a weekly schedule (DECISIONS phase 9,
# "T-084 CI scope"). Each sanitizer/perf job builds into its own scratch path (.build/asan,
# .build/tsan, .build/perf), so it never invalidates the normal .build/debug and .build/release.
# Logs: .build/ci-logs/. Environment knobs:
#   DAW_TSAN_ITERATIONS  stress loop passes in the tsan job (default 10)
#   DAW_CI_KEEP_BUILD=1  `test` skips the clean (a quicker local rerun; not what CI does)
#   DAW_CI_SKIP=<regex>  asan/tsan/perf: also skip these tests (`swift test --skip`), e.g. to see
#                        the rest of a sanitizer run past a known finding while it is being fixed
set -uo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)
logs="$root/.build/ci-logs"
mkdir -p "$logs"

usage() { echo "usage: scripts/ci.sh test|asan|tsan|perf" >&2; exit 2; }
(( $# == 1 )) || usage
job=$1

note() { echo "ci[$job]: $*"; }
fail() { echo "ci[$job]: FAILED: $*" >&2; exit 1; }

# run_tests <log> <swift test args…>: runs swift test, keeps its output in <log>, and fails unless
# it passed and actually ran tests (a filter that matches nothing passes too).
run_tests() {
    local log=$1; shift
    local skip=${DAW_CI_SKIP:-}
    [[ -n "$known" ]] && skip=${skip:+$skip|}$known
    [[ -n "$skip" ]] && set -- "$@" --skip "$skip"
    note "swift test $* (log: ${log#"$root"/})"
    swift test "$@" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    (( rc == 0 )) || fail "swift test exited $rc (see $log)"
    grep -Eq 'Test run with [1-9][0-9]* tests? (in [0-9]+ suites? )?passed' "$log" \
        || fail "no Swift Testing run passed in $log (did the filter match anything?)"
}

# no_sanitizer_reports <log>: a sanitizer that reports and continues must still fail the job.
no_sanitizer_reports() {
    if grep -E 'ERROR: AddressSanitizer|runtime error:|WARNING: ThreadSanitizer|ERROR: ThreadSanitizer' "$1"; then
        fail "sanitizer reports in $1"
    fi
}

# Known sanitizer findings in test fixtures (not engine code), skipped by name until fixed so the
# job stays a regression signal. Each names the discovered-work item that removes it (T-084 report):
#   asan: CompressorChecks.cpp compressorThroughEngine reads 128 floats past `key` (48000 isn't a
#         multiple of its 256-frame step).
#   tsan: FakeAudioUnit.mm's FakeDSP gain/sidechainMix are plain floats written by the render block
#         and read by AUParameter's value provider on another thread.
known=
case "$job" in
asan) known='CompressorTests/throughEngine' ;;
tsan) known='AUPluginTests' ;;  # every test that renders the fake AU
esac

prepare() {
    scripts/bootstrap.sh || fail "bootstrap"
    # PLUG-011: the VST3 tests load real bundles (no-op when current).
    scripts/build-test-vst3.sh >"$logs/test-plugins.log" 2>&1 || fail "test plugins (see $logs/test-plugins.log)"
}

case "$job" in
test)
    if [[ "${DAW_CI_KEEP_BUILD:-}" != 1 ]]; then
        # DW-005: test.sh's warning check reads the build log, which lists only recompiled files.
        # Removing every compiled output (SwiftPM's and the app's derived data) makes it see all
        # of them. Fetched dependencies stay (.build/checkouts, .build/repositories).
        note "clean build: removing compiled outputs"
        swift package clean || fail "swift package clean"
        rm -rf .build/xcode .build/test-plugins
    fi
    scripts/test.sh || fail "scripts/test.sh"
    ;;

asan)
    prepare
    scratch=.build/asan
    note "building with ASan + UBSan into $scratch"
    swift build --build-tests --sanitize=address --sanitize=undefined --scratch-path "$scratch" \
        >"$logs/asan-build.log" 2>&1 || { tail -n 40 "$logs/asan-build.log"; fail "asan build"; }
    # DW-054: ASan replaces malloc, so the RT trap sees no allocations; the trap's own tests read
    # DAW_SANITIZER and skip what can't work (14-testing, "Sanitizers"). UBSan halts on the first
    # report; macOS has no LeakSanitizer (DW-039).
    DAW_SANITIZER=address \
    ASAN_OPTIONS=halt_on_error=1:detect_leaks=0 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        run_tests "$logs/asan-test.log" --skip-build --sanitize=address --sanitize=undefined \
        --scratch-path "$scratch" --filter '^DAWEngineTests\.'
    no_sanitizer_reports "$logs/asan-test.log"
    ;;

tsan)
    prepare
    scratch=.build/tsan
    iterations=${DAW_TSAN_ITERATIONS:-10}
    note "building with TSan into $scratch"
    swift build --build-tests --sanitize=thread --scratch-path "$scratch" \
        >"$logs/tsan-build.log" 2>&1 || { tail -n 40 "$logs/tsan-build.log"; fail "tsan build"; }
    export DAW_SANITIZER=thread TSAN_OPTIONS=halt_on_error=1:second_deadlock_stack=1
    # DW-065: the whole engine suite once (the RT-trap allocation tests, exit tests and IO-010's
    # wall-clock bound skip themselves under DAW_SANITIZER=thread)…
    run_tests "$logs/tsan-test.log" --skip-build --sanitize=thread --scratch-path "$scratch" \
        --filter '^DAWEngineTests\.'
    no_sanitizer_reports "$logs/tsan-test.log"
    # …then the snapshot publish/reclaim paths over and over: ENG-010..015 snapshots (10k publishes
    # during render, stalled audio thread, idle replace, RT retire), node lifetime on daw.reclaim
    # (ENG-013), GraphCompiler on daw.compile, asset references dropped on daw.reclaim (IO-032), lock-free telemetry
    # readers (ENG-050).
    stress='^DAWEngineTests\.(SnapshotTests|NodeAPITests|GraphBuilderTests|AudioAssetTests|TelemetryTests)'
    for (( i = 1; i <= iterations; i++ )); do
        run_tests "$logs/tsan-stress.log" --skip-build --sanitize=thread --scratch-path "$scratch" --filter "$stress"
        no_sanitizer_reports "$logs/tsan-stress.log"
        note "stress pass $i/$iterations clean"
    done
    ;;

perf)
    prepare
    scratch=.build/perf
    note "release build of the tests into $scratch"
    # The test targets use @testable imports, which a release build allows only with -enable-testing
    # (`swift test` adds it itself; `swift build --build-tests` doesn't).
    swift build --build-tests -c release -Xswiftc -enable-testing --scratch-path "$scratch" \
        >"$logs/perf-build.log" 2>&1 || { tail -n 40 "$logs/perf-build.log"; fail "perf build"; }
    export DAW_PERF_TESTS=1
    # TEST-008 alone, so nothing else competes for the CPU; it writes its ratio and the engine's
    # telemetry snapshot to perf-TEST-008.json (uploaded by the workflow).
    rm -f "$logs/perf-TEST-008.json"
    DAW_PERF_REPORT="$logs/perf-TEST-008.json" \
        run_tests "$logs/perf-test-008.log" -c release --skip-build --scratch-path "$scratch" \
        --filter '^GoldenTests\.PerfSmokeTests'
    [[ -s "$logs/perf-TEST-008.json" ]] || fail "TEST-008 wrote no report"
    cat "$logs/perf-TEST-008.json"; echo
    # DW-241/252, DW-223, IO-010: the wall-clock tests with their strict bounds.
    run_tests "$logs/perf-wallclock.log" -c release --skip-build --scratch-path "$scratch" \
        --filter '^(DAWModelTests\.SyncCostTests|DAWControlTests\.ProgressTests|DAWEngineTests\.TelemetryTests/concurrentReaders|DAWEngineTests\.OfflineDriverTests/performance|EmberStudioShellTests\.ArrangePerfTests)'
    ;;

*) usage ;;
esac

note "ok"
