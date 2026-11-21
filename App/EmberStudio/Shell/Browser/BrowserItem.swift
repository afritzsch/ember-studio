import Foundation

/// UI-060/061: one entry of the browser's content list: a folder, an audio file or a MIDI file.
/// Its `id` comes from its path (UI-067: stable across refreshes, never the row index), so a row
/// keeps its selection and expansion when the folder is read again.
struct BrowserItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case folder
        /// IO-031's formats.
        case audio
        /// `.mid`, `.midi` (loaded by T-125, MODEL-047).
        case midi
    }

    /// `BrowserItem.id(forPath:)` of `url`.
    let id: String
    let url: URL
    let name: String
    let kind: Kind

    init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
        name = url.lastPathComponent
        id = Self.id(forPath: url.path)
    }

    var isFolder: Bool { kind == .folder }

    /// The one form of a path the browser uses for ids and folder keys: standardized, symlinks
    /// resolved (`/var/…` and `/private/var/…` name the same folder; `contentsOfDirectory` and
    /// FSEvents hand back the latter). Children are built from their parent's canonical path, so
    /// only roots (places, assets, dropped files) need this.
    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    /// UI-067: a stable item id from a path, 16 hex digits (FNV-1a 64 of the path's UTF-8), so it
    /// fits the control id scheme (`browser.item.<id>`, UI-052) whatever characters the path has.
    static func id(forPath path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// IO-031: the formats `AudioFileLoader` decodes (WAV, AIFF, CAF, MP3, AAC, FLAC).
    static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "aac", "m4a", "flac"]
    static let midiExtensions: Set<String> = ["mid", "midi"]

    /// The kind of a file by its extension (case-insensitive); nil for anything the browser
    /// doesn't show.
    static func fileKind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if midiExtensions.contains(ext) { return .midi }
        return nil
    }
}

/// A row of the content list: an item at a depth of the tree (0 for top-level items; search
/// results are flat, depth 0, but their folders can still be expanded).
struct BrowserRow: Identifiable, Hashable, Sendable {
    let item: BrowserItem
    let depth: Int
    /// Folders only.
    let isExpanded: Bool
    /// The file or folder isn't there (a Current Project asset whose file is gone).
    var isMissing = false

    var id: String { item.id }
}
