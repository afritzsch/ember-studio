import Foundation
import os

/// DW-335 (T-112, MODEL-044): the project folder as the store's queued file operations see it.
/// `ProjectStore.folderURL` changes on the main actor when a save resumes, after any autosave queued
/// behind that save has been told where to write. So the queue keeps its own copy: a save sets it
/// once its files are written (on the queue), and an autosave reads it when it runs, so an autosave
/// queued behind a Save As writes into the new folder.
final class AutosaveDestination: Sendable {
    private let folder: OSAllocatedUnfairLock<URL?>

    init(_ folder: URL?) {
        self.folder = OSAllocatedUnfairLock(initialState: folder)
    }

    var url: URL? {
        get { folder.withLock { $0 } }
        set { folder.withLock { $0 = newValue } }
    }
}
