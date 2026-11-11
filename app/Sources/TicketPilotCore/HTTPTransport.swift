import Foundation

/// Sends one HTTP request; injectable so the Atlassian MCP code is tested without a network.
public protocol HTTPTransport: Sendable {
    /// A whole, small body (OAuth documents and token answers).
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// The body as it arrives, for an answer that may be a long-lived event stream: the reader stops as
    /// soon as it has what it needs, which ends the request.
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>)
}

extension HTTPTransport {
    /// The whole body as one chunk.
    public func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let (data, response) = try await send(request)
        return (response, AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        })
    }
}

/// The real transport. Its responses are never cached, and no request lasts more than two minutes.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            let reader = Task {
                do {
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        // A line at a time, so an event is seen as soon as it ends.
                        if byte == UInt8(ascii: "\n") || chunk.count >= 16_384 {
                            continuation.yield(chunk)
                            chunk = Data()
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                bytes.task.cancel()
            }
        }
        return (http, stream)
    }
}

/// What can go wrong between TicketPilot and the Atlassian MCP server. Never carries a token.
public enum MCPError: Error, Equatable, Sendable {
    /// No Atlassian sign-in is stored.
    case notConnected
    /// The server refused the access token, even after a refresh.
    case unauthorized
    case unreachable
    case http(status: Int)
    case invalidResponse
    /// The answer grew past its limit.
    case responseTooLarge
    /// The server lacks what TicketPilot needs (client registration, PKCE S256).
    case unsupportedServer(String)
    /// The sign-in was refused; the server's own words (an administrator block, a denied consent).
    case authorizationFailed(String)
    /// The browser came back with another sign-in's state.
    case stateMismatch
    /// The sign-in did not come back within five minutes.
    case timedOut
    case cancelled
    /// A JSON-RPC error.
    case rpc(code: Int, message: String)
    /// A tool answered with an error; its text.
    case tool(String)
    case keychain(OSStatus)
}

extension MCPError {
    /// A sentence for an alert.
    public var message: String {
        switch self {
        case .notConnected: "TicketPilot is not connected to Atlassian."
        case .unauthorized: "Atlassian refused the sign-in. Connect Jira again."
        case .unreachable: "Atlassian can't be reached. Check your network."
        case let .http(status): "Atlassian answered unexpectedly (HTTP \(status))."
        case .invalidResponse: "Atlassian answered unexpectedly."
        case .responseTooLarge: "Atlassian sent a larger answer than expected."
        case let .unsupportedServer(reason): reason
        case let .authorizationFailed(reason): reason
        case .stateMismatch: "The sign-in came back from another attempt. Try again."
        case .timedOut: "The sign-in took longer than five minutes. Try again."
        case .cancelled: "The sign-in was cancelled."
        case let .rpc(_, message): message
        case let .tool(text): text
        case let .keychain(status): "The Keychain refused access (status \(status))."
        }
    }
}
