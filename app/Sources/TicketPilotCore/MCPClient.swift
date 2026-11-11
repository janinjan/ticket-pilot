import Foundation

/// A JSON value that can cross actors: the arguments of a tool call.
public enum JSONValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    var foundation: Any {
        switch self {
        case let .string(value): value
        case let .int(value): value
        case let .bool(value): value
        case let .array(values): values.map(\.foundation)
        case let .object(members): members.mapValues(\.foundation)
        }
    }
}

/// Where the MCP client gets its bearer token.
public protocol MCPAccessTokenProviding: Sendable {
    func accessToken() async throws(MCPError) -> String
    /// A new token, after the server refused the current one.
    func refreshedAccessToken() async throws(MCPError) -> String
}

extension AtlassianMCPAuth: MCPAccessTokenProviding {}

/// A tool of the server, with the names of its arguments.
public struct MCPTool: Equatable, Sendable {
    public var name: String
    public var properties: [String]

    public init(name: String, properties: [String]) {
        self.name = name
        self.properties = properties
    }
}

public struct MCPToolResult: Equatable, Sendable {
    /// The text of each `text` content item.
    public var texts: [String]
    /// `structuredContent`, serialized, when the server sent one.
    public var structured: Data?
    public var isError: Bool
}

/// The `data` of each event of a `text/event-stream` body.
public enum ServerSentEvents {
    public static func messages(in data: Data) -> [Data] {
        let text = String(decoding: data, as: UTF8.self)
        var messages: [Data] = []
        var lines: [String] = []
        func dispatch() {
            if !lines.isEmpty {
                messages.append(Data(lines.joined(separator: "\n").utf8))
            }
            lines = []
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                dispatch()
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst("data:".count)
                if value.hasPrefix(" ") { value = value.dropFirst() }
                lines.append(String(value))
            }
        }
        dispatch()
        return messages
    }
}

/// What the Jira client needs of an MCP client.
public protocol MCPToolCalling: Sendable {
    func listTools() async throws(MCPError) -> [MCPTool]
    func callTool(_ name: String, arguments: [String: JSONValue]) async throws(MCPError) -> MCPToolResult
}

/// A minimal MCP client over Streamable HTTP (protocol 2025-06-18): `initialize`, `tools/list`,
/// `tools/call`. Keeps the server's session id; on a 401 refreshes the token once, then reports
/// `.unauthorized`. Never logs a token.
public actor MCPClient: MCPToolCalling {
    public static let protocolVersion = "2025-06-18"

    private let url: URL
    private let tokens: MCPAccessTokenProviding
    private let transport: HTTPTransport
    private let clientVersion: String
    private var sessionID: String?
    private var negotiatedVersion: String?
    private var initialized = false
    private var initializing: Task<Void, any Error>?
    private var nextID = 1
    private var tools: [MCPTool]?

    public init(
        url: URL = AtlassianMCPAuth.defaultServer,
        tokens: MCPAccessTokenProviding,
        transport: HTTPTransport = URLSessionTransport(),
        clientVersion: String = "1.0"
    ) {
        self.url = url
        self.tokens = tokens
        self.transport = transport
        self.clientVersion = clientVersion
    }

    /// Every tool of the server, read once.
    public func listTools() async throws(MCPError) -> [MCPTool] {
        if let tools { return tools }
        var found: [MCPTool] = []
        var cursor: String?
        repeat {
            let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
            let result = try await request("tools/list", params: params)
            for tool in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = tool["name"] as? String else { continue }
                let schema = tool["inputSchema"] as? [String: Any]
                let properties = (schema?["properties"] as? [String: Any]).map { $0.keys.sorted() } ?? []
                found.append(MCPTool(name: name, properties: properties))
            }
            cursor = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while cursor != nil && found.count < 10_000
        tools = found
        return found
    }

    public func callTool(_ name: String, arguments: [String: JSONValue]) async throws(MCPError) -> MCPToolResult {
        let result = try await request("tools/call", params: [
            "name": name,
            "arguments": arguments.mapValues(\.foundation),
        ])
        let content = result["content"] as? [[String: Any]] ?? []
        let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        let structured = (result["structuredContent"]).flatMap { value -> Data? in
            JSONSerialization.isValidJSONObject(value) ? try? JSONSerialization.data(withJSONObject: value) : nil
        }
        return MCPToolResult(texts: texts, structured: structured, isError: result["isError"] as? Bool ?? false)
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, params: [String: Any]) async throws(MCPError) -> [String: Any] {
        try await ensureInitialized()
        do {
            return try await rpc(method, params: params)
        } catch .http(status: 404) where sessionID != nil {
            // The server forgot the session: start a new one, once.
            sessionID = nil
            initialized = false
            try await ensureInitialized()
            return try await rpc(method, params: params)
        }
    }

    /// Concurrent callers share one handshake.
    private func ensureInitialized() async throws(MCPError) {
        guard !initialized else { return }
        if let initializing {
            do {
                return try await initializing.value
            } catch let error as MCPError {
                throw error
            } catch {
                throw .unreachable
            }
        }
        let task = Task<Void, any Error> { try await self.initialize() }
        initializing = task
        defer { initializing = nil }
        do {
            try await task.value
        } catch let error as MCPError {
            throw error
        } catch {
            throw .unreachable
        }
    }

    private func initialize() async throws(MCPError) {
        guard !initialized else { return }
        sessionID = nil
        negotiatedVersion = nil
        let result = try await rpc("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "TicketPilot", "version": clientVersion],
        ])
        negotiatedVersion = result["protocolVersion"] as? String ?? Self.protocolVersion
        // A notification gets no answer worth reading: its body is dropped unread.
        _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
        initialized = true
    }

    /// The most an answer may weigh.
    static let maxResponseBytes = 5 * 1024 * 1024

    private func rpc(_ method: String, params: [String: Any]) async throws(MCPError) -> [String: Any] {
        let id = nextID
        nextID += 1
        let (response, body) = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        if method == "initialize", let session = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty {
            sessionID = session
        }
        let isStream = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") ?? false
        var buffer = Data()
        var scanned = 0
        do {
            for try await chunk in body {
                buffer.append(chunk)
                guard buffer.count <= Self.maxResponseBytes else { throw MCPError.responseTooLarge }
                // An event stream may stay open after the answer (pings, other messages): stop at the answer.
                guard isStream, let end = Self.lastEventEnd(in: buffer, from: scanned) else { continue }
                if let message = Self.message(withID: id, in: ServerSentEvents.messages(in: buffer[scanned..<end])) {
                    return try Self.result(of: message)
                }
                scanned = end
            }
        } catch let error as MCPError {
            throw error
        } catch {
            throw .unreachable
        }
        let rest = Data(buffer[scanned...])
        let candidates = isStream ? ServerSentEvents.messages(in: rest) : [rest]
        guard let message = Self.message(withID: id, in: candidates) else { throw .invalidResponse }
        return try Self.result(of: message)
    }

    /// The end of the last complete event (after its blank line) in `buffer[from...]`, if any.
    private static func lastEventEnd(in buffer: Data, from start: Int) -> Int? {
        let bytes = buffer[start...]
        var end: Int?
        var previous: UInt8?
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\n"), previous == UInt8(ascii: "\n") {
                end = index + 1
            }
            if byte != UInt8(ascii: "\r") { previous = byte }
            index += 1
        }
        return end
    }

    private static func message(withID id: Int, in candidates: [Data]) -> [String: Any]? {
        for candidate in candidates {
            guard let json = try? JSONSerialization.jsonObject(with: candidate) else { continue }
            let messages = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            if let message = messages.first(where: { ($0["id"] as? Int) == id }) { return message }
        }
        return nil
    }

    private static func result(of message: [String: Any]) throws(MCPError) -> [String: Any] {
        if let error = message["error"] as? [String: Any] {
            throw .rpc(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? "Unknown error")
        }
        guard let result = message["result"] as? [String: Any] else { throw .invalidResponse }
        return result
    }

    /// POSTs one JSON-RPC message; refreshes the token once on a 401. A 2xx body is left to the caller.
    private func post(_ message: [String: Any]) async throws(MCPError) -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { throw .invalidResponse }
        var token = try await tokens.accessToken()
        var refreshed = false
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
            let response: HTTPURLResponse
            let stream: AsyncThrowingStream<Data, any Error>
            do {
                (response, stream) = try await transport.open(request)
            } catch {
                throw .unreachable
            }
            switch response.statusCode {
            case 200..<300:
                return (response, stream)
            case 401 where !refreshed:
                refreshed = true
                token = try await tokens.refreshedAccessToken()
            case 401:
                throw .unauthorized
            case 403:
                let data = await Self.prefix(of: stream, limit: 65_536)
                throw Self.serverMessage(in: data).map(MCPError.authorizationFailed) ?? .http(status: 403)
            default:
                throw .http(status: response.statusCode)
            }
        }
    }

    /// The first `limit` bytes of an error body; the rest is not read.
    private static func prefix(of stream: AsyncThrowingStream<Data, any Error>, limit: Int) async -> Data {
        var data = Data()
        do {
            for try await chunk in stream {
                data.append(chunk)
                if data.count >= limit { break }
            }
        } catch {}
        return data.prefix(limit)
    }

    /// The explanation of an OAuth or JSON-RPC error body.
    private static func serverMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.count > 500 ? nil : text
        }
        if let description = object["error_description"] as? String { return description }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return (object["message"] as? String) ?? (object["error"] as? String)
    }
}
