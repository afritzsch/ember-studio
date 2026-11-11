import Foundation

/// `project.json` (MODEL-040): encoding, decoding with migrations (MODEL-042), and the validity
/// check on open (MODEL-032, DW-111). Folder handling is `ProjectFolder`'s.
public enum ProjectFile {
    /// Pretty-printed with sorted keys, so files diff well and the same project gives the same
    /// bytes. Slashes stay unescaped (asset paths). A new encoder per use: JSONEncoder is a class.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The file contents for `project`. Plugin states are left out: they live in
    /// `Plugins/<slotID>.state` (MODEL-040), not as base64 in the JSON.
    public static func encode(_ project: Project) throws(DAWError) -> Data {
        var stripped = project
        stripped.updateEachDeviceSlot { $0.pluginState = nil }
        do {
            return try encoder.encode(stripped)
        } catch {
            throw .invalidProject("cannot encode: \(error)")
        }
    }

    /// Decodes a file, migrating it first if its `formatVersion` is older than `currentVersion`
    /// (MODEL-042). A newer file is rejected rather than read with fields this build would drop.
    public static func decode(
        _ data: Data, currentVersion: Int = Project.currentFormatVersion,
        steps: [Int: Migrations.Step] = Migrations.steps
    ) throws(DAWError) -> (project: Project, migratedFrom: Int?) {
        struct Header: Decodable { var formatVersion: Int? }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw .invalidProject("not a project file: \(describe(error))")
        }
        guard header.formatVersion != currentVersion else {
            return (try decodeProject(data), nil)
        }
        var json = try JSON(parsing: data)
        let original = try Migrations.migrate(&json, to: currentVersion, steps: steps)
        return (try decodeProject(json.encoded()), original)
    }

    /// DW-111: checks every invariant (MODEL-032). The repairs are orderings, which are safe
    /// because the order is a function of the data: clips by (start, id) (DW-110) and notes by
    /// (start, id); and, since T-088 (DW-150, user decision), a note velocity of 0 becomes 1 (a
    /// note-on with velocity 0 would be a note-off; the clip player already played it as 1).
    /// Anything else is reported as an error and the file isn't opened. Returns one line per
    /// repair.
    public static func validateOrRepair(_ project: inout Project) throws(DAWError) -> [String] {
        let failure: DAWError
        do {
            try project.validate()
            return []
        } catch {
            failure = error
        }
        var repaired = project
        var repairs: [String] = []
        for t in repaired.tracks.indices {
            let track = repaired.tracks[t].id
            for c in repaired.tracks[t].clips.indices {
                guard case .midi(var clip) = repaired.tracks[t].clips[c] else { continue }
                // DW-150
                for n in clip.notes.indices where clip.notes[n].velocity == 0 {
                    clip.notes[n].velocity = 1
                    repaired.tracks[t].clips[c] = .midi(clip)
                    repairs.append("set the velocity of note \(clip.notes[n].id) from 0 to 1 (DW-150)")
                }
                let sorted = clip.notes.sorted(by: Note.clipOrder)
                guard sorted.map(\.id) != clip.notes.map(\.id) else { continue }
                clip.notes = sorted
                repaired.tracks[t].clips[c] = .midi(clip)
                repairs.append("sorted the notes of clip \(clip.id) by start (then id)")
            }
            let clips = repaired.tracks[t].clips.sorted(by: Clip.timelineOrder)
            if clips.map(\.id) != repaired.tracks[t].clips.map(\.id) {
                repaired.tracks[t].clips = clips
                repairs.append("sorted the clips of track \(track) by start (DW-110)")
            }
        }
        guard !repairs.isEmpty else { throw .invalidProject(failure.description) }
        do {
            try repaired.validate()
        } catch {
            throw .invalidProject(error.description)
        }
        project = repaired
        return repairs
    }

    private static func decodeProject(_ data: Data) throws(DAWError) -> Project {
        do {
            return try JSONDecoder().decode(Project.self, from: data)
        } catch {
            throw .invalidProject(describe(error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "\($0)" } ?? $0.stringValue }
            return keys.isEmpty ? "the file" : keys.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context)): missing \(key.stringValue)"
        case .typeMismatch(let type, let context): return "\(path(context)): expected \(type)"
        case .valueNotFound(let type, let context): return "\(path(context)): expected \(type), got null"
        case .dataCorrupted(let context): return "\(path(context)): \(context.debugDescription)"
        @unknown default: return String(describing: error)
        }
    }
}
