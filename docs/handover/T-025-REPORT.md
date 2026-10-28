## Status at stop

- **Committed** (`31dd787`, "T-025: WIP …", on `t-025-m2-goldens`):
  - `GoldenFixture.swift` / `GoldenHarness.swift`: `# @expect` takes an optional `"channel": n`, which checks only that channel of a per-channel field. pan_law needs it (hard-left means L loud and R silent), and so does the planned PDC null (L null, R signal).
  - `fixtures/assets/gen_m2_assets.py` and its outputs `tone_1k_48k.wav` (1 kHz at 0.5, 12000 frames, mono float32 at 48 kHz, ends on a zero crossing) and `click_48k.wav` (1.0 at frame 0, then 4799 frames of silence).
  - `fixtures/pan_law.jsonl` (MIX-005): five tracks with clips in successive 480-tick segments, panned −1/−0.5/0/+0.5/+1, plus per-segment and per-channel `@expect` lines computed from the law (−9.031 / −9.719 & −17.374 / −12.041 dBFS peak).
- **Not green at the last commit.** `scripts/test.sh` was never run. GoldenTests will fail on this commit because `pan_law` has no reference yet (`referencesMatchFixtures` and the golden case both fail). No reference was generated. The `swift build --build-tests` that passed started before the harness edit, so the `channel` change hasn't been compiled yet.
- **Half-done:** in dawmcp, `pan_law` builds cleanly (`daw_test_fixture` ran 16 requests, 1 skipped), using a temporary `assets` symlink that has since been removed. Its render hasn't been analyzed yet.
- **Exact next steps:**
  1. `swift build --build-tests` to compile the `channel` change. Add a `GoldenHarnessTests` case for `channel` (it passes on one channel, fails out of range, and fails on a scalar field).
  2. `scripts/update-goldens.sh pan_law`, then commit the reference with the summary pasted (TEST-003). Add a `GoldenReferenceTests` check that L²+R² of the reference is constant across all five segments.
  3. `bus_send_sum.jsonl` (MIX-004/007). Plan: bus "FX" goes to master at unity. Bus "Dry" goes to master and is muted, and every track outputs to Dry, so only the send paths are heard. Each segment is 12000 frames and FX→out is ×0.5:
     - seg 0: "Post" (gain 0.5, pan −1, post-fader send at level 1): L −18.06, R silent.
     - seg 1: "Pre" (gain 0.25, pan −1, pre-fader send at level 0.5): both channels −18.06.
     - seg 2: both clips play: L −12.04, R −18.06 (MIX-004 sum).
     - seg 3: "Muted" track with a pre- and a post-fader send: silent. Silence is checked as `peakDb` −180 ± 60.
     - IDs: master is 1 and IDs are then sequential (AddBus, AddTrack and AddSend each take the next one, as do asset.import and clips).
  4. Optional `send_ramps.jsonl` (DW-093). Use a DC test source (`@node` impulse with samples 1). Bus FX-L is panned −1 and FX-R +1. Prime-render with one track's send level at 0 (post-fader send → FX-L) and another track muted (pre-fader send → FX-R). Then set the level to 1 and unmute. In the golden, block 0 ramps 0→1 on both: L = 0.5·(i+1)/512 and R = √½·(i+1)/512. Check the ramp shape against GainNode first.
  5. `pdc_alignment_null.jsonl` (MIX-021/023). A latent insert can be placed through commands: `RestoreTrack`/`RestoreBus` accept full `inserts` with builtin kinds and claim any unused IDs. `RestoreTrack` was verified in dawmcp and accepted IDs 10/11. In the real engine `delay` has no factory ("no factory for NodeKind 7"), so this fixture renders only in GoldenTests (DW-135).
     - Test nodes: `@node` delay = fakeLatency 1000, eq = fakeLatency 300, compressor = fakeLatency 500.
     - Bus "Master FX" (from RestoreBus, with the compressor insert) stands in for a master insert: every track routes through it, so graph latency is 1500.
     - Tracks: "Dry" (pan −1) and "Latent" (delay insert, pan −1, phase invert), both with the tone clip at tick 480, null L. "Latent R" (eq insert, pan +1, tone clip at tick 480) and "Click" (pan +1, click clip at tick 0) go to R.
     - Expect: L silent throughout. R: −6.02 in frames 0..<1, silent in 1..<12001, −12.04 in 12000..<24000, silent in 24000..<36000. Render 0..1440 ticks.
     - Add an exact-sample reference test.
  6. Run `scripts/test.sh` (rerun with `DAW_SKIP_DEVICE_TESTS=1` if the CoreAudio test fails for environmental reasons), then write the full report.

## T-025 report
- Requirements: MIX-005 → `GoldenRenderTests` "pan_law" (fixture committed, reference pending); MIX-004/007 → `bus_send_sum` (not started; plan above); MIX-021/023 → `pdc_alignment_null` (not started; plan above)
- Tests: not run (session stopped by lead). GoldenTests are expected to fail at `31dd787` until the pan_law reference exists.
- RT violations: not measured
- Interface proposals: none
- Discovered work:
  - No command places a **master** insert: there's no `InsertDevice` and no `RestoreMaster`. A literal "latent master insert" (MIX-023 golden) can't be scripted, so a bus that every track routes through stands in for it. Lane: model (T-031 or a later commands task).
  - Track and bus inserts can only be placed through `RestoreTrack`/`RestoreBus` with hand-written IDs. `InsertDevice` (MODEL-005) is still missing. Lane: model.
  - dawmcp `test.fixture` resolves a fixture's relative `asset.import` paths against the server's cwd, not the fixture's folder or the `assets/` symlink GoldenHarness provides. So `wav_playback_resampled` and `pan_law` fail in dawmcp with "no file at <worktree>/assets/…". Lane: control (T-032 / dawmcp).
- Notes for reviewer: the assets are float32 at the session rate on purpose, so the levels in `@expect` are exact (the old 16-bit asset reads 0.49998 instead of 0.5). The `channel` directive is backwards compatible: when it's omitted, every channel is checked as before.
