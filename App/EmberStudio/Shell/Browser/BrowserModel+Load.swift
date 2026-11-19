import CoreGraphics
import DAWModel
import Foundation

/// UI-063: where loaded files go.
enum BrowserDropTarget: Equatable, Sendable {
    case track(NodeIDValue)
    /// The empty area under the tracks: a new track of the files' kind.
    case newTrack
}

/// UI-063: what a load did (one undo entry).
struct BrowserLoadResult: Equatable, Sendable {
    var track: NodeIDValue
    var newTrack: Bool
    /// Where the first clip starts.
    var tick: Tick
    var clips: [ModelID]
    /// The clips' assets, in order: imported, or Current Project assets reused.
    var assets: [ModelID]
    var imported: [ModelID]
}

extension BrowserModel {
    /// How long one file may take to load before the load is given up.
    static let loadTimeout: Duration = .seconds(60)

    /// Double-click / Return (UI-063): onto the selected track (the first selected, in track
    /// order) at the playhead, else onto a new track.
    @discardableResult
    func loadAtPlayhead(_ item: BrowserItem) async throws(BrowserError) -> BrowserLoadResult {
        guard let window else { throw .refused("No project window") }
        let target = window.project.tracks.first { window.selectedTracks.contains($0.id) }
            .map { BrowserDropTarget.track($0.id) } ?? .newTrack
        return try await load([item.url], onto: target, at: Tick(max(window.transport.tick.raw, 0)))
    }

    /// UI-063: the drop target and tick for a point of the arrange canvas (view coordinates): the
    /// track whose row (or automation lane, or take row) is there, or the empty area under the
    /// last track. The tick is snapped unless `snapping` is false (⌘ held), and never negative.
    /// Nil over the ruler.
    static func dropTarget(at point: CGPoint, in arrange: ArrangeModel, snapping: Bool) -> (target: BrowserDropTarget, tick: Tick)? {
        let g = arrange.geometry
        guard point.y >= TimelineGeometry.rulerHeight else { return nil }
        let tracks = arrange.tracks
        let index = g.trackUnclamped(atY: point.y)
        let target: BrowserDropTarget = index >= 0 && index < tracks.count ? .track(tracks[index].id) : .newTrack
        return (target, snappedDropTick(g.tick(atX: point.x), in: arrange, snapping: snapping))
    }

    /// UI-063: a drop's tick, snapped to the arrange view's grid (unless `snapping` is false).
    static func snappedDropTick(_ tick: Tick, in arrange: ArrangeModel, snapping: Bool = true) -> Tick {
        let tick = Tick(max(tick.raw, 0))
        guard snapping, arrange.snap != .off else { return tick }
        return Tick(max(arrange.grid.snap(tick, arrange.snap).raw, 0))
    }

    /// UI-063: loads `urls` (from the browser or Finder) onto `target` from `tick`, as one undo
    /// entry: `ImportAsset` for each file the project doesn't have yet (a Current Project asset is
    /// reused) and `AddClip`, the files one after another; onto `.newTrack`, an `AddTrack` first.
    /// Each file is loaded into the window's engine under a reserved ID before anything changes
    /// (DW-339), so a file that doesn't load leaves the project as it was. Refusals (a folder, a
    /// file that isn't audio, audio onto a MIDI track, MIDI files: T-125) change nothing and post
    /// an error toast; the error says the same.
    @discardableResult
    func load(_ urls: [URL], onto target: BrowserDropTarget, at tick: Tick) async throws(BrowserError) -> BrowserLoadResult {
        do {
            return try await performLoad(urls, onto: target, at: tick)
        } catch {
            window?.toasts.post(.error, .error, title: urls.count == 1 ? "Couldn't load \(urls[0].lastPathComponent)" : "Couldn't load the files",
                                message: error.description)
            throw error
        }
    }

    private func performLoad(_ urls: [URL], onto target: BrowserDropTarget, at tick: Tick) async throws(BrowserError) -> BrowserLoadResult {
        guard let window else { throw .refused("No project window") }
        let store = window.store
        guard !urls.isEmpty else { throw .refused("Nothing to load") }
        let files = urls.map(BrowserItem.canonical)
        for file in files {
            if BrowserFileSystem.isFolder(file) { throw .refused("\(file.lastPathComponent) is a folder; open it in the browser to load its files") }
            switch BrowserItem.fileKind(of: file) {
            case .audio?: continue
            case .midi?: throw .refused("MIDI files can't be loaded yet")  // T-125 (MODEL-047)
            default: throw .refused("\(file.lastPathComponent) isn't an audio or MIDI file")
            }
        }
        try checkTarget(target, in: store.project)
        guard let engine = window.engine else { throw .refused("The window has no audio engine") }

        // Each file once: a Current Project asset is reused, the others load under reserved IDs.
        var assetFor: [String: AssetRef] = [:]
        for file in files where assetFor[file.path] == nil {
            if let asset = existingAsset(for: file, in: store) {
                assetFor[file.path] = asset
                continue
            }
            let id = store.reserveID()  // DW-339: nothing performed during the load can take it
            let job = if let folder = store.folderURL {
                engine.loadAsset(id, path: file.path, peakCacheDirectory: folder.appending(path: "Cache", directoryHint: .isDirectory).path)
            } else {
                engine.loadAsset(id, path: file.path)
            }
            guard job != 0 else { throw .refused("The engine refused to load \(file.lastPathComponent)") }
            let status = await engine.waitForJob(job, timeout: Self.loadTimeout)
            guard status.state == .succeeded, let info = status.asset else {
                throw .refused(status.error.map { "\(file.lastPathComponent): \($0.description)" }
                    ?? "\(file.lastPathComponent) didn't load (\(status.state))")
            }
            let asset = AssetRef(id: id, path: Self.assetPath(of: file, in: store.folderURL), channels: Int(info.channels),
                                 originalSampleRate: info.fileSampleRate, frames: info.fileFrames)
            assetFor[file.path] = asset
        }
        guard window.store === store else { throw .refused("The project changed while the files loaded") }
        try checkTarget(target, in: store.project)

        // One composite, built on a copy so each clip starts where the one before ends. The new
        // track's ID is peeked within this synchronous step (07 "Contract delta (T-112)").
        var working = store.project
        var commands: [any Command] = []
        func add(_ command: any Command) throws(DAWError) -> any Command {
            let inverse = try command.apply(to: &working)
            commands.append(command)
            return inverse
        }
        var result = BrowserLoadResult(track: 0, newTrack: target == .newTrack, tick: tick, clips: [], assets: [], imported: [])
        do {
            switch target {
            case .track(let id):
                result.track = id
            case .newTrack:
                result.track = working.ids.next
                _ = try add(AddTrack(name: files[0].deletingPathExtension().lastPathComponent, kind: .audio))
            }
            var start = tick
            for file in files {
                guard let asset = assetFor[file.path] else { continue }
                if working.asset(asset.id) == nil {
                    _ = try add(ImportAsset(asset: asset))
                    result.imported.append(asset.id)
                }
                let inverse = try add(AddClip(trackID: result.track, start: start, assetID: asset.id))
                guard let clipID = (inverse as? RemoveClip)?.clipID, let clip = working.clip(clipID) else { continue }
                result.clips.append(clipID)
                result.assets.append(asset.id)
                start = Tick(clip.start.raw + clip.length.raw)
            }
            let label = files.count == 1 ? "Load \(files[0].lastPathComponent)" : "Load \(files.count) Files"
            try store.perform(CompositeCommand(label, commands))
        } catch {
            throw .refused(error.description)
        }
        window.selectedTracks = [result.track]
        window.selectedClips = Set(result.clips)
        return result
    }

    /// UI-063: audio goes onto audio tracks or a new track. Audio onto a MIDI track (a Sampler,
    /// UI-063) comes with T-125.
    private func checkTarget(_ target: BrowserDropTarget, in project: Project) throws(BrowserError) {
        guard case .track(let id) = target else { return }
        guard let track = project.track(id) else { throw .refused("Track \(id) isn't in the project") }
        if track.kind == .midi { throw .refused("Audio files can't go on a MIDI track (\(track.name)) yet; drop them on an audio track") }
    }

    /// The project's asset for `file`, if it has one (UI-063: reused, not imported again).
    private func existingAsset(for file: URL, in store: ProjectStore) -> AssetRef? {
        let path = file.resolvingSymlinksInPath().path
        return store.project.assets.first {
            Self.fileURL(of: $0, in: store.folderURL).resolvingSymlinksInPath().path == path
        }
    }

    /// `AssetRef.path`: project-relative inside the project folder, else absolute (a save copies
    /// it into `Audio/`, DW-124).
    static func assetPath(of file: URL, in folder: URL?) -> String {
        guard let folder else { return file.path }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : file.path
    }
}
