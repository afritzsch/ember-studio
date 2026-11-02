import AppKit

// UI-001: the AppKit entry point. Everything else lives in Shell/, which the EmberStudioShell
// SwiftPM target also compiles so its view models are unit-tested without the app (UI-003).
@main
enum EmberStudioApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate(options: AppOptions(arguments: CommandLine.arguments))
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
