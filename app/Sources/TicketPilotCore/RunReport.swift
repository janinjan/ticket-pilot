import Foundation

/// The final report of a run, saved by `tp run-report` next to the run state, and what "Read the report"
/// opens: the saved report of a finished run, in a window of the app; the session has its own entry in the
/// card's menu ("Open the session").
public enum RunReport {
    public static func file(runID: String, runsDirectory: URL) -> URL {
        runsDirectory.appendingPathComponent("\(runID).report.md")
    }

    /// True to open the saved report rather than the session: a finished run whose report was saved.
    public static func opensFile(run: Run, reportSavedAt: Date?) -> Bool {
        run.status == .done && reportSavedAt != nil
    }

    public static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}
