import AppKit
import DAWControl
import DAWModel
import UniformTypeIdentifiers
import os

/// The app's lifecycle: menus (UI-001), windows, the control socket (CTL-030), the parent-process
/// watch (CTL-023), the event pump (UI-004) and a clean quit (DW-144).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let options: AppOptions
    private(set) var app: AppModel!
    private var windows: WindowManager!
    private var server: ControlSocketServer?
    private var pumpTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    private static let log = Logger(subsystem: "dev.emberstudio", category: "app")

    init(options: AppOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        app = AppModel(engine: options.engine)
        windows = WindowManager(app: app)
        windows.confirmsUnsavedChanges = !options.isAutomated
        app.presenter = windows
        NSApp.mainMenu = makeMainMenu()

        // CTL-030: the socket, when asked for (or in Debug).
        if let path = options.controlSocket {
            let server = ControlSocketServer(path: path, dispatcher: app.dispatcher)
            do {
                try server.start()
                self.server = server
                Self.log.info("control socket at \(path, privacy: .public)")
            } catch {
                Self.log.error("no control socket: \(error.detail, privacy: .public)")
                FileHandle.standardError.write(Data("Ember Studio: no control socket: \(error.detail)\n".utf8))
            }
        }
        // CTL-023: a launcher that goes away takes the app with it; SIGTERM (its terminate()) is a quit.
        if let parent = options.parentPID {
            ParentProcessWatch.start(parent) { DispatchQueue.main.async { NSApp.terminate(nil) } }
        }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        app.newProject()
        // UI-004: events, toast expiry and the transport, at display-ish rate.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.pump() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pumpTimer = timer
        NSApp.activate()
    }

    private func pump() {
        app.pump()
        for window in app.windows { windows.setTitle(window) }
    }

    /// DW-144: set once every project is closed; the next terminate goes through.
    private var readyToQuit = false
    private var quitting = false

    /// Never `.terminateLater`: AppKit would then spin a nested run loop until a reply, and a quit
    /// that starts inside a main-queue callback (SIGTERM, the parent watch) could never get one,
    /// because the main-actor task that closes the projects runs on that same queue. Instead the
    /// first terminate is cancelled, the projects close asynchronously, and then terminate again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToQuit { return .terminateNow }
        guard !quitting else { return .terminateCancel }
        let dirty = app.windows.filter { $0.store.isDirty }
        if !options.isAutomated, !dirty.isEmpty {
            let alert = NSAlert()
            alert.messageText = dirty.count == 1
                ? "Quit without saving \"\(dirty[0].store.project.name)\"?" : "Quit without saving \(dirty.count) projects?"
            alert.informativeText = "Your changes since the last save will be lost."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        quitting = true
        // DW-144: close every project (removes autosaves, so nothing offers recovery next time).
        Task { @MainActor in
            pumpTimer?.invalidate()
            await app.quit()
            server?.stop()
            readyToQuit = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && app.windows.isEmpty { app.newProject() }
        return true
    }

    // MARK: File menu (UI-001)

    @objc func newDocument(_ sender: Any?) {
        app.newProject()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder (Name.dawproject)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                try await app.open(url)
            } catch {
                presentError("Couldn't open \(url.lastPathComponent)", error)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let window = app.mainWindow else { return }
        guard window.store.folderURL != nil else { return saveDocumentAs(sender) }
        Task { @MainActor in
            do {
                try await app.save(window, to: nil)
            } catch {
                presentError("Couldn't save", error)
            }
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window = app.mainWindow else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = window.store.project.name + ".dawproject"
        panel.message = "The project is saved as a folder"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != "dawproject" { url.appendPathExtension("dawproject") }
        Task { @MainActor in
            do {
                try await app.save(window, to: url)
            } catch {
                presentError("Couldn't save", error)
            }
        }
    }

    @objc func exportAudio(_ sender: Any?) {
        guard let window = app.mainWindow else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = window.store.project.name + ".wav"
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let result = try await app.export(window, to: url)
                window.toasts.post(.info, .info, title: "Exported \(url.lastPathComponent)",
                                   message: String(format: "%.1f s in %.2f s", Double(result.framesWritten) / max(result.sampleRate, 1),
                                                   result.renderSeconds))
            } catch {
                presentError("Export failed", error)
            }
        }
    }

    @objc func closeProjectWindow(_ sender: Any?) {
        NSApp.mainWindow?.performClose(sender)
    }

    @objc func undoEdit(_ sender: Any?) { app.mainWindow?.store.undo() }
    @objc func redoEdit(_ sender: Any?) { app.mainWindow?.store.redo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let store = app?.mainWindow?.store
        switch item.action {
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(exportAudio(_:)),
             #selector(closeProjectWindow(_:)):
            return store != nil
        case #selector(undoEdit(_:)):
            item.title = store?.undoLabel.map { "Undo \($0)" } ?? "Undo"
            return store?.canUndo ?? false
        case #selector(redoEdit(_:)):
            item.title = store?.redoLabel.map { "Redo \($0)" } ?? "Redo"
            return store?.canRedo ?? false
        default:
            return true
        }
    }

    private func presentError(_ title: String, _ error: any Error) {
        let detail = (error as? DAWError)?.description ?? error.localizedDescription
        if let window = app.mainWindow {
            window.toasts.post(.error, .error, title: title, message: detail)
        } else {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.runModal()
        }
    }

    // MARK: Menus

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let name = "Ember Studio"

        let appMenu = NSMenu(title: name)
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: name)

        let file = NSMenu(title: "File")
        file.addItem(item("New", #selector(newDocument(_:)), "n"))
        file.addItem(item("Open…", #selector(openDocument(_:)), "o"))
        file.addItem(.separator())
        file.addItem(item("Close", #selector(closeProjectWindow(_:)), "w"))
        file.addItem(item("Save", #selector(saveDocument(_:)), "s"))
        file.addItem(item("Save As…", #selector(saveDocumentAs(_:)), "s", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Export…", #selector(exportAudio(_:)), "e", [.command, .shift]))
        main.addItem(submenu: file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", #selector(undoEdit(_:)), "z"))
        edit.addItem(item("Redo", #selector(redoEdit(_:)), "z", [.command, .shift]))
        main.addItem(submenu: edit, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window
        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
