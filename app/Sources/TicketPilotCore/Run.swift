import Foundation

/// A ticket run as written by the plugin (`ticket_pilot/runs.py`).
/// Unknown fields are ignored and optional ones may be absent, so files from
/// older or newer plugin versions stay listed.
public struct Run: Decodable, Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        case running, waiting, done, unknown
    }

    public struct SessionInfo: Decodable, Equatable, Sendable {
        public var state: String
        public var lastNotification: String?
        public var notifiedAt: Date?
        public var endedAt: Date?
        /// Where the session's last hook event ran (`cwd`), when the plugin recorded it.
        public var cwd: String?

        private enum CodingKeys: String, CodingKey {
            case state, cwd
            case lastNotification = "last_notification"
            case notifiedAt = "notified_at"
            case endedAt = "ended_at"
        }

        public init(state: String, lastNotification: String?, notifiedAt: Date?, endedAt: Date? = nil, cwd: String? = nil) {
            self.state = state
            self.lastNotification = lastNotification
            self.notifiedAt = notifiedAt
            self.endedAt = endedAt
            self.cwd = cwd
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            state = try container.decode(String.self, forKey: .state)
            lastNotification = (try? container.decodeIfPresent(String.self, forKey: .lastNotification)) ?? nil
            notifiedAt = (try? container.decodeIfPresent(Date.self, forKey: .notifiedAt)) ?? nil
            endedAt = (try? container.decodeIfPresent(Date.self, forKey: .endedAt)) ?? nil
            cwd = (try? container.decodeIfPresent(String.self, forKey: .cwd)) ?? nil
        }
    }

    public struct Waiting: Decodable, Equatable, Sendable {
        public var kind: String
        public var text: String
        public var since: Date
    }

    public struct HistoryEntry: Decodable, Equatable, Sendable {
        public var step: Int
        public var startedAt: Date
        public var endedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case step
            case startedAt = "started_at"
            case endedAt = "ended_at"
        }
    }

    public var id: String
    public var key: String
    /// The ticket's title, recorded by the plugin once it read the ticket (`run-set --title`).
    public var title: String?
    public var repo: String
    public var repoPath: String
    public var worktree: String?
    public var branch: String?
    public var sessionID: String?
    public var session: SessionInfo?
    public var step: Int
    public var stepName: String
    public var status: Status
    public var waiting: Waiting?
    public var history: [HistoryEntry]
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, key, title, repo, worktree, branch, session, step, waiting, history, status
        case repoPath = "repo_path"
        case sessionID = "session_id"
        case stepName = "step_name"
        case updatedAt = "updated_at"
    }

    public init(
        id: String, key: String, repo: String, repoPath: String, worktree: String?, branch: String?,
        sessionID: String?, session: SessionInfo?, step: Int, stepName: String, status: Status,
        waiting: Waiting?, history: [HistoryEntry], updatedAt: Date
    ) {
        self.id = id
        self.key = key
        self.repo = repo
        self.repoPath = repoPath
        self.worktree = worktree
        self.branch = branch
        self.sessionID = sessionID
        self.session = session
        self.step = step
        self.stepName = stepName
        self.status = status
        self.waiting = waiting
        self.history = history
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        repo = try container.decode(String.self, forKey: .repo)
        repoPath = try container.decode(String.self, forKey: .repoPath)
        worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        session = try? container.decodeIfPresent(SessionInfo.self, forKey: .session)
        step = try container.decode(Int.self, forKey: .step)
        stepName = try container.decode(String.self, forKey: .stepName)
        let rawStatus = try container.decode(String.self, forKey: .status)
        status = switch rawStatus {
        case "running": .running
        case "waiting": .waiting
        case "done": .done
        default: .unknown
        }
        // A malformed `waiting` or history entry is dropped, never the whole run.
        waiting = (try? container.decodeIfPresent(Waiting.self, forKey: .waiting)) ?? nil
        history = ((try? container.decodeIfPresent([Lossy<HistoryEntry>].self, forKey: .history)) ?? nil)?
            .compactMap(\.value) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// Decodes an element of a list, or nil when it is invalid, so one bad element does not fail the list.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension JSONDecoder {
    /// Decoder for run files: dates are `yyyy-MM-dd'T'HH:mm:ss'Z'` in UTC, like `runs.now()`.
    static var runDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "Invalid run date: \(text)"
                ))
            }
            return date
        }
        return decoder
    }
}
