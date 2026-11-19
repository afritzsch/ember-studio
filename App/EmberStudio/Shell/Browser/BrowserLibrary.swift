import Foundation
import Observation

/// UI-061: what every window's browser shares: the places (folders the user added, app-wide, in
/// `Browser.json`), the folder contents read so far, and the FSEvents watcher that keeps them
/// current. Folders are read lazily (the first time a window shows them) and off the main actor.
@Observable
@MainActor
final class BrowserLibrary {
    /// A folder the user added. `isMissing` when it isn't there (moved, an unplugged disk): it
    /// shows greyed with Locate… and Remove.
    struct Place: Identifiable, Hashable, Sendable {
        let url: URL
        var isMissing: Bool

        /// `BrowserItem.id(forPath:)` of the folder.
        var id: String { BrowserItem.id(forPath: url.path) }
        var name: String { url.lastPathComponent }
        /// The folder as the browser reads it (`BrowserItem.canonical`).
        var folder: URL { BrowserItem.canonical(url) }
    }

    /// The app's library: Browser.json in Application Support, or a per-process copy for an
    /// automated launch (`BrowserSettings.appURL`). Outside the app bundle (the shell's unit tests)
    /// it keeps its places in memory, so no test reads or writes the user's file; tests that need
    /// a file give `AppModel` a library of their own.
    static let shared = BrowserLibrary(settingsURL: Bundle.main.bundleURL.pathExtension == "app"
        ? BrowserSettings.appURL(automated: AppOptions(arguments: CommandLine.arguments).isAutomated) : nil)

    /// Nil: nothing is read or written (a window made without the app, in tests).
    @ObservationIgnored let settingsURL: URL?
    @ObservationIgnored let watchesFileSystem: Bool

    private var _places: [Place] = []
    @ObservationIgnored private var settingsRead = false

    /// The folders read so far, by path: their shown children (UI-061).
    private(set) var contents: [String: [BrowserItem]] = [:]
    /// Folders being read (not observed: the list asks for folders while it is drawn).
    @ObservationIgnored private(set) var reading: Set<String> = []
    /// Bumped on every file-system change under a place, so scans (the Samples and MIDI Files
    /// categories) run again.
    private(set) var fileSystemVersion = 0

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var listeners: [ObjectIdentifier: WeakListener] = [:]

    /// The last error a place change hit (writing Browser.json).
    private(set) var lastError: String?

    init(settingsURL: URL?, watchesFileSystem: Bool = true) {
        self.settingsURL = settingsURL
        self.watchesFileSystem = watchesFileSystem
    }

    /// UI-061: the places, in the order they were added. Reading them reads Browser.json the
    /// first time.
    var places: [Place] {
        readSettingsIfNeeded()
        return _places
    }

    func place(_ id: String) -> Place? { places.first { $0.id == id } }

    // MARK: Places (UI-061)

    /// Adds a folder (nothing if it is a place already). Throws for something that isn't a folder.
    func addPlace(_ url: URL) throws(BrowserError) {
        readSettingsIfNeeded()
        let url = url.standardizedFileURL
        guard BrowserFileSystem.isFolder(url) else { throw .notAFolder(url.path) }
        guard !_places.contains(where: { $0.url == url }) else { return }
        _places.append(Place(url: url, isMissing: false))
        placesChanged()
    }

    func removePlace(_ id: String) {
        readSettingsIfNeeded()
        guard let index = _places.firstIndex(where: { $0.id == id }) else { return }
        let removed = _places.remove(at: index)
        forget(under: removed.url)
        placesChanged()
    }

    /// Locate…: a missing place points at `url` instead, in the same position.
    func relocatePlace(_ id: String, to url: URL) throws(BrowserError) {
        readSettingsIfNeeded()
        let url = url.standardizedFileURL
        guard BrowserFileSystem.isFolder(url) else { throw .notAFolder(url.path) }
        guard let index = _places.firstIndex(where: { $0.id == id }) else { throw .noPlace(id) }
        forget(under: _places[index].url)
        if _places.contains(where: { $0.url == url }) {
            _places.remove(at: index)  // it is a place already
        } else {
            _places[index] = Place(url: url, isMissing: false)
        }
        placesChanged()
    }

    private func placesChanged() {
        lastError = nil
        if let settingsURL {
            do {
                try BrowserSettings(places: _places.map { .init(path: $0.url.path) }).write(settingsURL)
            } catch {
                lastError = "Couldn't save the browser's places: \(error.localizedDescription)"
            }
        }
        restartWatcher()
        notify()
    }

    private func readSettingsIfNeeded() {
        guard !settingsRead else { return }
        settingsRead = true
        guard let settingsURL else { return }
        _places = BrowserSettings.read(settingsURL).places.map {
            let url = URL(fileURLWithPath: $0.path).standardizedFileURL
            return Place(url: url, isMissing: !BrowserFileSystem.isFolder(url))
        }
        restartWatcher()
    }

    // MARK: Folder contents

    /// The shown children of `folder`, or nil while they are being read (it starts reading them).
    func children(of folder: URL) -> [BrowserItem]? {
        let key = folder.path
        if let items = contents[key] { return items }
        read(folder)
        return nil
    }

    /// Reads `folder` off the main actor (again, if it was read before).
    func read(_ folder: URL) {
        let key = folder.path
        guard tasks[key] == nil else { return }
        reading.insert(key)
        tasks[key] = Task { [weak self] in
            let items = await Task.detached(priority: .userInitiated) { BrowserFileSystem.children(of: folder) ?? [] }.value
            guard let self else { return }
            self.tasks[key] = nil
            self.reading.remove(key)
            if self.contents[key] != items { self.contents[key] = items }
        }
    }

    /// Waits for every folder read in progress (tests and `ui.perform`).
    func settle() async {
        while let task = tasks.values.first { await task.value }
    }

    /// Drops what was read under `url` (a removed place).
    private func forget(under place: URL) {
        let url = BrowserItem.canonical(place)
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        for key in contents.keys where key == url.path || key.hasPrefix(prefix) { contents[key] = nil }
    }

    // MARK: File-system changes (FSEvents)

    private func restartWatcher() {
        watcher?.stop()
        watcher = nil
        guard watchesFileSystem else { return }
        let paths = _places.filter { !$0.isMissing }.map(\.folder.path)
        watcher = FolderWatcher(paths: paths) { [weak self] changed in
            Task { @MainActor in self?.fileSystemChanged(changed) }
        }
    }

    /// UI-061: folders whose contents changed are read again (if they were read), places are
    /// checked for being there, and scans run again.
    func fileSystemChanged(_ paths: [String]) {
        for raw in paths {
            let path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            for key in contents.keys where Self.samePath(key, path) { read(URL(fileURLWithPath: key, isDirectory: true)) }
        }
        var missingChanged = false
        for i in _places.indices {
            let missing = !BrowserFileSystem.isFolder(_places[i].url)
            if missing != _places[i].isMissing {
                _places[i].isMissing = missing
                missingChanged = true
            }
        }
        if missingChanged { restartWatcher() }
        fileSystemVersion += 1
        notify()
    }

    /// Whether a folder key and an FSEvents path name the same folder. FSEvents reports real
    /// paths (`/private/var/…`) where the place may go through a symlink (`/var/…`).
    private static func samePath(_ key: String, _ path: String) -> Bool {
        if key == path { return true }
        return URL(fileURLWithPath: key).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Checks every place again and re-reads the folders shown (the pane appearing, a window
    /// coming to the front).
    func refresh() {
        fileSystemChanged(Array(contents.keys))
    }

    // MARK: Listeners

    /// Browsers hear about place and file-system changes (their scans and searches run again).
    func addListener(_ listener: any BrowserLibraryListener) {
        listeners[ObjectIdentifier(listener)] = WeakListener(listener: listener)
    }

    func removeListener(_ listener: any BrowserLibraryListener) {
        listeners[ObjectIdentifier(listener)] = nil
    }

    private func notify() {
        listeners = listeners.filter { $0.value.listener != nil }
        for entry in listeners.values { entry.listener?.libraryChanged() }
    }

    private struct WeakListener {
        weak var listener: (any BrowserLibraryListener)?
    }

}

@MainActor
protocol BrowserLibraryListener: AnyObject {
    func libraryChanged()
}

/// What a browser action can fail with; shown as an error toast (UI-004) or returned by
/// `ui.perform` (UI-067).
enum BrowserError: Error, Equatable, CustomStringConvertible {
    case notAFolder(String)
    case noPlace(String)
    case refused(String)

    var description: String {
        switch self {
        case .notAFolder(let path): "\(path) isn't a folder"
        case .noPlace(let id): "no place \(id)"
        case .refused(let message): message
        }
    }
}
