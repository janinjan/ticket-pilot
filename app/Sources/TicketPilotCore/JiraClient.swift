import Foundation

public enum JiraError: Error, Equatable {
    case unauthorized
    case unreachable
    case http(status: Int)
    case invalidResponse
}

public protocol JiraSearching: Sendable {
    func openAssignedIssues() async throws(JiraError) -> [JiraIssue]
    func statusCategories(of keys: [String]) async throws(JiraError) -> [String: JiraIssue.StatusCategory]
    func checkCredentials() async throws(JiraError)
}

/// Read-only Jira Cloud client: `GET` and the `POST` search endpoint only.
public final class JiraClient: JiraSearching {
    private static let openAssignedJQL = "assignee = currentUser() AND statusCategory != Done"
    private static let fields = ["summary", "status", "labels", "components"]
    private static let pageSize = 100

    private let site: URL
    private let authorization: String
    private let session: URLSession

    public init(site: URL, email: String, token: String, session: URLSession = .shared) {
        self.site = site
        self.authorization = "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
        self.session = session
    }

    public func openAssignedIssues() async throws(JiraError) -> [JiraIssue] {
        try await search(jql: Self.openAssignedJQL)
    }

    public func statusCategories(of keys: [String]) async throws(JiraError) -> [String: JiraIssue.StatusCategory] {
        guard !keys.isEmpty else { return [:] }
        let issues = try await search(jql: "key in (\(keys.joined(separator: ", ")))")
        return Dictionary(issues.map { ($0.key, $0.statusCategory) }, uniquingKeysWith: { first, _ in first })
    }

    public func checkCredentials() async throws(JiraError) {
        var request = URLRequest(url: endpoint("myself"))
        request.httpMethod = "GET"
        _ = try await send(request)
    }

    // MARK: - Private

    private func endpoint(_ path: String) -> URL {
        site.appendingPathComponent("rest/api/3").appendingPathComponent(path)
    }

    private func search(jql: String) async throws(JiraError) -> [JiraIssue] {
        var issues: [JiraIssue] = []
        var pageToken: String?
        repeat {
            let page = try await searchPage(jql: jql, pageToken: pageToken)
            issues += page.issues
            pageToken = page.nextPageToken
        } while pageToken != nil
        return issues
    }

    private func searchPage(jql: String, pageToken: String?) async throws(JiraError) -> SearchPage {
        let body = SearchBody(jql: jql, fields: Self.fields, maxResults: Self.pageSize, nextPageToken: pageToken)
        var request = URLRequest(url: endpoint("search/jql"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw .invalidResponse
        }
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(SearchPage.self, from: data)
        } catch {
            throw .invalidResponse
        }
    }

    private func send(_ request: URLRequest) async throws(JiraError) -> Data {
        var request = request
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw .unauthorized
        default: throw .http(status: http.statusCode)
        }
    }
}

// MARK: - Wire format

private struct SearchBody: Encodable {
    var jql: String
    var fields: [String]
    var maxResults: Int
    var nextPageToken: String?
}

private struct SearchPage: Decodable {
    var issues: [JiraIssue]
    var nextPageToken: String?
}

extension JiraIssue: Decodable {
    private enum CodingKeys: String, CodingKey {
        case key, fields
    }

    private struct Fields: Decodable {
        struct Status: Decodable {
            struct Category: Decodable { var key: String }
            var name: String
            var statusCategory: Category
        }
        struct Component: Decodable { var name: String }

        var summary: String
        var status: Status
        var labels: [String]?
        var components: [Component]?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = try container.decode(Fields.self, forKey: .fields)
        key = try container.decode(String.self, forKey: .key)
        summary = fields.summary
        statusName = fields.status.name
        // An unknown category (e.g. "undefined") is treated as not started.
        statusCategory = StatusCategory(rawValue: fields.status.statusCategory.key) ?? .toDo
        labels = fields.labels ?? []
        components = fields.components?.map(\.name) ?? []
    }
}
