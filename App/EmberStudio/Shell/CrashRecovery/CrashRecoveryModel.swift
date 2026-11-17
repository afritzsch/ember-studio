import DAWModel
import Foundation
import Observation

/// UI-043 (T-083): the crash-recovery dialog. At launch, `CrashMarkerSession.start` hands over the
/// running markers of sessions that crashed (PLUG-021). The dialog lists their projects and the
/// plugins each one hosted, and offers to open them:
///   - **Open with Plugins Disabled** (`crashRecovery.openSafe`): safe mode (DW-224), the AU/VST3
///     slots are built without their plugins for this session; the document isn't changed.
///   - **Open Normally** (`crashRecovery.openNormally`).
///   - **Don't Open** (`crashRecovery.dontOpen`).
/// MODEL-045 / DW-144: a project whose autosave is newer than its last save gets a "Recover
/// autosave" checkbox (`crashRecovery.project.<n>.recover`, on by default): the project then opens
/// from the autosave (`recover: true`). This replaces the "Unsaved changes found" toast for
/// projects opened from the dialog.
///
/// It is app-level state: `AppModel.crashRecovery`. Every window shows it while it is presented (a
/// strip under the toolbar, like the export dialog, so `ui.snapshot` captures it) and lists its
/// controls, so `ui.perform` reaches them through the main window (UI-052).
@Observable
@MainActor
final class CrashRecoveryModel {
    /// One project a crashed session had open (projects in several crashed sessions are listed once).
    struct Entry: Identifiable, Equatable {
        /// 1-based, in the dialog's order (control ids).
        let id: Int
        let name: String
        /// The project folder; nil for a project that was never saved (nothing to reopen).
        let path: String?
        let plugins: [CrashMarker.Plugin]
        /// When the session that had it open was launched (the newest such session).
        let launched: Date
        /// MODEL-045: its autosave is newer than its last save.
        let recoveryAvailable: Bool
        /// Open from the autosave (only when available).
        var recover: Bool

        var canOpen: Bool { path != nil }
        var url: URL? { path.map { URL(filePath: $0, directoryHint: .inferFromPath) } }
    }

    /// What the dialog was answered with (`ui.state`, tests).
    enum Choice: String, Codable, Sendable {
        case openSafe, openNormally, dontOpen
    }

    /// Opens one project: `AppModel.open(_:recover:safeMode:offerRecovery:into:)` in the app.
    typealias Opener = @MainActor (_ url: URL, _ recover: Bool, _ safeMode: Bool) async throws -> Void

    private(set) var entries: [Entry]
    /// The markers the dialog was made from, oldest first.
    let sessions: [CrashMarker]
    private(set) var isPresented = true
    private(set) var choice: Choice?
    /// While the chosen projects open.
    private(set) var isOpening = false
    /// Projects that didn't open, with why.
    private(set) var failures: [(name: String, error: String)] = []

    @ObservationIgnored var opener: Opener?
    /// Called once the dialog is answered and every chosen project has been opened (or failed).
    @ObservationIgnored var onFinish: (@MainActor (CrashRecoveryModel) -> Void)?

    /// `hasNewerAutosave` is `ProjectStore.hasNewerAutosave(at:)`, injectable for tests.
    init(sessions: [CrashMarker], hasNewerAutosave: (URL) -> Bool = { ProjectStore.hasNewerAutosave(at: $0) }) {
        self.sessions = sessions
        var order: [String] = []
        var byKey: [String: (name: String, path: String?, plugins: [CrashMarker.Plugin], launched: Date)] = [:]
        for session in sessions {
            for (index, project) in session.projects.enumerated() {
                // An unsaved project has no identity across sessions: each is its own entry.
                let key = project.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                    ?? "unsaved-\(session.processID)-\(index)"
                if var known = byKey[key] {
                    for plugin in project.plugins where !known.plugins.contains(plugin) { known.plugins.append(plugin) }
                    known.launched = max(known.launched, session.launched)
                    known.name = project.name
                    byKey[key] = known
                } else {
                    order.append(key)
                    byKey[key] = (project.name, project.path, project.plugins, session.launched)
                }
            }
        }
        entries = order.enumerated().compactMap { offset, key in
            guard let e = byKey[key] else { return nil }
            let available = e.path.map { hasNewerAutosave(URL(filePath: $0, directoryHint: .inferFromPath)) } ?? false
            return Entry(id: offset + 1, name: e.name, path: e.path, plugins: e.plugins, launched: e.launched,
                         recoveryAvailable: available, recover: available)
        }
    }

    /// Projects the open buttons act on.
    var openable: [Entry] { entries.filter(\.canOpen) }

    var title: String {
        sessions.count == 1 ? "Ember Studio quit unexpectedly" : "Ember Studio quit unexpectedly \(sessions.count) times"
    }

    var message: String {
        let plugins = Set(entries.flatMap { $0.plugins.map(\.name) }).count
        let hint = plugins > 0
            ? " A plugin may have caused it. Open the projects with their plugins disabled to be safe: their settings are kept."
            : ""
        let n = openable.count
        return (n == 1 ? "1 project was open." : "\(n) projects were open.") + hint
    }

    // MARK: Answers

    func setRecover(_ id: Int, _ on: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].recoveryAvailable else { return }
        entries[i].recover = on
    }

    /// Answers the dialog. The open choices open every openable project in turn (the first one
    /// that fails doesn't stop the others).
    func answer(_ choice: Choice) async {
        guard isPresented, !isOpening else { return }
        self.choice = choice
        if choice != .dontOpen, let opener {
            isOpening = true
            for entry in openable {
                guard let url = entry.url else { continue }
                do {
                    try await opener(url, entry.recover && entry.recoveryAvailable, choice == .openSafe)
                } catch {
                    failures.append((entry.name, (error as? DAWError)?.description ?? "\(error)"))
                }
            }
            isOpening = false
        }
        isPresented = false
        onFinish?(self)
    }

    // MARK: Controls (UI-052)

    /// While presented: the three answers, and a recover toggle per project with a newer autosave.
    var controls: [UIControl] {
        guard isPresented else { return [] }
        let enabled = !isOpening
        var controls: [UIControl] = [
            .button("crashRecovery.openSafe", "Open with Plugins Disabled", enabled: enabled && !openable.isEmpty) { [weak self] in
                self?.answerLater(.openSafe)
            },
            .button("crashRecovery.openNormally", "Open Normally", enabled: enabled && !openable.isEmpty) { [weak self] in
                self?.answerLater(.openNormally)
            },
            .button("crashRecovery.dontOpen", "Don't Open", enabled: enabled) { [weak self] in
                self?.answerLater(.dontOpen)
            },
        ]
        for entry in entries where entry.recoveryAvailable && entry.canOpen {
            controls.append(.toggle("crashRecovery.project.\(entry.id).recover", "Recover autosave of \(entry.name)",
                                    isOn: entry.recover, enabled: enabled) { [weak self] in
                self?.setRecover(entry.id, !entry.recover)
            })
        }
        return controls
    }

    /// The task the last button press started (tests and `ui.perform` callers wait on it).
    @ObservationIgnored private(set) var pending: Task<Void, Never>?

    private func answerLater(_ choice: Choice) {
        pending = Task { @MainActor [weak self] in await self?.answer(choice) }
    }
}
