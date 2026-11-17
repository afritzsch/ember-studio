import DAWModel
import Foundation

/// UI-043, PLUG-021 (T-083): where the app keeps its `running` marker and whether the crash
/// dialog may show at launch.
///
///     --crash-marker-dir <path>   keep the running markers in <path> instead of the default, and
///                                 show the crash dialog for markers found there, also in an
///                                 automated launch. Tests and agents use it to inject crashed
///                                 sessions: write a `running-<pid>.json` (`CrashMarker`) with the
///                                 pid of a process that is gone, then launch.
///
/// Without it, a user's launch uses `~/Library/Application Support/Ember Studio` and shows the
/// dialog; an automated launch (`AppOptions.isAutomated`) keeps its marker in
/// `$TMPDIR/EmberStudio-Sessions` (T-064, CONV §9) and doesn't show the dialog: the markers other
/// automated sessions left there (killed test apps) aren't the user's crashes, and nobody is
/// there to answer. They are still handed over (removed) as before.
struct CrashRecoveryLaunch: Equatable {
    static let argument = "--crash-marker-dir"

    /// The directory given with `--crash-marker-dir`, if any.
    var markerDirectory: URL?
    var isAutomated: Bool

    init(arguments: [String], isAutomated: Bool) {
        var rest = arguments.dropFirst()
        var directory: URL?
        while let argument = rest.popFirst() {
            if argument == Self.argument, let path = rest.popFirst() {
                directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
        markerDirectory = directory
        self.isAutomated = isAutomated
    }

    /// Where `CrashMarkerSession.start` reads and writes markers.
    var directory: URL {
        if let markerDirectory { return markerDirectory }
        return isAutomated
            ? FileManager.default.temporaryDirectory.appendingPathComponent("EmberStudio-Sessions", isDirectory: true)
            : CrashMarker.defaultDirectory
    }

    /// Whether crashed sessions found at launch get the dialog.
    var showsDialog: Bool { !isAutomated || markerDirectory != nil }
}
