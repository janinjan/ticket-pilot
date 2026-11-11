import Foundation

/// Filesystem locations used by ticket-pilot. Mirrors `ticket_pilot/paths.py`.
public struct StatePaths: Sendable {
    public var stateHome: URL
    public var configFile: URL

    public var runsDirectory: URL { stateHome.appendingPathComponent("runs", isDirectory: true) }
    public var appDirectory: URL { stateHome.appendingPathComponent("app", isDirectory: true) }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if let override = environment["TICKET_PILOT_HOME"], !override.isEmpty {
            stateHome = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            stateHome = home
                .appendingPathComponent("Library/Application Support/ticket-pilot", isDirectory: true)
        }
        if let override = environment["TICKET_PILOT_CONFIG"], !override.isEmpty {
            configFile = URL(fileURLWithPath: override)
        } else {
            configFile = home.appendingPathComponent(".config/ticket-pilot/config.json")
        }
    }
}
