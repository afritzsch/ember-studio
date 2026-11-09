import AppKit
import DAWControl
import DAWModel
import Foundation
import Observation
import Testing

@testable import EmberStudioShell

// UI-030 (strips), UI-031 (meters), UI-033 (routing pickers), DW-202 (the header's arm, monitor and
// input controls on a strip): the Mixer tab's view model and its AppKit controls.

/// A window with audio track A, MIDI track M, buses X and Y, the mixer tab open.
@MainActor
private func mixerWindow() throws -> (window: ProjectWindowModel, engine: FakeEngine, a: NodeIDValue, m: NodeIDValue, x: NodeIDValue, y: NodeIDValue) {
    let (window, engine) = try makeWindow(tracks: ["A"])
    window.perform(AddTrack(name: "M", kind: .midi))
    window.perform(AddBus(name: "X"))
    window.perform(AddBus(name: "Y"))
    window.bottomPane = .mixer
    return (window, engine, window.project.tracks[0].id, window.project.tracks[1].id, window.project.buses[0].id, window.project.buses[1].id)
}

@MainActor
private func strip(_ window: ProjectWindowModel, _ id: NodeIDValue, sourceLocation: SourceLocation = #_sourceLocation) throws -> MixerStripModel {
    try #require(window.mixer.strips.first { $0.id == id }, "no strip \(id)", sourceLocation: sourceLocation)
}

private final class Flag: @unchecked Sendable {
    var fired = false
}

/// A value the tests change between frames, read by a `@Sendable` meter closure.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("Fader taper (UI-030)")
struct FaderTaperTests {
    @Test("UI-030: 0 dB at 0.75, +12 dB (the model's max) at the top, silence at 0, monotonic, round trips")
    func taper() {
        #expect(FaderTaper.position(gain: 1) == 0.75)
        #expect(FaderTaper.gain(position: 0.75) == 1)
        #expect(FaderTaper.position(gain: 0) == 0 && FaderTaper.gain(position: 0) == 0)
        #expect(FaderTaper.gain(position: 1) == ChannelStripState.maxGain)
        #expect(FaderTaper.position(gain: ChannelStripState.maxGain) > 0.999)
        var last = -1.0
        for i in 0...2000 {
            let p = Double(i) / 2000
            let db = FaderTaper.db(position: p)
            #expect(db > last || i == 0, "\(p): \(db)")
            last = db
            let g = FaderTaper.gain(position: p)
            if i > 0 {
                #expect(abs(FaderTaper.position(gain: g) - p) < 1e-5, "\(p)")
            }
        }
        #expect(abs(FaderTaper.db(position: 0.5) - -12) < 1e-9 && abs(FaderTaper.db(position: 0.25) - -30) < 1e-9)
    }

    @Test("UI-030: nudges move 1 dB; down from the bottom of the marked range is silence, up from silence is −60 dB; clamped to the model's max")
    func nudges() {
        #expect(abs(FaderTaper.nudged(gain: 1, by: 1) - 1.122) < 1e-3)
        #expect(FaderTaper.nudged(gain: 0, by: 1) == FaderTaper.gain(db: -60))
        #expect(FaderTaper.nudged(gain: 0, by: -1) == 0)
        #expect(FaderTaper.nudged(gain: FaderTaper.gain(db: -60), by: -1) == 0)
        #expect(FaderTaper.nudged(gain: ChannelStripState.maxGain, by: 1) == ChannelStripState.maxGain)
    }

    @Test("UI-030: readouts: dB with sign, −∞, C/L/R")
    func labels() {
        #expect(FaderTaper.label(gain: 1) == "0.0" && FaderTaper.label(gain: 0) == "−∞")
        #expect(FaderTaper.label(gain: 2) == "+6.0" && FaderTaper.label(gain: 0.5) == "−6.0")
        #expect(PanTaper.label(pan: 0) == "C" && PanTaper.label(pan: -0.4) == "L40" && PanTaper.label(pan: 1) == "R100")
        #expect(PanTaper.position(pan: 0) == 0.5 && PanTaper.pan(position: 1) == 1 && PanTaper.pan(position: 0) == -1)
    }
}

@MainActor
@Suite("Mixer view model (UI-030, UI-033, DW-202)", .serialized)
struct MixerModelTests {
    @Test("UI-030: one strip per track, bus and master, in that order; values and kinds from the project")
    func strips() throws {
        let (window, _, a, m, x, y) = try mixerWindow()
        window.perform(SetParam(target: .strip(channel: a, param: .gain), value: 0.5))
        window.perform(SetParam(target: .strip(channel: a, param: .pan), value: -0.5))
        window.perform(SetParam(target: .strip(channel: x, param: .mute), value: 1))
        let strips = window.mixer.strips
        #expect(strips.map(\.id) == [a, m, x, y, window.project.master.id])
        #expect(strips.map(\.kind) == [.audio, .midi, .bus, .bus, .master])
        #expect(strips[0].gain == 0.5 && strips[0].pan == -0.5 && strips[2].mute)
        #expect(strips.last?.name == "Master" && strips[2].name == "X")
    }

    @Test("DW-202: tracks show the header's own arm/monitor/input controls; audio has input, MIDI arm without input; a bus and the master have none")
    func headerControls() throws {
        let (window, _, a, m, x, _) = try mixerWindow()
        let audio = try strip(window, a)
        let midi = try strip(window, m)
        #expect(audio.header?.armControl.id == "track.\(a).arm", "the same descriptor as the arrange header")
        #expect(audio.muteControl.id == "track.\(a).mute" && audio.soloControl?.id == "track.\(a).solo")
        #expect(midi.header?.armControl.id == "track.\(m).arm")
        #expect(midi.header?.inputControls.isEmpty == true, "MIDI tracks have no input menu")
        #expect(try strip(window, x).header == nil)
        // The strip's arm control is the header's: it performs ArmTrack, not a copy of the logic.
        try window.control("track.\(a).arm").action()
        #expect(window.project.track(a)?.armed == true)
        #expect(try strip(window, a).armed)
    }

    @Test("UI-030: the master has no output, sends, solo or arm; a bus has mute and solo but no arm")
    func masterAndBus() throws {
        let (window, _, _, _, x, _) = try mixerWindow()
        let master = try #require(window.mixer.strips.last)
        #expect(master.kind == .master && master.output == nil && master.outputControls.isEmpty && master.sendAddControls.isEmpty)
        #expect(master.soloControl == nil && master.header == nil && master.sends.isEmpty)
        try window.control("mixer.master.mute").action()
        #expect(window.project.master.strip.mute)
        try window.control("mixer.bus.\(x).solo").action()
        #expect(window.project.buses[0].strip.solo)
        #expect(try strip(window, x).solo)
    }

    @Test("UI-030: strips follow arrange edits and undo/redo: mute from the header, a removed track")
    func staysInSync() throws {
        let (window, _, a, m, _, _) = try mixerWindow()
        try window.control("track.\(a).mute").action()
        #expect(try strip(window, a).mute)
        window.store.undo()
        #expect(try strip(window, a).mute == false)
        window.store.redo()
        #expect(try strip(window, a).mute)
        window.perform(RemoveTrack(trackID: m))
        #expect(window.mixer.strips.count == 4)
        window.store.undo()
        #expect(window.mixer.strips.map(\.id).contains(m), "undo restores its strip")
    }

    @Test("UI-030: fader and pan nudges and resets are one SetParam each; disabled at the ends")
    func nudgeAndReset() throws {
        let (window, _, a, _, x, _) = try mixerWindow()
        try window.control("mixer.track.\(a).fader.up").action()
        #expect(abs((window.project.track(a)?.strip.gain ?? 0) - 1.122) < 0.01)
        #expect(window.store.undoLabel == "Set Gain")
        try window.control("mixer.track.\(a).fader.reset").action()
        #expect(window.project.track(a)?.strip.gain == 1)
        #expect(try window.control("mixer.track.\(a).fader.reset").isEnabled == false, "already 0 dB")
        try window.control("mixer.track.\(a).pan.left").action()
        #expect(window.project.track(a)?.strip.pan == -0.05)
        try window.control("mixer.track.\(a).pan.right").action()
        try window.control("mixer.track.\(a).pan.right").action()
        #expect(abs((window.project.track(a)?.strip.pan ?? 0) - 0.05) < 1e-6)
        try window.control("mixer.track.\(a).pan.center").action()
        #expect(window.project.track(a)?.strip.pan == 0)
        // Bus faders too, and a fader at the top can't go up.
        window.perform(SetParam(target: .strip(channel: x, param: .gain), value: ChannelStripState.maxGain))
        #expect(try window.control("mixer.bus.\(x).fader.up").isEnabled == false)
        window.perform(SetParam(target: .strip(channel: x, param: .pan), value: -1))
        #expect(try window.control("mixer.bus.\(x).pan.left").isEnabled == false)
    }

    @Test("MODEL-003, UI-030: a 100-step fader drag is one undo entry; no movement, none; undo restores the start")
    func gesture() throws {
        let (window, _, a, _, _, _) = try mixerWindow()
        let mixer = window.mixer
        let start = window.store.undoLabel
        mixer.beginDrag(.gain(a))
        for i in 0...100 {
            mixer.updateDrag(.gain(a), position: 0.2 + Double(i) * 0.005)
            #expect(try strip(window, a).gain == FaderTaper.gain(position: 0.2 + Double(i) * 0.005))
        }
        #expect(mixer.activeDrag == .gain(a))
        mixer.endDrag()
        #expect(mixer.activeDrag == nil)
        #expect(window.store.undoLabel == "Set Gain")
        window.store.undo()
        #expect(window.project.track(a)?.strip.gain == 1, "one undo step takes back the whole drag")
        #expect(window.store.undoLabel == start)
        // A press without movement: no gesture and no undo entry (the view begins on first movement).
        mixer.beginDrag(.pan(a))
        mixer.endDrag()
        #expect(window.store.undoLabel == start)
    }

    @Test("MODEL-003: a drag ends with its window's document replaced; a stale update does nothing; double-click resets")
    func gestureEdges() throws {
        let (window, _, a, _, _, _) = try mixerWindow()
        let mixer = window.mixer
        mixer.beginDrag(.gain(a))
        mixer.updateDrag(.gain(a), position: 0.5)
        mixer.updateDrag(.pan(a), position: 0.9)  // not the active drag
        #expect(window.project.track(a)?.strip.pan == 0)
        let old = window.store
        let store = ProjectStore(project: Project(name: "New"))
        store.autosavePolicy = nil
        window.replace(store: store)
        #expect(mixer.activeDrag == nil && !old.isGestureActive)
        // A double-click: the default value as one undo step.
        window.replace(store: old)
        mixer.reset(.gain(a))
        #expect(window.project.track(a)?.strip.gain == 1)
    }

    @Test("UI-033: the output menu sets SetTrackOutput; toggles are on for the current output; a bus's output works too")
    func outputMenu() throws {
        let (window, _, a, _, x, y) = try mixerWindow()
        #expect(try window.control("mixer.track.\(a).output.master").isOn == true)
        try window.control("mixer.track.\(a).output.bus.\(x)").action()
        #expect(window.project.track(a)?.output == .bus(x))
        #expect(try window.control("mixer.track.\(a).output.bus.\(x)").isOn == true)
        #expect(try window.control("mixer.track.\(a).output.master").isOn == false)
        #expect(try strip(window, a).outputTitle == "X")
        try window.control("mixer.bus.\(x).output.bus.\(y)").action()
        #expect(window.project.buses[0].output == .bus(y))
        window.store.undo()
        window.store.undo()
        #expect(window.project.track(a)?.output == .master && window.project.buses[0].output == .master)
    }

    @Test("UI-033, MODEL-030: a cycle-creating output shows the model's error and changes nothing; the menu stays correct")
    func outputCycle() throws {
        let (window, _, _, _, x, y) = try mixerWindow()
        try window.control("mixer.bus.\(x).output.bus.\(y)").action()
        let before = window.project
        // Y → X closes the cycle X → Y → X. It is offered, and the model refuses it.
        let cycle = try window.control("mixer.bus.\(y).output.bus.\(x)")
        cycle.action()
        #expect(window.project == before, "nothing changed")
        let toast = try #require(window.toasts.toasts.last)
        #expect(toast.severity == .error && toast.title == "Set Output failed")
        #expect(toast.message.contains("routing cycle"), "the model's message: \(toast.message)")
        #expect(toast.message.contains("Y → X → Y") || toast.message.contains("X → Y"), "names the channels: \(toast.message)")
        #expect(try window.control("mixer.bus.\(y).output.master").isOn == true, "the menu still shows the real output")
        // A bus can't output to itself, and that is the model's error too.
        try window.control("mixer.bus.\(x).output.bus.\(x)").action()
        #expect(window.project == before)
        #expect(window.toasts.toasts.count == 2)
    }

    @Test("UI-030: sends: add, level, pre/post, remove through the routing commands; add to every bus is offered")
    func sends() throws {
        let (window, _, a, _, x, y) = try mixerWindow()
        #expect(try strip(window, a).sendTargets.map(\.id) == [x, y])
        try window.control("mixer.track.\(a).send.add.\(x)").action()
        let send = try #require(window.project.track(a)?.sends.first)
        #expect(send.target == x && send.tap == .postFader && send.level == 1)
        let shown = try #require(try strip(window, a).sends.first)
        #expect(shown.values.targetName == "X" && shown.values.tap == .postFader)
        let prefix = "mixer.track.\(a).send.\(send.id)"
        try window.control("\(prefix).level.down").action()
        #expect(window.project.track(a)?.sends[0].level ?? 0 < 1)
        #expect(window.store.undoLabel == "Set Send Level")
        try window.control("\(prefix).level.reset").action()
        #expect(window.project.track(a)?.sends[0].level == 1)
        try window.control("\(prefix).tap.pre").action()
        #expect(window.project.track(a)?.sends[0].tap == .preFader)
        #expect(try window.control("\(prefix).tap.pre").isOn == true)
        try window.control("\(prefix).tap.pre").action()
        #expect(window.project.track(a)?.sends[0].tap == .postFader)
        try window.control("\(prefix).remove").action()
        #expect(window.project.track(a)?.sends.isEmpty == true)
        window.store.undo()
        #expect(window.project.track(a)?.sends.first?.id == send.id, "undo restores the send with its id")
    }

    @Test("UI-033, MODEL-030: a send that closes a cycle shows the model's error and adds nothing")
    func sendCycle() throws {
        let (window, _, _, _, x, y) = try mixerWindow()
        try window.control("mixer.bus.\(x).send.add.\(y)").action()
        let before = window.project
        try window.control("mixer.bus.\(y).send.add.\(x)").action()
        #expect(window.project == before)
        let toast = try #require(window.toasts.toasts.last)
        #expect(toast.title == "Add Send failed" && toast.message.contains("routing cycle"))
    }

    @Test("UI-030: a send level drag is one undo entry (SetSendLevel)")
    func sendDrag() throws {
        let (window, _, a, _, x, _) = try mixerWindow()
        window.perform(AddSend(channelID: a, busID: x))
        let send = try #require(window.project.track(a)?.sends.first?.id)
        let mixer = window.mixer
        mixer.beginDrag(.sendLevel(send))
        for i in 0..<40 { mixer.updateDrag(.sendLevel(send), position: 0.5 + Double(i) * 0.005) }
        mixer.endDrag()
        #expect(window.store.undoLabel == "Set Send Level")
        window.store.undo()
        #expect(window.project.track(a)?.sends[0].level == 1)
    }

    @Test("UI-030: the inserts list is read-only names with bypass state")
    func inserts() throws {
        let (window, _, _, _, _, _) = try mixerWindow()
        let next = window.project.ids.next
        let slots = [DeviceSlot(id: next, kind: .builtin(.eq)), DeviceSlot(id: next + 1, kind: .au(AUDescriptor(identifier: "a:b:c", name: "Space")), bypass: true)]
        window.perform(RestoreTrack(track: Track(id: next + 2, name: "I", kind: .audio, inserts: slots), index: 2))
        let shown = try strip(window, next + 2)
        #expect(shown.inserts == [MixerInsert(id: next, name: "EQ", bypass: false), MixerInsert(id: next + 1, name: "Space", bypass: true)])
    }

    @Test("UI-052: strips reuse the header's track.<id>.… ids, list their own only while the tab is open, and are unique")
    func controlsListed() throws {
        let (window, _, a, _, x, _) = try mixerWindow()
        var ids = window.controls.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("mixer.track.\(a).fader.up") && ids.contains("track.\(a).mute"))
        #expect(ids.filter { $0 == "track.\(a).mute" }.count == 1, "one descriptor, drawn in the header and the strip")
        window.bottomPane = .pianoRoll
        ids = window.controls.map(\.id)
        #expect(!ids.contains("mixer.track.\(a).fader.up") && !ids.contains("mixer.bus.\(x).mute"))
        #expect(ids.contains("track.\(a).mute"), "the headers stay")
        #expect(!window.windowControls.map(\.id).contains("mixer.master.mute"))
    }

    @Test("UI-030: a strip's `==` compares what it shows, so changing one channel leaves the others equal (no re-render)")
    func oneChangeOneStrip() throws {
        let (window, _, a, m, x, _) = try mixerWindow()
        let before = window.mixer.strips
        window.perform(SetParam(target: .strip(channel: a, param: .gain), value: 0.5))
        let after = window.mixer.strips
        #expect(before[0] != after[0])
        for i in 1..<before.count { #expect(before[i] == after[i], "\(before[i].name)") }
        #expect(try strip(window, m).name == "M" && strip(window, x).kind == .bus)
    }

    @Test("UI-030: 100 strips build quickly (smoke)")
    func manyStrips() throws {
        let (window, _) = try makeWindow(tracks: (0..<100).map { "T\($0)" })
        window.bottomPane = .mixer
        let start = Date()
        let strips = window.mixer.strips
        let controls = window.mixer.controls
        #expect(strips.count == 101 && controls.count > 700)
        #expect(Date().timeIntervalSince(start) < 2, "debug-build smoke bound")
    }
}

@Suite("Meter ballistics (UI-031)")
struct MeterBallisticsTests {
    @Test("UI-031: instant attack, 24 dB/s release; hold line stays 1.5 s then falls")
    func release() {
        var m = MeterBallistics()
        m.advance(MeterReading(peak: 0.5, rms: 0.25), now: 0)
        #expect(abs(m.peakDB - -6.02) < 0.05 && abs(m.holdDB - -6.02) < 0.05 && abs(m.rmsDB - -12.04) < 0.05)
        m.advance(MeterReading(peak: 0, rms: 0), now: 1)
        #expect(abs(m.peakDB - -30.02) < 0.05, "fell 24 dB in 1 s")
        #expect(abs(m.holdDB - -6.02) < 0.05, "held")
        #expect(m.rmsDB == MeterBallistics.floorDB)
        m.advance(MeterReading(peak: 0, rms: 0), now: 2)
        #expect(m.holdDB < -6.1, "hold released after 1.5 s")
    }

    @Test("UI-031: the clip indicator latches above full scale until cleared; NaN is silence; nil is silence")
    func clip() {
        var m = MeterBallistics()
        m.advance(MeterReading(peak: 0.9, rms: 0.1), now: 0)
        #expect(!m.clipped)
        m.advance(MeterReading(peak: 1.2, rms: 0.1), now: 0.1)
        #expect(m.clipped)
        m.advance(MeterReading(peak: 0.1, rms: 0.01), now: 0.2)
        #expect(m.clipped, "latched")
        m.clearClip()
        #expect(!m.clipped)
        m.advance(MeterReading(peak: .nan, rms: .nan), now: 0.3)
        #expect(!m.clipped && m.rmsDB == MeterBallistics.floorDB)
        m.advance(nil, now: 0.4)
        #expect(!m.clipped)
    }

    @Test("UI-031: the scale runs from −60 to +6 dB, clamped")
    func scale() {
        #expect(MeterBallistics.position(db: -60) == 0 && MeterBallistics.position(db: 6) == 1)
        #expect(MeterBallistics.position(db: -100) == 0 && MeterBallistics.position(db: 20) == 1)
        #expect(MeterBallistics.decibels(0) == MeterBallistics.floorDB && MeterBallistics.decibels(.nan) == MeterBallistics.floorDB)
        #expect(abs(MeterBallistics.decibels(1)) < 1e-9)
    }
}

@MainActor
@Suite("Mixer meters and controls in AppKit (UI-031, UI-030)", .serialized)
struct MixerAppKitTests {
    private func hostWindow(size: NSSize = NSSize(width: 300, height: 300)) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        return window
    }

    @Test("UI-031: meter frames publish no @Observable change (no SwiftUI invalidation per frame)")
    func noInvalidation() throws {
        let (window, _, a, _, x, _) = try mixerWindow()
        let level = Box<Float>(0.1)
        let bank = window.mixer.meters
        bank.readMeter = { _ in MeterReading(peak: level.value, rms: level.value / 2) }
        let now = Box<TimeInterval>(0)
        bank.clock = { now.value }
        let host = hostWindow()
        defer { host.close() }
        let meter = ChannelMeterView(channel: a, bank: bank)
        meter.frame = NSRect(x: 10, y: 10, width: 12, height: 150)
        host.contentView?.addSubview(meter)
        host.contentView?.layoutSubtreeIfNeeded()
        let flag = Flag()
        // Everything the views read from the view models: none of it may change across frames.
        withObservationTracking {
            _ = window.mixer.strips
            _ = window.mixer.activeDrag
            _ = window.mixer.controls
            _ = window.controls
            _ = window.project
            _ = window.toasts.toasts
        } onChange: { flag.fired = true }
        for frame in 0..<240 {
            now.value = Double(frame) / 60
            level.value = 0.1 + Float(frame % 7) / 8
            bank.displayFrame()
        }
        #expect(!flag.fired, "meter frames must not touch observable state")
        #expect(bank.state(of: a)?.holdDB ?? -100 > -12, "the frames did read the meter")
        // The state dump reads it directly, not through the view models.
        #expect(UIStateDumper.dump(window.mixer)["strips"]?[0]?["meter"]?["peak"]?.doubleValue != nil)
        _ = x
    }

    @Test("UI-031: only meters on screen read the engine: off-window, hidden or scrolled away don't")
    func onlyVisibleMetersRead() throws {
        let bank = MeterBank()
        let reads = Box<[NodeIDValue]>([])
        bank.readMeter = { id in reads.value.append(id); return MeterReading(peak: 0.5, rms: 0.2) }
        let host = hostWindow()
        defer { host.close() }
        let content = try #require(host.contentView)
        let visible = ChannelMeterView(channel: 1, bank: bank)
        visible.frame = NSRect(x: 10, y: 10, width: 12, height: 100)
        let clippedAway = ChannelMeterView(channel: 2, bank: bank)
        clippedAway.frame = NSRect(x: 2000, y: 10, width: 12, height: 100)
        let hidden = ChannelMeterView(channel: 3, bank: bank)
        hidden.frame = NSRect(x: 30, y: 10, width: 12, height: 100)
        hidden.isHidden = true
        for view in [visible, clippedAway, hidden] { content.addSubview(view) }
        bank.displayFrame()
        #expect(reads.value == [1])
        // Out of the window: never again, and not retained by the bank.
        visible.removeFromSuperview()
        reads.value = []
        bank.displayFrame()
        #expect(reads.value.isEmpty)
    }

    @Test("UI-031: the display link runs only while the clock view is in a window, and doesn't retain its window")
    func displayLink() throws {
        let bank = MeterBank()
        let host = hostWindow()
        let content = try #require(host.contentView)
        let clock = MeterClockView(bank: bank)
        #expect(!clock.isRunning)
        content.addSubview(clock)
        #expect(clock.isRunning)
        clock.removeFromSuperview()  // the tab hidden
        #expect(!clock.isRunning)
        content.addSubview(clock)
        #expect(clock.isRunning)
        clock.removeFromSuperview()
        host.close()
    }

    @Test("UI-031: a clock view isn't kept alive by its display link (the link's target holds it weakly)")
    func linkDoesNotRetain() throws {
        weak var weakClock: MeterClockView?
        autoreleasepool {
            let host = hostWindow()
            let bank = MeterBank()
            let clock = MeterClockView(bank: bank)
            host.contentView?.addSubview(clock)
            #expect(clock.isRunning)
            weakClock = clock
            clock.removeFromSuperview()
            host.close()
        }
        #expect(weakClock == nil, "no retain cycle through the display link")
    }

    @Test("UI-031: a click on the meter clears its clip indicator; the control does the same")
    func clearClip() throws {
        let bank = MeterBank()
        let peak = Box<Float>(2)
        bank.readMeter = { _ in MeterReading(peak: peak.value, rms: 0) }
        let now = Box(0.0)
        bank.clock = { now.value }
        let host = hostWindow()
        defer { host.close() }
        let meter = ChannelMeterView(channel: 7, bank: bank)
        meter.frame = NSRect(x: 0, y: 0, width: 12, height: 100)
        host.contentView?.addSubview(meter)
        bank.displayFrame()
        #expect(bank.state(of: 7)?.clipped == true)
        peak.value = 0.1
        now.value = 1
        bank.displayFrame()
        #expect(bank.state(of: 7)?.clipped == true, "latched")
        meter.mouseDown(with: try mouseEvent(.leftMouseDown, in: host, at: NSPoint(x: 5, y: 5)))
        #expect(bank.state(of: 7)?.clipped == false)
    }

    private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    @Test("UI-030: MixerSliderView: a drag begins on first movement and reports relative position; a double-click resets; no movement is no gesture")
    func slider() throws {
        let host = hostWindow(size: NSSize(width: 40, height: 208))
        defer { host.close() }
        let view = MixerSliderView(axis: .vertical)
        view.frame = NSRect(x: 0, y: 0, width: 30, height: 208)  // travel 200
        host.contentView?.addSubview(view)
        view.position = 0.5
        var begun = 0, ended = 0, resets = 0
        var values: [Double] = []
        view.onBegin = { begun += 1 }
        view.onChange = { values.append($0) }
        view.onEnd = { ended += 1 }
        view.onReset = { resets += 1 }
        let centre = NSPoint(x: 15, y: 100)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: host, at: centre))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: host, at: centre))
        #expect(begun == 0 && ended == 0, "a click without movement is no gesture")
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: host, at: centre))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: host, at: NSPoint(x: 15, y: 120)))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: host, at: NSPoint(x: 15, y: 140)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: host, at: NSPoint(x: 15, y: 140)))
        #expect(begun == 1 && ended == 1)
        #expect(values.count == 2 && abs(values[0] - 0.6) < 1e-6 && abs(values[1] - 0.7) < 1e-6, "up is higher, relative to the grab: \(values)")
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: host, at: centre, clicks: 2))
        #expect(resets == 1, "double-click")
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: host, at: NSPoint(x: 15, y: 150)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: host, at: NSPoint(x: 15, y: 150)))
        #expect(begun == 1, "the double-click isn't a drag")
    }

    @Test("UI-030: a horizontal MixerSliderView maps right to higher, and a drag cut short by removal still ends")
    func horizontalSlider() throws {
        let host = hostWindow(size: NSSize(width: 208, height: 40))
        defer { host.close() }
        let view = MixerSliderView(axis: .horizontal)
        view.frame = NSRect(x: 0, y: 0, width: 208, height: 18)
        host.contentView?.addSubview(view)
        view.position = 0
        var values: [Double] = []
        var ended = 0
        view.onChange = { values.append($0) }
        view.onEnd = { ended += 1 }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: host, at: NSPoint(x: 10, y: 10)))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: host, at: NSPoint(x: 60, y: 10)))
        #expect(values == [0.25])
        view.removeFromSuperview()
        #expect(ended == 1, "the drag ends with the view")
    }
}
