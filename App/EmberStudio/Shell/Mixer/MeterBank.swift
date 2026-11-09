import AppKit
import DAWModel
import QuartzCore

/// UI-031: the mixer's meters, driven by one display link (`MeterClockView`). Each frame it reads the
/// engine (`EngineClient.meter`, through `readMeter`) for the meters on screen and hands the
/// ballistics to their views.
///
/// Deliberately *not* `@Observable`: this runs at display rate, and nothing it changes may invalidate
/// SwiftUI. Clip latches and hold lines live here, so they survive a strip being scrolled away.
@MainActor
final class MeterBank {
    /// How a frame reads a channel's meter (tests stand in for the engine).
    var readMeter: @MainActor (NodeIDValue) -> MeterReading? = { _ in nil }
    /// `now` for the ballistics (tests move it by hand).
    var clock: @MainActor () -> TimeInterval = { CACurrentMediaTime() }

    private var states: [NodeIDValue: MeterBallistics] = [:]
    private let views = NSHashTable<ChannelMeterView>.weakObjects()

    func register(_ view: ChannelMeterView) { views.add(view) }
    func unregister(_ view: ChannelMeterView) { views.remove(view) }

    /// One display frame: only meters actually on screen read the engine or draw.
    func displayFrame() {
        let now = clock()
        for view in views.allObjects where view.isOnScreen {
            var state = states[view.channel] ?? MeterBallistics()
            state.advance(readMeter(view.channel), now: now)
            states[view.channel] = state
            view.present(state)
        }
    }

    func state(of channel: NodeIDValue) -> MeterBallistics? { states[channel] }

    func clearClip(of channel: NodeIDValue) {
        states[channel]?.clearClip()
        for view in views.allObjects where view.channel == channel {
            if let state = states[channel] { view.present(state) }
        }
    }

    /// A new project: nothing the old engine's meters showed still applies.
    func reset() {
        states = [:]
        for view in views.allObjects { view.present(MeterBallistics()) }
    }
}

/// UI-031: the display link of the mixer's meters: a zero-size view that exists only while the Mixer
/// tab is shown. It stops as soon as the tab is hidden (the view leaves the window), and pauses
/// while the window is occluded. The link retains only a proxy, which holds this view and the bank
/// weakly, so the meters never keep a window alive.
final class MeterClockView: NSView {
    let bank: MeterBank
    private var link: CADisplayLink?
    /// Whether frames are firing (tests, `ui.state`).
    var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    init(bank: MeterBank) {
        self.bank = bank
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window { NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard let window else { return }
        let proxy = MeterClockProxy(clock: self)
        let newLink = displayLink(target: proxy, selector: #selector(MeterClockProxy.frame(_:)))
        newLink.add(to: .main, forMode: .common)
        link = newLink
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    /// A window nobody can see draws no meters.
    @objc private func occlusionChanged(_ note: Notification) {
        link?.isPaused = window?.occlusionState.contains(.visible) != true
    }

    func displayFrame() { bank.displayFrame() }
}

/// The display link's target: weak, so the link keeps neither the view nor its window alive, and it
/// ends the link if the view went away without leaving its window first.
@MainActor
private final class MeterClockProxy: NSObject {
    weak var clock: MeterClockView?

    init(clock: MeterClockView) { self.clock = clock }

    @objc func frame(_ link: CADisplayLink) {
        guard let clock else {
            link.invalidate()
            return
        }
        clock.displayFrame()
    }
}
