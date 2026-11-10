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
    private var keyMonitor: KeyMonitor?
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
        // UI-002: shortcuts go to the key window's view model.
        keyMonitor = KeyMonitor { [weak self] window in self?.windows.model(for: window) }

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
            keyMonitor?.stop()
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

    /// UI-042 (T-082): File > Export… (⇧⌘E) opens the main window's export dialog (`export`), which
    /// renders and toasts the outcome itself.
    @objc func exportAudio(_ sender: Any?) {
        app.mainWindow?.exportDialog.isOpen = true
    }

    @objc func closeProjectWindow(_ sender: Any?) {
        NSApp.mainWindow?.performClose(sender)
    }

    /// Edit, Track, Transport and View menu items: they run the main window's control with the id in
    /// `representedObject` (UI-052), the one its button, its shortcut (UI-002) and `ui.perform` run.
    @objc func performControl(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let control = mainWindowControl(id), control.isEnabled else { return }
        control.action()
    }

    private func mainWindowControl(_ id: String) -> UIControl? {
        app?.mainWindow?.controls.first { $0.id == id }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let store = app?.mainWindow?.store
        switch item.action {
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(exportAudio(_:)),
             #selector(closeProjectWindow(_:)):
            return store != nil
        case #selector(performControl(_:)):
            guard let id = item.representedObject as? String, let control = mainWindowControl(id) else { return false }
            // Undo/redo and play/stop name what they'll do.
            if ["edit.undo", "edit.redo", "transport.playStop"].contains(id) { item.title = control.label }
            item.state = control.isOn == true ? .on : .off
            return control.isEnabled
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
        // UI-040 (T-055): the main window's audio settings (⌘,).
        appMenu.addItem(controlItem("Settings…", "prefs.audio"))
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

        // UI-002: the shortcuts' menus. ⌘ chords show (and, if `KeyMonitor` passed them on, take)
        // their key equivalent; plain keys (Space, R, L, ⌫) are named in the title.
        let edit = NSMenu(title: "Edit")
        edit.addItem(controlItem("Undo", "edit.undo"))
        edit.addItem(controlItem("Redo", "edit.redo"))
        edit.addItem(.separator())
        edit.addItem(controlItem("Split at Playhead", "edit.split"))
        edit.addItem(controlItem("Duplicate", "edit.duplicate"))
        edit.addItem(controlItem("Delete (⌫)", "edit.delete"))
        edit.addItem(.separator())
        edit.addItem(controlItem("Select All Clips", "edit.selectAll"))
        edit.addItem(controlItem("Deselect Clips", "edit.deselectAll"))
        main.addItem(submenu: edit, title: "Edit")

        let track = NSMenu(title: "Track")
        track.addItem(controlItem("New Audio Track", "track.add.audio"))
        track.addItem(controlItem("New MIDI Track", "track.add.midi"))
        main.addItem(submenu: track, title: "Track")

        let transport = NSMenu(title: "Transport")
        transport.addItem(controlItem("Play (Space)", "transport.playStop"))
        transport.addItem(controlItem("Record (R)", "transport.record"))
        transport.addItem(controlItem("Loop (L)", "transport.loop"))
        transport.addItem(controlItem("Metronome", "transport.metronome"))
        main.addItem(submenu: transport, title: "Transport")

        let view = NSMenu(title: "View")
        view.addItem(controlItem("Zoom In", "zoom.in"))
        view.addItem(controlItem("Zoom Out", "zoom.out"))
        main.addItem(submenu: view, title: "View")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window
        return main
    }

    private func controlItem(_ title: String, _ controlID: String) -> NSMenuItem {
        let key = KeyBindings.chord(for: controlID)?.menuKeyEquivalent
        let item = item(title, #selector(performControl(_:)), key?.key ?? "", key?.modifiers ?? [])
        item.representedObject = controlID
        return item
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
