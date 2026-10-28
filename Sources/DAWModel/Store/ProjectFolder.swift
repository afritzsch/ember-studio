import Darwin
import Foundation

/// MODEL-040: a project on disk is a folder (`Name.dawproject/` by convention):
///
///     project.json            the document (ProjectFile), replaced atomically (MODEL-041)
///     Audio/                  audio files the project owns; AssetRef paths inside the folder are relative
///     Plugins/<slotID>.state  plugin state blobs (MODEL-043)
///     Cache/                  disposable (waveform overviews and the like)
///     autosave/               project.json + Plugins/ of the last autosave (MODEL-044)
///
/// Everything here is plain file I/O on value types, so `ProjectStore` runs it off the main actor.
struct ProjectFolder: Sendable {
    static let projectFileName = "project.json"
    static let audioFolderName = "Audio"
    static let pluginsFolderName = "Plugins"
    static let cacheFolderName = "Cache"
    static let autosaveFolderName = "autosave"
    static let pluginStateExtension = "state"

    let url: URL

    var projectFile: URL { url.appending(path: Self.projectFileName) }
    var audioFolder: URL { url.appending(path: Self.audioFolderName, directoryHint: .isDirectory) }
    var autosaveFolder: URL { url.appending(path: Self.autosaveFolderName, directoryHint: .isDirectory) }
    var autosaveFile: URL { autosaveFolder.appending(path: Self.projectFileName) }

    // MARK: Open

    /// Reads the project (MODEL-045: the autosave instead when `recover` is set and it is newer),
    /// migrates (MODEL-042), checks it (DW-111), reads plugin states back into the slots and
    /// reports assets whose file is missing (MODEL-046).
    func load(recover: Bool) throws(DAWError) -> (Project, ProjectLoadReport) {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw .fileIO(path: url.path, detail: "no project folder")
        }
        let mainDate = Self.modificationDate(projectFile)
        let autosaveDate = Self.modificationDate(autosaveFile)
        var autosaveIsNewer = false
        if let autosaveDate { autosaveIsNewer = mainDate.map { autosaveDate > $0 } ?? true }

        var report = ProjectLoadReport()
        let source: URL
        let pluginsFolder: URL
        if recover && autosaveIsNewer {
            source = autosaveFile
            pluginsFolder = autosaveFolder.appending(path: Self.pluginsFolderName)
            report.recovered = true
        } else {
            guard mainDate != nil else {
                let hint = autosaveDate != nil ? "; an autosave exists, open with recovery" : ""
                throw .fileIO(path: projectFile.path, detail: "no \(Self.projectFileName)\(hint)")
            }
            source = projectFile
            pluginsFolder = url.appending(path: Self.pluginsFolderName)
            report.recoveryAvailable = autosaveIsNewer
        }

        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw .fileIO(path: source.path, detail: error.localizedDescription)
        }
        var (project, migratedFrom) = try ProjectFile.decode(data)
        report.migratedFrom = migratedFrom
        report.repairs = try ProjectFile.validateOrRepair(&project)
        project.updateEachDeviceSlot { slot in
            let file = pluginsFolder.appending(path: "\(slot.id).\(Self.pluginStateExtension)")
            if let state = try? Data(contentsOf: file) { slot.pluginState = state }
        }
        report.offlineAssets = project.assets.filter { asset in
            guard let file = Self.resolve(asset, in: url) else { return true }
            return !fm.isReadableFile(atPath: file.path)
        }.map(\.id).sorted()
        return (project, report)
    }

    /// Where an asset's file is: its absolute path, or its relative path inside `folder`. Nil for
    /// a relative path without a folder.
    static func resolve(_ asset: AssetRef, in folder: URL?) -> URL? {
        if asset.path.hasPrefix("/") { return URL(filePath: asset.path) }
        return folder?.appending(path: asset.path)
    }

    // MARK: Save

    /// Writes the project into this folder. Assets outside it are copied into `Audio/` first and
    /// their paths made relative (DW-124); relative paths resolve against `sourceFolder`, where
    /// the project was until now. Returns the asset paths that changed. Order: audio, plugin
    /// states, then `project.json` as the commit point (MODEL-041); stale plugin states and the
    /// autosave, which is older than the file now, are removed after it.
    func save(_ project: Project, pluginStates: [NodeIDValue: Data], sourceFolder: URL?) throws(DAWError)
        -> [ModelID: String]
    {
        try createFolders()
        var project = project
        let moved = try relocateAssets(&project, from: sourceFolder)
        let plugins = url.appending(path: Self.pluginsFolderName)
        try writePluginStates(pluginStates, into: plugins)
        try AtomicFile.write(ProjectFile.encode(project), to: projectFile)
        removeStalePluginStates(in: plugins, keeping: Set(pluginStates.keys))
        removeAutosave()
        return moved
    }

    /// MODEL-044: writes `autosave/project.json` and `autosave/Plugins/`. Never touches the main
    /// file, and copies no audio: relative asset paths resolve against the project folder.
    func autosave(_ project: Project, pluginStates: [NodeIDValue: Data]) throws(DAWError) {
        let plugins = autosaveFolder.appending(path: Self.pluginsFolderName)
        try Self.createFolder(plugins)
        try writePluginStates(pluginStates, into: plugins)
        try AtomicFile.write(ProjectFile.encode(project), to: autosaveFile)
        removeStalePluginStates(in: plugins, keeping: Set(pluginStates.keys))
    }

    /// MODEL-045: a clean quit (or a save) leaves no autosave behind.
    func removeAutosave() {
        try? FileManager.default.removeItem(at: autosaveFolder)
    }

    // MARK: Private

    private func createFolders() throws(DAWError) {
        for name in [Self.audioFolderName, Self.pluginsFolderName, Self.cacheFolderName] {
            try Self.createFolder(url.appending(path: name, directoryHint: .isDirectory))
        }
    }

    private static func createFolder(_ folder: URL) throws(DAWError) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw .fileIO(path: folder.path, detail: error.localizedDescription)
        }
    }

    /// DW-124: every asset ends up with a path relative to this folder if its file is here or can
    /// be copied here. A missing file keeps an absolute path to where it was expected, so it stays
    /// offline instead of pointing somewhere else (MODEL-046).
    private func relocateAssets(_ project: inout Project, from sourceFolder: URL?) throws(DAWError) -> [ModelID: String] {
        let fm = FileManager.default
        var moved: [ModelID: String] = [:]
        for i in project.assets.indices {
            let asset = project.assets[i]
            guard let file = Self.resolve(asset, in: sourceFolder) else { continue }
            var path: String
            if let inside = Self.relativePath(of: file, inside: url) {
                path = inside
            } else if fm.isReadableFile(atPath: file.path) {
                path = try copyIntoAudio(file)
            } else {
                path = file.path
            }
            if path != asset.path {
                project.assets[i].path = path
                moved[asset.id] = path
            }
        }
        return moved
    }

    /// Copies `file` into `Audio/` under its own name, or `name-2`, `name-3`… if another file has
    /// it. A file with the same contents already there is reused, so saving twice (or redoing an
    /// import of the same file) doesn't copy again.
    private func copyIntoAudio(_ file: URL) throws(DAWError) -> String {
        let fm = FileManager.default
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        for n in 1... {
            let name = n == 1 ? file.lastPathComponent : "\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)")
            let destination = audioFolder.appending(path: name)
            if !fm.fileExists(atPath: destination.path) {
                try AtomicFile.copy(file, to: destination)
            } else if !fm.contentsEqual(atPath: destination.path, andPath: file.path) {
                continue
            }
            return "\(Self.audioFolderName)/\(name)"
        }
        fatalError("unreachable")
    }

    private func writePluginStates(_ states: [NodeIDValue: Data], into folder: URL) throws(DAWError) {
        guard !states.isEmpty else { return }
        try Self.createFolder(folder)
        for (slot, state) in states.sorted(by: { $0.key < $1.key }) {
            try AtomicFile.write(state, to: folder.appending(path: "\(slot).\(Self.pluginStateExtension)"))
        }
    }

    private func removeStalePluginStates(in folder: URL, keeping slots: Set<NodeIDValue>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == Self.pluginStateExtension {
            if let slot = NodeIDValue(file.deletingPathExtension().lastPathComponent), slots.contains(slot) { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// `file`'s path below `folder`, or nil if it isn't inside. Both are compared by their real
    /// paths (temporary folders are behind the /var → /private/var link).
    static func relativePath(of file: URL, inside folder: URL) -> String? {
        let f = realPath(file).pathComponents
        let d = realPath(folder).pathComponents
        guard f.count > d.count, Array(f.prefix(d.count)) == d else { return nil }
        return f.dropFirst(d.count).joined(separator: "/")
    }

    /// The real path of `url`, or of its folder plus its name when it doesn't exist.
    private static func realPath(_ url: URL) -> URL {
        let standard = url.standardizedFileURL
        if let resolved = realpath(standard.path, nil) {
            defer { free(resolved) }
            return URL(filePath: String(cString: resolved))
        }
        let parent = standard.deletingLastPathComponent()
        guard parent.path != standard.path else { return standard }
        return realPath(parent).appending(path: standard.lastPathComponent)
    }
}
