import Foundation

public enum NeedsYouEvent: Equatable, Sendable {
    case waiting(runID: String, key: String, kind: String, text: String)
    case reportReady(runID: String, key: String)
}

/// Spots runs that newly need the user. The first call only records the
/// current state, so launching the app never notifies about what was already
/// waiting or done.
public struct NeedsYouTracker: Sendable {
    private struct Seen: Equatable {
        var waitingSince: Date?
        var done: Bool
    }

    private var seen: [String: Seen]?

    public init() {}

    public mutating func events(for runs: [Run]) -> [NeedsYouEvent] {
        func state(of run: Run) -> Seen {
            Seen(waitingSince: run.status == .waiting ? run.waiting?.since : nil, done: run.status == .done)
        }
        // First call: record only. Later calls merge, so a run whose file is
        // briefly unreadable keeps its entry and does not look new on return.
        guard var known = seen else {
            seen = Dictionary(runs.map { ($0.id, state(of: $0)) }, uniquingKeysWith: { $1 })
            return []
        }
        var events: [NeedsYouEvent] = []
        for run in runs {
            let current = state(of: run)
            let previous = known[run.id] ?? Seen(waitingSince: nil, done: false)
            known[run.id] = current
            if let waiting = run.waiting, let since = current.waitingSince, previous.waitingSince != since {
                events.append(.waiting(runID: run.id, key: run.key, kind: waiting.kind, text: waiting.text))
            }
            if current.done, !previous.done {
                events.append(.reportReady(runID: run.id, key: run.key))
            }
        }
        seen = known
        return events
    }
}

extension NeedsYouEvent {
    public var runID: String {
        switch self {
        case let .waiting(runID, _, _, _), let .reportReady(runID, _): runID
        }
    }

    /// Identifier of the event's notification: the run plus the moment it started needing the user
    /// (`waiting.since`, or `updated_at` for a report), so each wait gets its own notification.
    public func notificationID(in runs: [Run]) -> String {
        let run = runs.first { $0.id == runID }
        let since = switch self {
        case .waiting: run?.waiting?.since ?? run?.updatedAt
        case .reportReady: run?.updatedAt
        }
        return "\(runID)@" + (since.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown")
    }
}

public struct NotificationText: Equatable, Sendable {
    public var title: String
    public var body: String

    public static func make(_ event: NeedsYouEvent) -> NotificationText {
        switch event {
        case let .waiting(_, key, kind, text):
            NotificationText(title: "\(key) needs you", body: text.isEmpty ? fallback(kind) : text)
        case let .reportReady(_, key):
            NotificationText(title: "\(key) report ready", body: "Open the report")
        }
    }

    private static func fallback(_ kind: String) -> String {
        switch kind {
        case "go": "Waiting for your go"
        case "launch_app": "Launch the app"
        case "input": "Waiting for your input"
        default: "Waiting for you"
        }
    }
}
