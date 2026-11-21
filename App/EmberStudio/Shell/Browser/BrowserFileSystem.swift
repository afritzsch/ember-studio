import Foundation

/// UI-061/062: the browser's file-system reads. Everything here is plain file I/O that runs off
/// the main actor (`Task.detached`): reading one folder, and the recursive search/scan, which
/// streams its results in batches and stops when the task is cancelled.
enum BrowserFileSystem {
    /// UI-062: at most this many results; one more found sets `truncated`.
    static let resultCap = 5000
    /// A batch goes to the main actor when it has this many items, or after `batchInterval`.
    static let batchSize = 250
    static let batchInterval: Duration = .milliseconds(30)

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]

    /// The folder's subfolders and shown files (IO-031 audio, MIDI), folders first, each group
    /// in Finder order. Hidden files and packages are skipped (UI-061). Nil when it can't be read
    /// (missing, no permission).
    static func children(of folder: URL) -> [BrowserItem]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }
        // Each child under `folder` as given (the enumerator may hand back another form of the
        // path, `/private/var/…` for `/var/…`), so ids stay the same however a folder is reached.
        let items = urls.compactMap { url in
            item(for: url).map { BrowserItem(url: folder.appending(path: $0.name, directoryHint: $0.isFolder ? .isDirectory : .notDirectory), kind: $0.kind) }
        }
        return sorted(items)
    }

    /// Folders first, then files, by name as Finder sorts them.
    static func sorted(_ items: [BrowserItem]) -> [BrowserItem] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The item for a URL the enumerator produced, nil for what the browser doesn't show.
    private static func item(for url: URL) -> BrowserItem? {
        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isHidden == true || values?.isPackage == true { return nil }
        if values?.isDirectory == true { return BrowserItem(url: url, kind: .folder) }
        return BrowserItem.fileKind(of: url).map { BrowserItem(url: url, kind: $0) }
    }

    /// Whether `url` is an existing folder.
    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Search (UI-062)

    /// What a search or category scan reports.
    enum Event: Sendable {
        case batch([BrowserItem])
        /// More than `resultCap` matched; nothing follows.
        case truncated
    }

    /// What to look for: items whose name contains `query` (case-insensitive; empty matches
    /// everything) and whose kind is one of `kinds`.
    struct Search: Sendable {
        var roots: [URL]
        var query: String
        var kinds: Set<BrowserItem.Kind>
        var cap = BrowserFileSystem.resultCap

        func matches(_ item: BrowserItem) -> Bool {
            kinds.contains(item.kind) && (query.isEmpty || item.name.range(of: query, options: [.caseInsensitive]) != nil)
        }
    }

    /// UI-062: walks `search.roots` recursively off the main actor and streams the matches in
    /// batches. Cancelling the consuming task (the next keystroke) stops the walk.
    static func search(_ search: Search) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let walk = Task.detached(priority: .userInitiated) {
                var batch: [BrowserItem] = []
                var found = 0
                let clock = ContinuousClock()
                var lastSent = clock.now
                func flush() {
                    if !batch.isEmpty { continuation.yield(.batch(batch)) }
                    batch = []
                    lastSent = clock.now
                }
                roots: for root in search.roots {
                    // Relative paths, appended to the root as given (see `children(of:)`).
                    guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { continue }
                    while let relative = enumerator.nextObject() as? String {
                        if Task.isCancelled { break roots }
                        let name = (relative as NSString).lastPathComponent
                        let isDirectory = enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
                        if name.hasPrefix(".") {
                            if isDirectory { enumerator.skipDescendants() }  // UI-061: hidden
                            continue
                        }
                        let url = root.appending(path: relative, directoryHint: isDirectory ? .isDirectory : .notDirectory)
                        let item: BrowserItem
                        if isDirectory {
                            // A package (an .app, a .logicx) is one file to Finder: skipped whole.
                            if !url.pathExtension.isEmpty, (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
                                enumerator.skipDescendants()
                                continue
                            }
                            item = BrowserItem(url: url, kind: .folder)
                        } else if let kind = BrowserItem.fileKind(of: url) {
                            item = BrowserItem(url: url, kind: kind)
                        } else {
                            continue
                        }
                        guard search.matches(item) else { continue }
                        if found == search.cap {
                            flush()
                            continuation.yield(.truncated)
                            break roots
                        }
                        found += 1
                        batch.append(item)
                        if batch.count >= batchSize || clock.now - lastSent >= batchInterval { flush() }
                    }
                }
                if !Task.isCancelled { flush() }
                continuation.finish()
            }
            continuation.onTermination = { _ in walk.cancel() }
        }
    }
}
