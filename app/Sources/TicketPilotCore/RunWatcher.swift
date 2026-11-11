import Foundation

/// Calls `onChange` whenever the runs directory changes (a run file is written or replaced).
public final class RunWatcher: @unchecked Sendable {
    private let directory: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "ticket-pilot.run-watcher")
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?

    public init(directory: URL, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: queue
        )
        let onChange = onChange
        source.setEventHandler { onChange() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        source?.cancel()
        source = nil
    }
}
