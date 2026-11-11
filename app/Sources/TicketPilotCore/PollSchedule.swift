/// Delay between Jira polls: the configured interval, or a doubling backoff (1 to 30 minutes) while failing.
public struct PollSchedule: Sendable {
    private static let maxBackoffSeconds = 30 * 60

    private let normalSeconds: Int
    private var failures = 0

    public init(pollMinutes: Int) {
        normalSeconds = max(pollMinutes, 1) * 60
    }

    public mutating func recordSuccess() {
        failures = 0
    }

    public mutating func recordFailure() {
        failures += 1
    }

    public var isFailing: Bool { failures > 0 }

    public var nextDelay: Duration {
        guard failures > 0 else { return .seconds(normalSeconds) }
        let exponent = min(failures - 1, 10)
        return .seconds(min(60 << exponent, Self.maxBackoffSeconds))
    }
}
