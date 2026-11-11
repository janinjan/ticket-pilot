import Foundation

public enum ConfigError: Error, Equatable {
    case missing(path: String)
    case invalid(String)
}

public struct JiraSettings: Decodable, Sendable {
    public var site: URL
    public var email: String
    public var keychainService: String

    private enum CodingKeys: String, CodingKey {
        case site, email
        case keychainService = "keychain_service"
    }
}

public struct MatchRules: Decodable, Sendable, Hashable {
    public var titlePrefixes: [String]
    public var labels: [String]
    public var components: [String]

    private enum CodingKeys: String, CodingKey {
        case titlePrefixes = "title_prefixes"
        case labels, components
    }

    public init(titlePrefixes: [String] = [], labels: [String] = [], components: [String] = []) {
        self.titlePrefixes = titlePrefixes
        self.labels = labels
        self.components = components
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        titlePrefixes = try container.decodeIfPresent([String].self, forKey: .titlePrefixes) ?? []
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        components = try container.decodeIfPresent([String].self, forKey: .components) ?? []
    }
}

public struct RepoConfig: Decodable, Sendable, Hashable {
    public var name: String
    public var path: String
    public var mainBranch: String
    public var review: String
    public var match: MatchRules

    private enum CodingKeys: String, CodingKey {
        case name, path, review, match
        case mainBranch = "main_branch"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        mainBranch = try container.decode(String.self, forKey: .mainBranch)
        review = try container.decode(String.self, forKey: .review)
        match = try container.decodeIfPresent(MatchRules.self, forKey: .match) ?? MatchRules()
    }
}

public struct AppConfig: Decodable, Sendable {
    public var jira: JiraSettings
    public var repos: [RepoConfig]
    public var pollMinutes: Int
    public var readyStatuses: [String]
    public var terminalApp: String?
    public var permissionMode: String?
    public var stuckMinutes: [String: Int]

    private enum CodingKeys: String, CodingKey {
        case jira, repos
        case pollMinutes = "poll_minutes"
        case readyStatuses = "ready_statuses"
        case terminalApp = "terminal_app"
        case permissionMode = "permission_mode"
        case stuckMinutes = "stuck_minutes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jira = try container.decode(JiraSettings.self, forKey: .jira)
        repos = try container.decode([RepoConfig].self, forKey: .repos)
        pollMinutes = try container.decodeIfPresent(Int.self, forKey: .pollMinutes) ?? 5
        readyStatuses = try container.decodeIfPresent([String].self, forKey: .readyStatuses) ?? ["To Start"]
        terminalApp = try container.decodeIfPresent(String.self, forKey: .terminalApp)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        stuckMinutes = try container.decodeIfPresent([String: Int].self, forKey: .stuckMinutes) ?? [:]
    }

    public static func load(from url: URL) throws(ConfigError) -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw .missing(path: url.path)
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw .invalid("\(url.path): \(error)")
        }
    }
}

extension JiraSettings {
    /// The page of an issue on the Jira site.
    public func browseURL(key: String) -> URL {
        site.appendingPathComponent("browse").appendingPathComponent(key)
    }
}

extension RepoConfig {
    /// `path` with a leading `~` expanded, as a shell would not expand it once quoted.
    public var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }
}
