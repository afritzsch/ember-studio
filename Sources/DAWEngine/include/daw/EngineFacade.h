#pragma once
// 08-bridge-facade: the only engine API Swift sees (D-18, 01 Interfaces). EngineClient
// (DAWModel/Engine) wraps it; nothing else in Swift imports DAWEngine (BRIDGE-007).
//
// What may appear here: the standard library, daw/GraphDescription.h, and plain-data types
// that mirror engine types without including them (the engine's headers aren't on Swift's
// include path). No templates of ours, no exceptions, no std::function, no owning raw pointers
// except the facade itself, which is a Swift class reference (BRIDGE-001).
//
// Threads (BRIDGE-002): every method is non-RT and thread-safe. Long operations (asset loads,
// offline renders) return a JobID that Swift polls with pollJob(); the engine never calls back
// into Swift. Events are polled too (BRIDGE-004).
//
// Deltas to the 08 contract (setDevice's return type, EngineEventType's facade cases,
// graphStatus/waitForGraph/nodeLatencies (T-014); device changes, the fake driver and
// simulateDeviceEvent (T-051)) are listed in specs/08-bridge-facade.md.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "daw/GraphDescription.h"

#if __has_include(<swift/bridging>)
#include <swift/bridging>
#else
#define SWIFT_SHARED_REFERENCE(_retain, _release)
#define SWIFT_RETURNS_RETAINED
#define SWIFT_UNCHECKED_SENDABLE
#endif

namespace daw {

// MARK: Plain data

using JobID = uint64_t;                          // 0: no job (the request was rejected up front)
// BRIDGE-006: plugin state blobs. Named so Swift can construct one (it can't spell templates).
using ByteVector = std::vector<uint8_t>;
inline constexpr ParamID kInvalidParamID = 0xFFFF'FFFFu;  // allocateParams failed

// BRIDGE-008
enum class EngineMode : uint8_t {
    realtime,  // a device driver renders (04 IO-001); see facade/DriverAdapter.h
    offline,   // no device: renders only through renderOffline (dawctl, dawmcp, tests)
};

// T-051, DW-089: which device driver a realtime facade runs. `fake` is FakeDeviceDriver (TEST-005)
// on two made-up devices, paced in real time: id 1 "Fake Device A" (44.1/48/88.2/96 kHz, nominal
// 48 kHz) and id 2 "Fake Device B" (44.1 kHz only). simulateDeviceEvent drives it, so dawctl and
// dawmcp can exercise IO-021 without hardware.
enum class DeviceDriverKind : uint8_t { coreAudio, fake };

// IO-003/004: mirrors io/DriverConfig.h's DriverConfig (the 08 contract calls it DriverConfig,
// which the io type already is; Swift can't see io/). The facade decides inputEnabled itself
// (DW-067: input runs while a track is armed). In offline mode only sampleRate matters: it is the
// session rate.
struct DriverConfigPOD {
    uint32_t outputDevice = 0;    // AudioObjectID; 0: the system default output
    uint32_t inputDevice = 0;     // 0: the system default input (IO-004 may pick the output)
    double sampleRate = 48000.0;  // 0 in realtime mode: the device's nominal rate
    uint32_t bufferFrames = 256;  // 32…2048
    uint32_t outputChannels = 2;
    uint32_t inputChannels = 2;
    DeviceDriverKind driver = DeviceDriverKind::coreAudio;  // fixed at create (T-051)
};

// Mirrors daw::ErrorCode (core/Result.h), plus `none` for success. DW-050: `cycle` is a
// rejected routing cycle (MIX-002); Error::nodes crosses as FacadeError::cycle.
enum class FacadeErrorCode : uint32_t {
    none,
    invalidArgument,
    outOfMemory,
    notFound,
    unsupported,
    io,
    internal,
    cycle,
};

struct FacadeError {
    FacadeErrorCode code = FacadeErrorCode::none;
    std::string message;
    std::vector<NodeID> cycle;  // ascending; set only for code == cycle
    bool ok() const { return code == FacadeErrorCode::none; }
};

// TIME-009, DW-059: the playhead (TransportPlayhead), i.e. the position being heard.
struct TransportPOD {
    int64_t sample = 0;
    Tick tick = 0;
    bool playing = false;
    bool recording = false;
    bool loopEnabled = false;
    Tick loopStart = 0;
    Tick loopEnd = 0;
    // REC-005 (T-052): the punch range (setPunch). Recording writes only inside it while the loop
    // is off.
    bool punchEnabled = false;
    Tick punchIn = 0;
    Tick punchOut = 0;
};

// MARK: Jobs (BRIDGE-002)

enum class JobKind : uint8_t { none, loadAsset, renderOffline, instantiatePlugin };
enum class JobState : uint8_t {
    unknown,    // no such job
    queued,
    running,
    succeeded,
    failed,
};

// loadAsset's result (IO-031): the asset in RAM, at the session rate.
struct AssetInfoPOD {
    uint64_t assetID = 0;
    uint32_t channels = 0;
    int64_t frames = 0;           // at sampleRate
    double sampleRate = 0;        // the session rate
    double fileSampleRate = 0;
    int64_t fileFrames = 0;       // at fileSampleRate
    bool resampled = false;
};

// IO-034 / UI-011 (autobuild, see DECISIONS.md): one level of a loaded asset's peak mipmap, for the
// arrange canvas's waveforms. Read-only and non-RT: the facade computes the mipmap on daw.loader
// when the asset loads (PeakMipmap::compute) and `peaks` copies one level out under its lock.
using FloatVector = std::vector<float>;
inline constexpr uint32_t kPeakLevelCount = 4;  // PeakMipmap::kBlockSizes: 256, 1024, 4096, 16384

struct PeakLevelPOD {
    bool found = false;      // false: the asset hasn't loaded (yet), or `level` is out of range
    uint64_t assetID = 0;
    uint32_t channels = 0;
    double sampleRate = 0;   // the asset's rate in RAM (the session rate)
    int64_t frames = 0;      // at sampleRate
    uint32_t blockSize = 0;  // frames per min/max pair
    int64_t blockCount = 0;  // ceil(frames / blockSize); the last block may be partial
    FloatVector minMax;      // channel-major pairs: [(c × blockCount + b) × 2] = min, [… + 1] = max
};

// renderOffline's result (IO-010..013, OfflineRenderStats).
struct OfflineResultPOD {
    double sampleRate = 0;
    int64_t rangeFrames = 0;
    int64_t tailFrames = 0;
    int64_t framesWritten = 0;
    uint64_t blocks = 0;
    uint64_t rtViolations = 0;    // IO-013: the render thread's own count (0 in Release)
    uint64_t clippedSamples = 0;
    double renderSeconds = 0;
};

struct JobStatus {
    JobID job = 0;
    JobKind kind = JobKind::none;
    JobState state = JobState::unknown;
    double progress = 0;          // 0…1; renders: frames so far / (range + maximum tail)
    FacadeError error;            // set when failed
    AssetInfoPOD asset;           // loadAsset, once succeeded
    OfflineResultPOD render;      // renderOffline, once finished (partial stats if failed)
};

// MARK: Offline export (DW-057)

// Mirror io/AudioFileWriter.h's AudioFileType and AudioSampleFormat.
enum class ExportFileType : uint8_t { caf, wav, aiff };
enum class ExportSampleFormat : uint8_t { int16, int24, float32 };

// Maps onto daw::ExportSpec (io/ExportSpec.h). The tempo map isn't here: the facade passes the
// map of the graph it is rendering (DW-064).
struct ExportSpecPOD {
    std::string path;             // empty: render without writing a file
    ExportFileType fileType = ExportFileType::wav;
    ExportSampleFormat sampleFormat = ExportSampleFormat::float32;
    bool dither = false;          // IO-035: TPDF, for int16/int24
    uint64_t ditherSeed = 0x6d61'6344'4157'0035ull;  // kDefaultDitherSeed (io/TpdfDither.h)
    uint32_t numChannels = 2;
    uint32_t blockSize = 512;     // IO-010; at most the graph's maxBlock (DW-056)
    // IO-012
    bool tailEnabled = true;
    double tailThresholdDb = -90.0;
    double tailQuietSeconds = 1.0;
    double tailMaxSeconds = 10.0;
    // T-036: keep the transport's loop and wrap at its end (ExportSpec::followLoop); false plays
    // the range straight through.
    bool followLoop = false;
};

// MARK: Graph status (DW-047)

struct GraphStatusPOD {
    uint64_t submittedVersion = 0;  // the latest applyGraph
    uint64_t completedVersion = 0;  // the latest one built, rejected or dropped as superseded
    uint64_t publishedVersion = 0;  // the one rendering (0: none yet)
    FacadeError lastError;          // from the latest build; none after a success
};

// MARK: Observability (BRIDGE-005)

// ENG-050/051, DW-049: TelemetrySnapshot field by field, plus facade-level state.
struct TelemetryPOD {
    float dspLoadPercent = 0;
    float lastBlockLoadPercent = 0;
    uint64_t xruns = 0;
    uint64_t rtViolations = 0;
    uint64_t graphEpoch = 0;
    uint64_t oversizeBlocks = 0;
    uint64_t retireQueueFullBlocks = 0;
    uint32_t deviceOutputLatency = 0;
    uint32_t graphLatency = 0;
    uint32_t outputLatency = 0;
    uint32_t numNodeLatencies = 0;
    // Facade additions.
    uint64_t graphVersion = 0;        // DW-047: applyGraph version of the published graph
    uint64_t blocksRendered = 0;
    uint32_t paramsAllocated = 0;     // slots in use, including ones waiting to be freed
    uint32_t paramsPendingFree = 0;   // DW-029: freed but maybe still read by an old graph
    uint32_t assetsLoaded = 0;
    uint64_t eventsDropped = 0;       // the event queue overflowed (nobody polled)
    double sampleRate = 0;            // the session rate graphs are built at
    bool deviceRunning = false;
    // T-051: the output device running (AudioObjectID; 0 while stopped), and xruns (IO-023) by
    // source: kAudioDeviceProcessorOverload notifications and render overruns (DW-068). Counted
    // since the facade was created; xruns may also hold counts from before.
    uint32_t outputDeviceID = 0;
    uint64_t processorOverloads = 0;
    uint64_t renderOverruns = 0;
    // IO-033 (T-056): assets of the running session-rate re-conversion still to come (0: none
    // running; play() is refused until it is 0 again).
    uint32_t assetsReloadPending = 0;
    // REC-002/003 (T-052): frames dropped because a recording FIFO was full (all takes since the
    // facade was created), the running device's input latency (IO-005; 0 without input), and
    // the tracks armed for recording (armInput).
    uint64_t recordDrops = 0;
    uint32_t deviceInputLatency = 0;
    uint32_t armedTracks = 0;
    // REC-010/011 (T-053): MIDI input events dropped (a full queue or a full record buffer, all
    // time) and the tracks armed for MIDI input (armMidiInput).
    uint64_t midiInputDrops = 0;
    uint32_t armedMidiTracks = 0;
};

struct NodeLatencyPOD {
    NodeID node = 0;
    uint32_t samples = 0;
};

struct MeterPOD {
    float peak = 0;  // linear
    float rms = 0;
    bool valid = false;  // false: the node has no meter (yet)
};

// MARK: Events (BRIDGE-004, IO-022)

// 04 Interfaces' EngineEventType, plus the facade's own cases (T-014 delta).
enum class EngineEventType : uint8_t {
    deviceChanged,       // IO-021: `device` says why and what changed; error: the device isn't running
    overload,            // IO-023: `count` is the total xrun count
    recordingFinalized,
    assetsReloaded,
    pluginCrashed,
    assetLoaded,         // subject = assetID, job = the load job
    assetLoadFailed,     // subject = assetID, error set
    graphRejected,       // subject = the rejected version, error set (cycle → code cycle)
    jobFinished,         // subject = job kind, job = the job; error set if it failed
};

// IO-021 (7), T-051: why a deviceChanged event happened.
enum class DeviceChangeReason : uint8_t {
    deviceLost,            // the running output (or separate input) device went away: fell back
                           // to the system default (D-26)
    sampleRateChanged,     // its nominal rate moved off the session rate: restarted
    defaultOutputChanged,  // following the system default (outputDevice 0), and it moved
    deviceAvailable,       // nothing was running (no device, a failed start) and a device appeared
    startFailed,           // a start the facade made itself failed (create, after an export,
                           // arming input)
};

struct DeviceChangePOD {
    DeviceChangeReason reason = DeviceChangeReason::deviceLost;
    uint32_t previousDeviceID = 0;  // output AudioObjectID before (0: none was running)
    uint32_t deviceID = 0;          // running now (0: none; the event's error says why)
    double previousSampleRate = 0;  // session rate before
    double sampleRate = 0;          // session rate after (differs only when IO-021 (5) changed it)
};

// IO-033, DW-044 (T-056): where an assetsReloaded event is in a session-rate change. Every change
// of the session rate (setSessionSampleRate, setDevice, a device fallback, IO-021 (5)) raises
// `started`, one `progress` per asset as it is re-converted from its original file on daw.loader,
// and `finished` once the new assets are swapped in through a new graph. With no assets loaded,
// `started` is followed by `finished` at once. The transport stays stopped in between: play() is
// refused, and an offline render waits for `finished`.
enum class AssetsReloadPhase : uint8_t { started, progress, finished };

struct AssetsReloadPOD {
    AssetsReloadPhase phase = AssetsReloadPhase::finished;
    double previousSampleRate = 0;  // the session rate before the change
    double sampleRate = 0;          // and after: the rate the assets are converted to
    uint32_t done = 0;              // assets converted (or failed) so far
    uint32_t total = 0;             // assets to convert
    uint32_t failed = 0;            // assets that didn't load again (dropped: their clips are silent)
    uint64_t assetID = 0;           // progress: the asset just done
};

// T-053 (REC-012): one recorded note of a MIDI take, in timeline samples (latency-compensated).
struct RecordedNotePOD {
    int64_t start = 0;
    int64_t end = 0;
    uint8_t pitch = 0;
    uint8_t velocity = 0;
    uint8_t channel = 0;
};
using RecordedNoteVector = std::vector<RecordedNotePOD>;

// REC-004 (T-052): a finished recording, one event per track. `startSample` is where the file's
// first frame belongs on the timeline, at the session rate, already compensated for input +
// output latency (REC-003); it can be negative (recording from the very start). The model turns
// it into ImportAsset + AddClip (one undoable edit). An event with `error` set and `frames` > 0
// still has a usable file: the error says what went wrong (e.g. REC-002 dropped frames, filled
// with silence); with `file` empty nothing could be written.
struct RecordingPOD {
    NodeID track = 0;
    std::string file;           // absolute path of the 32-bit float CAF
    int64_t startSample = 0;
    int64_t frames = 0;         // in the file
    uint32_t takeIndex = 0;     // REC-030 (loop takes, T-080): 0
    uint32_t channels = 2;
    double sampleRate = 0;      // the session rate it was recorded at
    uint32_t inputPair = 0;     // channels 2·inputPair, 2·inputPair + 1
    uint64_t droppedFrames = 0; // REC-002
    // T-053 (REC-012): a MIDI take. `file` stays empty and `frames` is 0; `droppedFrames` counts
    // events the record buffer had no room for. startSample/endSample are the compensated record
    // start and stop, the notes are in timeline samples.
    bool midi = false;
    int64_t endSample = 0;
    RecordedNoteVector notes;
};

struct EngineEventPOD {
    EngineEventType type = EngineEventType::deviceChanged;
    uint64_t subject = 0;
    JobID job = 0;
    uint64_t count = 0;
    FacadeError error;
    DeviceChangePOD device;  // deviceChanged
    AssetsReloadPOD reload;  // assetsReloaded (T-056)
    RecordingPOD recording;  // recordingFinalized (T-052); subject = the track
};

// REC-010 (T-053): one MIDI input source, for the UI and dawctl.
struct MidiInputInfoPOD {
    int32_t uniqueID = 0;     // kMIDIPropertyUniqueID
    std::string name;
    bool connected = false;   // connected to the input port (every source is, until slots run out)
};

// T-051, DW-089: what simulateDeviceEvent makes the fake device do.
enum class DeviceEventKind : uint8_t {
    deviceLost,         // it disappears (IO-021 runs)
    deviceRestored,     // it comes back
    sampleRateChanged,  // another app sets its nominal rate to `sampleRate`
    processorOverload,  // a kAudioDeviceProcessorOverload notification (an xrun, IO-023)
};

struct DeviceEventPOD {
    DeviceEventKind kind = DeviceEventKind::deviceLost;
    uint32_t deviceID = 0;  // 0: the device running (stopped: the default output)
    double sampleRate = 0;  // sampleRateChanged: a rate the device supports
};

// MARK: Devices and plugins (04, 10)

struct DeviceInfoPOD {
    uint32_t deviceID = 0;  // AudioObjectID, for DriverConfigPOD
    std::string name;
    uint32_t inputChannels = 0;
    uint32_t outputChannels = 0;
    double nominalSampleRate = 0;
    bool isDefaultOutput = false;
};

enum class PluginFormatPOD : uint8_t { audioUnit, vst3 };

// DW-017: mirrors DAWModel's AUDescriptor / VST3Descriptor.
struct PluginDescriptorPOD {
    PluginFormatPOD format = PluginFormatPOD::audioUnit;
    std::string identifier;  // AU "type:subtype:manufacturer", VST3 "path#classUID"
    std::string name;
    std::string vendor;
    std::string version;
};

// MARK: GraphDescription builder (BRIDGE-003)

// Swift fills a GraphDescription through this instead of instantiating std::vector<NodeDesc>
// itself. The version is stamped by applyGraph.
class GraphDescriptionBuilder {
public:
    GraphDescriptionBuilder() = default;

    void addNode(NodeID id, NodeKind kind, uint32_t configVersion, ParamID firstParam,
                 uint32_t numParams, const std::string& configJSON) {
        desc_.nodes.push_back(NodeDesc{id, kind, configVersion, firstParam, numParams, configJSON});
    }
    void addEdge(uint64_t edgeID, NodeID from, NodeID to, EdgeKind kind, uint8_t toPort) {
        desc_.edges.push_back(EdgeDesc{edgeID, from, to, kind, toPort});
    }
    void addClip(NodeID player, uint64_t clipID, Tick start, Tick length, uint64_t assetID,
                 int64_t sourceOffsetSamples, float gain, Tick fadeIn, Tick fadeOut) {
        desc_.audioClips.push_back(ClipDesc{player, clipID, start, length, assetID,
                                            sourceOffsetSamples, gain, fadeIn, fadeOut});
    }
    void addNote(NodeID player, Tick start, Tick length, uint8_t pitch, uint8_t velocity,
                 uint8_t channel) {
        desc_.notes.push_back(NoteDesc{player, start, length, pitch, velocity, channel});
    }
    // Tempo and time-signature events, each list starting at tick 0 (TIME model).
    void setTempo(Tick tick, double bpm) { desc_.tempo.tempos.push_back(TempoPointDesc{tick, bpm}); }
    void setTimeSignature(Tick tick, int32_t num, int32_t den) {
        desc_.tempo.timeSigs.push_back(TimeSigDesc{tick, num, den});
    }
    void setMaster(NodeID master) { desc_.master = master; }
    void clear() { desc_ = GraphDescription{}; }

    // A copy: Swift can't hold a reference into the builder.
    GraphDescription description() const { return desc_; }

private:
    GraphDescription desc_{};
};

// MARK: The facade

class EngineFacade;

} // namespace daw

// BRIDGE-001: the facade's retain/release. At global scope because that is where Swift looks
// them up for SWIFT_SHARED_REFERENCE.
void retainFacade(daw::EngineFacade* facade);
void releaseFacade(daw::EngineFacade* facade);

namespace daw {

// BRIDGE-001: Swift holds it as a class reference; the last release destroys it, which stops
// rendering and joins every engine thread.
class SWIFT_SHARED_REFERENCE(retainFacade, releaseFacade) SWIFT_UNCHECKED_SENDABLE EngineFacade {
public:
    // BRIDGE-008. Returns with one reference (Swift takes it over). Null if `config` is invalid
    // in offline mode (sample rate out of range). Realtime mode without a device driver yet
    // (T-011) gives an engine that never renders: devices() is empty, setDevice fails.
    static EngineFacade* create(EngineMode mode, const DriverConfigPOD& config) SWIFT_RETURNS_RETAINED;

    EngineFacade(const EngineFacade&) = delete;
    EngineFacade& operator=(const EngineFacade&) = delete;

    EngineMode mode() const;

    // BRIDGE-001 diagnostics: a process-unique ID per facade, and whether that facade still
    // exists (so a test can check that its own instances were destroyed).
    uint64_t instanceID() const;
    static bool isLive(uint64_t instanceID);

    // MARK: Graph & params

    // MIX-001, DW-053: queues the description for daw.compile (coalesced) and returns the
    // version it stamped on it (T-014 delta). The outcome shows in graphStatus() and, on failure,
    // as a graphRejected event.
    uint64_t applyGraph(const GraphDescription& desc);
    GraphStatusPOD graphStatus() const;
    // Blocks up to `timeoutMs` until `version` has been built, rejected or superseded.
    GraphStatusPOD waitForGraph(uint64_t version, uint32_t timeoutMs);

    // ENG-020. kInvalidParamID when the table has no free run of `count` slots.
    ParamID allocateParams(uint32_t count);
    // DW-029: the slots are reused only once no graph that might reference them can still be
    // rendering, i.e. after a graph applied later than this call has replaced them.
    void freeParams(ParamID first, uint32_t count);
    // ENG-021/023: writes the slot only; nothing is rebuilt. Out-of-range IDs are ignored.
    void setParam(ParamID id, float value);
    float getParam(ParamID id) const;

    // MARK: Transport (TIME-004/009)

    void play();
    void stop();
    void locate(Tick tick);
    void setLoop(bool enabled, Tick start, Tick end);
    void setRecording(bool recording);
    TransportPOD transport() const;

    // UI-021 (T-043, accepted (autobuild, see docs/autobuild/DECISIONS.md)): auditions `pitch` on
    // the instrument fed by the MIDI source node `source` (a MIDI track's MidiClipPlayer), on MIDI
    // channel 1, whether the transport plays or not. Non-RT, any thread; it queues the note
    // lock-free for the audio thread, which plays it at the start of the next block. A note-on for
    // a sounding pitch retriggers it; every note-on needs its note-off, and stop(), locate() and
    // renderOffline() turn off every preview note still on. A note-on is ignored in offline mode
    // and while an export runs (nothing would hear it but the export); a note-off never is.
    void previewNote(NodeID source, uint8_t pitch, uint8_t velocity, bool on);

    // MARK: Assets (IO-031, DW-041)

    // Decodes `path` on daw.loader at the session rate. A later load of the same assetID
    // replaces the asset once it has loaded.
    JobID loadAsset(uint64_t assetID, const std::string& path);
    JobStatus pollJob(JobID job) const;
    // IO-034 / UI-011 (autobuild, see DECISIONS.md): `level` (0…kPeakLevelCount-1, finest
    // first) of the asset's peaks, as loaded. Non-RT, any thread; found == false until it loads.
    PeakLevelPOD peaks(uint64_t assetID, uint32_t level) const;
    // DW-077 (T-056): like loadAsset, and IO-034's peaks go through the cache file
    // <peakCacheDir>/<assetID>.peaks (reused when current, rewritten when stale, e.g. after a
    // session-rate change). An empty directory is the two-argument form.
    JobID loadAsset(uint64_t assetID, const std::string& path, const std::string& peakCacheDir);

    // MARK: Recording (09) and plugins (10): later tasks

    // DW-067: the device's input runs while any track is armed; turning it on or off restarts
    // the driver. REC-001 (T-052): an armed track records input channels 2·pair and 2·pair + 1
    // (pairs 0…15) while the transport plays and records. Changing what is armed during a take
    // finalizes it first (REC-022: arming is structural).
    void armInput(NodeID track, uint32_t inputChannelPair, bool armed);
    JobID instantiatePlugin(NodeID slot, const PluginDescriptorPOD& plugin);
    ByteVector getPluginState(NodeID slot);
    void setPluginState(NodeID slot, const ByteVector& state);
    void* createPluginView(NodeID slot);  // NSView*, owned by the facade
    // PLUG-010/011/015 (T-061, T-062, accepted (autobuild, see docs/autobuild/DECISIONS.md)): what
    // the slot's hosted plugin is (VST3: address/id are the ParamID, min/max 0/1, normalized values), as JSON: {"slot", "identifier", "loaded", "error"?, "name", "instrument",
    // "midi", "sidechain", "inputChannels", "outputChannels", "latencySamples", "tailSeconds",
    // "params": [{"index", "address", "id", "name", "unit", "min", "max", "value", "canRamp"}]}.
    // Param slot i of the auPlugin or vst3Plugin node drives params[i]. {"slot": n, "loaded": false} for a slot
    // the engine has no plugin for. Non-RT, any thread.
    std::string pluginInfoJSON(NodeID slot) const;
    void destroyPluginView(NodeID slot);

    // MARK: Recording (09, T-052; accepted (autobuild, see docs/autobuild/DECISIONS.md))
    //
    // A take records while the transport plays with setRecording(true) and some track is armed
    // (realtime mode: offline engines have no input). It ends, and its files are finalized
    // (recordingFinalized events, REC-004), on stop(), setRecording(false), a locate while it
    // runs, a change to what is armed, an export, and a device change (IO-021 (2), DW-119).

    // REC-002: where recordings are written (created when needed). Empty: a per-process folder
    // in $TMPDIR. A take already running keeps its folder.
    void setRecordingDirectory(const std::string& directory);
    std::string recordingDirectory() const;
    // REC-005: with `enabled` and the loop off, only [in, out) of the timeline is recorded.
    // Disabling keeps the range (or stores [in, out) for later when in < out). An enabled request
    // with in < 0 or in >= out is ignored, leaving punch as it was.
    void setPunch(bool enabled, Tick in, Tick out);

    // MARK: MIDI input (09, T-053; accepted (autobuild, see docs/autobuild/DECISIONS.md))
    //
    // REC-011: every connected CoreMIDI source reaches every armed MIDI track on all channels,
    // and play-through doesn't depend on the monitoring mode. A MIDI take records while the
    // transport plays with setRecording(true) and some track is armed (realtime mode), and ends
    // like an audio take: it becomes one recordingFinalized event per armed track, with
    // `recording.midi` set and the notes, or nothing at all if no note was played.

    // REC-011: arms or disarms MIDI track `track`. `player` is its MidiClipPlayer node (a MIDI
    // track's GraphNodeID.source), which plays the input through to the track's instrument; a
    // track with no instrument has no player and still records. A take running ends first
    // (REC-022: arming is structural). Disarming sends note-offs for notes still held.
    void armMidiInput(NodeID track, NodeID player, bool armed);
    // REC-010: the MIDI sources CoreMIDI knows. Empty on offline and fake-device engines, which
    // have no CoreMIDI input (they have injectMidi).
    std::vector<MidiInputInfoPOD> midiInputs() const;
    // T-053 test seam: a MIDI message (1…3 bytes, `size`) arriving as if from a source. While the
    // transport plays, `atSample` is the transport sample it is struck at (`relativeToNow`:
    // frames after the block about to render); a position already past, or a stopped transport,
    // means now. unsupported in offline mode; invalidArgument for a malformed message.
    FacadeError injectMidi(int64_t atSample, bool relativeToNow, uint8_t status, uint8_t data1, uint8_t data2, uint8_t size);

    // MARK: Offline (IO-010..013, DW-057)

    // Renders [from, to) plus the tail of the latest applied graph on a job thread. The device
    // driver (if any) is stopped for the duration and recording is disarmed (DW-064).
    JobID renderOffline(Tick from, Tick to, const ExportSpecPOD& spec);

    // MARK: Device (04)

    std::vector<DeviceInfoPOD> devices() const;
    // Restarts the device with `config` (its `driver` must be the one the facade was created
    // with). DW-079: a sampleRate other than the session rate makes it the session rate (the
    // graph is rebuilt at it, as in IO-021 (5)); rate 0 keeps the session rate if the device
    // supports it.
    FacadeError setDevice(const DriverConfigPOD& config);  // T-014 delta: not Result<void>
    // DW-089: plays `event` on the fake device and returns once the facade has reacted to it
    // (IO-021 ran if it needed to; see the deviceChanged event). unsupported unless the facade
    // was created with DeviceDriverKind::fake; invalidArgument for an unknown device or rate.
    FacadeError simulateDeviceEvent(const DeviceEventPOD& event);
    // MODEL-005 SetSessionSampleRate, IO-033 (T-056): makes `rate` (44.1/48/88.2/96 kHz) the
    // session rate in either mode. The transport stops, the graph is rebuilt at the rate, and every
    // loaded asset is re-converted from its file in the background (assetsReloaded events). A
    // realtime engine restarts its device at the rate (setDevice with the running config), and
    // refuses (unsupported, nothing changed) when the device can't run it. The same rate is a
    // no-op; invalidArgument for another rate; unsupported during an export.
    FacadeError setSessionSampleRate(double rate);

    // MARK: Observability (BRIDGE-004/005)

    TelemetryPOD telemetry() const;
    std::vector<NodeLatencyPOD> nodeLatencies() const;
    MeterPOD meter(NodeID node) const;
    // Moves up to `max` queued events into `out`, oldest first, and returns how many.
    size_t pollEvents(EngineEventPOD* out, size_t max);
    std::string paramInfoJSON(NodeKind kind) const;

private:
    friend void ::retainFacade(EngineFacade*);
    friend void ::releaseFacade(EngineFacade*);
    friend class EngineFacadeAccess;  // facade/ internals (C++ only)

    struct Impl;
    explicit EngineFacade(Impl* impl);
    ~EngineFacade();

    Impl* impl_;
};

} // namespace daw
