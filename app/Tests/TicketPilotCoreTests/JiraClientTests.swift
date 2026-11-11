import Foundation
import Testing
@testable import TicketPilotCore

/// Routes requests to per-test handlers, keyed by the `X-Test-ID` header of each test's session,
/// so tests can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private static let handlers = HandlerStore()

    private final class HandlerStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Handler] = [:]

        func set(_ handler: Handler?, for id: String) {
            lock.lock()
            defer { lock.unlock() }
            storage[id] = handler
        }

        func handler(for id: String) -> Handler? {
            lock.lock()
            defer { lock.unlock() }
            return storage[id]
        }
    }

    static func session(handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        handlers.set(handler, for: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-ID": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Test-ID") ?? ""
        guard let handler = Self.handlers.handler(for: id), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var captured = request
        captured.httpBody = Self.readBody(of: request)
        do {
            let (status, data) = try handler(captured)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Collects the requests a stub session received.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
    }

    func bodyJSON(at index: Int) throws -> [String: Any] {
        let body = try #require(requests[index].httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

struct JiraClientTests {
    private let site = URL(string: "https://example.atlassian.net")!

    private func client(
        log: RequestLog = RequestLog(),
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
    ) -> JiraClient {
        let session = StubURLProtocol.session { request in
            log.append(request)
            return try handler(request)
        }
        return JiraClient(site: site, email: "me@example.com", token: "secret", session: session)
    }

    private func page(_ issues: String, next: String? = nil) -> Data {
        let token = next.map { ",\"nextPageToken\":\"\($0)\"" } ?? ""
        return Data("{\"issues\":[\(issues)]\(token),\"isLast\":\(next == nil)}".utf8)
    }

    private func issueJSON(
        _ key: String,
        category: String = "new",
        labels: String = "[]",
        components: String = "[]"
    ) -> String {
        """
        {"key":"\(key)","fields":{"summary":"Summary \(key)","status":{"name":"To Start",\
        "statusCategory":{"key":"\(category)"}},"labels":\(labels),"components":\(components)}}
        """
    }

    @Test func test_searchSendsTheSpecQuery() async throws {
        let log = RequestLog()
        let jira = client(log: log) { _ in (200, self.page("")) }
        _ = try await jira.openAssignedIssues()

        let request = try #require(log.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://example.atlassian.net/rest/api/3/search/jql")
        let expectedAuth = "Basic " + Data("me@example.com:secret".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == expectedAuth)
        let body = try log.bodyJSON(at: 0)
        #expect(body["jql"] as? String == "assignee = currentUser() AND statusCategory != Done")
        #expect(body["fields"] as? [String] == ["summary", "status", "labels", "components"])
        #expect(body["maxResults"] as? Int == 100)
    }

    @Test func test_followsNextPageToken() async throws {
        let log = RequestLog()
        let jira = client(log: log) { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            if body?["nextPageToken"] as? String == "p2" {
                return (200, self.page(self.issueJSON("ABC-2")))
            }
            return (200, self.page(self.issueJSON("ABC-1"), next: "p2"))
        }
        let issues = try await jira.openAssignedIssues()

        #expect(issues.map(\.key) == ["ABC-1", "ABC-2"])
        #expect(log.requests.count == 2)
        #expect(try log.bodyJSON(at: 0)["nextPageToken"] == nil)
        #expect(try log.bodyJSON(at: 1)["nextPageToken"] as? String == "p2")
    }

    @Test func test_mapsStatusCategory() async throws {
        let issues = [
            issueJSON("ABC-1", category: "new", labels: "[\"ios\",\"fast\"]", components: "[{\"name\":\"iOS\"}]"),
            issueJSON("ABC-2", category: "indeterminate"),
            issueJSON("ABC-3", category: "done"),
        ].joined(separator: ",")
        let jira = client { _ in (200, self.page(issues)) }
        let result = try await jira.openAssignedIssues()

        #expect(result.map(\.statusCategory) == [.toDo, .inProgress, .done])
        #expect(result[0].labels == ["ios", "fast"])
        #expect(result[0].components == ["iOS"])
        #expect(result[0].summary == "Summary ABC-1")
        #expect(result[0].statusName == "To Start")
    }

    @Test(arguments: [401, 403])
    func test_unauthorizedStatuses(status: Int) async {
        let jira = client { _ in (status, Data()) }
        await #expect(throws: JiraError.unauthorized) {
            try await jira.openAssignedIssues()
        }
    }

    @Test func test_networkErrorIsUnreachable() async {
        let jira = client { _ in throw URLError(.cannotFindHost) }
        await #expect(throws: JiraError.unreachable) {
            try await jira.openAssignedIssues()
        }
    }

    @Test func test_500IsHTTPError() async {
        let jira = client { _ in (500, Data()) }
        await #expect(throws: JiraError.http(status: 500)) {
            try await jira.openAssignedIssues()
        }
    }

    @Test func test_garbageBodyIsInvalidResponse() async {
        let jira = client { _ in (200, Data("nope".utf8)) }
        await #expect(throws: JiraError.invalidResponse) {
            try await jira.openAssignedIssues()
        }
    }

    @Test func test_statusCategoriesQueriesTheKeys() async throws {
        let log = RequestLog()
        let issues = [issueJSON("ABC-1", category: "done"), issueJSON("ABC-2", category: "indeterminate")]
            .joined(separator: ",")
        let jira = client(log: log) { _ in (200, self.page(issues)) }
        let result = try await jira.statusCategories(of: ["ABC-1", "ABC-2"])

        #expect(result == ["ABC-1": .done, "ABC-2": .inProgress])
        #expect(try log.bodyJSON(at: 0)["jql"] as? String == "key in (ABC-1, ABC-2)")
    }

    @Test func test_statusCategoriesOfNoKeysSendsNothing() async throws {
        let log = RequestLog()
        let jira = client(log: log) { _ in (200, self.page("")) }
        let result = try await jira.statusCategories(of: [])

        #expect(result == [:])
        #expect(log.requests.isEmpty)
    }

    @Test func test_checkCredentialsCallsMyself() async throws {
        let log = RequestLog()
        let jira = client(log: log) { _ in (200, Data("{}".utf8)) }
        try await jira.checkCredentials()

        let request = try #require(log.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://example.atlassian.net/rest/api/3/myself")
    }

    @Test func test_checkCredentialsRejectsBadToken() async {
        let jira = client { _ in (401, Data()) }
        await #expect(throws: JiraError.unauthorized) {
            try await jira.checkCredentials()
        }
    }
}
