import Foundation
import Testing
@testable import TicketPilotCore

/// Answers each request with a per-test handler that can set response headers.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)

    private let lock = NSLock()
    private var log: [URLRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    private func record(_ request: URLRequest) {
        lock.withLock { log.append(request) }
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// Answers like this transport, without logging: for a transport wrapping it.
    func handlerForTests(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        try handler(request)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (status, headers, data) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (data, response)
    }
}

/// Keeps the credentials in memory instead of the Keychain.
final class MemoryCredentialStore: MCPCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MCPCredentials?
    private(set) var saves = 0

    init(_ credentials: MCPCredentials? = nil) {
        stored = credentials
    }

    var current: MCPCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func load() throws(MCPError) -> MCPCredentials? {
        current
    }

    /// The next saves to refuse, as a locked Keychain would.
    var failingSaves = 0

    func save(_ credentials: MCPCredentials) throws(MCPError) {
        lock.lock()
        defer { lock.unlock() }
        saves += 1
        if failingSaves > 0 {
            failingSaves -= 1
            throw .keychain(-25308)
        }
        stored = credentials
    }

    func delete() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}

func formFields(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var components = URLComponents()
    components.percentEncodedQuery = body
    return Dictionary(
        (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { first, _ in first }
    )
}

struct AtlassianMCPAuthTests {
    static let server = URL(string: "https://mcp.example.com/v1/mcp")!

    /// The authorization server metadata as the Atlassian MCP server publishes it.
    static let metadataJSON = """
    {"issuer":"https://mcp.example.com","authorization_endpoint":"https://mcp.example.com/v1/authorize",\
    "token_endpoint":"https://mcp.example.com/v1/token","registration_endpoint":"https://mcp.example.com/v1/register",\
    "response_types_supported":["code"],"response_modes_supported":["query"],\
    "grant_types_supported":["authorization_code","refresh_token"],\
    "token_endpoint_auth_methods_supported":["client_secret_basic","client_secret_post","none"],\
    "revocation_endpoint":"https://mcp.example.com/v1/token","code_challenge_methods_supported":["plain","S256"]}
    """

    static func metadata() throws -> AuthorizationServerMetadata {
        try AuthorizationServerMetadata.parse(Data(metadataJSON.utf8))
    }

    static func credentials(expiresAt: Date?, refreshToken: String? = "refresh-1") -> MCPCredentials {
        MCPCredentials(
            server: server.absoluteString,
            clientID: "client-1",
            tokenEndpoint: "https://mcp.example.com/v1/token",
            accessToken: "access-1",
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    // MARK: - Metadata

    @Test func test_parsesAuthorizationServerMetadata() throws {
        let metadata = try Self.metadata()
        #expect(metadata.authorizationEndpoint.absoluteString == "https://mcp.example.com/v1/authorize")
        #expect(metadata.tokenEndpoint.absoluteString == "https://mcp.example.com/v1/token")
        #expect(metadata.registrationEndpoint?.absoluteString == "https://mcp.example.com/v1/register")
        #expect(metadata.supportsS256)
    }

    @Test func test_metadataWithoutTheEndpointsIsInvalid() {
        #expect(throws: MCPError.invalidResponse) {
            try AuthorizationServerMetadata.parse(Data(#"{"issuer":"https://x"}"#.utf8))
        }
    }

    @Test func test_parsesProtectedResourceMetadata() throws {
        let json = #"{"resource":"https://mcp.example.com/v1/mcp","authorization_servers":["https://auth.example.com"]}"#
        let metadata = try ProtectedResourceMetadata.parse(Data(json.utf8))
        #expect(metadata.resource == "https://mcp.example.com/v1/mcp")
        #expect(metadata.authorizationServers.map(\.absoluteString) == ["https://auth.example.com"])
    }

    @Test func test_readsResourceMetadataFromWWWAuthenticate() {
        let header = #"Bearer realm="OAuth", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", error="invalid_token""#
        #expect(
            WWWAuthenticate.resourceMetadataURL(in: header)?.absoluteString
                == "https://mcp.example.com/.well-known/oauth-protected-resource"
        )
        #expect(WWWAuthenticate.resourceMetadataURL(in: #"Bearer realm="OAuth", error="invalid_token""#) == nil)
    }

    @Test func test_wellKnownURLsInsertThePathAfterTheOrigin() {
        #expect(
            WellKnown.urls(for: "oauth-protected-resource", of: Self.server).map(\.absoluteString) == [
                "https://mcp.example.com/.well-known/oauth-protected-resource/v1/mcp",
                "https://mcp.example.com/.well-known/oauth-protected-resource",
            ]
        )
        #expect(
            WellKnown.urls(for: "oauth-authorization-server", of: URL(string: "https://mcp.example.com")!)
                .map(\.absoluteString) == ["https://mcp.example.com/.well-known/oauth-authorization-server"]
        )
    }

    // MARK: - PKCE and the authorize URL

    @Test func test_pkceChallengeIsTheS256OfTheVerifier() {
        // RFC 7636, appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func test_randomVerifierIsLongAndURLSafe() {
        let first = PKCE.random()
        let second = PKCE.random()
        #expect(first.verifier != second.verifier)
        #expect((43...128).contains(first.verifier.count))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(first.verifier.unicodeScalars.allSatisfy(allowed.contains))
    }

    @Test func test_authorizeURLCarriesPKCEAndState() throws {
        let url = AuthorizeRequest(
            endpoint: try Self.metadata().authorizationEndpoint,
            clientID: "client-1",
            redirectURI: "http://127.0.0.1:5555/callback",
            challenge: "challenge",
            state: "state-1",
            resource: nil
        ).url
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(components.host == "mcp.example.com")
        #expect(components.path == "/v1/authorize")
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "client-1")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5555/callback")
        #expect(items["code_challenge"] == "challenge")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "state-1")
        #expect(items["resource"] == nil)
    }

    @Test func test_authorizeURLNamesTheResourceWhenKnown() throws {
        let url = AuthorizeRequest(
            endpoint: try Self.metadata().authorizationEndpoint,
            clientID: "c", redirectURI: "http://127.0.0.1:1/callback", challenge: "x", state: "s",
            resource: "https://mcp.example.com/v1/mcp"
        ).url
        #expect(url.absoluteString.contains("resource=https://mcp.example.com/v1/mcp"))
    }

    // MARK: - Tokens

    @Test func test_parsesTokenResponse() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let json = #"{"access_token":"a","token_type":"bearer","expires_in":3600,"refresh_token":"r","scope":""}"#
        let tokens = try TokenResponse.parse(Data(json.utf8), status: 200)
        #expect(tokens.accessToken == "a")
        #expect(tokens.refreshToken == "r")
        #expect(tokens.expiresAt(now: now) == Date(timeIntervalSince1970: 4_600))
    }

    @Test func test_tokenErrorKeepsTheServerMessage() {
        let json = #"{"error":"invalid_grant","error_description":"Refresh token expired"}"#
        #expect(throws: MCPError.authorizationFailed("Refresh token expired")) {
            try TokenResponse.parse(Data(json.utf8), status: 400)
        }
    }

    @Test func test_expiryHasALeeway() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(!Self.credentials(expiresAt: now.addingTimeInterval(120)).isExpired(now: now))
        #expect(Self.credentials(expiresAt: now.addingTimeInterval(30)).isExpired(now: now))
        #expect(Self.credentials(expiresAt: now.addingTimeInterval(-1)).isExpired(now: now))
        #expect(!Self.credentials(expiresAt: nil).isExpired(now: now))
    }

    @Test func test_credentialsRoundTripAsOneJSONItem() throws {
        let credentials = Self.credentials(expiresAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(credentials)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys).isSuperset(of: ["client_id", "access_token", "refresh_token", "expires_at", "server"]))
        #expect(try JSONDecoder().decode(MCPCredentials.self, from: data) == credentials)
    }

    // MARK: - Discovery, registration, exchange

    private func discoveryTransport(prm: Bool = false, registration: Bool = true) -> StubTransport {
        StubTransport { request in
            let url = request.url!.absoluteString
            switch url {
            case "https://mcp.example.com/.well-known/oauth-protected-resource/v1/mcp",
                 "https://mcp.example.com/.well-known/oauth-protected-resource":
                guard prm else { return (404, [:], Data("Not Found".utf8)) }
                let json = #"{"resource":"https://mcp.example.com/v1/mcp","authorization_servers":["https://mcp.example.com"]}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            case "https://mcp.example.com/.well-known/oauth-authorization-server":
                var json = Self.metadataJSON
                if !registration {
                    json = json.replacingOccurrences(
                        of: #""registration_endpoint":"https://mcp.example.com/v1/register","#, with: ""
                    )
                }
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            case "https://mcp.example.com/v1/register":
                return (201, [:], Data(#"{"client_id":"client-new","token_endpoint_auth_method":"none"}"#.utf8))
            case "https://mcp.example.com/v1/token":
                let json = #"{"access_token":"access-new","token_type":"bearer","expires_in":3600,"refresh_token":"refresh-new"}"#
                return (200, [:], Data(json.utf8))
            default:
                return (404, [:], Data())
            }
        }
    }

    @Test func test_discoveryFallsBackToTheOriginWithoutResourceMetadata() async throws {
        let auth = AtlassianMCPAuth(server: Self.server, store: MemoryCredentialStore(), transport: discoveryTransport())
        let discovery = try await auth.discover()
        #expect(discovery.metadata.registrationEndpoint?.absoluteString == "https://mcp.example.com/v1/register")
        #expect(discovery.resource == nil)
    }

    @Test func test_discoveryUsesResourceMetadataWhenPublished() async throws {
        let auth = AtlassianMCPAuth(
            server: Self.server, store: MemoryCredentialStore(), transport: discoveryTransport(prm: true)
        )
        let discovery = try await auth.discover()
        #expect(discovery.resource == "https://mcp.example.com/v1/mcp")
    }

    @Test func test_discoveryRefusesAServerWithoutRegistration() async {
        let auth = AtlassianMCPAuth(
            server: Self.server, store: MemoryCredentialStore(), transport: discoveryTransport(registration: false)
        )
        await #expect(throws: MCPError.unsupportedServer("The server offers no client registration.")) {
            try await auth.discover()
        }
    }

    @Test func test_registersAPublicLoopbackClient() async throws {
        let transport = discoveryTransport()
        let auth = AtlassianMCPAuth(server: Self.server, store: MemoryCredentialStore(), transport: transport)
        let clientID = try await auth.register(
            at: URL(string: "https://mcp.example.com/v1/register")!, redirectURI: "http://127.0.0.1:5555/callback"
        )
        #expect(clientID == "client-new")
        let request = try #require(transport.requests.last)
        #expect(request.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["client_name"] as? String == "TicketPilot")
        #expect(body["redirect_uris"] as? [String] == ["http://127.0.0.1:5555/callback"])
        #expect(body["token_endpoint_auth_method"] as? String == "none")
        #expect(body["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
        #expect(body["response_types"] as? [String] == ["code"])
    }

    @Test func test_exchangesTheCodeWithTheVerifierAndStoresTheTokens() async throws {
        let transport = discoveryTransport()
        let store = MemoryCredentialStore()
        let now = Date(timeIntervalSince1970: 1_000)
        let auth = AtlassianMCPAuth(server: Self.server, store: store, transport: transport, now: { now })
        let credentials = try await auth.exchange(
            code: "code-1",
            pending: PendingAuthorization(
                tokenEndpoint: URL(string: "https://mcp.example.com/v1/token")!,
                clientID: "client-new",
                redirectURI: "http://127.0.0.1:5555/callback",
                verifier: "verifier-1",
                state: "state-1",
                resource: nil
            )
        )
        let fields = formFields(try #require(transport.requests.last))
        #expect(fields == [
            "grant_type": "authorization_code",
            "code": "code-1",
            "redirect_uri": "http://127.0.0.1:5555/callback",
            "client_id": "client-new",
            "code_verifier": "verifier-1",
        ])
        #expect(credentials.accessToken == "access-new")
        #expect(credentials.refreshToken == "refresh-new")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 4_600))
        #expect(store.current == credentials)
    }

    @Test func test_callbackChecksTheState() throws {
        #expect(throws: MCPError.stateMismatch) {
            try PendingAuthorization.code(from: ["code": "c", "state": "other"], expectedState: "state-1")
        }
        #expect(throws: MCPError.authorizationFailed("Your administrator blocked this app")) {
            try PendingAuthorization.code(
                from: ["error": "access_denied", "error_description": "Your administrator blocked this app", "state": "state-1"],
                expectedState: "state-1"
            )
        }
        #expect(try PendingAuthorization.code(from: ["code": "c", "state": "state-1"], expectedState: "state-1") == "c")
    }

    // MARK: - Access token and refresh

    @Test func test_validTokenIsReturnedWithoutRefresh() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let transport = discoveryTransport()
        let store = MemoryCredentialStore(Self.credentials(expiresAt: now.addingTimeInterval(3_000)))
        let auth = AtlassianMCPAuth(server: Self.server, store: store, transport: transport, now: { now })
        #expect(try await auth.accessToken() == "access-1")
        #expect(transport.requests.isEmpty)
    }

    @Test func test_expiredTokenIsRefreshed() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let transport = discoveryTransport()
        let store = MemoryCredentialStore(Self.credentials(expiresAt: now.addingTimeInterval(-10)))
        let auth = AtlassianMCPAuth(server: Self.server, store: store, transport: transport, now: { now })
        #expect(try await auth.accessToken() == "access-new")
        let fields = formFields(try #require(transport.requests.last))
        #expect(fields == ["grant_type": "refresh_token", "refresh_token": "refresh-1", "client_id": "client-1"])
        #expect(store.current?.refreshToken == "refresh-new")
        #expect(store.current?.expiresAt == now.addingTimeInterval(3_600))
    }

    @Test func test_refreshKeepsTheOldRefreshTokenWhenNoneIsReturned() async throws {
        let transport = StubTransport { _ in
            (200, [:], Data(#"{"access_token":"access-2","token_type":"bearer","expires_in":60}"#.utf8))
        }
        let store = MemoryCredentialStore(Self.credentials(expiresAt: nil))
        let auth = AtlassianMCPAuth(server: Self.server, store: store, transport: transport)
        #expect(try await auth.refreshedAccessToken() == "access-2")
        #expect(store.current?.refreshToken == "refresh-1")
    }

    @Test func test_noCredentialsIsNotConnected() async {
        let auth = AtlassianMCPAuth(server: Self.server, store: MemoryCredentialStore(), transport: discoveryTransport())
        await #expect(throws: MCPError.notConnected) {
            try await auth.accessToken()
        }
    }

    @Test func test_refusedRefreshIsUnauthorized() async {
        let transport = StubTransport { _ in
            (400, [:], Data(#"{"error":"invalid_grant","error_description":"Grant revoked"}"#.utf8))
        }
        let store = MemoryCredentialStore(Self.credentials(expiresAt: nil))
        let auth = AtlassianMCPAuth(server: Self.server, store: store, transport: transport)
        await #expect(throws: MCPError.unauthorized) {
            try await auth.refreshedAccessToken()
        }
    }

    @Test func test_refreshWithoutRefreshTokenIsUnauthorized() async {
        let store = MemoryCredentialStore(Self.credentials(expiresAt: nil, refreshToken: nil))
        let auth = AtlassianMCPAuth(server: Self.server, store: store, transport: discoveryTransport())
        await #expect(throws: MCPError.unauthorized) {
            try await auth.refreshedAccessToken()
        }
    }

    // MARK: - Hardening

    private static func metadata(replacing old: String, with new: String) -> Data {
        Data(metadataJSON.replacingOccurrences(of: old, with: new).utf8)
    }

    @Test func test_metadataMustStayOnTheAuthorizationServer() throws {
        let origin = URL(string: "https://mcp.example.com")!
        try Self.metadata().validate(authorizationServer: origin)
        let tampered = [
            Self.metadata(replacing: "\"token_endpoint\":\"https://mcp.example.com", with: "\"token_endpoint\":\"http://mcp.example.com"),
            Self.metadata(replacing: "\"authorization_endpoint\":\"https://mcp.example.com", with: "\"authorization_endpoint\":\"https://evil.example.org"),
            Self.metadata(replacing: "\"registration_endpoint\":\"https://mcp.example.com", with: "\"registration_endpoint\":\"https://mcp.example.com:8443"),
            Self.metadata(replacing: "\"issuer\":\"https://mcp.example.com\"", with: "\"issuer\":\"https://evil.example.org\""),
            Self.metadata(replacing: "\"issuer\":\"https://mcp.example.com\",", with: ""),
        ]
        for data in tampered {
            let metadata = try AuthorizationServerMetadata.parse(data)
            #expect(throws: MCPError.self) { try metadata.validate(authorizationServer: origin) }
        }
    }

    @Test func test_discoveryRefusesTamperedMetadata() async {
        let transport = StubTransport { request in
            guard request.url!.path == "/.well-known/oauth-authorization-server" else { return (404, [:], Data()) }
            return (200, [:], Self.metadata(replacing: "\"issuer\":\"https://mcp.example.com\"", with: "\"issuer\":\"https://other.example.com\""))
        }
        let auth = AtlassianMCPAuth(server: Self.server, store: MemoryCredentialStore(), transport: transport)
        await #expect(throws: MCPError.unsupportedServer("The authorization server's metadata names another issuer.")) {
            try await auth.discover()
        }
    }

    @Test func test_discoveryRefusesAnAuthorizationServerElsewhere() async {
        let transport = StubTransport { request in
            if request.url!.path.hasPrefix("/.well-known/oauth-protected-resource") {
                return (200, [:], Data(#"{"resource":"https://mcp.example.com/v1/mcp","authorization_servers":["https://evil.example.org"]}"#.utf8))
            }
            return (200, [:], Data(Self.metadataJSON.utf8))
        }
        let auth = AtlassianMCPAuth(server: Self.server, store: MemoryCredentialStore(), transport: transport)
        await #expect(throws: MCPError.unsupportedServer("The MCP server names an authorization server TicketPilot does not trust.")) {
            try await auth.discover()
        }
    }

    @Test func test_disconnectDuringARefreshStoresNothing() async throws {
        let gate = Gate()
        let transport = GatedTransport(gate: gate) { request in
            if request.url!.path == "/v1/token" {
                return (200, [:], Data(#"{"access_token":"access-new","expires_in":3600,"refresh_token":"refresh-new"}"#.utf8))
            }
            return (200, [:], Data())
        }
        var credentials = Self.credentials(expiresAt: nil)
        credentials.revocationEndpoint = "https://mcp.example.com/v1/token"
        let store = MemoryCredentialStore(credentials)
        let auth = AtlassianMCPAuth(server: Self.server, store: store, transport: transport)
        let refreshing = Task { try await auth.refreshedAccessToken() }
        await gate.waitUntilEntered()
        let disconnecting = Task { await auth.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        await disconnecting.value

        await #expect(throws: MCPError.self) { try await refreshing.value }
        #expect(store.current == nil)
        await #expect(throws: MCPError.notConnected) { try await auth.accessToken() }
        // The tokens were revoked, refresh token first.
        let revoked = transport.requests.filter { formFields($0)["token_type_hint"] != nil }
        #expect(revoked.map { formFields($0)["token_type_hint"] } == ["refresh_token", "access_token"])
        #expect(revoked.map { formFields($0)["token"] } == ["refresh-1", "access-1"])
    }

    @Test func test_disconnectWithoutRevocationEndpointOnlyDeletes() async {
        let transport = discoveryTransport()
        let store = MemoryCredentialStore(Self.credentials(expiresAt: nil))
        let auth = AtlassianMCPAuth(server: Self.server, store: store, transport: transport)
        await auth.disconnect()
        #expect(store.current == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func test_refreshedCredentialsStayInMemoryWhenTheKeychainRefusesThem() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let transport = discoveryTransport()
        let store = MemoryCredentialStore(Self.credentials(expiresAt: now.addingTimeInterval(-10)))
        store.failingSaves = 1
        let auth = AtlassianMCPAuth(server: Self.server, store: store, transport: transport, now: { now })
        #expect(try await auth.accessToken() == "access-new")
        #expect(store.current?.refreshToken == "refresh-1")
        // The next use answers from memory, without refreshing again, and saves again.
        #expect(try await auth.accessToken() == "access-new")
        #expect(transport.requests.count == 1)
        #expect(store.current?.refreshToken == "refresh-new")
    }

    @Test func test_credentialsOfAnotherServerAreIgnored() async {
        var other = Self.credentials(expiresAt: nil)
        other.server = "https://other.example.com/mcp"
        let auth = AtlassianMCPAuth(server: Self.server, store: MemoryCredentialStore(other), transport: discoveryTransport())
        await #expect(throws: MCPError.notConnected) {
            try await auth.accessToken()
        }
    }
}

/// Holds a request until opened.
actor Gate {
    private var entered = false
    private var isOpen = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        enterWaiters.forEach { $0.resume() }
        enterWaiters = []
        if isOpen { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func open() {
        isOpen = true
        openWaiters.forEach { $0.resume() }
        openWaiters = []
    }
}

/// Like `StubTransport`, but the token request waits at the gate.
final class GatedTransport: HTTPTransport, @unchecked Sendable {
    private let gate: Gate
    private let inner: StubTransport

    init(gate: Gate, handler: @escaping StubTransport.Handler) {
        self.gate = gate
        inner = StubTransport(handler: handler)
    }

    var requests: [URLRequest] { inner.requests }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if formFields(request)["grant_type"] == "refresh_token" {
            await gate.enter()
        }
        return try await inner.send(request)
    }
}
