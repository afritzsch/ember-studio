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
        #expect(w["zoom"]?["pixelsPerBeat"]?.doubleValue == 64)
        #expect(w["scroll"]?["y"]?.doubleValue == 0 && w["visibleTracks"] == [.int(Int64(track))])
        // T-054 (REC-021): monitoringLatency depends on the device; RecordingUITests checks its value.
        var track0 = try #require(w["tracks"]?[0]?.objectValue)
        #expect(track0.removeValue(forKey: "monitoringLatency")?["samples"]?.int64Value != nil)
        #expect(JSONValue.object(track0) == ["id": .int(Int64(track)), "name": "Gtr", "kind": "audio", "mute": false, "solo": false,
                                             "selected": true, "armed": false, "inputPair": 0, "monitoring": "auto"])
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

    @Test("UI-030, UI-052 (T-076): ui.state reports the mixer's strips, values, meters and control ids; ui.perform drives its faders, pans and routing")
    func mixer() async throws {
        let t = TestApp()
        let window = t.app.newProject()
        window.perform(AddTrack(name: "Gtr", kind: .audio))
        window.perform(AddBus(name: "Verb"))
        let track = window.project.tracks[0].id
        let bus = window.project.buses[0].id
        window.perform(AddSend(channelID: track, busID: bus))
        window.mixer.meters.readMeter = { id in id == track ? MeterReading(peak: 0.5, rms: 0.25) : nil }
        let d = t.app.dispatcher
        var state = try await d.call(.uiState)
        var mixer = try #require(state["windows"]?[0]?["mixer"])
        #expect(mixer["open"] == true && mixer["gesture"] == .null)
        var strip = try #require(mixer["strips"]?[0])
        #expect(strip["kind"] == "audio" && strip["name"] == "Gtr" && strip["controlPrefix"] == .string("mixer.track.\(track)"))
        #expect(strip["gain"]?.doubleValue == 1 && strip["gainDB"]?.doubleValue == 0 && strip["faderPosition"]?.doubleValue == 0.75)
        #expect(strip["pan"]?.doubleValue == 0 && strip["panLabel"] == "C" && strip["armed"] == false)
        #expect(strip["output"] == ["kind": "master", "name": "Master"])
        #expect(strip["sends"]?[0]?["targetName"] == "Verb" && strip["sends"]?[0]?["tap"] == "postFader")
        #expect(strip["meter"]?["peak"]?.doubleValue == 0.5 && strip["meter"]?["clipped"] == false)
        let ids = strip["controls"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(ids.contains("track.\(track).mute") && ids.contains("mixer.track.\(track).fader.up") && ids.contains("track.\(track).arm"))
        #expect(mixer["strips"]?.arrayValue?.count == 3)
        let master = try #require(mixer["strips"]?[2])
        #expect(master["kind"] == "master" && master["output"] == .null && master["meter"] == .null)
        // Nudge, reset, pan and route through ui.perform.
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("mixer.track.\(track).fader.down"), "action": "click"])
        state = try await d.call(.uiState)
        mixer = try #require(state["windows"]?[0]?["mixer"])
        strip = try #require(mixer["strips"]?[0])
        #expect((strip["gainDB"]?.doubleValue).map { abs($0 + 1) < 1e-4 } == true)
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("mixer.track.\(track).fader.reset"), "action": "press"])
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("mixer.track.\(track).pan.left"), "action": "click"])
        #expect(window.project.tracks[0].strip.gain == 1 && window.project.tracks[0].strip.pan == -0.05)
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("mixer.track.\(track).output.bus.\(bus)"), "action": "on"])
        #expect(window.project.tracks[0].output == .bus(bus))
        // A cycle: the toast names it, the project doesn't change.
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("mixer.bus.\(bus).output.bus.\(bus)"), "action": "on"])
        state = try await d.call(.uiState)
        #expect(state["windows"]?[0]?["toasts"]?[0]?["message"]?.stringValue?.contains("routing cycle") == true)
        #expect(window.project.buses[0].output == .master)
        // The tab closed: its controls leave the list, its strips stay readable.
        window.bottomPane = nil
        state = try await d.call(.uiState)
        mixer = try #require(state["windows"]?[0]?["mixer"])
        #expect(mixer["open"] == false && mixer["strips"]?.arrayValue?.count == 3)
        #expect(state["windows"]?[0]?["controls"]?.arrayValue?.contains { $0["id"] == .string("mixer.track.\(track).fader.up") } == false)
    }

    @Test("UI-030, UI-051: ui.snapshot renders a mixer with strips (real window); the meter layers are captured")
    func mixerSnapshot() async throws {
        let dir = try TempDir()
        let t = TestApp(workingDirectory: dir.url)
        let manager = realWindowManager(for: t.app)
        let window = t.app.newProject()
        defer { manager.close(window) }
        window.perform(AddTrack(name: "Lead", kind: .audio))
        window.perform(AddTrack(name: "Keys", kind: .midi))
        window.perform(AddBus(name: "Verb"))
        window.perform(AddSend(channelID: window.project.tracks[0].id, busID: window.project.buses[0].id))
        let content = try #require(manager.nsWindow(for: window)?.contentView)
        content.layoutSubtreeIfNeeded()
        let meters = window.mixer.meters
        meters.readMeter = { _ in MeterReading(peak: 0.9, rms: 0.5) }
        meters.displayFrame()
        let result = try await t.app.dispatcher.call(.uiSnapshot, ["path": .string(dir.file("mixer.png").path)])
        let path = try #require(result["pngPath"]?.stringValue)
        let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(image.pixelsWide >= 760)
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
