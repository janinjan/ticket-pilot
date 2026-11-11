import Foundation

public struct ProcessResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public var error: String

    public init(status: Int32, output: String, error: String) {
        self.status = status
        self.output = output
        self.error = error
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], currentDirectory: URL?) throws -> ProcessResult
}

/// Runs a process to completion, reading stdout and stderr concurrently so large outputs cannot block it.
/// With a `timeout`, a child still running after that delay is terminated (then killed after a short
/// grace period) and reported as a failure. Output held open by grandchildren is not waited for beyond
/// that grace period, so the call always returns.
public struct SystemProcessRunner: ProcessRunning {
    private static let grace: TimeInterval = 1
    private static let drainLimit: TimeInterval = 10

    private let timeout: TimeInterval?

    public init(timeout: TimeInterval? = nil) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String], currentDirectory: URL?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let outBox = DataBox()
        let errBox = DataBox()
        let readers = DispatchGroup()
        for (handle, box) in [(outPipe.fileHandleForReading, outBox), (errPipe.fileHandleForReading, errBox)] {
            readers.enter()
            // Its own queue, not the global one: the global queue runs about one block per core, and readers
            // blocked on other processes could then starve this one, leaving its process stuck on a full pipe.
            DispatchQueue(label: "SystemProcessRunner.reader").async {
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    box.append(chunk)
                }
                readers.leave()
            }
        }

        var timedOut = false
        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                // Decided here, from the process state: a child that just exited is not a timeout.
                timedOut = process.isRunning
                if timedOut {
                    process.terminate()
                    if exited.wait(timeout: .now() + Self.grace) == .timedOut {
                        kill(process.processIdentifier, SIGKILL)
                        exited.wait()
                    }
                } else {
                    exited.wait()
                }
            }
            // After a clean exit the readers still have output to drain: give them time, bounded in case a
            // grandchild holds the pipes. After a terminate or kill, only a short grace.
            _ = readers.wait(timeout: .now() + (timedOut ? Self.grace : Self.drainLimit))
        } else {
            exited.wait()
            readers.wait()
        }

        var error = String(decoding: errBox.snapshot, as: UTF8.self)
        var status = process.terminationStatus
        if timedOut {
            if !error.isEmpty, !error.hasSuffix("\n") { error += "\n" }
            error += "timed out after \(timeout ?? 0) seconds"
            if status == 0 { status = 1 }
        }
        return ProcessResult(status: status, output: String(decoding: outBox.snapshot, as: UTF8.self), error: error)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var snapshot: Data { lock.withLock { data } }
}
