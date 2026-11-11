import Foundation

/// Remembers which ticket keys the user has already been told about.
public struct SeenStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// `nil` when the file is absent or unreadable.
    public func load() -> Set<String>? {
        guard
            let data = try? Data(contentsOf: file),
            let keys = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return Set(keys)
    }

    public func save(_ keys: Set<String>) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(keys.sorted())
        try data.write(to: file, options: .atomic)
    }
}

public struct DetectionOutcome: Equatable, Sendable {
    public var toNotify: [JiraIssue]
    /// The set to persist; `nil` means keep what is stored.
    public var seen: Set<String>?
    public var failed: Bool
}

public enum TicketTracker {
    public static func apply(_ result: Result<[JiraIssue], JiraError>, seen: Set<String>?) -> DetectionOutcome {
        switch result {
        case .failure:
            return DetectionOutcome(toNotify: [], seen: nil, failed: true)
        case .success(let issues):
            let current = Set(issues.map(\.key))
            guard let seen else {
                return DetectionOutcome(toNotify: [], seen: current, failed: false)
            }
            return DetectionOutcome(
                toNotify: issues.filter { !seen.contains($0.key) },
                seen: seen.union(current),
                failed: false
            )
        }
    }
}
