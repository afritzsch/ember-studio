import AppKit
import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-032 (device chain view), DW-196 (steps in the generic UI), DW-250 (editable mixer inserts),
// DW-254 (device controls feed the automation recorder), DW-264 (generic UI for a plugin without an
// editor), DW-226 (safe mode shows plugins as bypassed): T-065.

/// The engine's built-in ParamInfo as the shell sees it (`ParamCatalog.builtin`; FakeEngine
/// publishes none).
@MainActor
private func registerBuiltinCatalog() throws {
    _ = ParamCatalog(engine: try EngineClient(.offline()))
}

/// A window (FakeEngine) with track A (EQ, Compressor, Delay), track B and bus X; the Device Chain
/// tab open on A; a plugin manager with no plugins.
@MainActor
private func chainWindow() throws -> (window: ProjectWindowModel, engine: FakeEngine, a: NodeIDValue, b: NodeIDValue,
                                      x: NodeIDValue, eq: NodeIDValue, comp: NodeIDValue, delay: NodeIDValue) {
    try registerBuiltinCatalog()
    let (window, engine) = try makeWindow(tracks: ["A", "B"])
    window.pluginPanel.manager = try emptyManager()
    window.perform(AddBus(name: "X"))
    let a = window.project.tracks[0].id
    for node in [NodeKind.eq, .compressor, .delay] { window.perform(InsertDevice(channel: a, device: .builtin(node))) }
    window.selectedTracks = [a]
    window.bottomPane = .deviceChain
    let inserts = window.project.tracks[0].inserts
    return (window, engine, a, window.project.tracks[1].id, window.project.buses[0].id, inserts[0].id, inserts[1].id, inserts[2].id)
}

/// A manager over an empty cache in a temp folder (no system plugins, no scans).
@MainActor
func emptyManager() throws -> PluginManagerModel {
    let dir = try TempDir()
    return PluginManagerModel(cacheURL: dir.file("plugins.json"), scannerURL: nil)
}

@MainActor
private func card(_ window: ProjectWindowModel, _ slot: NodeIDValue, sourceLocation: SourceLocation = #_sourceLocation) throws -> DeviceCardModel {
    try #require(window.deviceChain.devices.first { $0.id == slot }, "no card \(slot)", sourceLocation: sourceLocation)
}

@MainActor
private func param(_ window: ProjectWindowModel, _ slot: NodeIDValue, _ index: Int) throws -> DeviceParamModel {
    try #require(try card(window, slot).params.first { $0.index == index })
}

@MainActor
private func value(_ window: ProjectWindowModel, _ slot: NodeIDValue, _ index: Int) -> Float? {
    window.project.deviceSlot(slot)?.params.first { $0.index == index }?.value
}

@MainActor
private func transport(_ engine: FakeEngine, _ window: ProjectWindowModel, tick: Int64, playing: Bool) {
    if playing { engine.play() } else { engine.stop() }
    engine.setPlayhead(Tick(tick))
    window.pollTransport()
}

@MainActor
@Suite("Device chain (UI-032, DW-196, DW-250, DW-254, DW-264, DW-226; T-065)", .serialized)
struct DeviceChainTests {
    @Test("UI-032: the tab shows the selected track's devices in order with generic controls from ParamInfo; DW-196: switches are toggles, the delay's note a menu, the rest sliders")
    func cardsAndParams() throws {
        let (window, _, a, b, x, eq, comp, delay) = try chainWindow()
        let chain = window.deviceChain
        #expect(chain.isOpen && chain.channelID == a)
        #expect(chain.devices.map(\.name) == ["EQ", "Compressor", "Delay"])
        #expect(chain.devices.map(\.position) == [0, 1, 2] && chain.devices.allSatisfy { $0.showsParams && !$0.isPlugin })
        #expect(try card(window, eq).params.count == 22 && card(window, delay).params.count == 7)
        let note = try param(window, delay, 2)
        #expect(note.style == "menu" && note.display == "1/8" && note.row.labels?.count == 14)
        #expect(try param(window, delay, 1).style == "toggle" && param(window, delay, 1).display == "On")
        #expect(try param(window, delay, 0).style == "slider" && param(window, delay, 0).display == "375 ms")
        #expect(try param(window, comp, 6).style == "menu" && param(window, comp, 6).display == "Peak", "labelled switch")
        #expect(try param(window, eq, 0).style == "toggle")
        // Only the compressor (of these) takes a sidechain.
        #expect(try card(window, comp).acceptsSidechain && !(card(window, eq).acceptsSidechain))
        // Channel picker: tracks, buses, master; following the selection, or picked.
        #expect(chain.channelChoices.map(\.name) == ["A", "B", "X", "Master"])
        window.selectedTracks = [b]
        #expect(chain.channelID == b && chain.devices.isEmpty)
        try window.control("deviceChain.channel.\(x)").action()
        #expect(chain.channelID == x && window.bottomPane == .deviceChain)
        try window.control("deviceChain.channel.\(window.project.master.id)").action()
        #expect(chain.channelID == window.project.master.id)
        // Controls are listed only while the tab shows.
        window.bottomPane = .mixer
        #expect(!window.controls.contains { $0.id.hasPrefix("deviceChain.") })
    }

    @Test("UI-032, DW-196: menus, toggles and nudges set the param (one undo entry each); reset goes back to the default")
    func discreteAndNudges() throws {
        let (window, _, _, _, _, _, comp, delay) = try chainWindow()
        let prefix = "deviceChain.device.\(delay).param"
        let eighthDotted = try window.control("\(prefix).2.value.7")
        #expect(eighthDotted.kind == .toggle && eighthDotted.isOn == false && eighthDotted.label == "Note Value 1/8D")
        #expect(try window.control("\(prefix).2.value.5").isOn == true)
        eighthDotted.action()
        #expect(value(window, delay, 2) == 7 && window.store.undoLabel == "Set Parameter")
        #expect(try param(window, delay, 2).display == "1/8D")
        try window.control("\(prefix).1").action()  // sync off
        #expect(try value(window, delay, 1) == 0 && (window.control("\(prefix).1").isOn) == false)
        try window.control("deviceChain.device.\(comp).param.6.value.1").action()  // RMS
        #expect(value(window, comp, 6) == 1)
        // Nudges move a twentieth of the mapped range (log for time): one undo entry each.
        try window.control("\(prefix).6.up").action()
        #expect(value(window, delay, 6).map { abs($0 - 0.35) < 1e-5 } == true)
        try window.control("\(prefix).0.down").action()
        let time = try #require(value(window, delay, 0))
        #expect(abs(time - 247.7) < 1, "a twentieth of the log range 1…4000 ms below 375")
        #expect(try window.control("\(prefix).6.reset").isEnabled)
        try window.control("\(prefix).6.reset").action()
        #expect(value(window, delay, 6) == 0.3)
        window.store.undo()
        #expect(value(window, delay, 6).map { abs($0 - 0.35) < 1e-5 } == true)
    }

    @Test("UI-032, MODEL-003: a slider drag is one undo entry through the param's mapping (log for Hz); a press with no movement is none")
    func dragIsOneGesture() throws {
        let (window, _, _, _, _, _, _, delay) = try chainWindow()
        let chain = window.deviceChain
        let key = DeviceParamKey(slot: delay, index: 4)  // lowpass 200…20000 Hz, log
        let before = window.store.undoLabel
        chain.beginDrag(key)
        chain.endDrag()
        #expect(window.store.undoLabel == before)
        chain.beginDrag(key)
        #expect(chain.activeDrag == key)
        for i in 0...20 { chain.updateDrag(key, position: 0.2 + Double(i) * 0.015) }
        chain.endDrag()
        #expect(chain.activeDrag == nil && window.store.undoLabel == "Set Parameter")
        // position 0.5 on a log 200…20000 range is 2000 Hz.
        #expect(value(window, delay, 4).map { abs($0 - 2000) < 1 } == true)
        window.store.undo()
        #expect(value(window, delay, 4) == nil, "the whole drag was one entry")
    }

    @Test("DW-254: a device param drag while playing on a touch lane records automation (RecordAutomation at release); stopped, it edits the point under the playhead")
    func automationRecording() throws {
        let (window, engine, _, _, _, _, _, delay) = try chainWindow()
        let chain = window.deviceChain
        let target = ParamTarget.device(slot: delay, index: 6)  // mix, linear 0…1
        window.perform(AddAutomationPoints(target: target, points: [AutomationPoint(tick: 0, value: 0.3)]))
        window.perform(SetAutomationMode(target: target, mode: .touch))
        transport(engine, window, tick: 960, playing: true)
        #expect(try param(window, delay, 6).automated)
        let key = DeviceParamKey(slot: delay, index: 6)
        chain.beginDrag(key)
        chain.updateDrag(key, position: 0.8)
        #expect(window.automation.recorder?.isRecording(target) == true)
        #expect(try abs(param(window, delay, 6).value - 0.8) < 1e-5, "the control shows the gesture")
        engine.setPlayhead(1920)
        chain.updateDrag(key, position: 0.6)
        chain.endDrag()
        #expect(window.store.undoLabel == "Record Automation")
        #expect(value(window, delay, 6) == nil, "the document's own value doesn't move")
        let lane = try #require(window.project.automationLane(for: target)?.lane)
        #expect(abs(lane.value(at: 960)! - 0.8) < 1e-4 && abs(lane.value(at: 1920)! - 0.6) < 1e-4)
        // A switch click while playing on a write lane is recorded too.
        let sync = ParamTarget.device(slot: delay, index: 1)
        window.perform(SetAutomationMode(target: sync, mode: .latch))
        try window.control("deviceChain.device.\(delay).param.1").action()
        #expect(window.automation.recorder?.isRecording(sync) == true || window.project.automationLane(for: sync)?.lane.points.isEmpty == false)
        transport(engine, window, tick: 2400, playing: false)
        // Stopped on the mix lane's point at 1920: a drag moves that point's value.
        transport(engine, window, tick: 1920, playing: false)
        chain.beginDrag(key)
        chain.updateDrag(key, position: 0.25)
        chain.endDrag()
        let edited = try #require(window.project.automationLane(for: target)?.lane)
        #expect(abs(edited.value(at: 1920)! - 0.25) < 1e-4 && value(window, delay, 6) == nil)
    }

    @Test("UI-032: bypass, move (buttons and drag-and-drop), remove and add through the chain's controls; the master's chain too")
    func editChain() throws {
        let (window, _, a, _, _, eq, comp, delay) = try chainWindow()
        try window.control("deviceChain.device.\(comp).bypass").action()
        #expect(window.project.deviceSlot(comp)?.bypass == true && window.store.undoLabel == "Bypass Device")
        #expect(try card(window, comp).isBypassed && (window.control("deviceChain.device.\(comp).bypass").isOn) == true)
        #expect(try window.control("deviceChain.device.\(eq).moveUp").isEnabled == false)
        try window.control("deviceChain.device.\(eq).moveDown").action()
        #expect(window.project.track(a)?.inserts.map(\.id) == [comp, eq, delay])
        window.deviceChain.move(delay, onto: comp)  // drag-and-drop
        #expect(window.project.track(a)?.inserts.map(\.id) == [delay, comp, eq] && window.store.undoLabel == "Move Device")
        try window.control("deviceChain.device.\(eq).remove").action()
        #expect(window.project.track(a)?.inserts.map(\.id) == [delay, comp])
        try window.control("deviceChain.add.builtin.reverb").action()
        #expect(window.project.track(a)?.inserts.last.map { MixerModel.insertName($0.kind) } == "Reverb")
        window.store.undo()
        window.store.undo()
        #expect(window.project.track(a)?.inserts.map(\.id) == [delay, comp, eq])
        // The master's chain.
        let master = window.project.master.id
        try window.control("deviceChain.channel.\(master)").action()
        try window.control("deviceChain.add.builtin.eq").action()
        #expect(window.project.master.inserts.count == 1 && window.deviceChain.devices.map(\.name) == ["EQ"])
    }

    @Test("UI-032, MIX-008, MODEL-030: the sidechain picker sets the compressor's source; a source that closes a cycle is refused with a toast")
    func sidechain() throws {
        let (window, _, a, b, x, _, comp, _) = try chainWindow()
        let none = try window.control("deviceChain.device.\(comp).sidechain.none")
        #expect(none.isOn == true)
        #expect(!window.controls.contains { $0.id == "deviceChain.device.\(comp).sidechain.\(a)" }, "not its own channel")
        try window.control("deviceChain.device.\(comp).sidechain.\(b)").action()
        #expect(try window.project.deviceSlot(comp)?.sidechainSource?.source == b && (card(window, comp).sidechain?.name) == "B")
        // A → X, so X as A's sidechain would close a cycle.
        window.perform(SetTrackOutput(channelID: a, output: .bus(x)))
        try window.control("deviceChain.device.\(comp).sidechain.\(x)").action()
        #expect(window.project.deviceSlot(comp)?.sidechainSource?.source == b)
        #expect(window.toasts.toasts.last?.title == "Set Sidechain failed")
        try window.control("deviceChain.device.\(comp).sidechain.none").action()
        #expect(window.project.deviceSlot(comp)?.sidechainSource == nil)
    }

    @Test("DW-264, UI-032: a plugin shows its pluginInfoJSON params on request; one without an editor shows them by itself; drags set the slot's param, reset unsets it")
    func pluginGenericUI() throws {
        let (window, _, a, _, _, _, _, _) = try chainWindow()
        window.perform(InsertDevice(channel: a, index: 0, device: .vst3(VST3Descriptor(identifier: "/x.vst3#01", name: "Plain"))))
        let slot = window.project.track(a)!.inserts[0].id
        window.deviceChain.readPluginInfo = { id in
            id == slot ? #"{"slot":\#(id),"loaded":true,"name":"Plain","sidechain":false,"params":[{"index":0,"id":"7","name":"Gain","unit":"dB","min":0,"max":1,"value":0.25},{"index":1,"id":"8","name":"Tone","unit":"","min":0,"max":1,"value":0.5}]}"# : ""
        }
        window.pluginEditors.panels = nil
        window.pluginEditors.makeView = { _ in nil }  // no editor of its own
        var plain = try card(window, slot)
        #expect(plain.isPlugin && plain.format == "vst3" && plain.loaded == true && !plain.showsParams && !plain.acceptsSidechain)
        #expect(plain.params.map(\.row.name) == ["Gain", "Tone"] && plain.params[0].value == 0.25 && !plain.params[0].isSet)
        #expect(!window.controls.contains { $0.id == "deviceChain.device.\(slot).param.0.up" }, "generic controls hidden")
        try window.control("deviceChain.device.\(slot).editor").action()
        plain = try card(window, slot)
        #expect(plain.noEditor && plain.showsParams && !window.pluginEditors.isOpen(slot))
        #expect(window.toasts.toasts.last?.title == "No editor for Plain")
        // A drag sets param 0 of the slot (normalized VST3 value), one undo entry.
        let key = DeviceParamKey(slot: slot, index: 0)
        window.deviceChain.beginDrag(key)
        window.deviceChain.updateDrag(key, position: 0.7)
        window.deviceChain.endDrag()
        #expect(try value(window, slot, 0).map { abs($0 - 0.7) < 1e-6 } == true && (param(window, slot, 0)).isSet)
        try window.control("deviceChain.device.\(slot).param.0.reset").action()
        #expect(value(window, slot, 0) == nil, "not set: the plugin keeps its own value")
        // The generic toggle hides them again; an editor that exists opens instead.
        try window.control("deviceChain.device.\(slot).generic").action()
        #expect(try !(card(window, slot)).showsParams)
        window.pluginEditors.makeView = { _ in NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)) }
        try window.control("deviceChain.device.\(slot).editor").action()
        #expect(try window.pluginEditors.isOpen(slot) && (card(window, slot)).editorOpen)
        window.pluginEditors.closeAll()
    }

    @Test("DW-226, PLUG-021: in safe mode AU/VST3 slots show as bypassed by safe mode (toggle on, disabled) in the chain and the mixer; built-ins keep their own bypass")
    func safeMode() throws {
        let (window, _, a, _, _, eq, _, _) = try chainWindow()
        window.perform(InsertDevice(channel: a, device: .au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay"))))
        let au = window.project.track(a)!.inserts.last!.id
        window.store.isSafeMode = true
        let plugin = try card(window, au)
        #expect(plugin.safeModeBypassed && plugin.isBypassed && !plugin.bypass)
        let toggle = try window.control("deviceChain.device.\(au).bypass")
        #expect(toggle.isOn == true && !toggle.isEnabled && toggle.label == "AUDelay Bypassed by Safe Mode")
        #expect(try !(card(window, eq)).safeModeBypassed && (window.control("deviceChain.device.\(eq).bypass")).isEnabled)
        #expect(try window.control("deviceChain.device.\(au).editor").isEnabled == false, "no editors in safe mode")
        window.bottomPane = .mixer
        let insert = try #require(window.mixer.strips.first { $0.id == a }?.inserts.last)
        #expect(insert.safeModeBypassed && insert.isBypassed)
        let mixerToggle = try window.control("mixer.track.\(a).insert.\(au).bypass")
        #expect(mixerToggle.isOn == true && !mixerToggle.isEnabled)
        window.store.isSafeMode = false
        #expect(try window.control("mixer.track.\(a).insert.\(au).bypass").isOn == false)
    }

    @Test("DW-250: the mixer's inserts are editable: add from the picker (built-ins and scanned plugins; the master too), bypass, up/down, remove, show in the Device Chain tab")
    func mixerInserts() throws {
        let (window, _, a, _, _, eq, comp, delay) = try chainWindow()
        let dir = try TempDir()
        window.pluginPanel.manager = try PluginManagerModel.withPlugins([
            ScannedPlugin(format: .au, identifier: "aufx:dely:appl", name: "AUDelay", vendor: "Apple"),
            ScannedPlugin(format: .au, identifier: "aumu:samp:appl", name: "AUSampler", isInstrument: true),
            ScannedPlugin(format: .vst3, identifier: "/b.vst3#02", name: "Broken", blockedReason: "scanner crashed (SIGSEGV)"),
        ], in: dir)
        window.bottomPane = .mixer
        let prefix = "mixer.track.\(a)"
        let strip = try #require(window.mixer.strips.first { $0.id == a })
        #expect(strip.insertChoices.map(\.key) == ["builtin.eq", "builtin.compressor", "builtin.delay", "builtin.reverb", "builtin.gain", "plugin.0"])
        #expect(strip.insertChoices.last?.name == "AUDelay", "instruments and blocked plugins aren't offered")
        try window.control("\(prefix).insert.add.plugin.0").action()
        let added = try #require(window.project.track(a)?.inserts.last)
        #expect(added.kind == .au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay", vendor: "Apple")))
        try window.control("\(prefix).insert.\(comp).bypass").action()
        #expect(window.project.deviceSlot(comp)?.bypass == true)
        try window.control("\(prefix).insert.\(delay).up").action()
        #expect(window.project.track(a)?.inserts.map(\.id) == [eq, delay, comp, added.id])
        #expect(try window.control("\(prefix).insert.\(added.id).down").isEnabled == false)
        try window.control("\(prefix).insert.\(eq).remove").action()
        #expect(window.project.track(a)?.inserts.map(\.id) == [delay, comp, added.id])
        window.mixer.moveInsert(added.id, onto: delay)
        #expect(window.project.track(a)?.inserts.map(\.id) == [added.id, delay, comp])
        // The master strip adds to the master's chain (its ID is the channel).
        try window.control("mixer.master.insert.add.builtin.reverb").action()
        #expect(window.project.master.inserts.map { MixerModel.insertName($0.kind) } == ["Reverb"])
        // Show: the Device Chain tab on that channel.
        try window.control("\(prefix).insert.\(comp).show").action()
        #expect(window.bottomPane == .deviceChain && window.deviceChain.channelID == a)
    }

    @Test("UI-050, UI-052: ui.state reports the chain (devices, params with steps/labels, controls) and mixer inserts; ui.perform drives the chain")
    func attachMode() async throws {
        try registerBuiltinCatalog()
        let t = TestApp()
        let window = t.app.newProject()
        window.pluginPanel.manager = try emptyManager()
        window.perform(AddTrack(name: "Gtr", kind: .audio))
        let track = window.project.tracks[0].id
        window.perform(InsertDevice(channel: track, device: .builtin(.delay)))
        let delay = window.project.tracks[0].inserts[0].id
        let d = t.app.dispatcher
        _ = try await d.call(.uiPerform, ["accessibilityId": "pane.bottom.deviceChain", "action": "on"])
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("deviceChain.channel.\(track)"), "action": "on"])
        var state = try await d.call(.uiState)
        var chain = try #require(state["windows"]?[0]?["deviceChain"])
        #expect(chain["open"] == true && chain["channelName"] == "Gtr" && chain["safeMode"] == false)
        #expect(chain["channels"]?.arrayValue?.count == 2)
        #expect(chain["choices"]?[0]?["key"] == "builtin.eq")
        var device = try #require(chain["devices"]?[0])
        #expect(device["name"] == "Delay" && device["format"] == "builtin" && device["position"] == 0 && device["bypass"] == false)
        let note = try #require(device["params"]?[2])
        #expect(note["id"] == "note" && note["steps"] == 13 && note["style"] == "menu" && note["display"] == "1/8")
        #expect(note["labels"]?[13] == "1/1")
        #expect(device["params"]?[1]?["style"] == "toggle" && device["params"]?[0]?["labels"] == .null)
        #expect(device["controls"]?.arrayValue?.contains(.string("deviceChain.device.\(delay).param.2.value.8")) == true)
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("deviceChain.device.\(delay).param.2.value.8"), "action": "on"])
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("deviceChain.device.\(delay).bypass"), "action": "on"])
        state = try await d.call(.uiState)
        chain = try #require(state["windows"]?[0]?["deviceChain"])
        device = try #require(chain["devices"]?[0])
        #expect(device["params"]?[2]?["display"] == "1/4" && device["params"]?[2]?["set"] == true && device["bypass"] == true)
        _ = try await d.call(.uiPerform, ["accessibilityId": "deviceChain.add.builtin.eq", "action": "click"])
        #expect(window.project.tracks[0].inserts.count == 2)
        // The mixer's inserts carry format and safe-mode state.
        window.bottomPane = .mixer
        state = try await d.call(.uiState)
        let inserts = try #require(state["windows"]?[0]?["mixer"]?["strips"]?[0]?["inserts"])
        #expect(inserts[0]?["name"] == "Delay" && inserts[0]?["bypass"] == true && inserts[0]?["safeModeBypassed"] == false)
        #expect(inserts[1]?["format"] == "builtin")
        let ids = state["windows"]?[0]?["controls"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(ids.contains("mixer.track.\(track).insert.add.builtin.reverb") && ids.contains("mixer.track.\(track).insert.\(delay).remove"))
    }

    @Test("UI-032, UI-051: the Device Chain tab renders cards in a real window (ui.snapshot path)")
    func snapshot() async throws {
        try registerBuiltinCatalog()
        let dir = try TempDir()
        let t = TestApp(workingDirectory: dir.url)
        let manager = realWindowManager(for: t.app)
        let window = t.app.newProject()
        defer { manager.close(window) }
        window.pluginPanel.manager = try emptyManager()
        window.perform(AddTrack(name: "Lead", kind: .audio))
        let track = window.project.tracks[0].id
        window.perform(InsertDevice(channel: track, device: .builtin(.eq)))
        window.perform(InsertDevice(channel: track, device: .builtin(.delay)))
        window.selectedTracks = [track]
        window.bottomPane = .deviceChain
        window.pluginPanel.isOpen = true
        let content = try #require(manager.nsWindow(for: window)?.contentView)
        content.layoutSubtreeIfNeeded()
        let result = try await t.app.dispatcher.call(.uiSnapshot, ["path": .string(dir.file("chain.png").path)])
        let path = try #require(result["pngPath"]?.stringValue)
        let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(image.pixelsWide >= 760 && image.pixelsHigh >= 480)
    }

    @Test("UI-052: device chain and plugin manager views make buttons and toggles only through ControlButton/ControlToggle")
    func noRawControls() throws {
        let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../EmberStudio/Shell").standardizedFileURL
        var files: [URL] = []
        for folder in ["DeviceChain", "PluginManager"] {
            files += try FileManager.default.contentsOfDirectory(at: shell.appending(path: folder), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix("View.swift") }
        }
        #expect(files.count == 2)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                #expect(code.firstMatch(of: /(^|[^A-Za-z])(Button|Toggle|Slider|Picker|Stepper|TextField)\s*\(/) == nil,
                        "\(file.lastPathComponent):\(n + 1): \(line)")
            }
        }
    }
}
