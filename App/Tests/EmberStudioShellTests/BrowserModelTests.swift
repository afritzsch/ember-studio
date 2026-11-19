import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-060..063 (T-124): the browser's view model over a temp folder tree (CONV §9) and a FakeEngine.

/// A folder tree under a TempDir: `files` are paths relative to the root ("Drums/kick.wav").
@MainActor
private func makeTree(_ files: [String], in temp: TempDir) throws -> URL {
    let root = temp.url.appending(path: "Library", directoryHint: .isDirectory)
    for file in files {
        let url = root.appending(path: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if file.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.standardizedFileURL
}

/// A window with a browser over its own library (settings in `temp`, FSEvents off unless asked).
@MainActor
private func makeBrowser(_ temp: TempDir, tracks: [String] = [], watches: Bool = false) throws -> (BrowserModel, ProjectWindowModel, FakeEngine) {
    let (window, engine) = try makeWindow(tracks: tracks)
    let library = BrowserLibrary(settingsURL: temp.file("Browser.json"), watchesFileSystem: watches)
    let browser = BrowserModel(window: window, library: library)
    browser.chooseFolder = { _, done in done(nil) }
    browser.reveal = { _ in }
    return (browser, window, engine)
}

@MainActor
@Suite("Browser (UI-060..063)", .serialized)
struct BrowserModelTests {
    // MARK: UI-060

    @Test("UI-060: sidebar sections; rows are a tree with disclosure; ↑/↓ select, ←/→ collapse/expand, Return opens folders")
    func sidebarTreeAndKeyboard() async throws {
        let temp = try TempDir()
        let root = try makeTree(["Drums/kick.wav", "Drums/snare.aif", "Drums/Loops/beat.wav", "bass.flac", "song.mid"], in: temp)
        let (browser, _, _) = try makeBrowser(temp)
        #expect(browser.sections.map(\.title) == ["Categories", "Places"])
        #expect(browser.sections[0].entries.map(\.item) == [.category(.samples), .category(.midiFiles)])
        #expect(browser.sections[1].entries.map(\.item) == [.currentProject])
        #expect(browser.addPlace(root))
        let place = try #require(browser.library.places.first)
        #expect(browser.sidebarSelection == .place(place.id), "a new place is shown")
        #expect(browser.sections[1].entries.map(\.title) == ["Current Project", "Library"])
        await browser.settle()
        #expect(browser.rows.map(\.item.name) == ["Drums", "bass.flac", "song.mid"], "folders first")
        let drums = browser.rows[0]
        #expect(drums.item.kind == .folder && !drums.isExpanded && drums.id == BrowserItem.id(forPath: root.appending(path: "Drums").path))

        browser.moveSelection(by: 1)  // nothing selected: the first row
        #expect(browser.selection == drums.id)
        browser.expandSelection()  // →
        await browser.settle()
        #expect(browser.rows.map(\.item.name) == ["Drums", "Loops", "kick.wav", "snare.aif", "bass.flac", "song.mid"])
        #expect(browser.rows[1].depth == 1)
        browser.moveSelection(by: 2)  // ↓↓
        #expect(browser.selectedRow?.item.name == "kick.wav")
        browser.collapseSelection()  // ← on a file: up to its folder
        #expect(browser.selection == drums.id)
        browser.collapseSelection()  // ← on an open folder: closes it
        #expect(browser.rows.count == 3)
        browser.moveSelection(by: 5)
        #expect(browser.selectedRow?.item.name == "song.mid", "clamped at the last row")
        browser.moveSelection(by: -10)
        #expect(browser.selection == drums.id)
        browser.activateSelection()  // Return on a folder opens it
        await browser.settle()
        #expect(browser.row(drums.id)?.isExpanded == true)
        browser.activate(drums.id)
        #expect(browser.row(drums.id)?.isExpanded == false)
    }

    // MARK: UI-061

    @Test("UI-061: places persist in Browser.json (atomic); remove; hidden files, packages and other files are skipped")
    func placesPersistAndFilter() async throws {
        let temp = try TempDir()
        let root = try makeTree([".hidden.wav", "notes.txt", "Tool.app/inside.wav", "a.WAV", "b.midi", "Sub/"], in: temp)
        let (browser, _, _) = try makeBrowser(temp)
        #expect(browser.addPlace(root))
        #expect(!browser.addPlace(temp.file("nope")), "not a folder")
        await browser.settle()
        // A package (a folder with a known package extension) counts as one file, which isn't shown.
        #expect(browser.rows.map(\.item.name) == ["Sub", "a.WAV", "b.midi"])
        #expect(browser.rows.map(\.item.kind) == [.folder, .audio, .midi])

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: temp.file("Browser.json"))) as? [String: Any]
        #expect(json?["version"] as? Int == 1)
        #expect((json?["places"] as? [[String: Any]])?.first?["path"] as? String == root.path)
        let again = BrowserLibrary(settingsURL: temp.file("Browser.json"), watchesFileSystem: false)
        #expect(again.places.map(\.url) == [root], "read back by a new library (the next launch)")
        #expect(again.places.first?.id == browser.library.places.first?.id, "same id from the same path")

        browser.removePlace(try #require(browser.library.places.first).id)
        #expect(browser.library.places.isEmpty && browser.sidebarSelection == .currentProject)
        #expect(BrowserLibrary(settingsURL: temp.file("Browser.json"), watchesFileSystem: false).places.isEmpty)
    }

    @Test("UI-061: a missing place shows greyed; Locate… points it at another folder; Remove drops it")
    func missingPlace() async throws {
        let temp = try TempDir()
        let root = try makeTree(["one.wav"], in: temp)
        let other = temp.url.appending(path: "Moved", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: other.appending(path: "two.wav").path, contents: Data())
        try BrowserSettings(places: [.init(path: root.path), .init(path: temp.file("Gone").path)]).write(temp.file("Browser.json"))
        let (browser, _, _) = try makeBrowser(temp)
        let places = browser.library.places
        #expect(places.map(\.isMissing) == [false, true])
        #expect(browser.sections[1].entries.map(\.isMissing) == [false, false, true])
        let gone = places[1].id
        #expect(browser.controls.contains { $0.id == "browser.place.\(gone).locate" })
        #expect(!browser.controls.contains { $0.id == "browser.place.\(places[0].id).locate" })
        browser.selectSidebar(.place(gone))
        #expect(browser.rows.isEmpty)
        browser.chooseFolder = { _, done in done(other) }
        browser.locatePlace(gone)
        #expect(browser.library.places.map(\.url) == [root, other.standardizedFileURL], "same position")
        await browser.settle()
        #expect(browser.rows.map(\.item.name) == ["two.wav"], "the relocated place stays shown")
        browser.removePlace(browser.library.places[1].id)
        #expect(browser.library.places.map(\.url) == [root])
    }

    @Test("UI-061: contents follow the file system (FSEvents): a new file shows up in an open folder")
    func fileSystemEvents() async throws {
        let temp = try TempDir()
        let root = try makeTree(["Kit/a.wav"], in: temp)
        let (browser, _, _) = try makeBrowser(temp, watches: true)
        #expect(browser.addPlace(root))
        await browser.settle()
        let kit = try #require(browser.rows.first)
        browser.setExpanded(kit.id, true)
        await browser.settle()
        #expect(browser.rows.map(\.item.name) == ["Kit", "a.wav"])
        FileManager.default.createFile(atPath: root.appending(path: "Kit/b.wav").path, contents: Data())
        FileManager.default.createFile(atPath: root.appending(path: "top.wav").path, contents: Data())
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while browser.rows.count < 4 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            await browser.settle()
        }
        #expect(browser.rows.map(\.item.name) == ["Kit", "a.wav", "b.wav", "top.wav"])
        #expect(browser.rows[0].id == kit.id && browser.rows[0].isExpanded, "ids and expansion survive the re-read")
    }

    @Test("UI-061: Current Project lists the project's assets (once per file, missing ones greyed); categories list every matching file in all places")
    func currentProjectAndCategories() async throws {
        let temp = try TempDir()
        let root = try makeTree(["A/kick.wav", "A/B/hat.aif", "groove.mid", "C/fill.midi"], in: temp)
        let (browser, window, _) = try makeBrowser(temp)
        let kick = root.appending(path: "A/kick.wav")
        try window.store.perform(ImportAsset(asset: AssetRef(id: window.store.reserveID(), path: kick.path, channels: 2,
                                                              originalSampleRate: 48000, frames: 48000)))
        try window.store.perform(ImportAsset(asset: AssetRef(id: window.store.reserveID(), path: kick.path, channels: 2,
                                                              originalSampleRate: 48000, frames: 48000)))
        try window.store.perform(ImportAsset(asset: AssetRef(id: window.store.reserveID(), path: temp.file("gone.wav").path, channels: 1,
                                                              originalSampleRate: 48000, frames: 10)))
        #expect(browser.rows.map(\.item.name) == ["kick.wav", "gone.wav"])
        #expect(browser.rows.map(\.isMissing) == [false, true])

        #expect(browser.addPlace(root))
        browser.selectSidebar(.category(.samples))
        await browser.settle()
        #expect(Set(browser.rows.map(\.item.name)) == ["kick.wav", "hat.aif"])
        browser.selectSidebar(.category(.midiFiles))
        await browser.settle()
        #expect(Set(browser.rows.map(\.item.name)) == ["groove.mid", "fill.midi"])
        #expect(browser.rows.allSatisfy { $0.depth == 0 })
    }

    // MARK: UI-062

    @Test("UI-062: search is a case-insensitive substring match, recursive, in the selected sidebar item; clearing restores the tree with its expansion")
    func search() async throws {
        let temp = try TempDir()
        let root = try makeTree(["Drums/Kick 01.wav", "Drums/Deep/KICK-sub.aif", "Drums/snare.wav", "kickstart.mid", "Pads/warm.wav"], in: temp)
        let (browser, _, _) = try makeBrowser(temp)
        #expect(browser.addPlace(root))
        await browser.settle()
        let drums = try #require(browser.rows.first { $0.item.name == "Drums" })
        browser.setExpanded(drums.id, true)
        await browser.settle()
        let tree = browser.rows.map(\.item.name)
        #expect(tree == ["Drums", "Deep", "Kick 01.wav", "snare.wav", "Pads", "kickstart.mid"])

        browser.setQuery("kick")
        #expect(browser.showsScan && browser.isScanning)
        await browser.settle()
        #expect(!browser.isScanning)
        #expect(Set(browser.rows.map(\.item.name)) == ["Kick 01.wav", "KICK-sub.aif", "kickstart.mid"])
        browser.setQuery("deep")
        await browser.settle()
        #expect(browser.rows.map(\.item.name) == ["Deep"], "folders match too")

        // Current Project searches the project's assets.
        browser.selectSidebar(.currentProject)
        await browser.settle()
        #expect(browser.rows.isEmpty)

        browser.selectSidebar(.place(try #require(browser.library.places.first).id))
        browser.setQuery("")
        await browser.settle()
        #expect(browser.rows.map(\.item.name) == tree, "the tree comes back as it was, expanded")
    }

    @Test("UI-062: the next keystroke cancels the search in progress; only the last query's results arrive")
    func searchCancelled() async throws {
        let temp = try TempDir()
        let root = try makeTree((0..<2000).map { "F\($0 % 20)/take\($0).wav" } + ["zebra.wav"], in: temp)
        let (browser, _, _) = try makeBrowser(temp)
        #expect(browser.addPlace(root))
        browser.setQuery("take")
        browser.setQuery("zeb")
        await browser.settle()
        #expect(browser.rows.map(\.item.name) == ["zebra.wav"])
    }

    @Test("UI-062: 10,000 files: results arrive in batches, capped at 5,000 with more results; the main actor is never blocked > 16 ms")
    func searchLargeTree() async throws {
        let temp = try TempDir()
        let root = try makeTree((0..<10_000).map { "Folder\($0 / 500)/sample\($0).wav" }, in: temp)
        let (browser, _, _) = try makeBrowser(temp)
        #expect(browser.addPlace(root))
        browser.setQuery("SAMPLE")
        var sawPartial = false
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(60)
        while browser.isScanning && clock.now < deadline {
            if !browser.scanItems.isEmpty && browser.scanItems.count < BrowserFileSystem.resultCap { sawPartial = true }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!browser.isScanning)
        #expect(sawPartial, "results arrive as they are found")
        #expect(browser.scanItems.count == BrowserFileSystem.resultCap && browser.scanTruncated)
        #expect(browser.rows.count == BrowserFileSystem.resultCap)
        #expect(browser.longestMainActorStep < .milliseconds(16), "\(browser.longestMainActorStep)")

        browser.setQuery("sample9999")
        await browser.settle()
        #expect(browser.rows.map(\.item.name) == ["sample9999.wav"] && !browser.scanTruncated)
    }
}
