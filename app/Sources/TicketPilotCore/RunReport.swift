import Foundation

/// The final report of a run, saved by `tp run-report` next to the run state, and what "Read the report"
/// opens: the session while it still ends on the report, the saved report once the session went on.
public enum RunReport {
    /// A session busy for longer than this after the report was saved went on with something else.
    public static let sessionMovedOnAfter: TimeInterval = 15 * 60

    public static func file(runID: String, runsDirectory: URL) -> URL {
        runsDirectory.appendingPathComponent("\(runID).report.md")
    }

    /// True to open the saved report rather than the session: a finished run whose report was saved and
    /// whose session is gone or kept going well after it.
    public static func opensFile(run: Run, reportSavedAt: Date?, sessionActiveAt: Date?) -> Bool {
        guard run.status == .done, let reportSavedAt else { return false }
        guard let sessionActiveAt else { return true }
        return sessionActiveAt.timeIntervalSince(reportSavedAt) > sessionMovedOnAfter
    }

    /// When the session's transcript was last written, nil when it cannot be found.
    public static func sessionActiveAt(
        sessionID: String?,
        projectsDirectory: URL = SessionCommand.defaultProjectsDirectory()
    ) -> Date? {
        guard let sessionID, let transcript = SessionCommand.transcriptFile(
            sessionID: sessionID, projectsDirectory: projectsDirectory
        ) else { return nil }
        return modified(transcript)
    }

    public static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}
