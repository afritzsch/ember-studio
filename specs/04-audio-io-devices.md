# 04 — Audio I/O, Devices & File Loading

**Depends on:** 02, 03 · **Owns:** `Sources/DAWEngine/io/` (DeviceDriver, OfflineDriver, DeviceMonitor, AudioFileLoader, AudioFileWriter).

## Device driver

| ID | Requirement | Acceptance |
|---|---|---|
| IO-001 | `CoreAudioDriver` uses the AUHAL output unit (input enabled when recording/monitoring is armed) and calls `Engine::render` from the IO proc. | Plays a test sine through the default device |
| IO-002 | The audio thread joins the device's `os_workgroup` (`kAudioDevicePropertyIOThreadOSWorkgroup`). | Verified via `os_workgroup` API return codes in a test log |
| IO-003 | Configurable buffer size (32–2048, default 256) and sample rate (44.1/48/88.2/96 kHz, default = device nominal). | — |
| IO-004 | Separate input and output devices are supported only when they share a clock (aggregate devices are user-made). Otherwise input = output device. | — |
| IO-005 | Report `inputLatency` and `outputLatency` in samples = device latency + safety offset + buffer size (+ stream latency) from CoreAudio properties. | Telemetry shows values |

## Offline driver

| ID | Requirement | Acceptance |
|---|---|---|
| IO-010 | `OfflineDriver` calls `Engine::render` in a loop on a non-RT thread with a fixed block size, as fast as possible, writing to an `AudioFileWriter`. It needs no device. | Renders a 60 s project in < 10 s for a simple project |
| IO-011 | The offline render is **bit-identical** to itself across runs (determinism: no time-based randomness; reverb/delay use seeded state). | Golden test runs twice and compares |
| IO-012 | Offline render applies a tail: after the range end it continues until output < −90 dBFS for 1 s or 10 s max (configurable). | — |
| IO-013 | The RT trap remains active in offline mode, so offline tests catch RT violations. | — |

## Hot-swap, rate changes, overload (D-12, D-26)

| ID | Requirement | Acceptance |
|---|---|---|
| IO-020 | `DeviceMonitor` listens to `kAudioHardwarePropertyDevices`, `DefaultOutputDevice`, `kAudioDevicePropertyDeviceIsAlive` and `NominalSampleRate`. | — |
| IO-021 | On device loss or rate change: (1) stop transport, (2) if recording, finalize recordings (09), (3) stop the driver, (4) select the system default output, (5) if the rate changed, set `sessionRate` (or keep the project rate if the device supports it), re-prepare all nodes, re-resample loaded audio (IO-033), rebuild the graph, (6) restart the driver, (7) emit `EngineEvent.deviceChanged{reason}` for a UI toast. | Simulated test: a `FakeDeviceDriver` triggers loss; the sequence is observed in order |
| IO-022 | No callback to the UI happens on the audio thread; events go through `SpscQueue<EngineEvent>` and are polled by the facade. | — |
| IO-023 | **Xrun detection:** count `kAudioDeviceProcessorOverload` notifications and render-time > block-duration events; expose them via telemetry and as `EngineEvent.overload`. No auto-bypass in v1. | Test with a deliberately slow node |

## Audio files (D-10, D-27)

| ID | Requirement | Acceptance |
|---|---|---|
| IO-030 | Import copies (or references, user option, default copy) the original file into `Project/Audio/` unchanged. | — |
| IO-031 | `AudioFileLoader` (on `daw.loader`) decodes WAV/AIFF/CAF/MP3/AAC/FLAC via `ExtAudioFile`/`AVAudioFile` into a non-interleaved float32 `AudioAsset` in RAM at the **session rate**, resampling with `AVAudioConverter` (quality `.max`, `sampleRateConverterAlgorithm = Mastering`). | Null-ish test: 48k→44.1k→48k round trip with residual < −80 dB in band |
| IO-032 | `AudioAsset` is immutable, ref-counted and retired through the reclaim mechanism (ENG-014). | — |
| IO-033 | A session-rate change re-converts every asset from the original files in the background; new assets swap in through a new snapshot; playback stays stopped until done (with progress events). | — |
| IO-034 | Waveform overview: at import/load, compute min/max peak mipmaps (block sizes 256, 1024, 4096, 16384), cached as `Project/Cache/<assetID>.peaks`. | UI reads them (12) |
| IO-035 | `AudioFileWriter` writes 32-bit float CAF (recording) or WAV/AIFF 16/24/32f (export) with optional TPDF dither for 16/24-bit. | Export test |

## Interfaces (contract)
```cpp
namespace daw {
class AudioDriver { public: virtual Result<void> start(const DriverConfig&) = 0; virtual void stop() = 0;
  virtual DeviceLatency latency() const = 0; virtual ~AudioDriver() = default; };
class CoreAudioDriver final : public AudioDriver { ... };
class OfflineDriver { public: Result<void> render(Engine&, Tick from, Tick to, const ExportSpec&, ProgressFn); };
enum class EngineEventType : uint8_t { deviceChanged, overload, recordingFinalized, assetsReloaded, pluginCrashed };
struct AudioAsset { uint64_t assetID; double sampleRate; uint32_t channels; int64_t frames; const float* const* data; };
}
```

## Status
| ID | status | test |
|---|---|---|
| IO-001 | done (T-011) | `DeviceRendererTests` (cycles render in blocks ≤ buffer size, contiguous, extra channels silent, 0 RT violations); `CoreAudioDriverTests` "plays a sine" (AUHAL default output, stop/restart; skipped without a device or with `DAW_SKIP_DEVICE_TESTS=1`; −80 dBFS unless `DAW_AUDIBLE_DEVICE_TEST=1`) |
| IO-002 | done (T-011) | `WorkgroupJoinTests` (fake os_workgroup: join on first cycle and on a new IO thread, leave on stop, EALREADY/errors, 0 RT violations); device run logs the join result (AUHAL IO threads are already members: EALREADY) |
| IO-003 | done (T-011) | `DriverConfigTests` "resolves" (nominal default rate, fallback, explicit; buffer 32…2048 clamped to the device; channels); device run checks the resolved rate/buffer. `DriverConfig` defined in `io/DriverConfig.h` |
| IO-004 | done (T-011) | `DriverConfigTests` "inputChoice" (separate input only on a shared clock); `InputFifoTests` (wrap, underrun, backlog drop, overflow; two threads, 0 RT violations); opt-in device runs (`DAW_DEVICE_INPUT_TESTS=1`): duplex and separate-device input via second AUHAL + FIFO |
| IO-005 | done (T-011) | `DeviceLatencyTests` (device + safety offset + buffer + stream, saturating; published to `Telemetry::setDeviceOutputLatency` and `Transport::setOutputLatency`); device run matches the CoreAudio properties. `DeviceLatency` defined in `io/DeviceLatency.h` |
| IO-030 | done (T-010) | `AudioFileLoaderTests` "Audio import" (copy by default, no overwrite on collision, reference mode, rejects bad files). `AudioImporter::importFile`; the ImportAsset command is model work |
| IO-031 | done (T-010) | `AudioFileLoaderTests` "AudioFileLoader" (48k→44.1k→48k residual < −80 dB; decode per format; mono/6ch/empty; errors; ordered on daw.loader). AudioConverter Mastering SRC; MP3 decode untested (macOS can't encode it, no fixture) |
| IO-032 | done (T-010) | `AudioFileLoaderTests` "AudioAsset" (ref-counted, last release retires; on the audio thread via `AudioAssetRef::retire(engine.retireQueue())`, otherwise via RetireHook; 0 RT violations) |
| IO-033 | todo (T-056) | Peak cache already detects a stale rate and rewrites itself |
| IO-034 | done (T-010) | `AudioFileLoaderTests` "Peak mipmaps" (brute-force match, documented `.peaks` layout, corrupt files rejected, cache reuse/refresh) |
| IO-010 | done (T-009) | `OfflineDriverTests` (tick range → frames at fixed block size, follows tempo changes, progress; 60 s simple project < 10 s). Exports play through the transport (play + locate(from), restore after); per-block playhead check fails on a wrong map/rate, graph swap or oversize block. 60 s render takes 0.49 s in Debug |
| IO-011 | done (T-009) | `OfflineDriverTests` (two runs → identical bytes: 16-bit dithered file, float file, sink; two exports on one engine with stateful timeline nodes); `TpdfDitherTests` (same seed → same bytes for any block split) |
| IO-012 | done (T-009) | `OfflineDriverTests` (decaying tail ends after quiet time; loud frame restarts the count; endless tone stops at max) |
| IO-013 | done (T-009) | `OfflineDriverTests` (nodes run inside the trap scope offline; allocating node counted by the render thread's own count) |
| IO-035 | done (T-009) | `AudioFileWriterTests` (9 formats round trip within quantization error; recordings are float CAF; clamp/NaN; errors); `TpdfDitherTests` (triangular, variance 1/6, seeded). `ExportSpec` defined in `io/ExportSpec.h` |
| IO-* (rest) | todo | |
