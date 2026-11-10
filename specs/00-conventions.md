# 00 — Conventions

**Applies to:** everything.

## 1. Languages & style
- **C++20** (Apple Clang) in `DAWEngine`. Use `-Wall -Wextra -Werror`, no exceptions across module boundaries, and no RTTI in RT code paths. Namespace `daw`.
- **Swift 6** language mode with strict concurrency in `DAWModel`, `DAWControl`, `dawctl`, `dawmcp` and `App`.
- Naming: C++ types `PascalCase`, functions `camelCase`, members `m_` prefix is **not** used (use trailing `_` for private members). Swift follows the API Design Guidelines.
- One type per file where practical; file name = type name.
- Comments explain *why*, and cite requirement IDs where behavior is spec-driven: `// ENG-014: never free on the audio thread`.

## 2. Real-time rules (CONV-RT)
These apply to any code reachable from `Engine::render()`.

| ID | Rule |
|---|---|
| CONV-RT-01 | No heap allocation or deallocation (`new`, `delete`, `malloc`, `std::vector` growth, `std::string`, `std::function` construction). |
| CONV-RT-02 | No locks (`std::mutex`, `os_unfair_lock`, `@synchronized`), no condition variables, no `dispatch_*`. |
| CONV-RT-03 | No Objective-C or Swift runtime calls, no logging, no file or socket I/O, no syscalls except those CoreAudio makes. |
| CONV-RT-04 | Unbounded loops are forbidden; every loop is bounded by block size, node count or voice count. |
| CONV-RT-05 | Cross-thread communication uses only `std::atomic`, SPSC ring buffers (`daw::SpscQueue`) or the snapshot pointer (ENG). |
| CONV-RT-06 | RT functions are annotated `DAW_RT` (a macro, expands to `noexcept [[clang::nonblocking]]` when available: clang warns on a nonblocking function that isn't `noexcept`, and `-Werror` fails; DW-008) so they can be found by grep and checked by the compiler. |

The debug RT trap (ENG-030..033) enforces RT-01/02 at runtime. A violation fails tests.

## 3. Threads
Named threads, created only by `DAWEngine`:

| Name | Role |
|---|---|
| `daw.audio` | CoreAudio render callback (joined to the device `os_workgroup`) |
| `daw.compile` | Builds RenderGraphs from GraphDescriptions |
| `daw.reclaim` | Frees retired snapshots and other RT-retired objects |
| `daw.diskwrite` | Writes recorded audio from FIFOs to disk |
| `daw.loader` | Decodes and resamples audio files into RAM |
| `daw.export` | Runs offline render jobs (export, `render.offline`) for the facade, off the main thread (T-014, DW-080) |
| `daw.device` | Reacts to device notifications (IO-020..022): runs the hot-swap sequence through the facade, never on `daw.audio` (T-051) |
| `daw.midi` | Owns the CoreMIDI client (REC-010): connects sources as they appear, closes gone ones; CoreMIDI's own receive thread feeds the input queues (T-053) |

In Swift, the model is `@MainActor`-isolated in the app. In `dawctl`/`dawmcp` it runs on a single serial actor.

## 4. Errors & logging
- C++: return `daw::Result<T>` (expected-like) from non-RT APIs. RT code never fails; it outputs silence and bumps a telemetry counter instead.
- Swift: typed `throws(DAWError)` at module boundaries.
- Logging uses `os_log` with subsystem `dev.emberstudio` and categories per module. RT code logs only through a lock-free telemetry ring drained by `daw.reclaim`.

## 5. Definition of done (any task)
1. Code builds with `swift build` and `xcodebuild` (app) without warnings.
2. All requirements claimed by the task have tests that cite their IDs, and those tests pass under `swift test`.
3. Any RT code path is exercised by a test with the RT trap enabled and shows 0 violations.
4. If the task touches audio output, a golden render test exists (see 14-testing).
5. If the task adds user-visible behavior, it can be driven through `dawctl`/`dawmcp` (see 13-control-mcp), unless it is UI-only.
6. The worker's final report maps each requirement to its test. The **lead** copies this into the spec's **Status** table when merging (workers don't edit Status tables, to avoid conflicts between worktrees).

## 6. Spec change protocol
- **Requirements** (behavior) may be clarified by the implementing agent if the change doesn't affect other specs. Edit the spec in the same change and note it in the commit message.
- **Interfaces** (sections titled *Interfaces*) are contracts between agents. To change one:
  1. Edit the interface in the spec, marking it `PROPOSED` with a rationale.
  2. List the affected specs and tasks.
  3. Stop and get orchestrator/user approval before implementing.
- **Decision log** entries (SPEC.md) are changed only by the user.

## 7. Module ownership
An agent edits only files in the module(s) its task names. If it needs a change in another module, it lists that change under *Discovered work* in its final report, and the lead turns it into a task in `specs/90-tasks.md`.

## 9. Parallel worktrees
Workers run concurrently in separate git worktrees (Patchbay, see `90-tasks.md`). So nothing may depend on a fixed machine-global path that two worktrees would share at the same time: sockets, temp files, build outputs, caches written during tests. Use paths inside the worktree, or under `$TMPDIR` with a per-process unique name.

## 8. Requirement status tracking
Every spec ends with a `Status` table: `| ID | status | test |` where status ∈ `todo | wip | done | deferred`.
