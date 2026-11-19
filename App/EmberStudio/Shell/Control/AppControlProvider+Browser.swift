import DAWControl
import DAWModel
import Foundation

/// UI-067 (T-124, 13 "Contract delta (T-124)"): `ui.perform` on the browser's controls
/// (`browser.*`, `BrowserModel.controls`). Each call waits until the browser has settled (the
/// search or scan it started has finished, the folders it shows are read; at most 10 s), so the
/// next `ui.state` shows the result.
///   - Buttons and toggles: `click`/`press`, `toggle`/`on`/`off`, as for every control. Row
///     controls work on every row of the list, not only the 200 `ui.state` lists.
///   - `browser.search`: `setText` with `text` searches (empty clears).
///   - `browser.places.add` / `browser.place.<id>.locate`: `click` with `text` (a folder path)
///     adds or relocates the place without the open panel; without `text` the panel opens.
///   - `browser.item.<id>.load`: `click` loads as a double-click does and returns what it did.
///   - `browser.item.<id>` with `action: "drop"`, `tick` and optional `track` (absent: the empty
///     area, a new track): the drop of UI-063, tick snapped like a drop. A refused load is
///     `invalidArgument` (the window also toasts it).
extension AppControlProvider {
    func browserPerform(_ params: UIPerformParams, in window: ProjectWindowModel) async throws -> JSONValue {
        let browser = window.browser
        let id = params.accessibilityId
        if params.action == "drop" { return try await browserDrop(params, browser: browser, window: window) }
        guard let action = UIAction(rawValue: params.action) else {
            throw ControlError.invalidParams("action must be one of \((UIAction.allCases.map(\.rawValue) + ["drop"]).joined(separator: ", "))")
        }
        let controls = browser.controls + browser.rowControls(browser.rows.dropFirst(BrowserModel.controlRowLimit))
        guard let control = controls.first(where: { $0.id == id }) else {
            throw ControlError.invalidParams("no browser control \"\(id)\"; there are: \(controls.map(\.id).joined(separator: ", "))")
        }
        guard control.isEnabled else { throw DAWError.invalidArgument("\(control.id) (\(control.label)) is disabled") }
        var result: [String: JSONValue] = [
            "accessibilityId": .string(id), "kind": .string(control.kind.rawValue), "action": .string(action.rawValue),
        ]
        switch (control.kind, action) {
        case (.textField, .setText):
            guard let text = params.text else { throw ControlError.invalidParams("setText needs text") }
            browser.setQuery(text)
        case (.textField, _):
            throw ControlError.invalidParams("\(id) is a text field; use setText with text")
        case (_, .setText):
            throw ControlError.invalidParams("\(id) is a \(control.kind.rawValue), not a text field; setText works on text fields")
        case (.button, .click), (.button, .press):
            if let text = params.text, id == "browser.places.add" {
                guard browser.addPlace(Self.folderURL(text)) else { throw DAWError.invalidArgument("can't add \(text) as a place") }
            } else if let text = params.text, id.hasPrefix("browser.place."), id.hasSuffix(".locate") {
                let placeID = String(id.dropFirst("browser.place.".count).dropLast(".locate".count))
                guard browser.relocatePlace(placeID, to: Self.folderURL(text)) else {
                    throw DAWError.invalidArgument("can't locate the place at \(text)")
                }
            } else if id.hasSuffix(".load"), id.hasPrefix("browser.item.") {
                let itemID = String(id.dropFirst("browser.item.".count).dropLast(".load".count))
                guard let row = browser.row(itemID) else { throw ControlError.invalidParams("no browser item \(itemID)") }
                browser.select(itemID)
                do {
                    result["load"] = Self.json(try await browser.loadAtPlayhead(row.item))
                } catch {
                    throw DAWError.invalidArgument(error.description)
                }
            } else {
                control.action()
            }
        case (.button, _):
            throw ControlError.invalidParams("\(id) is a button; use click")
        case (.toggle, .on):
            if control.isOn != true { control.action() }
        case (.toggle, .off):
            if control.isOn != false { control.action() }
        case (.toggle, _):
            control.action()
        }
        await browser.settle()
        let after = browser.controls.first { $0.id == id } ?? browser.rowControls(browser.rows).first { $0.id == id }
        if let isOn = after?.isOn { result["isOn"] = .bool(isOn) }
        if control.kind == .textField {
            result["text"] = .string(browser.query)
            result["results"] = .int(Int64(browser.rows.count))
            result["moreResults"] = .bool(browser.scanTruncated)
        }
        return .object(result)
    }

    /// UI-063: `{accessibilityId: "browser.item.<id>", action: "drop", tick, track?}`.
    private func browserDrop(_ params: UIPerformParams, browser: BrowserModel, window: ProjectWindowModel) async throws -> JSONValue {
        let prefix = "browser.item."
        let id = params.accessibilityId
        guard id.hasPrefix(prefix), !id.dropFirst(prefix.count).contains(".") else {
            throw ControlError.invalidParams("drop works on browser items (browser.item.<id>), not \"\(id)\"")
        }
        guard let tick = params.tick else { throw ControlError.invalidParams("drop needs tick") }
        let itemID = String(id.dropFirst(prefix.count))
        guard let row = browser.row(itemID) else { throw ControlError.invalidParams("no browser item \(itemID) in the list") }
        let target: BrowserDropTarget = params.track.map { .track($0) } ?? .newTrack
        let snapped = BrowserModel.snappedDropTick(Tick(tick), in: window.arrange)
        do {
            let loaded = try await browser.load([row.item.url], onto: target, at: snapped)
            guard case .object(var json) = Self.json(loaded) else { return .null }
            json["accessibilityId"] = .string(id)
            json["kind"] = "browserItem"
            json["action"] = "drop"
            return .object(json)
        } catch {
            throw DAWError.invalidArgument(error.description)
        }
    }

    private static func json(_ result: BrowserLoadResult) -> JSONValue {
        let ids = { (ids: [ModelID]) in JSONValue.array(ids.map { .int(Int64(bitPattern: $0)) }) }
        return [
            "track": .int(Int64(bitPattern: result.track)), "newTrack": .bool(result.newTrack), "tick": .int(result.tick.raw),
            "clips": ids(result.clips), "assets": ids(result.assets), "imported": ids(result.imported),
        ]
    }

    /// A folder path from `ui.perform`: `~` expanded, relative to the app's working directory.
    private static func folderURL(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: expanded, directoryHint: .isDirectory)
    }
}
