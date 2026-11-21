import CoreServices
import Foundation

/// UI-061: FSEvents on the browser's places. The handler gets the folders whose contents changed
/// (FSEvents reports directories, recursively under the watched roots; `WatchRoot` adds an event
/// when a root itself is moved or deleted) on a private queue.
final class FolderWatcher: @unchecked Sendable {
    // @unchecked: `stream` is set once in init and torn down in `stop()`, which the owner (the
    // main actor) calls; the callback only reads `handler`, which is immutable.
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.emberstudio.browser.fsevents")
    private let handler: @Sendable ([String]) -> Void

    init?(paths: [String], latency: TimeInterval = 0.2, handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        guard !paths.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes: `paths` is a CFArray of CFStrings.
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            watcher.handler(changed)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stops the stream; no callback runs after it returns.
    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        queue.sync {}  // a callback already running finishes before the watcher can go away
    }

    deinit { stop() }
}
