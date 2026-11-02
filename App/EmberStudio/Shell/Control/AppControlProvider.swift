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
        let (png, width, height) = try presenter.snapshot(window)
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
        return ["pngPath": .string(url.standardizedFileURL.path), "width": .int(Int64(width)), "height": .int(Int64(height)),
                "window": .int(Int64(window.id))]
    }

    /// Clicks or toggles the control with `accessibilityId` in the main window. Actions: `click`
    /// (alias `press`) for buttons and toggles, `toggle`, `on` and `off` for toggles.
    func uiPerform(_ params: UIPerformParams) async throws -> JSONValue {
        let window = try mainWindow()
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

    private func mainWindow() throws -> ProjectWindowModel {
        guard let window = app?.mainWindow else { throw ControlError.noProject }
        return window
    }
}
