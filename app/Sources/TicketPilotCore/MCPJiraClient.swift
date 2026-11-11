import Foundation

/// Read-only Jira through the Atlassian Remote MCP server's tools: the same searches as `JiraClient`,
/// with the Atlassian sign-in instead of an API token.
public actor MCPJiraClient: JiraSearching {
    private static let openAssignedJQL = "assignee = currentUser() AND statusCategory != Done"
    private static let fields: [String] = ["summary", "status", "labels", "components"]
    private static let pageSize = 100
    private static let maxPages = 50

    enum Tool {
        static let resources = "getAccessibleAtlassianResources"
        static let search = "searchJiraIssuesUsingJql"
        static let userInfo = "atlassianUserInfo"
        /// The only tools ever called: all three only read.
        static let allowed: Set<String> = [resources, search, userInfo]
    }

    private let site: URL
    private let tools: MCPToolCalling
    private var cloudID: String?
    private var toolList: [MCPTool]?

    public init(site: URL, tools: MCPToolCalling) {
        self.site = site
        self.tools = tools
    }

    public func openAssignedIssues() async throws(JiraError) -> [JiraIssue] {
        try await search(jql: Self.openAssignedJQL)
    }

    public func statusCategories(of keys: [String]) async throws(JiraError) -> [String: JiraIssue.StatusCategory] {
        guard !keys.isEmpty else { return [:] }
        let issues = try await search(jql: "key in (\(keys.joined(separator: ", ")))")
        return Dictionary(issues.map { ($0.key, $0.statusCategory) }, uniquingKeysWith: { first, _ in first })
    }

    /// The account and the site's cloud: proves the sign-in reaches this Jira site.
    public func checkCredentials() async throws(JiraError) {
        _ = try await accountEmail()
        _ = try await resolveCloudID()
    }

    /// The email of the signed-in Atlassian account, if the server tells it.
    public func accountEmail() async throws(JiraError) -> String? {
        let result = try await call(Tool.userInfo, arguments: [:])
        guard let object = Self.jsonObjects(in: result).compactMap({ $0 as? [String: Any] }).first else {
            throw .invalidResponse
        }
        return (object["email"] as? String) ?? (object["emailAddress"] as? String)
    }

    // MARK: - Search

    private func search(jql: String) async throws(JiraError) -> [JiraIssue] {
        let cloud = try await resolveCloudID()
        let properties = try await properties(of: Tool.search)
        func argument(_ names: [String]) -> String? {
            // A tool without a schema gets the documented names.
            properties.isEmpty ? names.first : names.first(where: properties.contains)
        }
        let cloudKey = argument(["cloudId", "cloud_id", "cloudID"]) ?? "cloudId"
        let jqlKey = argument(["jql", "query"]) ?? "jql"
        let fieldsKey = argument(["fields"])
        let maxKey = argument(["maxResults", "max_results", "limit"])
        let tokenKey = argument(["nextPageToken", "next_page_token"])

        var issues: [JiraIssue] = []
        var token: String?
        var pages = 0
        repeat {
            var arguments: [String: JSONValue] = [cloudKey: .string(cloud), jqlKey: .string(jql)]
            if let fieldsKey { arguments[fieldsKey] = .array(Self.fields.map(JSONValue.string)) }
            if let maxKey { arguments[maxKey] = .int(Self.pageSize) }
            if let tokenKey, let token { arguments[tokenKey] = .string(token) }
            let result = try await call(Tool.search, arguments: arguments)
            guard let page = Self.parseSearch(result) else { throw .invalidResponse }
            issues += page.issues
            pages += 1
            token = page.isLast || page.issues.isEmpty ? nil : page.nextPageToken
        } while token != nil && tokenKey != nil && pages < Self.maxPages
        return issues
    }

    struct SearchPage: Equatable {
        var issues: [JiraIssue]
        var nextPageToken: String?
        var isLast: Bool
    }

    /// The issues of a search result, whatever its wrapping; nil when it holds no issue list.
    static func parseSearch(_ result: MCPToolResult) -> SearchPage? {
        for json in jsonObjects(in: result) {
            if let container = findIssues(in: json, depth: 0) {
                let issues = (container["issues"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.compactMap(issue)
                let token = (container["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return SearchPage(issues: issues, nextPageToken: token, isLast: container["isLast"] as? Bool ?? (token == nil))
            }
            if let array = json as? [Any], array.allSatisfy({ ($0 as? [String: Any])?["key"] != nil }) {
                let issues = array.compactMap { $0 as? [String: Any] }.compactMap(issue)
                return SearchPage(issues: issues, nextPageToken: nil, isLast: true)
            }
        }
        return nil
    }

    private static func findIssues(in json: Any, depth: Int) -> [String: Any]? {
        guard let object = json as? [String: Any], depth < 4 else { return nil }
        if object["issues"] is [Any] { return object }
        for value in object.values {
            if let found = findIssues(in: value, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func issue(_ object: [String: Any]) -> JiraIssue? {
        guard let key = object["key"] as? String, !key.isEmpty else { return nil }
        let fields = object["fields"] as? [String: Any] ?? object
        var statusName = ""
        var category = JiraIssue.StatusCategory.toDo
        if let status = fields["status"] as? [String: Any] {
            statusName = status["name"] as? String ?? ""
            let statusCategory = status["statusCategory"] as? [String: Any]
            if let categoryKey = statusCategory?["key"] as? String, let known = JiraIssue.StatusCategory(rawValue: categoryKey) {
                category = known
            } else {
                category = switch (statusCategory?["name"] as? String)?.lowercased() {
                case "done": .done
                case "in progress": .inProgress
                default: .toDo
                }
            }
        } else if let status = fields["status"] as? String {
            statusName = status
        }
        let components = (fields["components"] as? [Any] ?? []).compactMap { component in
            (component as? [String: Any])?["name"] as? String ?? component as? String
        }
        return JiraIssue(
            key: key,
            summary: fields["summary"] as? String ?? "",
            statusName: statusName,
            statusCategory: category,
            labels: fields["labels"] as? [String] ?? [],
            components: components
        )
    }

    // MARK: - Cloud id

    /// The cloud of `jira.site` among the sign-in's sites; else the site's host name, which the tools
    /// also accept.
    private func resolveCloudID() async throws(JiraError) -> String {
        if let cloudID { return cloudID }
        let result = try await call(Tool.resources, arguments: [:])
        let host = site.host?.lowercased() ?? site.absoluteString
        var resources: [[String: Any]] = []
        for json in Self.jsonObjects(in: result) {
            if let array = json as? [[String: Any]] {
                resources = array
            } else if let object = json as? [String: Any], let array = object["resources"] as? [[String: Any]] {
                resources = array
            }
            if !resources.isEmpty { break }
        }
        let match = resources.first { resource in
            (resource["url"] as? String).flatMap(URL.init(string:))?.host?.lowercased() == host
        }
        let id = (match?["id"] as? String) ?? host
        cloudID = id
        return id
    }

    // MARK: - Calls

    private func properties(of name: String) async throws(JiraError) -> [String] {
        try await tool(named: name)?.properties ?? []
    }

    /// The tool of exactly this name, among the read-only ones; nil when the server does not list it.
    private func tool(named name: String) async throws(JiraError) -> MCPTool? {
        guard Tool.allowed.contains(name) else { return nil }
        if toolList == nil {
            do {
                toolList = try await tools.listTools()
            } catch {
                throw Self.jiraError(error)
            }
        }
        let list = toolList ?? []
        return list.first { $0.name == name }
    }

    private func call(_ name: String, arguments: [String: JSONValue]) async throws(JiraError) -> MCPToolResult {
        guard Tool.allowed.contains(name) else { throw .serverError("TicketPilot only reads Jira.") }
        let result: MCPToolResult
        do {
            result = try await tools.callTool(name, arguments: arguments)
        } catch {
            throw Self.jiraError(error)
        }
        if result.isError {
            let message = result.texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw .serverError(message.isEmpty ? "The Atlassian MCP server could not run \(name)." : String(message.prefix(500)))
        }
        return result
    }

    static func jiraError(_ error: MCPError) -> JiraError {
        switch error {
        case .notConnected: .notConnected
        case .unauthorized: .unauthorized
        case .unreachable: .unreachable
        case let .http(status): .http(status: status)
        case .invalidResponse, .responseTooLarge: .invalidResponse
        case let .authorizationFailed(message): .refused(message)
        case let .keychain(status): .keychain(status)
        case let .unsupportedServer(message), let .rpc(_, message), let .tool(message): .serverError(message)
        case .stateMismatch, .timedOut, .cancelled: .serverError(error.message)
        }
    }

    /// Every JSON document of a result: its structured content first, then each text that parses.
    static func jsonObjects(in result: MCPToolResult) -> [Any] {
        let candidates = (result.structured.map { [$0] } ?? []) + result.texts.map { Data($0.utf8) }
        return candidates.compactMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            .filter { $0 is [Any] || $0 is [String: Any] }
    }
}
