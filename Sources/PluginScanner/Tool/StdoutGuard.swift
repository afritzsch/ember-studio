import Foundation

/// Plugins print to stdout while loading. The scanner's stdout is its result channel, so the
/// real stdout is set aside and fd 1 is pointed at stderr until the JSON is written.
struct StdoutGuard {
    private let resultFD: Int32

    init() {
        fflush(stdout)
        resultFD = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
    }

    func write(_ data: Data) {
        fflush(stdout)
        FileHandle(fileDescriptor: resultFD, closeOnDealloc: false).write(data)
    }
}
