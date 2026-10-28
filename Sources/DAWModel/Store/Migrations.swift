/// MODEL-042: brings an older `project.json` forward, one format version at a time, before it is
/// decoded. A step is keyed by the version it upgrades *from* (`steps[1]` turns v1 into v2) and
/// only reshapes the JSON; `migrate` stamps the new `formatVersion` after each step.
///
/// To change the file shape: bump `Project.currentFormatVersion`, add the step for the old
/// version here, and add a fixture of the old shape with a test that opens it.
public enum Migrations {
    public typealias Step = @Sendable (inout JSON) throws -> Void

    /// Every step this build knows. Format 1 is the first, so there are none yet.
    public static let steps: [Int: Step] = [:]

    /// The file's `formatVersion`.
    public static func formatVersion(of json: JSON) throws(DAWError) -> Int {
        guard let version = json["formatVersion"]?.intValue else {
            throw .invalidProject("formatVersion is missing or not an integer")
        }
        return Int(version)
    }

    /// Applies the steps from the file's version up to `target`, in order. Returns the version
    /// the file had. A file newer than `target`, or a version without a step, is rejected.
    @discardableResult
    public static func migrate(
        _ json: inout JSON, to target: Int = Project.currentFormatVersion, steps: [Int: Step] = Migrations.steps
    ) throws(DAWError) -> Int {
        let original = try formatVersion(of: json)
        guard original >= 1 else { throw .invalidProject("formatVersion \(original) is not a version") }
        guard original <= target else {
            throw .invalidProject("formatVersion \(original) is newer than this build reads (\(target))")
        }
        for version in original..<target {
            guard let step = steps[version] else {
                throw .invalidProject("no migration from formatVersion \(version) to \(version + 1)")
            }
            do {
                try step(&json)
            } catch {
                throw .invalidProject("migration from formatVersion \(version) to \(version + 1) failed: \(error)")
            }
            json["formatVersion"] = .int(Int64(version + 1))
        }
        return original
    }
}
