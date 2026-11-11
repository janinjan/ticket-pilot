import Foundation
import TicketPilotCore

/// The result of one Jira poll.
enum PollOutcome {
    case failed
    /// `newTickets`: the issues to notify, empty on the first successful poll.
    case succeeded(issues: [JiraIssue], newTickets: [JiraIssue])
}

/// Polls Jira on `PollSchedule` and keeps `seen.json` up to date (never from a failed poll).
@MainActor
final class JiraPoller {
    private let seenStore: SeenStore
    private let onPoll: @MainActor (PollOutcome, any JiraSearching) async -> Void
    private var seen: Set<String>?
    private var schedule = PollSchedule(pollMinutes: 5)
    private var task: Task<Void, Never>?

    init(seenStore: SeenStore, onPoll: @escaping @MainActor (PollOutcome, any JiraSearching) async -> Void) {
        self.seenStore = seenStore
        self.onPoll = onPoll
        seen = seenStore.load()
    }

    /// Polls at once, then on schedule; replaces any previous loop.
    func start(jira: any JiraSearching, pollMinutes: Int) {
        stop()
        schedule = PollSchedule(pollMinutes: pollMinutes)
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.poll(jira) else { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func poll(_ jira: any JiraSearching) async -> Duration {
        let result: Result<[JiraIssue], JiraError>
        do throws(JiraError) {
            result = .success(try await jira.openAssignedIssues())
        } catch {
            result = .failure(error)
        }
        guard !Task.isCancelled else { return schedule.nextDelay }
        let outcome = TicketTracker.apply(result, seen: seen)
        guard !outcome.failed, case let .success(issues) = result else {
            schedule.recordFailure()
            await onPoll(.failed, jira)
            return schedule.nextDelay
        }
        schedule.recordSuccess()
        if let newSeen = outcome.seen {
            seen = newSeen
            try? seenStore.save(newSeen)
        }
        await onPoll(.succeeded(issues: issues, newTickets: outcome.toNotify), jira)
        return schedule.nextDelay
    }
}
