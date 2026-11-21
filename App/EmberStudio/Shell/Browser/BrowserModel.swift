import AppKit
import DAWModel
import Foundation
import Observation

/// UI-060: the file categories of the sidebar. T-125 adds Instruments, Audio Effects and
/// Plug-ins (devices, not files) next to these.
enum BrowserCategory: String, CaseIterable, Hashable, Sendable {
    case samples, midiFiles

    var title: String {
        switch self {
        case .samples: "Samples"
        case .midiFiles: "MIDI Files"
        }
    }

    /// UI-061: what the category lists from every place.
    var kinds: Set<BrowserItem.Kind> {
        switch self {
        case .samples: [.audio]
        case .midiFiles: [.midi]
        }
    }
}

/// UI-060: a sidebar entry. T-127 adds collections, T-125 the device categories.
enum BrowserSidebarItem: Hashable, Sendable {
    case currentProject
    case category(BrowserCategory)
    /// A place, by `BrowserLibrary.Place.id`.
    case place(String)

    /// The control id suffix (`browser.sidebar.<key>`, UI-067) and `ui.state`'s `sidebar`.
    var key: String {
        switch self {
        case .currentProject: "currentProject"
        case .category(let category): category.rawValue
        case .place(let id): "place.\(id)"
        }
    }
}

/// UI-060: a section of the sidebar as the pane shows it.
struct BrowserSidebarSection: Identifiable {
    struct Entry: Identifiable {
        let item: BrowserSidebarItem
        let title: String
        var isMissing = false
        var id: String { item.key }
    }

    let title: String
    let entries: [Entry]
    var id: String { title }
}

/// UI-060..063, UI-067 (T-124): one window's browser. The sidebar (Categories, Places), the
/// content list (a tree of the selected place's folders, the Current Project's assets, or a scan:
/// a search, or a category's files from every place), keyboard navigation and loading files into
/// the arrange view. Folder contents and the places come from the app-wide `BrowserLibrary`.
@Observable
@MainActor
final class BrowserModel: BrowserLibraryListener {
    @ObservationIgnored weak var window: ProjectWindowModel?
    let library: BrowserLibrary

    private(set) var sidebarSelection: BrowserSidebarItem = .currentProject
    /// Expanded folders, by item id (kept while searching, so clearing the search restores them).
    private(set) var expanded: Set<String> = []
    /// The selected row's item id.
    private(set) var selection: String?
    /// UI-062: the search field.
    private(set) var query = ""

    /// A search's or a category's results, as they arrive.
    private(set) var scanItems: [BrowserItem] = []
    /// More than `BrowserFileSystem.resultCap` matched (the list ends in a "more results" row).
    private(set) var scanTruncated = false
    private(set) var isScanning = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0

    /// UI-062's budget: the longest a scan's step on the main actor took (taking a batch in), so
    /// tests can check the main actor is never blocked by the browser.
    @ObservationIgnored private(set) var longestMainActorStep: Duration = .zero

    /// Hooks the views and tests replace: the "Add Folder…" / "Locate…" open panel (non-modal, so
    /// `ui.perform` returns at once) and Reveal in Finder.
    @ObservationIgnored var chooseFolder: @MainActor (_ title: String, _ done: @escaping @MainActor (URL?) -> Void) -> Void = BrowserModel.openPanel
    @ObservationIgnored var reveal: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    /// Existence of Current Project files, by path (checked once per path; `refresh()` forgets).
    @ObservationIgnored private var existing: [String: Bool] = [:]

    init(window: ProjectWindowModel?, library: BrowserLibrary) {
        self.window = window
        self.library = library
        library.addListener(self)
    }

    // MARK: Sidebar (UI-060)

    var sections: [BrowserSidebarSection] {
        [
            BrowserSidebarSection(title: "Categories", entries: BrowserCategory.allCases.map {
                .init(item: .category($0), title: $0.title)
            }),
            BrowserSidebarSection(title: "Places", entries: [.init(item: .currentProject, title: "Current Project")]
                + library.places.map { .init(item: .place($0.id), title: $0.name, isMissing: $0.isMissing) }),
        ]
    }

    func selectSidebar(_ item: BrowserSidebarItem) {
        guard item != sidebarSelection else { return }
        sidebarSelection = item
        selection = nil
        restartScan()
    }

    /// The selected place, if a place is selected.
    var selectedPlace: BrowserLibrary.Place? {
        guard case .place(let id) = sidebarSelection else { return nil }
        return library.place(id)
    }

    // MARK: Places (UI-061)

    /// "Add Folder…": the open panel, then the folder becomes a place (and is selected).
    func addFolder() {
        chooseFolder("Add Folder") { [weak self] url in
            guard let self, let url else { return }
            self.addPlace(url)
        }
    }

    /// Adds `url` as a place and selects it; a refusal is an error toast.
    @discardableResult
    func addPlace(_ url: URL) -> Bool {
        do {
            try library.addPlace(url)
        } catch {
            window?.toasts.post(.error, .error, title: "Couldn't add the folder", message: error.description)
            return false
        }
        if let place = library.places.first(where: { $0.url == url.standardizedFileURL }) { selectSidebar(.place(place.id)) }
        if let error = library.lastError { window?.toasts.post(.error, .error, title: "Browser", message: error) }
        return true
    }

    func removePlace(_ id: String) {
        library.removePlace(id)
        if sidebarSelection == .place(id) { selectSidebar(.currentProject) }
    }

    /// Locate…: picks where a missing place went.
    func locatePlace(_ id: String) {
        chooseFolder("Locate Folder") { [weak self] url in
            guard let self, let url else { return }
            self.relocatePlace(id, to: url)
        }
    }

    @discardableResult
    func relocatePlace(_ id: String, to url: URL) -> Bool {
        let shown = sidebarSelection == .place(id)
        do {
            try library.relocatePlace(id, to: url)
        } catch {
            window?.toasts.post(.error, .error, title: "Couldn't locate the folder", message: error.description)
            return false
        }
        if shown, let place = library.places.first(where: { $0.url == url.standardizedFileURL }) {
            sidebarSelection = .place(place.id)
            restartScan()
        }
        return true
    }

    func revealPlace(_ id: String) {
        if let place = library.place(id) { reveal([place.url]) }
    }

    func revealItem(_ id: String) {
        if let row = row(id) { reveal([row.item.url]) }
    }

    nonisolated static func openPanel(title: String, done: @escaping @MainActor (URL?) -> Void) {
        MainActor.assumeIsolated {
            let panel = NSOpenPanel()
            panel.title = title
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.begin { response in
                MainActor.assumeIsolated { done(response == .OK ? panel.url : nil) }
            }
        }
    }

    // MARK: Content list (UI-060)

    /// Whether the list shows a scan (a search, or a category) instead of a tree.
    var showsScan: Bool {
        if !query.isEmpty { return true }
        if case .category = sidebarSelection { return true }
        return false
    }

    /// The rows the content list shows, top to bottom. A tree's folder whose contents aren't read
    /// yet shows no children (they arrive from the library).
    var rows: [BrowserRow] {
        var rows: [BrowserRow] = []
        if showsScan {
            appendTree(scanItems, depth: 0, into: &rows)
            return rows
        }
        switch sidebarSelection {
        case .currentProject:
            return currentProjectItems.map { BrowserRow(item: $0, depth: 0, isExpanded: false, isMissing: !exists($0.url)) }
        case .place(let id):
            guard let place = library.place(id), !place.isMissing, let items = library.children(of: place.folder) else { return [] }
            appendTree(items, depth: 0, into: &rows)
        case .category:
            break  // a scan
        }
        return rows
    }

    private func appendTree(_ items: [BrowserItem], depth: Int, into rows: inout [BrowserRow]) {
        for item in items {
            let isExpanded = item.isFolder && expanded.contains(item.id)
            rows.append(BrowserRow(item: item, depth: depth, isExpanded: isExpanded))
            if isExpanded, let children = library.children(of: item.url) {
                appendTree(children, depth: depth + 1, into: &rows)
            }
        }
    }

    /// UI-061: the project's assets, once each (by file), as the files they are.
    var currentProjectItems: [BrowserItem] {
        guard let window else { return [] }
        var seen = Set<String>()
        return window.project.assets.compactMap { asset in
            let url = Self.fileURL(of: asset, in: window.store.folderURL)
            guard seen.insert(url.path).inserted else { return nil }
            return BrowserItem(url: url, kind: .audio)
        }
    }

    /// The file an asset names: its absolute path, or its project-relative path in the folder.
    static func fileURL(of asset: AssetRef, in folder: URL?) -> URL {
        let url = asset.path.hasPrefix("/") ? URL(fileURLWithPath: asset.path) : folder?.appending(path: asset.path) ?? URL(fileURLWithPath: asset.path)
        return BrowserItem.canonical(url)
    }

    private func exists(_ url: URL) -> Bool {
        if let known = existing[url.path] { return known }
        let found = FileManager.default.fileExists(atPath: url.path)
        existing[url.path] = found
        return found
    }

    func row(_ id: String) -> BrowserRow? { rows.first { $0.id == id } }

    var selectedRow: BrowserRow? { selection.flatMap(row) }

    // MARK: Selection and expansion (UI-060 keyboard)

    func select(_ id: String?) {
        if selection != id { selection = id }
    }

    func setExpanded(_ id: String, _ on: Bool) {
        if on { expanded.insert(id) } else { expanded.remove(id) }
    }

    func toggleExpanded(_ id: String) { setExpanded(id, !expanded.contains(id)) }

    /// ↑/↓: the row above or below the selection (the first row when nothing is selected).
    func moveSelection(by delta: Int) {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        guard let current = selection.flatMap({ id in rows.firstIndex { $0.id == id } }) else {
            select(rows[delta < 0 ? rows.count - 1 : 0].id)
            return
        }
        select(rows[min(max(current + delta, 0), rows.count - 1)].id)
    }

    /// →: expands the selected folder.
    func expandSelection() {
        guard let row = selectedRow, row.item.isFolder, !row.isExpanded else { return }
        setExpanded(row.id, true)
    }

    /// ←: collapses the selected folder, or goes to the folder it is in.
    func collapseSelection() {
        let rows = self.rows
        guard let index = selection.flatMap({ id in rows.firstIndex { $0.id == id } }) else { return }
        let row = rows[index]
        if row.isExpanded {
            setExpanded(row.id, false)
        } else if row.depth > 0, let parent = rows[..<index].last(where: { $0.depth == row.depth - 1 }) {
            select(parent.id)
        }
    }

    /// Double-click / Return (UI-063): a folder opens or closes; a file loads onto the selected
    /// track at the playhead (no selected track: a new one).
    func activate(_ id: String) {
        guard let row = row(id) else { return }
        select(id)
        if row.item.isFolder {
            toggleExpanded(id)
            return
        }
        Task { _ = try? await loadAtPlayhead(row.item) }
    }

    func activateSelection() {
        if let selection { activate(selection) }
    }

    // MARK: Search and scans (UI-062, UI-061 categories)

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        restartScan()
    }

    /// Cancels the scan in progress and starts the one the sidebar and the query ask for.
    func restartScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        scanItems = []
        scanTruncated = false
        guard showsScan else {
            isScanning = false
            return
        }
        isScanning = true
        let generation = scanGeneration
        let query = self.query
        let stream: AsyncStream<BrowserFileSystem.Event>
        switch sidebarSelection {
        case .currentProject:
            let items = currentProjectItems
            let search = BrowserFileSystem.Search(roots: [], query: query, kinds: [.audio])
            stream = AsyncStream { continuation in
                let filter = Task.detached {
                    let matches = items.filter(search.matches)
                    if !Task.isCancelled, !matches.isEmpty { continuation.yield(.batch(matches)) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in filter.cancel() }
            }
        case .place(let id):
            let roots = library.place(id).map { [$0.folder] } ?? []
            stream = BrowserFileSystem.search(.init(roots: roots, query: query, kinds: [.folder, .audio, .midi]))
        case .category(let category):
            let roots = library.places.filter { !$0.isMissing }.map(\.folder)
            stream = BrowserFileSystem.search(.init(roots: roots, query: query, kinds: category.kinds))
        }
        scanTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.scanGeneration == generation, !Task.isCancelled else { return }
                self.take(event)
            }
            guard let self, self.scanGeneration == generation else { return }
            self.isScanning = false
        }
    }

    private func take(_ event: BrowserFileSystem.Event) {
        let clock = ContinuousClock()
        let started = clock.now
        switch event {
        case .batch(let items): scanItems.append(contentsOf: items)
        case .truncated: scanTruncated = true
        }
        longestMainActorStep = max(longestMainActorStep, clock.now - started)
    }

    /// Waits until the scan in progress has finished and the folders the list shows are read
    /// (tests and `ui.perform`; at most `timeout`).
    func settle(timeout: Duration = .seconds(10)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            await scanTask?.value
            _ = rows  // asks for the expanded folders' contents
            await library.settle()
            if !isScanning && library.reading.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: BrowserLibraryListener

    func libraryChanged() {
        if case .place(let id) = sidebarSelection, library.place(id) == nil { selectSidebar(.currentProject) }
        if showsScan { restartScan() }
    }

    /// Checks files again (the pane appearing): Current Project files, places, read folders.
    func refresh() {
        existing = [:]
        library.refresh()
    }
}
