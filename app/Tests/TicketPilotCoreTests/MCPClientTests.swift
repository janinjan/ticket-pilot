import Foundation
import Testing
@testable import TicketPilotCore

/// Hands out "token-1", then "token-2" once refreshed.
final class FakeTokens: MCPAccessTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var token = "token-1"
    private var refreshCount = 0
    private let refreshError: MCPError?

    init(refreshError: MCPError? = nil) {
        self.refreshError = refreshError
    }

    var refreshes: Int { lock.withLock { refreshCount } }

    func accessToken() async throws(MCPError) -> String {
        lock.withLock { token }
    }

    func refreshedAccessToken() async throws(MCPError) -> String {
        if let refreshError { throw refreshError }
        return lock.withLock {
            refreshCount += 1
            token = "token-\(refreshCount + 1)"
            return token
        }
    }
}

/// A Streamable HTTP MCP server: answers `initialize`, `tools/list` and `tools/call` from a table.
func rpcBody(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
}

func rpcResult(_ request: URLRequest, _ result: String) -> Data {
    let id = rpcBody(request)["id"] as? Int ?? 0
    return Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)
}

let initializeResult = #"""
{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"stub","version":"1"}}
"""#

struct MCPClientTests {
    static let url = URL(string: "https://mcp.example.com/v1/mcp")!

    private func standardServer(
        sse: Bool = false,
        tool: @escaping @Sendable ([String: Any]) -> String = { _ in #"{"content":[{"type":"text","text":"ok"}]}"# }
    ) -> StubTransport {
        StubTransport { request in
            let body = rpcBody(request)
            let headers = sse ? ["Content-Type": "text/event-stream"] : ["Content-Type": "application/json"]
            func wrap(_ data: Data) -> Data {
                sse ? Data("event: message\ndata: ".utf8) + data + Data("\n\n".utf8) : data
            }
            switch body["method"] as? String {
            case "initialize":
                var withSession = headers
                withSession["Mcp-Session-Id"] = "session-1"
                return (200, withSession, wrap(rpcResult(request, initializeResult)))
            case "notifications/initialized":
                return (202, [:], Data())
            case "tools/list":
                let tools = #"{"tools":[{"name":"searchJiraIssuesUsingJql","inputSchema":{"type":"object","properties":{"cloudId":{"type":"string"},"jql":{"type":"string"}},"required":["cloudId","jql"]}}]}"#
                return (200, headers, wrap(rpcResult(request, tools)))
            case "tools/call":
                return (200, headers, wrap(rpcResult(request, tool(body["params"] as? [String: Any] ?? [:]))))
            default:
                return (400, [:], Data())
            }
        }
    }

    @Test func test_handshakeThenCallsTheTool() async throws {
        let transport = standardServer()
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        let result = try await client.callTool("atlassianUserInfo", arguments: [:])

        #expect(result.texts == ["ok"])
        #expect(!result.isError)
        let methods = transport.requests.map { rpcBody($0)["method"] as? String }
        #expect(methods == ["initialize", "notifications/initialized", "tools/call"])
        let initialize = transport.requests[0]
        #expect(initialize.httpMethod == "POST")
        #expect(initialize.value(forHTTPHeaderField: "Accept") == "application/json, text/event-stream")
        #expect(initialize.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(initialize.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(initialize.value(forHTTPHeaderField: "Mcp-Session-Id") == nil)
        let params = try #require(rpcBody(initialize)["params"] as? [String: Any])
        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect((params["clientInfo"] as? [String: Any])?["name"] as? String == "TicketPilot")
        #expect(rpcBody(transport.requests[1])["id"] == nil)
        for request in transport.requests.dropFirst() {
            #expect(request.value(forHTTPHeaderField: "Mcp-Session-Id") == "session-1")
            #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")
        }
        let call = try #require(rpcBody(transport.requests[2])["params"] as? [String: Any])
        #expect(call["name"] as? String == "atlassianUserInfo")
    }

    @Test func test_initializesOnce() async throws {
        let transport = standardServer()
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        _ = try await client.callTool("a", arguments: [:])
        _ = try await client.callTool("b", arguments: [:])
        #expect(transport.requests.count == 4)
    }

    @Test func test_readsAnEventStreamAnswer() async throws {
        let transport = standardServer(sse: true)
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        let tools = try await client.listTools()
        #expect(tools == [MCPTool(name: "searchJiraIssuesUsingJql", properties: ["cloudId", "jql"])])
    }

    @Test func test_passesTheArguments() async throws {
        let transport = standardServer()
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        _ = try await client.callTool("t", arguments: [
            "jql": "key in (ABC-1)", "maxResults": 100, "fields": ["summary", "status"],
        ])
        let params = try #require(rpcBody(transport.requests[2])["params"] as? [String: Any])
        let arguments = try #require(params["arguments"] as? [String: Any])
        #expect(arguments["jql"] as? String == "key in (ABC-1)")
        #expect(arguments["maxResults"] as? Int == 100)
        #expect(arguments["fields"] as? [String] == ["summary", "status"])
    }

    @Test func test_toolErrorIsReturnedAsSuch() async throws {
        let transport = standardServer { _ in #"{"content":[{"type":"text","text":"Site not found"}],"isError":true}"# }
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        let result = try await client.callTool("t", arguments: [:])
        #expect(result.isError)
        #expect(result.texts == ["Site not found"])
    }

    @Test func test_rpcErrorKeepsItsMessage() async {
        let transport = StubTransport { request in
            let id = rpcBody(request)["id"] as? Int ?? 0
            return (200, ["Content-Type": "application/json"],
                    Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32603,"message":"Boom"}}"#.utf8))
        }
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        await #expect(throws: MCPError.rpc(code: -32603, message: "Boom")) {
            try await client.listTools()
        }
    }

    @Test func test_unauthorizedRefreshesOnceThenRetries() async throws {
        let tokens = FakeTokens()
        let inner = standardServer()
        let transport = StubTransport { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1" {
                return (401, ["WWW-Authenticate": #"Bearer realm="OAuth", error="invalid_token""#], Data())
            }
            return try inner.handlerForTests(request)
        }
        let client = MCPClient(url: Self.url, tokens: tokens, transport: transport)
        let result = try await client.callTool("t", arguments: [:])
        #expect(result.texts == ["ok"])
        #expect(tokens.refreshes == 1)
    }

    @Test func test_stillUnauthorizedAfterRefreshIsReported() async {
        let tokens = FakeTokens()
        let transport = StubTransport { _ in (401, [:], Data()) }
        let client = MCPClient(url: Self.url, tokens: tokens, transport: transport)
        await #expect(throws: MCPError.unauthorized) {
            try await client.listTools()
        }
        #expect(tokens.refreshes == 1)
    }

    @Test func test_refusedRefreshIsReported() async {
        let transport = StubTransport { _ in (401, [:], Data()) }
        let client = MCPClient(url: Self.url, tokens: FakeTokens(refreshError: .unauthorized), transport: transport)
        await #expect(throws: MCPError.unauthorized) {
            try await client.listTools()
        }
    }

    @Test func test_forbiddenKeepsTheServerMessage() async {
        let transport = StubTransport { _ in
            (403, ["Content-Type": "application/json"],
             Data(#"{"error":"access_denied","error_description":"Your organization admin has blocked this app"}"#.utf8))
        }
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        await #expect(throws: MCPError.authorizationFailed("Your organization admin has blocked this app")) {
            try await client.listTools()
        }
    }

    @Test func test_expiredSessionIsStartedAgain() async throws {
        let inner = standardServer()
        let expired = ExpiredOnce()
        let transport = StubTransport { request in
            if rpcBody(request)["method"] as? String == "tools/call",
               request.value(forHTTPHeaderField: "Mcp-Session-Id") == "session-1",
               expired.take() {
                return (404, [:], Data())
            }
            return try inner.handlerForTests(request)
        }
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        _ = try await client.callTool("a", arguments: [:])
        _ = try await client.callTool("b", arguments: [:])
        let methods = transport.requests.map { rpcBody($0)["method"] as? String }
        #expect(methods == [
            "initialize", "notifications/initialized", "tools/call",
            "initialize", "notifications/initialized", "tools/call", "tools/call",
        ])
    }

    @Test func test_networkFailureIsUnreachable() async {
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        await #expect(throws: MCPError.unreachable) {
            try await client.listTools()
        }
    }

    @Test func test_concurrentCallsShareOneHandshake() async throws {
        let transport = standardServer()
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        async let first = client.callTool("a", arguments: [:])
        async let second = client.callTool("b", arguments: [:])
        _ = try await (first, second)
        let methods = transport.requests.map { rpcBody($0)["method"] as? String }
        #expect(methods.filter { $0 == "initialize" }.count == 1)
    }

    @Test func test_stopsReadingAStreamThatStaysOpenOnceTheAnswerArrived() async throws {
        let transport = StreamingTransport { request, continuation in
            switch rpcBody(request)["method"] as? String {
            case "notifications/initialized":
                continuation.finish()
                return (202, [:])
            case "initialize":
                continuation.yield(Data("data: ".utf8) + rpcResult(request, initializeResult) + Data("\n\n".utf8))
            default:
                continuation.yield(Data(": ping\n\n".utf8))
                continuation.yield(Data("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n".utf8))
                continuation.yield(Data("data: ".utf8))
                continuation.yield(rpcResult(request, #"{"content":[{"type":"text","text":"ok"}]}"#))
                continuation.yield(Data("\n\n: ping\n\n".utf8))
            }
            // Never finished: the server keeps the stream open.
            return (200, ["Content-Type": "text/event-stream"])
        }
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        let result = try await client.callTool("t", arguments: [:])
        #expect(result.texts == ["ok"])
    }

    @Test func test_anOversizeStreamIsRefused() async {
        let transport = StreamingTransport { request, continuation in
            if rpcBody(request)["method"] as? String == "initialize" {
                continuation.yield(Data("data: ".utf8) + rpcResult(request, initializeResult) + Data("\n\n".utf8))
                return (200, ["Content-Type": "text/event-stream"])
            }
            if rpcBody(request)["method"] as? String == "notifications/initialized" {
                continuation.finish()
                return (202, [:])
            }
            let ping = Data(repeating: UInt8(ascii: "x"), count: 1024 * 1024)
            for _ in 0..<8 { continuation.yield(Data("data: ".utf8) + ping) }
            return (200, ["Content-Type": "text/event-stream"])
        }
        let client = MCPClient(url: Self.url, tokens: FakeTokens(), transport: transport)
        await #expect(throws: MCPError.responseTooLarge) {
            try await client.listTools()
        }
    }

    @Test func test_sseParserJoinsDataLinesAndSkipsComments() {
        let stream = ": ping\r\nevent: message\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\nid: 2\ndata:{\"b\":2}\n"
        let messages = ServerSentEvents.messages(in: Data(stream.utf8)).map { String(decoding: $0, as: UTF8.self) }
        #expect(messages == ["{\"a\":\n1}", "{\"b\":2}"])
    }
}

/// True the first time only.
final class ExpiredOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func take() -> Bool {
        lock.withLock {
            defer { used = true }
            return !used
        }
    }
}

/// Answers with a stream the handler feeds, and may leave open.
final class StreamingTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, AsyncThrowingStream<Data, any Error>.Continuation) -> (Int, [String: String])

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }

    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (status, headers) = handler(request, continuation)
        return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, stream)
    }
}
