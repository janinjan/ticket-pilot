import CryptoKit
import Foundation
import Security

// MARK: - Metadata

/// RFC 8414 authorization server metadata: only what the sign-in uses.
public struct AuthorizationServerMetadata: Equatable, Sendable {
    public var issuer: String?
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var revocationEndpoint: URL?
    public var codeChallengeMethods: [String]

    public var supportsS256: Bool { codeChallengeMethods.contains("S256") }

    public static func parse(_ data: Data) throws(MCPError) -> AuthorizationServerMetadata {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authorization = (object["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (object["token_endpoint"] as? String).flatMap(URL.init(string:))
        else { throw .invalidResponse }
        return AuthorizationServerMetadata(
            issuer: object["issuer"] as? String,
            authorizationEndpoint: authorization,
            tokenEndpoint: token,
            registrationEndpoint: (object["registration_endpoint"] as? String).flatMap(URL.init(string:)),
            revocationEndpoint: (object["revocation_endpoint"] as? String).flatMap(URL.init(string:)),
            codeChallengeMethods: object["code_challenge_methods_supported"] as? [String] ?? []
        )
    }

    /// Refuses metadata that could send the sign-in elsewhere: its `issuer` must be the authorization
    /// server it was read from (RFC 8414 §3.3), and every endpoint must be `https` on that same origin.
    public func validate(authorizationServer: URL) throws(MCPError) {
        func trimmed(_ text: String) -> String {
            var text = text
            while text.hasSuffix("/") { text.removeLast() }
            return text.lowercased()
        }
        guard let issuer, trimmed(issuer) == trimmed(authorizationServer.absoluteString) else { throw .unsupportedServer("The authorization server's metadata names another issuer.") }
        let endpoints = [authorizationEndpoint, tokenEndpoint] + [registrationEndpoint, revocationEndpoint].compactMap { $0 }
        for endpoint in endpoints {
            guard endpoint.scheme?.lowercased() == "https", Origin(endpoint) == Origin(authorizationServer) else {
                throw .unsupportedServer("The authorization server's metadata points outside \(authorizationServer.absoluteString).")
            }
        }
    }
}

/// The scheme, host and port of a URL.
struct Origin: Equatable {
    var scheme: String
    var host: String
    var port: Int?

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        self.scheme = scheme
        self.host = host
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        port = url.port == defaultPort ? nil : url.port
    }

    init?(_ string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url)
    }
}

/// RFC 9728 protected resource metadata: the resource and its authorization servers.
public struct ProtectedResourceMetadata: Equatable, Sendable {
    public var resource: String?
    public var authorizationServers: [URL]

    public static func parse(_ data: Data) throws(MCPError) -> ProtectedResourceMetadata {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["authorization_servers"] as? [String]
        else { throw .invalidResponse }
        let urls = servers.compactMap(URL.init(string:))
        guard !urls.isEmpty else { throw .invalidResponse }
        return ProtectedResourceMetadata(resource: object["resource"] as? String, authorizationServers: urls)
    }
}

public enum WWWAuthenticate {
    /// The `resource_metadata` parameter of a `Bearer` challenge, if any.
    public static func resourceMetadataURL(in header: String) -> URL? {
        guard let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let value = header[range].dropFirst("resource_metadata=\"".count).dropLast()
        return URL(string: String(value))
    }
}

public enum WellKnown {
    /// The well-known URLs of `name` for `url`: with its path inserted after `/.well-known/<name>` first,
    /// then at the origin (RFC 8414 §3, RFC 9728 §3).
    public static func urls(for name: String, of url: URL) -> [URL] {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        components.query = nil
        components.fragment = nil
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        var urls: [URL] = []
        if !path.isEmpty {
            components.path = "/.well-known/\(name)\(path)"
            components.url.map { urls.append($0) }
        }
        components.path = "/.well-known/\(name)"
        components.url.map { urls.append($0) }
        return urls
    }
}

// MARK: - PKCE, state and the authorize URL

/// RFC 7636 proof key, S256 only.
public struct PKCE: Sendable {
    public var verifier: String

    public init(verifier: String) {
        self.verifier = verifier
    }

    public var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    public static func random() -> PKCE {
        PKCE(verifier: randomToken())
    }
}

/// 32 random bytes, base64url: 43 URL-safe characters.
func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
        var generator = SystemRandomNumberGenerator()
        bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
    return Data(bytes).base64URLEncoded
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The browser page of the sign-in: authorization code, PKCE S256 and `state`.
public struct AuthorizeRequest: Sendable {
    public var endpoint: URL
    public var clientID: String
    public var redirectURI: String
    public var challenge: String
    public var state: String
    /// RFC 8707 resource, sent only when the server published one.
    public var resource: String?

    public var url: URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let resource {
            items.append(URLQueryItem(name: "resource", value: resource))
        }
        components.queryItems = items
        return components.url!
    }
}

// MARK: - Tokens and credentials

public struct TokenResponse: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresIn: TimeInterval?

    public func expiresAt(now: Date) -> Date? {
        expiresIn.map { now.addingTimeInterval($0) }
    }

    /// A token response, or the server's own explanation of why there is none.
    public static func parse(_ data: Data, status: Int) throws(MCPError) -> TokenResponse {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status), let access = object?["access_token"] as? String, !access.isEmpty {
            let expiresIn: TimeInterval? = switch object?["expires_in"] {
            case let number as NSNumber: number.doubleValue
            case let text as String: TimeInterval(text)
            default: nil
            }
            return TokenResponse(
                accessToken: access,
                refreshToken: (object?["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                expiresIn: expiresIn
            )
        }
        if let reason = (object?["error_description"] as? String) ?? (object?["error"] as? String) {
            throw .authorizationFailed(reason)
        }
        throw (200..<300).contains(status) ? .invalidResponse : .http(status: status)
    }
}

/// The Atlassian sign-in, stored as one JSON item in the Keychain. Never logged.
public struct MCPCredentials: Codable, Equatable, Sendable {
    public var server: String
    public var clientID: String
    public var tokenEndpoint: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    /// Where Disconnect revokes the tokens, when the server has one.
    public var revocationEndpoint: String?

    public init(
        server: String,
        clientID: String,
        tokenEndpoint: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        revocationEndpoint: String? = nil
    ) {
        self.revocationEndpoint = revocationEndpoint
        self.server = server
        self.clientID = clientID
        self.tokenEndpoint = tokenEndpoint
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Expired, or about to be: a minute of leeway for the request on its way.
    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 60
    }

    private enum CodingKeys: String, CodingKey {
        case server
        case clientID = "client_id"
        case tokenEndpoint = "token_endpoint"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case revocationEndpoint = "revocation_endpoint"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decode(String.self, forKey: .server)
        clientID = try container.decode(String.self, forKey: .clientID)
        tokenEndpoint = try container.decode(String.self, forKey: .tokenEndpoint)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt).map(Date.init(timeIntervalSince1970:))
        revocationEndpoint = try container.decodeIfPresent(String.self, forKey: .revocationEndpoint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(server, forKey: .server)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(tokenEndpoint, forKey: .tokenEndpoint)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encodeIfPresent(expiresAt?.timeIntervalSince1970, forKey: .expiresAt)
        try container.encodeIfPresent(revocationEndpoint, forKey: .revocationEndpoint)
    }
}

public protocol MCPCredentialStoring: Sendable {
    func load() throws(MCPError) -> MCPCredentials?
    func save(_ credentials: MCPCredentials) throws(MCPError)
    func delete()
}

/// The credentials as one generic password item of `service`.
public struct KeychainCredentialStore: MCPCredentialStoring {
    public static let defaultService = "ticket-pilot-atlassian-mcp"

    private let service: String
    private let account: String

    public init(service: String = Self.defaultService, account: String = NSUserName()) {
        self.service = service
        self.account = account
    }

    public func load() throws(MCPError) -> MCPCredentials? {
        let text: String
        do throws(KeychainError) {
            text = try Keychain.password(service: service)
        } catch {
            switch error {
            case .notFound: return nil
            case let .unexpected(status): throw .keychain(status)
            }
        }
        // An unreadable item is a sign-in to make again, not a failure.
        return try? JSONDecoder().decode(MCPCredentials.self, from: Data(text.utf8))
    }

    public func save(_ credentials: MCPCredentials) throws(MCPError) {
        guard let data = try? JSONEncoder().encode(credentials) else { throw .invalidResponse }
        do throws(KeychainError) {
            try Keychain.setPassword(
                String(decoding: data, as: UTF8.self),
                service: service,
                account: account,
                label: "TicketPilot Atlassian sign-in",
                thisDeviceOnly: true
            )
        } catch let .unexpected(status) {
            throw .keychain(status)
        } catch {
            throw .keychain(errSecItemNotFound)
        }
    }

    public func delete() {
        Keychain.deleteItems(service: service)
    }
}

// MARK: - The sign-in

/// What the sign-in must remember between the browser page and the token exchange.
public struct PendingAuthorization: Sendable {
    public var tokenEndpoint: URL
    public var clientID: String
    public var redirectURI: String
    public var verifier: String
    public var state: String
    public var resource: String?
    public var revocationEndpoint: URL?

    /// The code of the callback, once its `state` is checked; the server's message if it refused.
    public static func code(from query: [String: String], expectedState: String) throws(MCPError) -> String {
        guard query["state"] == expectedState else { throw .stateMismatch }
        if let error = query["error"] {
            throw .authorizationFailed(query["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error)
        }
        guard let code = query["code"], !code.isEmpty else { throw .invalidResponse }
        return code
    }
}

/// A sign-in in progress: the page to open, and the loopback listener waiting for its callback.
public struct MCPSignIn: Sendable {
    public let authorizeURL: URL
    let pending: PendingAuthorization
    let callback: LoopbackCallbackServer

    /// Stops waiting for the browser.
    public func cancel() {
        callback.cancel()
    }
}

public struct MCPDiscovery: Equatable, Sendable {
    public var metadata: AuthorizationServerMetadata
    /// The resource to name in the authorization and token requests, if the server published one.
    public var resource: String?
}

/// OAuth 2.1 for the Atlassian Remote MCP server, as the MCP authorization spec describes it: discovery,
/// dynamic client registration of a public loopback client, authorization code with PKCE S256, refresh.
public actor AtlassianMCPAuth {
    public static let defaultServer = URL(string: "https://mcp.atlassian.com/v1/mcp")!

    public nonisolated let server: URL
    private let store: MCPCredentialStoring
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    /// The hosts an authorization server may be on: the MCP server's own, unless told otherwise.
    private let allowedAuthorizationHosts: Set<String>
    private var refreshing: Task<String, any Error>?
    /// The credentials last read or written; kept when the Keychain refused to save them, so a rotated
    /// refresh token is not lost, and saved again on the next use.
    private var cached: MCPCredentials?
    private var unsaved = false
    /// Bumped by Disconnect: a refresh or sign-in started before it never stores anything.
    private var generation = 0

    public init(
        server: URL = AtlassianMCPAuth.defaultServer,
        store: MCPCredentialStoring = KeychainCredentialStore(),
        transport: HTTPTransport = URLSessionTransport(),
        allowedAuthorizationHosts: Set<String>? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.server = server
        self.store = store
        self.transport = transport
        self.allowedAuthorizationHosts = allowedAuthorizationHosts ?? Set([server.host?.lowercased()].compactMap { $0 })
        self.now = now
    }

    // MARK: Access token

    /// The stored access token, refreshed first when it has expired.
    public func accessToken() async throws(MCPError) -> String {
        let credentials = try storedCredentials()
        if credentials.isExpired(now: now()) {
            return try await refreshedAccessToken()
        }
        return credentials.accessToken
    }

    /// A new access token from the refresh token: after a 401, or once expired. Concurrent callers share
    /// one refresh, so a rotated refresh token is never used twice.
    public func refreshedAccessToken() async throws(MCPError) -> String {
        if let refreshing {
            return try await Self.value(of: refreshing)
        }
        let task = Task<String, any Error> { try await self.refresh() }
        refreshing = task
        defer { if refreshing == task { refreshing = nil } }
        return try await Self.value(of: task)
    }

    /// Whether a sign-in is stored for this server.
    public func isConnected() throws(MCPError) -> Bool {
        do {
            _ = try storedCredentials()
            return true
        } catch .notConnected {
            return false
        }
    }

    /// Forgets the sign-in: deletes its Keychain item, stops a refresh in flight from storing anything,
    /// then asks the server to revoke the tokens when it offers that (best effort).
    public func disconnect() async {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        let credentials = cached ?? ((try? store.load()) ?? nil)
        cached = nil
        unsaved = false
        store.delete()
        guard let credentials,
              let endpoint = credentials.revocationEndpoint.flatMap(URL.init(string:)),
              endpoint.scheme?.lowercased() == "https"
        else { return }
        let tokens = [(credentials.refreshToken, "refresh_token"), (credentials.accessToken, "access_token")]
        for case let (token?, hint) in tokens {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formEncoded([
                ("token", token), ("token_type_hint", hint), ("client_id", credentials.clientID),
            ]).utf8)
            _ = try? await transport.send(request)
        }
    }

    private static func value(of task: Task<String, any Error>) async throws(MCPError) -> String {
        do {
            return try await task.value
        } catch let error as MCPError {
            throw error
        } catch {
            throw .unreachable
        }
    }

    private func storedCredentials() throws(MCPError) -> MCPCredentials {
        if let cached {
            if unsaved { keep(cached) }
            return cached
        }
        guard let credentials = try store.load(), credentials.server == server.absoluteString else {
            throw .notConnected
        }
        cached = credentials
        return credentials
    }

    /// Stores `credentials`; when the Keychain refuses, keeps them in memory and tries again on next use.
    private func keep(_ credentials: MCPCredentials) {
        cached = credentials
        do {
            try store.save(credentials)
            unsaved = false
        } catch {
            unsaved = true
        }
    }

    private func refresh() async throws(MCPError) -> String {
        let started = generation
        var credentials = try storedCredentials()
        guard let refreshToken = credentials.refreshToken, let endpoint = URL(string: credentials.tokenEndpoint) else {
            throw .unauthorized
        }
        let tokens: TokenResponse
        do {
            tokens = try await tokenRequest(endpoint, fields: [
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken),
                ("client_id", credentials.clientID),
            ])
        } catch .authorizationFailed, .http(status: 400), .http(status: 401) {
            throw generation == started ? .unauthorized : .notConnected
        } catch {
            throw generation == started ? error : .notConnected
        }
        guard generation == started else { throw .notConnected }
        credentials.accessToken = tokens.accessToken
        credentials.refreshToken = tokens.refreshToken ?? refreshToken
        credentials.expiresAt = tokens.expiresAt(now: now())
        keep(credentials)
        return tokens.accessToken
    }

    // MARK: Sign-in

    /// Discovers the server, registers a client for a new loopback listener and returns the page to open.
    public func beginSignIn() async throws(MCPError) -> MCPSignIn {
        let discovery = try await discover()
        guard let registration = discovery.metadata.registrationEndpoint else {
            throw .unsupportedServer("The server offers no client registration.")
        }
        let state = randomToken()
        let callback = try await LoopbackCallbackServer.start(expectedState: state)
        do {
            let redirectURI = "http://127.0.0.1:\(callback.port)/callback"
            let clientID = try await register(at: registration, redirectURI: redirectURI)
            let pkce = PKCE.random()
            let pending = PendingAuthorization(
                tokenEndpoint: discovery.metadata.tokenEndpoint,
                clientID: clientID,
                redirectURI: redirectURI,
                verifier: pkce.verifier,
                state: state,
                resource: discovery.resource,
                revocationEndpoint: discovery.metadata.revocationEndpoint
            )
            let url = AuthorizeRequest(
                endpoint: discovery.metadata.authorizationEndpoint,
                clientID: clientID,
                redirectURI: redirectURI,
                challenge: pkce.challenge,
                state: state,
                resource: discovery.resource
            ).url
            return MCPSignIn(authorizeURL: url, pending: pending, callback: callback)
        } catch {
            callback.cancel()
            throw error
        }
    }

    /// Waits for the browser to come back with this sign-in's `state` (five minutes at most), then stores
    /// the tokens.
    public func completeSignIn(_ signIn: MCPSignIn) async throws(MCPError) -> MCPCredentials {
        let started = generation
        let query = try await signIn.callback.waitForCallback()
        let code = try PendingAuthorization.code(from: query, expectedState: signIn.pending.state)
        guard generation == started else { throw .cancelled }
        return try await exchange(code: code, pending: signIn.pending)
    }

    func exchange(code: String, pending: PendingAuthorization) async throws(MCPError) -> MCPCredentials {
        let started = generation
        var fields = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", pending.redirectURI),
            ("client_id", pending.clientID),
            ("code_verifier", pending.verifier),
        ]
        if let resource = pending.resource {
            fields.append(("resource", resource))
        }
        let tokens = try await tokenRequest(pending.tokenEndpoint, fields: fields)
        guard generation == started else { throw .cancelled }
        let credentials = MCPCredentials(
            server: server.absoluteString,
            clientID: pending.clientID,
            tokenEndpoint: pending.tokenEndpoint.absoluteString,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt(now: now()),
            revocationEndpoint: pending.revocationEndpoint?.absoluteString
        )
        keep(credentials)
        return credentials
    }

    /// The protected resource metadata when published, else the MCP origin as authorization server. The
    /// authorization server must be `https` on an allowed host, and its metadata must pass `validate`.
    public func discover(resourceMetadata hint: URL? = nil) async throws(MCPError) -> MCPDiscovery {
        var resource: String?
        var origin = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        var authorizationServer = origin.url ?? server
        let candidates = (hint.map { [$0] } ?? []) + WellKnown.urls(for: "oauth-protected-resource", of: server)
        for url in candidates where Origin(url) == Origin(server) {
            guard let data = try await getIfFound(url),
                  let metadata = try? ProtectedResourceMetadata.parse(data)
            else { continue }
            resource = metadata.resource
            authorizationServer = metadata.authorizationServers[0]
            break
        }
        guard authorizationServer.scheme?.lowercased() == "https",
              let host = authorizationServer.host?.lowercased(), allowedAuthorizationHosts.contains(host)
        else {
            throw .unsupportedServer("The MCP server names an authorization server TicketPilot does not trust.")
        }
        var metadata: AuthorizationServerMetadata?
        for url in WellKnown.urls(for: "oauth-authorization-server", of: authorizationServer) {
            if let data = try await getIfFound(url) {
                metadata = try AuthorizationServerMetadata.parse(data)
                break
            }
        }
        guard let metadata else { throw .unsupportedServer("The server publishes no authorization metadata.") }
        try metadata.validate(authorizationServer: authorizationServer)
        guard metadata.registrationEndpoint != nil else {
            throw .unsupportedServer("The server offers no client registration.")
        }
        guard metadata.supportsS256 else { throw .unsupportedServer("The server does not support PKCE S256.") }
        return MCPDiscovery(metadata: metadata, resource: resource)
    }

    /// RFC 7591 registration of a public client (no secret) for the loopback redirect URI.
    func register(at endpoint: URL, redirectURI: String) async throws(MCPError) -> String {
        let body: [String: Any] = [
            "client_name": "TicketPilot",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await send(request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status), let clientID = object?["client_id"] as? String, !clientID.isEmpty {
            return clientID
        }
        if let reason = (object?["error_description"] as? String) ?? (object?["error"] as? String) {
            throw .authorizationFailed(reason)
        }
        throw (200..<300).contains(status) ? .invalidResponse : .http(status: status)
    }

    // MARK: HTTP

    private func tokenRequest(_ endpoint: URL, fields: [(String, String)]) async throws(MCPError) -> TokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncoded(fields).utf8)
        let (data, status) = try await send(request)
        return try TokenResponse.parse(data, status: status)
    }

    static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    /// The body of a 200 answer, nil for a 4xx (not published).
    private func getIfFound(_ url: URL) async throws(MCPError) -> Data? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await send(request)
        if (200..<300).contains(status) { return data }
        if (400..<500).contains(status) { return nil }
        throw .http(status: status)
    }

    private func send(_ request: URLRequest) async throws(MCPError) -> (Data, Int) {
        do {
            let (data, response) = try await transport.send(request)
            return (data, response.statusCode)
        } catch {
            throw .unreachable
        }
    }
}
