import AppKit
import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

/// A fresh folder under $TMPDIR (CONV §9), removed when dropped.
final class TempDir: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appending(path: name) }
}

/// A clock the tests move by hand (toast expiry).
@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// An AppModel over FakeEngines, without windows.
@MainActor
final class TestApp {
    let clock = TestClock()
    var engines: [FakeEngine] = []
    var app: AppModel!

    init(workingDirectory: URL? = nil) {
        app = AppModel(engine: .offline, makeEngine: { [unowned self] rate throws(DAWError) in
            let engine = FakeEngine(mode: .offline(sampleRate: rate))
            engines.append(engine)
            return engine
        }, workingDirectory: workingDirectory, now: { [unowned self] in clock.now })
    }
}

/// A window model over a FakeEngine.
@MainActor
func makeWindow(tracks: [String] = [], clock: TestClock? = nil) throws -> (ProjectWindowModel, FakeEngine) {
    let store = ProjectStore(project: Project(name: "Test"))
    store.autosavePolicy = nil
    let engine = FakeEngine()
    try store.attachEngine(engine, debounce: .zero)
    for name in tracks { try store.perform(AddTrack(name: name, kind: .audio)) }
    let toasts = clock.map { clock in ToastCenter(now: { clock.now }) } ?? ToastCenter()
    return (ProjectWindowModel(id: 1, store: store, toasts: toasts), engine)
}

extension ProjectWindowModel {
    func control(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> UIControl {
        try #require(controls.first { $0.id == id }, "no control \(id)", sourceLocation: sourceLocation)
    }
}

/// Presents windows for real (AppKit), for snapshot tests.
@MainActor
func realWindowManager(for app: AppModel) -> WindowManager {
    _ = NSApplication.shared
    let manager = WindowManager(app: app)
    manager.confirmsUnsavedChanges = false
    app.presenter = manager
    return manager
}
