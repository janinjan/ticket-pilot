import Foundation
import Network

/// The request line of an HTTP request: its method, path and query items.
public struct CallbackRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]

    /// Parses the head of a request; nil until the blank line ending the headers has arrived.
    public static func parse(_ data: Data) -> CallbackRequest? {
        guard let head = String(data: data, encoding: .utf8), head.contains("\r\n\r\n") else { return nil }
        let line = head.prefix { $0 != "\r" && $0 != "\n" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: String(parts[1])) else { return nil }
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        return CallbackRequest(method: String(parts[0]), path: components.path, query: query)
    }
}

/// A one-shot HTTP listener on 127.0.0.1 for the sign-in's redirect. Only a `GET /callback` carrying the
/// sign-in's `state` ends it: it answers the browser with a neutral page (the app shows the outcome),
/// hands back the query and closes. Anything else gets an error page and the listener keeps waiting, so
/// another local process or a web page probing ports cannot end the sign-in. It also closes after its
/// timeout or when cancelled.
public final class LoopbackCallbackServer: @unchecked Sendable {
    public let port: UInt16

    static let maxConnections = 8
    static let connectionTimeout: TimeInterval = 10

    private let listener: NWListener
    private let queue: DispatchQueue
    private let expectedState: String
    private let lock = NSLock()
    private var outcome: Result<[String: String], MCPError>?
    private var waiter: CheckedContinuation<[String: String], any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private init(listener: NWListener, queue: DispatchQueue, port: UInt16, expectedState: String) {
        self.listener = listener
        self.queue = queue
        self.port = port
        self.expectedState = expectedState
    }

    /// The port the listener got; 0 (none) is a failure.
    static func validatedPort(_ port: UInt16?) throws(MCPError) -> UInt16 {
        guard let port, port != 0 else { throw .unsupportedServer("TicketPilot could not listen for the sign-in.") }
        return port
    }

    /// Listens on a random port of 127.0.0.1 only, for the callback of the sign-in `expectedState`.
    public static func start(
        expectedState: String,
        timeout: Duration = .seconds(300)
    ) async throws(MCPError) -> LoopbackCallbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .unsupportedServer("TicketPilot could not listen for the sign-in (\(error)).")
        }
        let queue = DispatchQueue(label: "ticket-pilot.loopback-callback")
        let box = ServerBox()
        listener.newConnectionHandler = { connection in box.server?.handle(connection) }
        let rawPort: UInt16
        do {
            rawPort = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
                let once = OnceFlag()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    case let .failed(error):
                        if once.take() { continuation.resume(throwing: error) }
                        listener.cancel()
                    case .cancelled:
                        if once.take() { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        } catch {
            listener.cancel()
            throw .unsupportedServer("TicketPilot could not listen for the sign-in (\(error)).")
        }
        let port: UInt16
        do {
            port = try validatedPort(rawPort)
        } catch {
            listener.cancel()
            throw error
        }
        let server = LoopbackCallbackServer(listener: listener, queue: queue, port: port, expectedState: expectedState)
        box.server = server
        listener.stateUpdateHandler = nil
        server.timeoutTask = Task { [weak server] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            server?.finish(.failure(.timedOut))
        }
        return server
    }

    /// The query of the callback; `.timedOut`, or `.cancelled` when cancelled or when the task is.
    public func waitForCallback() async throws(MCPError) -> [String: String] {
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if let outcome {
                        lock.unlock()
                        continuation.resume(with: outcome.mapError { $0 as any Error })
                    } else {
                        waiter = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                self.finish(.failure(.cancelled))
            }
        } catch let error as MCPError {
            throw error
        } catch {
            throw .cancelled
        }
    }

    public func cancel() {
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<[String: String], MCPError>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        timeoutTask?.cancel()
        listener.newConnectionHandler = nil
        listener.cancel()
        // The answer to the callback is already queued: let it go out, then close every connection.
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            let open = lock.withLock {
                defer { connections = [:] }
                return Array(connections.values)
            }
            open.forEach { $0.cancel() }
        }
        waiter?.resume(with: result.mapError { $0 as any Error })
    }

    // MARK: - Connections

    private func handle(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let accepted = lock.withLock { () -> Bool in
            guard outcome == nil, connections.count < Self.maxConnections else { return false }
            connections[id] = connection
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.lock.withLock { _ = self?.connections.removeValue(forKey: id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A connection that never sends its request does not hold a slot for long.
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = CallbackRequest.parse(buffer) {
                self.respond(to: request, on: connection)
            } else if error != nil || isComplete || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: CallbackRequest, on connection: NWConnection) {
        guard request.path == "/callback" else {
            send(status: "404 Not Found", body: "Not found", on: connection)
            return
        }
        guard request.method == "GET" else {
            send(status: "405 Method Not Allowed", body: "Method not allowed", on: connection)
            return
        }
        guard let state = request.query["state"], Self.constantTimeEqual(state, expectedState) else {
            send(status: "400 Bad Request", body: "This is not the sign-in TicketPilot is waiting for.", on: connection)
            return
        }
        // Neutral: the code is not exchanged yet, and Atlassian may have refused. The app tells the outcome.
        let message = "Return to TicketPilot to finish signing in. You can close this tab."
        let page = """
        <!doctype html><html><head><meta charset="utf-8"><title>TicketPilot</title></head>\
        <body style="font-family: -apple-system, sans-serif; margin: 4em; text-align: center">\
        <p>\(message)</p></body></html>
        """
        send(status: "200 OK", body: page, contentType: "text/html; charset=utf-8", on: connection)
        finish(.success(request.query))
    }

    private func send(status: String, body: String, contentType: String = "text/plain; charset=utf-8", on connection: NWConnection) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

extension LoopbackCallbackServer {
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Lets the listener's connection handler reach the server created after it.
private final class ServerBox: @unchecked Sendable {
    weak var server: LoopbackCallbackServer?
}

/// True the first time only.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
