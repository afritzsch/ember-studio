import AppKit
import DAWModel
import UniformTypeIdentifiers

/// UI-042 (T-082): the export dialog's "Choose…": a save panel for the destination, which confirms
/// overwriting an existing file itself. Non-modal (`begin`), so a `ui.perform` of `export.choose`
/// returns at once instead of blocking the control socket in a modal loop.
@MainActor
enum ExportDestinationPanel {
    static func choose(start: URL, fileType: ExportSpec.FileType, done: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Export Audio"
        panel.prompt = "Choose"
        panel.canCreateDirectories = true
        panel.directoryURL = start.deletingLastPathComponent()
        panel.nameFieldStringValue = start.lastPathComponent
        panel.allowedContentTypes = [contentType(fileType)]
        panel.begin { response in
            MainActor.assumeIsolated { done(response == .OK ? panel.url : nil) }
        }
    }

    static func contentType(_ type: ExportSpec.FileType) -> UTType {
        switch type {
        case .wav: .wav
        case .aiff: .aiff
        case .caf: UTType(filenameExtension: "caf") ?? .audio
        }
    }
}
