/// MODEL-001: the only way to change a `Project`. The UI and the control protocol (13) use the
/// same commands (D-11).
///
/// - `type` is the stable wire name (MODEL-006). Never rename it; a renamed command needs a
///   migration (MODEL-042). The JSON form is the command's own fields plus `"type"`, so a command
///   must not have a field called `type`. Register every command type in `CommandRegistry`.
/// - `apply` returns the inverse: the command that undoes it, computed from the project as it was
///   before. Applying the inverse returns a command that redoes it, which is how `UndoStack` redoes.
/// - `apply` may leave `project` half-changed when it throws. `UndoStack` and `CompositeCommand`
///   apply to a copy and keep it only on success, so a command can validate as it goes.
public protocol Command: Codable, Sendable {
    static var type: String { get }
    /// Shown in the undo menu ("Undo Rename Track").
    var label: String { get }
    func apply(to project: inout Project) throws(DAWError) -> any Command
}

extension Command {
    /// Applies to a copy and writes it back only on success, so a throwing command leaves
    /// `project` untouched.
    func applyAtomically(to project: inout Project) throws(DAWError) -> any Command {
        var working = project
        let inverse = try apply(to: &working)
        project = working
        return inverse
    }
}
