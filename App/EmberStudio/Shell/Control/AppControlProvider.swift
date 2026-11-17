import DAWControl
import DAWModel
import Foundation

/// The attach-only methods (CTL-005) for the running app: `ui.state` (UI-050), `ui.snapshot`
/// (UI-051) and `ui.perform` (UI-052), against the main window.
@MainActor
final class AppControlProvider: ControlUIProvider {
    weak var app: AppModel?
    private var snapshots = 0

    func uiState() async throws -> JSONValue {
        guard let app else { throw ControlError.internalError("the app is gone") }
        return UIStateDumper.dump(app)
    }

    /// Writes the main window as PNG to `path` (relative paths resolve against the app's working
    /// directory; default `$TMPDIR/emberstudio-<pid>-snapshot-<n>.png`).
    func uiSnapshot(_ params: UISnapshotParams) async throws -> JSONValue {
        let window = try mainWindow()
        guard let presenter = app?.presenter else {
            throw DAWError.notImplemented("ui.snapshot needs the app's windows")
        }
        let png: Data, width: Int, height: Int
        if let slot = params.pluginEditor {
            // PLUG-017 (T-063): the slot's plugin editor panel.
            guard let panel = window.pluginEditors.panels?.panel(for: slot) else {
                throw DAWError.invalidArgument("no plugin editor is open for slot \(slot)")
            }
            (png, width, height) = try WindowSnapshotter.png(of: panel)
        } else {
            (png, width, height) = try presenter.snapshot(window)
        }
        snapshots += 1
        let url: URL
        if let path = params.path {
            let expanded = (path as NSString).expandingTildeInPath
            url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: expanded)
        } else {
            url = FileManager.default.temporaryDirectory.appending(
                path: "emberstudio-\(ProcessInfo.processInfo.processIdentifier)-snapshot-\(snapshots).png")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            throw DAWError.fileIO(path: url.path, detail: error.localizedDescription)
        }
        var result: [String: JSONValue] = [
            "pngPath": .string(url.standardizedFileURL.path), "width": .int(Int64(width)), "height": .int(Int64(height)),
            "window": .int(Int64(window.id)),
        ]
        if let slot = params.pluginEditor { result["pluginEditor"] = .int(Int64(bitPattern: slot)) }  // T-063
        return .object(result)
    }

    /// Clicks or toggles the control with `accessibilityId` in the main window. Actions: `click`
    /// (alias `press`) for buttons and toggles, `toggle`, `on` and `off` for toggles.
    func uiPerform(_ params: UIPerformParams) async throws -> JSONValue {
        let window = try mainWindow()
        if params.action == "swipe" { return try swipe(params, in: window) }  // UI-016 (T-081)
        guard let action = UIAction(rawValue: params.action) else {
            throw ControlError.invalidParams("action must be one of \(UIAction.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let control = window.controls.first(where: { $0.id == params.accessibilityId }) else {
            let ids = window.controls.map(\.id).joined(separator: ", ")
            throw ControlError.invalidParams("no control \"\(params.accessibilityId)\" in the main window; there are: \(ids)")
        }
        guard control.isEnabled else {
            throw DAWError.invalidArgument("\(control.id) (\(control.label)) is disabled")
        }
        switch (control.kind, action) {
        case (.button, .click), (.button, .press), (.toggle, .click), (.toggle, .press), (.toggle, .toggle):
            control.action()
        case (.toggle, .on):
            if control.isOn != true { control.action() }
        case (.toggle, .off):
            if control.isOn != false { control.action() }
        case (.button, _):
            throw ControlError.invalidParams("\(control.id) is a button; use click")
        }
        var result: [String: JSONValue] = [
            "accessibilityId": .string(control.id), "kind": .string(control.kind.rawValue), "action": .string(action.rawValue),
        ]
        // The state after the action, read back from the view model.
        if let after = app?.mainWindow?.controls.first(where: { $0.id == control.id }), let isOn = after.isOn {
            result["isOn"] = .bool(isOn)
        }
        return .object(result)
    }

    /// UI-016 (T-081): `ui.perform {accessibilityId: "takeFolder.<folder>.take.<take>.swipe",
    /// action: "swipe", start, end}`: the swipe gesture on a take row, as ticks. Returns
    /// `{accessibilityId, kind: "takeRow", action, start, end, comp: [{start, end, take}]}`.
    private func swipe(_ params: UIPerformParams, in window: ProjectWindowModel) throws -> JSONValue {
        guard let start = params.start, let end = params.end else {
            throw ControlError.invalidParams("swipe needs start and end (ticks)")
        }
        guard let (folderID, _) = TakeFoldersModel.swipeTarget(params.accessibilityId) else {
            throw ControlError.invalidParams("swipe works on take rows: takeFolder.<folder>.take.<take>.swipe, not \"\(params.accessibilityId)\"")
        }
        try window.takes.performSwipe(params.accessibilityId, start: Tick(start), end: Tick(end))
        let comp = window.project.takeFolder(folderID)?.comp ?? []
        return [
            "accessibilityId": .string(params.accessibilityId), "kind": "takeRow", "action": "swipe",
            "start": .int(start), "end": .int(end),
            "comp": .array(comp.map { ["start": .int($0.start.raw), "end": .int($0.end.raw), "take": .int(Int64(bitPattern: $0.take))] }),
        ]
    }

    private func mainWindow() throws -> ProjectWindowModel {
        guard let window = app?.mainWindow else { throw ControlError.noProject }
        return window
    }
}
