import DAWModel
import Foundation
import Observation

/// UI-042 (T-082): what the export dialog renders: the loop, the whole project or the selected
/// clips' span.
enum ExportRange: String, CaseIterable, Codable, Sendable {
    case loop, project, selection

    var title: String {
        switch self {
        case .loop: "Loop"
        case .project: "Whole Project"
        case .selection: "Selection"
        }
    }
}

/// UI-042 (T-082): the export dialog of one project window: range, file type, sample format, dither,
/// normalize, tail, metronome and destination, then the render with its progress. 12 *Export dialog
/// details*.
///
/// The render runs on the window's engine (`renderOffline`, IO-010) after engine sync is flushed
/// and the graph is built, so it hears the project as it is. The project's click stays out unless
/// "Include Metronome" is on (DW-177): engine sync holds the metronome's `on` slot at 0 for the
/// render (a slot write, no rebuild), as `render.offline` does. Progress shows in the panel and the
/// toolbar; the outcome is a toast (UI-004).
@Observable
@MainActor
final class ExportModel {
    @ObservationIgnored weak var window: ProjectWindowModel?

    /// The panel shows (`export.dialog`, File > Export…). Opening it picks a range that exists and a
    /// destination that doesn't (unless one was chosen).
    var isOpen = false {
        didSet { if isOpen && !oldValue { prepare() } }
    }

    private(set) var range: ExportRange = .project
    private(set) var fileType: ExportSpec.FileType = .wav
    private(set) var sampleFormat: ExportSpec.SampleFormat = .int24
    /// IO-035: TPDF dither. Follows the sample format (on for int16/int24, off for float32) until
    /// changed; float32 is never dithered.
    private(set) var dither = true
    /// Peak to −0.1 dBFS before dither and quantization (`ExportSpec.normalize`). Off by default.
    private(set) var normalize = false
    /// IO-012: keep rendering past the range end until the output is quiet, at most `tailMaxSeconds`.
    private(set) var tail = true
    private(set) var tailMaxSeconds: Double = 10
    /// DW-177: the project's click is left out unless this is on. It starts in the metronome's
    /// state each time the panel opens (on when the click is on; DECISIONS.md "User review", T-026
    /// change, T-090); `ExportSpec`'s flag itself stays explicit.
    private(set) var includeMetronome = false
    /// Where the file goes. Set when the panel opens; "Choose…" changes it.
    private(set) var destination: URL?
    /// The user picked `destination` (a save panel, which confirmed any overwrite): later opens keep it.
    private(set) var destinationChosen = false

    /// A render is running (started from this dialog).
    private(set) var isRunning = false
    /// 0…1 of the running render (frames so far / range + maximum tail).
    private(set) var progress: Double = 0
    /// The last finished export.
    private(set) var lastResult: Finished?
    /// Why the last export failed, until the next one starts.
    private(set) var lastError: String?

    struct Finished: Equatable {
        var path: String
        var render: OfflineRenderResult
    }

    static let tailMaxChoices: [Double] = [2, 5, 10, 30]
    static let defaultName = "Export"

    /// Where exports of a project never saved go (tests point it elsewhere).
    @ObservationIgnored var unsavedDirectory: URL = {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return music.appendingPathComponent("Ember Studio", isDirectory: true)
    }()

    /// "Choose…": asks for a destination, starting at the current one, and calls back with the pick
    /// (nil: cancelled). The app shows an `NSSavePanel`; tests stand in for it.
    @ObservationIgnored var chooseDestination: @MainActor (URL, ExportSpec.FileType, @escaping @MainActor (URL?) -> Void) -> Void =
        ExportDestinationPanel.choose

    /// How long a render may take before the dialog gives up on it.
    @ObservationIgnored var renderTimeout: Duration = .seconds(600)

    var engine: (any EngineProtocol)? { window?.engine }

    // MARK: Ranges

    /// The ticks `range` covers now, nil when it has none: no loop region, no clip selected.
    func span(_ range: ExportRange) -> (from: Tick, to: Tick)? {
        guard let project = window?.project else { return nil }
        switch range {
        case .project:
            // To the end of the last clip, at least one bar.
            let end = project.tracks.flatMap(\.clips).map { $0.start.raw + $0.length.raw }.max() ?? 0
            let bar = project.tempoMap.bbtToTick(BBT(bar: 2, beat: 1, tick: 0)).raw
            return (Tick(0), Tick(max(end, bar)))
        case .loop:
            guard let loop = project.loop, loop.end > loop.start else { return nil }
            return (loop.start, loop.end)
        case .selection:
            let selected = window?.selectedClips ?? []
            let clips = project.tracks.flatMap(\.clips).filter { selected.contains($0.id) }
            guard let start = clips.map(\.start.raw).min(), let end = clips.map({ $0.start.raw + $0.length.raw }).max(),
                  end > start else { return nil }
            return (Tick(start), Tick(end))
        }
    }

    func isAvailable(_ range: ExportRange) -> Bool { span(range) != nil }

    /// Seconds `span` lasts through the tempo map.
    func seconds(_ span: (from: Tick, to: Tick)) -> Double {
        guard let map = window?.project.tempoMap, map.sampleRate > 0 else { return 0 }
        return Double(map.tickToSample(span.to) - map.tickToSample(span.from)) / map.sampleRate
    }

    // MARK: Settings

    func setRange(_ range: ExportRange) {
        guard !isRunning, isAvailable(range) else { return }
        self.range = range
    }

    func setFileType(_ type: ExportSpec.FileType) {
        guard !isRunning else { return }
        fileType = type
        if let destination {
            self.destination = destination.deletingPathExtension().appendingPathExtension(Self.fileExtension(type))
        }
    }

    /// Changing the sample format resets dither to its default for the format.
    func setSampleFormat(_ format: ExportSpec.SampleFormat) {
        guard !isRunning else { return }
        sampleFormat = format
        dither = format != .float32
    }

    func setDither(_ on: Bool) {
        guard !isRunning, sampleFormat != .float32 else { return }
        dither = on
    }

    func setNormalize(_ on: Bool) { if !isRunning { normalize = on } }
    func setTail(_ on: Bool) { if !isRunning { tail = on } }
    func setTailMax(_ seconds: Double) { if !isRunning { tailMaxSeconds = seconds } }
    func setIncludeMetronome(_ on: Bool) { if !isRunning { includeMetronome = on } }

    /// Sets the destination as if chosen in the save panel (its extension follows the file type).
    func setDestination(_ url: URL) {
        guard !isRunning else { return }
        var url = url
        if let type = Self.fileType(forExtension: url.pathExtension) { fileType = type }
        else { url = url.appendingPathExtension(Self.fileExtension(fileType)) }
        destination = url
        destinationChosen = true
    }

    func choose() {
        guard !isRunning else { return }
        let start = destination ?? defaultDestination()
        chooseDestination(start, fileType) { [weak self] url in
            if let url { self?.setDestination(url) }
        }
    }

    /// The spec the dialog renders with (`path` = the destination).
    var spec: ExportSpec {
        var spec = ExportSpec(path: destination?.path ?? "", fileType: fileType, sampleFormat: sampleFormat,
                              dither: dither && sampleFormat != .float32, tailEnabled: tail, tailMaxSeconds: tailMaxSeconds)
        spec.normalize = normalize
        return spec
    }

    /// What opening the panel sets up: a range that exists, a fresh destination unless one was
    /// chosen, and "Include Metronome" as the click is now (T-090).
    private func prepare() {
        if !isAvailable(range) { range = .project }
        includeMetronome = window?.project.metronome.enabled ?? false
        if !destinationChosen || destination == nil { destination = defaultDestination() }
    }

    /// The window shows another project: a default destination named after the old one is dropped.
    func documentReplaced() {
        if !destinationChosen { destination = nil }
        if isOpen { prepare() }
    }

    /// `<project folder>/Bounces/<name>.<ext>` for a saved project, else `unsavedDirectory`, with
    /// " 2", " 3", … added until no file is there.
    func defaultDestination() -> URL {
        let folder = window?.store.folderURL.map { $0.appendingPathComponent("Bounces", isDirectory: true) } ?? unsavedDirectory
        let name = window?.project.name.trimmingCharacters(in: .whitespaces) ?? ""
        let base = (name.isEmpty ? Self.defaultName : name).replacingOccurrences(of: "/", with: "-")
        let ext = Self.fileExtension(fileType)
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    // MARK: Render

    /// "Export": renders the range to the destination on the window's engine. Progress follows the
    /// job; the outcome is a toast, and a success closes the panel.
    func start() {
        guard !isRunning, let window, let engine, let span = span(range) else { return }
        let destination = destination ?? defaultDestination()
        self.destination = destination
        let spec = spec
        let includeMetronome = includeMetronome
        isRunning = true
        progress = 0
        lastError = nil
        Task { @MainActor [weak self] in
            do throws(DAWError) {
                let render = try await Self.render(window: window, engine: engine, from: span.from, to: span.to, spec: spec,
                                                   includeMetronome: includeMetronome, timeout: self?.renderTimeout ?? .seconds(600)) {
                    [weak self] fraction in self?.progress = fraction
                }
                self?.finished(.success(Finished(path: destination.path, render: render)), window: window)
            } catch {
                self?.finished(.failure(error), window: window)
            }
        }
    }

    private func finished(_ outcome: Result<Finished, DAWError>, window: ProjectWindowModel) {
        isRunning = false
        switch outcome {
        case .success(let done):
            progress = 1
            lastResult = done
            isOpen = false
            if !destinationChosen { destination = nil }  // the next open picks a free name again
            window.toasts.post(.info, .info, title: "Exported \(URL(fileURLWithPath: done.path).lastPathComponent)",
                               message: Self.summary(done.render, fileType: spec.fileType, sampleFormat: spec.sampleFormat,
                                                     normalized: normalize))
        case .failure(let error):
            lastError = error.description
            window.toasts.post(.error, .error, title: "Export failed", message: error.description)
        }
    }

    /// Renders `[from, to)` with `spec` on `engine`: engine sync flushed and imported takes loaded,
    /// the graph built, the click held off unless `includeMetronome` (DW-177), then the job polled
    /// for progress. The File menu's dialog and `AppModel.export` both come here.
    static func render(window: ProjectWindowModel, engine: any EngineProtocol, from: Tick, to: Tick, spec: ExportSpec,
                       includeMetronome: Bool, timeout: Duration = .seconds(600),
                       progress: @MainActor (Double) -> Void = { _ in }) async throws(DAWError) -> OfflineRenderResult {
        let sync = window.store.engineSync
        if let sync {
            await sync.settleLoads(timeout: .seconds(30))
            sync.flush()
        }
        let version = engine.graphStatus().submittedVersion
        if version > 0 {
            let status = await engine.graphApplied(version, timeout: .seconds(30))
            if let error = status.lastError { throw error }
        }
        if !spec.path.isEmpty {
            let folder = URL(fileURLWithPath: spec.path).deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw .engine(code: .io, detail: "cannot create \(folder.path)")
            }
        }
        // DW-177: the slot is held at 0 for the render only, whatever happens to the job.
        sync?.isMetronomeSuppressed = !includeMetronome
        defer { sync?.isMetronomeSuppressed = false }
        let job = engine.renderOffline(from: from, to: to, spec: spec)
        guard job != 0 else { throw .engine(code: .internal, detail: "the engine refused the export") }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let status = engine.pollJob(job)
            switch status.state {
            case .succeeded:
                progress(1)
                return status.render ?? OfflineRenderResult()
            case .failed:
                throw status.error ?? .engine(code: .internal, detail: "export failed")
            case .unknown:
                throw .engine(code: .notFound, detail: "the engine lost the export job")
            case .queued, .running:
                progress(min(max(status.progress, 0), 1))
            }
            guard clock.now < deadline else { throw .engine(code: .internal, detail: "export didn't finish within \(timeout)") }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Text

    static func fileExtension(_ type: ExportSpec.FileType) -> String {
        switch type {
        case .wav: "wav"
        case .aiff: "aif"
        case .caf: "caf"
        }
    }

    static func fileType(forExtension ext: String) -> ExportSpec.FileType? {
        switch ext.lowercased() {
        case "wav", "wave": .wav
        case "aif", "aiff", "aifc": .aiff
        case "caf": .caf
        default: nil
        }
    }

    static func title(_ type: ExportSpec.FileType) -> String {
        switch type {
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .caf: "CAF"
        }
    }

    static func title(_ format: ExportSpec.SampleFormat) -> String {
        switch format {
        case .int16: "16-bit"
        case .int24: "24-bit"
        case .float32: "32-bit float"
        }
    }

    static func tailTitle(_ seconds: Double) -> String { "\(Int(seconds)) s" }

    /// "4.0 s · 24-bit WAV · normalized +5.9 dB · rendered in 0.12 s"
    static func summary(_ render: OfflineRenderResult, fileType: ExportSpec.FileType, sampleFormat: ExportSpec.SampleFormat,
                        normalized: Bool) -> String {
        var parts = [String(format: "%.1f s", render.durationSeconds), "\(title(sampleFormat)) \(title(fileType))"]
        if normalized, render.normalizeGain > 0 {
            parts.append(String(format: "normalized %+.1f dB", 20 * log10(render.normalizeGain)))
        }
        if render.clippedSamples > 0 { parts.append("\(render.clippedSamples) samples clipped") }
        parts.append(String(format: "rendered in %.2f s", render.renderSeconds))
        return parts.joined(separator: " · ")
    }

    /// "Exporting… 45 %"
    var progressText: String { String(format: "Exporting… %.0f %%", progress * 100) }

    // MARK: Controls (UI-052)

    /// `export.dialog` (always: open/close the panel, like File > Export…); while the panel is open
    /// `export.close`, `export.start`, `export.choose`, `export.range.<loop|project|selection>`,
    /// `export.format.<wav|aiff|caf>`, `export.sampleFormat.<int16|int24|float32>`, `export.dither`,
    /// `export.normalize`, `export.tail`, `export.tailMax.<2|5|10|30>` and `export.metronome`. The
    /// choices are toggles (the one in force is on). Settings are disabled while a render runs.
    var controls: [UIControl] {
        let hasEngine = engine != nil
        var controls: [UIControl] = [
            .toggle("export.dialog", "Export…", isOn: isOpen, enabled: hasEngine || isOpen) { [weak self] in self?.isOpen.toggle() },
        ]
        guard isOpen else { return controls }
        let idle = !isRunning
        controls += [
            .button("export.close", "Close Export") { [weak self] in self?.isOpen = false },
            .button("export.start", "Export", enabled: idle && hasEngine && isAvailable(range)) { [weak self] in self?.start() },
            .button("export.choose", "Choose Destination…", enabled: idle) { [weak self] in self?.choose() },
        ]
        controls += ExportRange.allCases.map { r in
            .toggle("export.range.\(r.rawValue)", "Range: \(r.title)", isOn: range == r, enabled: idle && isAvailable(r)) {
                [weak self] in self?.setRange(r)
            }
        }
        controls += [ExportSpec.FileType.wav, .aiff, .caf].map { type in
            .toggle("export.format.\(type.rawValue)", "File Type: \(Self.title(type))", isOn: fileType == type, enabled: idle) {
                [weak self] in self?.setFileType(type)
            }
        }
        controls += [ExportSpec.SampleFormat.int16, .int24, .float32].map { format in
            .toggle("export.sampleFormat.\(format.rawValue)", "Sample Format: \(Self.title(format))", isOn: sampleFormat == format,
                    enabled: idle) { [weak self] in self?.setSampleFormat(format) }
        }
        controls += [
            .toggle("export.dither", "Dither", isOn: dither && sampleFormat != .float32, enabled: idle && sampleFormat != .float32) {
                [weak self] in
                guard let self else { return }
                setDither(!dither)
            },
            .toggle("export.normalize", "Normalize (−0.1 dBFS peak)", isOn: normalize, enabled: idle) { [weak self] in
                guard let self else { return }
                setNormalize(!normalize)
            },
            .toggle("export.tail", "Render Tail", isOn: tail, enabled: idle) { [weak self] in
                guard let self else { return }
                setTail(!tail)
            },
        ]
        controls += Self.tailMaxChoices.map { seconds in
            .toggle("export.tailMax.\(Int(seconds))", "Tail up to \(Self.tailTitle(seconds))", isOn: tailMaxSeconds == seconds,
                    enabled: idle && tail) { [weak self] in self?.setTailMax(seconds) }
        }
        controls.append(.toggle("export.metronome", "Include Metronome", isOn: includeMetronome, enabled: idle) { [weak self] in
            guard let self else { return }
            setIncludeMetronome(!includeMetronome)
        })
        return controls
    }
}
