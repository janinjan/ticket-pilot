import Foundation
import Testing
@testable import TicketPilotCore

struct RunReportTests {
    static let saved = Date(timeIntervalSince1970: 1_000_000)

    /// "Read the report" shows the report, even while the session still runs or went on after it: the
    /// session has its own entry in the card's menu.
    @Test func finishedRunWithAReportOpensTheReport() {
        #expect(RunReport.opensFile(run: NeedsYouTrackerTests.run(status: .done), reportSavedAt: Self.saved))
    }

    @Test func noReportOpensTheSession() {
        #expect(!RunReport.opensFile(run: NeedsYouTrackerTests.run(status: .done), reportSavedAt: nil))
    }

    @Test func unfinishedRunOpensTheSession() {
        #expect(!RunReport.opensFile(run: NeedsYouTrackerTests.run(status: .waiting), reportSavedAt: Self.saved))
    }
}
