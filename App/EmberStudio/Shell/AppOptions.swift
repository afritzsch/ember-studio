import DAWControl
import Foundation

/// The app's command line (CTL-030, CTL-023):
///
///     --control-socket <path>   serve the control protocol at <path> (attach mode)
///     --engine fake|coreAudio|offline
///     --parent-pid <pid>        quit when that process exits (the launcher's dawmcp or dawctl)
///
/// Without `--control-socket`, Debug builds still serve, at `$TMPDIR/emberstudio-<pid>.sock`
/// (CTL-032); Release builds don't. Arguments AppKit understands (`-NSDocumentRevisionsDebugMode
/// YES`, `-ApplePersistenceIgnoreState YES`) and unknown ones are left alone.
struct AppOptions: Equatable {
    var controlSocket: String?
    var engine: EngineChoice
    var parentPID: Int32?
    /// Launched by a tool (`--control-socket` or `--parent-pid` given): nobody sits in front of it,
    /// so quitting never waits on a "save changes?" question.
    var isAutomated: Bool

    init(arguments: [String], isDebug: Bool = AppOptions.isDebugBuild,
         pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        var socket: String?
        var engine = EngineChoice.coreAudio
        var parent: Int32?
        var rest = arguments.dropFirst()
        while let argument = rest.popFirst() {
            switch argument {
            case "--control-socket":
                socket = rest.popFirst()
            case "--engine":
                if let value = rest.popFirst(), let choice = EngineChoice(rawValue: value) { engine = choice }
            case "--parent-pid":
                parent = rest.popFirst().flatMap(Int32.init)
            default:
                continue
            }
        }
        isAutomated = socket != nil || parent != nil
        controlSocket = socket ?? (isDebug ? ControlSocketPath.forProcess(pid) : nil)
        self.engine = engine
        parentPID = parent
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
