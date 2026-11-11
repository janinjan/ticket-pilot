import Foundation
import Testing
@testable import TicketPilotCore

struct LoopbackCallbackServerTests {
    @Test func test_parsesTheRequestLine() {
        let head = "GET /callback?code=a%20b&state=s-1 HTTP/1.1\r\nHost: 127.0.0.1:5555\r\n\r\n"
        #expect(CallbackRequest.parse(Data(head.utf8)) == CallbackRequest(
            method: "GET", path: "/callback", query: ["code": "a b", "state": "s-1"]
        ))
    }

    @Test func test_waitsForTheEndOfTheHeaders() {
        #expect(CallbackRequest.parse(Data("GET /callback?code=a HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
    }

    @Test func test_answersTheBrowserAndHandsBackTheQuery() async throws {
        let server = try await LoopbackCallbackServer.start(expectedState: "s-1")
        #expect(server.port > 0)
        let waiting = Task { try await server.waitForCallback() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/callback?code=c-1&state=s-1")!
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Return to TicketPilot to finish signing in"))
        #expect(try await waiting.value == ["code": "c-1", "state": "s-1"])
    }

    @Test func test_otherPathsAreNotTheCallback() async throws {
        let server = try await LoopbackCallbackServer.start(expectedState: "s")
        defer { server.cancel() }
        let session = URLSession(configuration: .ephemeral)
        let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(server.port)/favicon.ico")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)

        let waiting = Task { try await server.waitForCallback() }
        _ = try await session.data(from: URL(string: "http://127.0.0.1:\(server.port)/callback?state=s")!)
        #expect(try await waiting.value == ["state": "s"])
    }

    @Test func test_aWrongStateIsRefusedAndTheListenerKeepsWaiting() async throws {
        let server = try await LoopbackCallbackServer.start(expectedState: "s-1")
        let waiting = Task { try await server.waitForCallback() }
        let session = URLSession(configuration: .ephemeral)
        for query in ["code=evil&state=other", "code=evil", "error=access_denied"] {
            let url = URL(string: "http://127.0.0.1:\(server.port)/callback?\(query)")!
            let (data, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 400)
            #expect(!String(decoding: data, as: UTF8.self).contains("Return to TicketPilot"))
        }
        let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(server.port)/callback?code=c-1&state=s-1")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await waiting.value == ["code": "c-1", "state": "s-1"])
    }

    @Test func test_onlyAGetEndsTheSignIn() async throws {
        let server = try await LoopbackCallbackServer.start(expectedState: "s-1")
        defer { server.cancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/callback?code=c&state=s-1")!)
        request.httpMethod = "POST"
        request.httpBody = Data("x".utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 405)

        let waiting = Task { try await server.waitForCallback() }
        _ = try await URLSession(configuration: .ephemeral)
            .data(from: URL(string: "http://127.0.0.1:\(server.port)/callback?code=c&state=s-1")!)
        #expect(try await waiting.value == ["code": "c", "state": "s-1"])
    }

    @Test func test_portZeroIsAFailure() throws {
        #expect(throws: MCPError.self) { try LoopbackCallbackServer.validatedPort(0) }
        #expect(throws: MCPError.self) { try LoopbackCallbackServer.validatedPort(nil) }
        #expect(try LoopbackCallbackServer.validatedPort(5555) == 5555)
    }

    @Test func test_stateComparison() {
        #expect(LoopbackCallbackServer.constantTimeEqual("abc", "abc"))
        #expect(!LoopbackCallbackServer.constantTimeEqual("abc", "abd"))
        #expect(!LoopbackCallbackServer.constantTimeEqual("abc", "abcd"))
    }

    @Test func test_timesOut() async throws {
        let server = try await LoopbackCallbackServer.start(expectedState: "s", timeout: .milliseconds(50))
        await #expect(throws: MCPError.timedOut) {
            try await server.waitForCallback()
        }
    }

    @Test func test_cancelStopsWaiting() async throws {
        let server = try await LoopbackCallbackServer.start(expectedState: "s")
        let waiting = Task { try await server.waitForCallback() }
        server.cancel()
        await #expect(throws: MCPError.cancelled) {
            try await waiting.value
        }
    }

    @Test func test_cancellingTheTaskStopsWaiting() async throws {
        let server = try await LoopbackCallbackServer.start(expectedState: "s")
        let waiting = Task { try await server.waitForCallback() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: MCPError.cancelled) {
            try await waiting.value
        }
    }

    @Test func test_signInEndToEndWithAStubServer() async throws {
        let transport = StubTransport { request in
            switch request.url!.path {
            case "/.well-known/oauth-authorization-server":
                return (200, [:], Data(AtlassianMCPAuthTests.metadataJSON.utf8))
            case "/v1/register":
                return (201, [:], Data(#"{"client_id":"client-new"}"#.utf8))
            case "/v1/token":
                return (200, [:], Data(#"{"access_token":"access-new","expires_in":3600,"refresh_token":"r"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }
        let store = MemoryCredentialStore()
        let auth = AtlassianMCPAuth(server: AtlassianMCPAuthTests.server, store: store, transport: transport)
        let signIn = try await auth.beginSignIn()
        let items = URLComponents(url: signIn.authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = try #require(items.first { $0.name == "state" }?.value)
        let redirect = try #require(items.first { $0.name == "redirect_uri" }?.value)
        #expect(redirect.hasPrefix("http://127.0.0.1:"))
        #expect(redirect.hasSuffix("/callback"))

        let completing = Task { try await auth.completeSignIn(signIn) }
        _ = try await URLSession(configuration: .ephemeral).data(from: URL(string: "\(redirect)?code=c-1&state=\(state)")!)
        let credentials = try await completing.value

        #expect(credentials.accessToken == "access-new")
        #expect(credentials.clientID == "client-new")
        #expect(store.current == credentials)
        #expect(formFields(try #require(transport.requests.last))["code"] == "c-1")
    }
}
