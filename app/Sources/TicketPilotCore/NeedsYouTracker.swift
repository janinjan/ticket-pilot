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

    /// What a question with no text reads as, by its kind.
    static func fallback(_ kind: String) -> String {
        switch kind {
        case "go": "Waiting for your go"
        case "launch_app": "Launch the app"
        case "input": "Waiting for your input"
        default: "Waiting for you"
        }
    }
}

/// What Settings says about the app's notifications, and its test notification.
public enum NotificationStatus {
    public static let testTitle = "TicketPilot test"
    public static let testBody = "This is how TicketPilot tells you a run needs you."
    /// System Settings › Notifications.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    public static let howToAllow = AlertText(
        title: "Notifications are not allowed",
        message: "In System Settings › Notifications › TicketPilot, turn on Allow notifications, choose Banners "
            + "or Alerts, and turn on Play sound for notifications."
    )

    /// "Notifications: allowed", "… sound off" (allowed without sound) or "… not allowed".
    public static func text(allowed: Bool, soundAllowed: Bool) -> String {
        guard allowed else { return "Notifications: not allowed" }
        return soundAllowed ? "Notifications: allowed" : "Notifications: sound off"
    }
}

/// When a needs-you notification is posted, and with or without sound.
public enum NotificationTiming: Equatable, Sendable {
    case now(sound: Bool)
    /// At `Date`, silently, if the wait that began at `since` is still pending then.
    case after(Date, since: Date)
}

/// Which waits are worth a notification. The plugin's Stop hook marks every end of a Claude Code turn as a
/// wait (`input`): while the user is in the session, that is no news.
public enum NotificationPolicy {
    /// How long a plain end of turn must stay unanswered before it is notified.
    public static let quietInputDelay: TimeInterval = 120

    /// A go, a question or "launch the app", and a ready report: at once, with sound. A plain end of turn
    /// (`input`): two minutes after it began, silently.
    public static func timing(for event: NeedsYouEvent, in runs: [Run], now: Date) -> NotificationTiming {
        guard case let .waiting(runID, _, kind, _) = event, kind == "input" else { return .now(sound: true) }
        guard let since = runs.first(where: { $0.id == runID })?.waiting?.since else { return .now(sound: false) }
        let deadline = since.addingTimeInterval(quietInputDelay)
        return deadline > now ? .after(deadline, since: since) : .now(sound: false)
    }

    /// The run still waits, and for the same wait (`since` unchanged).
    public static func isStillPending(runID: String, since: Date, in runs: [Run]) -> Bool {
        guard let run = runs.first(where: { $0.id == runID }) else { return false }
        return run.status == .waiting && run.waiting?.since == since
    }

    /// Ghostty is the frontmost app and its selected tab is the run's session (its title names the key).
    public static func userIsWatching(frontmostIsGhostty: Bool, selectedTabTitle: String?, key: String) -> Bool {
        guard frontmostIsGhostty, let title = selectedTabTitle else { return false }
        return SessionLocator.names(title, key: key)
    }
}
