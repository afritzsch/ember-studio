import AppKit
import DAWControl
import DAWModel
import Foundation
import SwiftUI
import Testing

@testable import EmberStudioShell

// UI-050 (UIStateDumper), UI-051 (WindowSnapshotter), UI-052 (ui.perform on control descriptors),
// through the app's attach-mode Dispatcher as `ui.*` requests arrive over the socket (CTL-002).

@MainActor
@Suite("Attach-mode UI methods (UI-050, UI-051, UI-052)", .serialized)
struct AttachUITests {
    @Test("UI-050: ui.state serializes windows, project, panes, selection, zoom, scroll, visible tracks, transport, toasts and controls")
    func uiState() async throws {
        let t = TestApp()
        let window = t.app.newProject()
        window.perform(AddTrack(name: "Gtr", kind: .audio))
        let track = window.project.tracks[0].id
        window.selectedTracks = [track]
        window.zoom(by: 2)
        window.toasts.post(.overload, .warning, title: "Audio dropout", count: 3)
        let state = try await t.app.dispatcher.call(.uiState)
        #expect(state["mainWindow"] == .int(Int64(window.id)))
        let w = try #require(state["windows"]?[0])
        #expect(w["isMain"] == true && w["title"] == "Untitled — Edited")
        #expect(w["project"]?["name"] == "Untitled" && w["project"]?["dirty"] == true && w["project"]?["path"] == .null)
        #expect(w["panes"] == ["browser": true, "inspector": true, "bottom": "mixer"])
        #expect(w["selection"] == ["tracks": [.int(Int64(track))], "clips": []])
        #expect(w["zoom"]?["pixelsPerBeat"] == 64)
        #expect(w["scroll"]?["y"] == 0 && w["visibleTracks"] == [.int(Int64(track))])
        #expect(w["tracks"]?[0] == ["id": .int(Int64(track)), "name": "Gtr", "kind": "audio", "mute": false, "solo": false,
                                    "selected": true])
        #expect(w["transport"]?["playing"] == false)
        #expect(w["toasts"]?[0]?["kind"] == "overload" && w["toasts"]?[0]?["count"] == 3)
        let mute = w["controls"]?.arrayValue?.first { $0["id"] == .string("track.\(track).mute") }
        #expect(mute == ["id": .string("track.\(track).mute"), "kind": "toggle", "label": "Mute Gtr", "enabled": true, "isOn": false])
    }

    @Test("UI-052: ui.perform clicks buttons and sets toggles by accessibility id; unknown ids, bad actions and disabled controls fail")
    func uiPerform() async throws {
        let t = TestApp()
        let window = t.app.newProject()
        window.perform(AddTrack(name: "Gtr", kind: .audio))
        let id = "track.\(window.project.tracks[0].id).mute"
        let d = t.app.dispatcher
        #expect(try await d.call(.uiPerform, ["accessibilityId": .string(id), "action": "toggle"])["isOn"] == true)
        #expect(window.project.tracks[0].strip.mute)
        #expect(try await d.call(.uiPerform, ["accessibilityId": .string(id), "action": "on"])["isOn"] == true, "already on")
        #expect(try await d.call(.uiPerform, ["accessibilityId": .string(id), "action": "off"])["isOn"] == false)
        #expect(window.store.undoLabel == "Set Mute")
        _ = try await d.call(.uiPerform, ["accessibilityId": "edit.undo", "action": "click"])
        #expect(window.project.tracks[0].strip.mute, "undid the off")
        _ = try await d.call(.uiPerform, ["accessibilityId": "transport.play", "action": "press"])
        #expect(window.transport.playing)

        func failure(_ params: JSONValue) async -> RPCError? {
            do {
                _ = try await d.call(.uiPerform, params)
                return nil
            } catch {
                return error.rpcError
            }
        }
        let unknown = await failure(["accessibilityId": "nope", "action": "click"])
        #expect(unknown?.code == -32602 && unknown?.message.contains("transport.play") == true, "lists what there is")
        #expect(await failure(["accessibilityId": .string(id), "action": "wiggle"])?.code == -32602)
        #expect(await failure(["accessibilityId": "zoom.in", "action": "on"])?.code == -32602, "buttons only click")
        #expect(await failure(["accessibilityId": "transport.play", "action": "click"])?.dawError == "invalidArgument", "disabled")
    }

    @Test("UI-051: ui.snapshot renders the main window to PNG with cacheDisplay; daw_ui_snapshot gets the path")
    func uiSnapshot() async throws {
        let dir = try TempDir()
        let t = TestApp(workingDirectory: dir.url)
        let manager = realWindowManager(for: t.app)
        let window = t.app.newProject()
        defer { manager.close(window) }
        window.perform(AddTrack(name: "Snap", kind: .audio))
        let result = try await t.app.dispatcher.call(.uiSnapshot, ["path": .string(dir.file("shots/w.png").path)])
        let path = try #require(result["pngPath"]?.stringValue)
        #expect(path == dir.file("shots/w.png").standardizedFileURL.path)
        let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(result["width"] == .int(Int64(image.pixelsWide)) && image.pixelsWide >= 760 && image.pixelsHigh >= 480)
        // Something is drawn: not one flat colour.
        var colours = Set<String>()
        for x in stride(from: 0, to: image.pixelsWide, by: 37) {
            for y in stride(from: 0, to: image.pixelsHigh, by: 41) {
                if let c = image.colorAt(x: x, y: y) { colours.insert("\(Int(c.redComponent * 255)),\(Int(c.greenComponent * 255))") }
            }
        }
        #expect(colours.count > 3, "\(colours)")
        // The default path, in $TMPDIR.
        let auto = try await t.app.dispatcher.call(.uiSnapshot)
        #expect(auto["pngPath"]?.stringValue.map { FileManager.default.fileExists(atPath: $0) } == true)
        try? FileManager.default.removeItem(atPath: auto["pngPath"]?.stringValue ?? "")
    }

    @Test("UI-051: without windows (no presenter), ui.snapshot says so instead of crashing; without a window, noProject")
    func snapshotWithoutWindows() async throws {
        let t = TestApp()
        do {
            _ = try await t.app.dispatcher.call(.uiSnapshot)
            Issue.record("snapshot without a window")
        } catch {
            #expect(error.name == "noProject")
        }
        _ = t.app.newProject()
        do {
            _ = try await t.app.dispatcher.call(.uiSnapshot)
        } catch {
            #expect(error.name == "notImplemented")
        }
    }
}

@Suite("Shell sources (UI-052)")
struct ShellSourceTests {
    /// App/EmberStudio/Shell/Views, found from this file.
    static let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../EmberStudio/Shell/Views").standardizedFileURL

    @Test("UI-052: views make buttons and toggles only through ControlButton/ControlToggle (which set the accessibility id)")
    func noRawControls() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 2)
        for file in files where file.lastPathComponent != "ControlViews.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                #expect(code.firstMatch(of: /(^|[^A-Za-z])(Button|Toggle|Slider|Picker|Stepper|TextField)\s*\(/) == nil,
                        "\(file.lastPathComponent):\(n + 1): \(line)")
            }
        }
        let controls = try String(contentsOf: Self.views.appending(path: "ControlViews.swift"), encoding: .utf8)
        #expect(controls.components(separatedBy: ".accessibilityIdentifier(control.id)").count == 3)
    }
}
