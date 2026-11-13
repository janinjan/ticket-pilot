import Foundation
import Testing
@testable import TicketPilotCore

struct RunReportTests {
    static let saved = Date(timeIntervalSince1970: 1_000_000)

    @Test func sessionThatEndsOnTheReportIsOpened() {
        #expect(!RunReport.opensFile(
            run: NeedsYouTrackerTests.run(status: .done),
            reportSavedAt: Self.saved,
            sessionActiveAt: Self.saved.addingTimeInterval(60)
        ))
    }

    @Test func sessionThatWentOnOpensTheReport() {
        #expect(RunReport.opensFile(
            run: NeedsYouTrackerTests.run(status: .done),
            reportSavedAt: Self.saved,
            sessionActiveAt: Self.saved.addingTimeInterval(RunReport.sessionMovedOnAfter + 1)
        ))
    }

    @Test func sessionGoneOpensTheReport() {
        #expect(RunReport.opensFile(
            run: NeedsYouTrackerTests.run(status: .done),
            reportSavedAt: Self.saved,
            sessionActiveAt: nil
        ))
    }

    @Test func noReportOpensTheSession() {
        #expect(!RunReport.opensFile(
            run: NeedsYouTrackerTests.run(status: .done),
            reportSavedAt: nil,
            sessionActiveAt: Self.saved
        ))
    }

    @Test func unfinishedRunOpensTheSession() {
        #expect(!RunReport.opensFile(
            run: NeedsYouTrackerTests.run(status: .waiting),
            reportSavedAt: Self.saved,
            sessionActiveAt: nil
        ))
    }

    @Test func sessionActivityIsItsTranscriptDate() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("tp-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projects) }
        let project = projects.appendingPathComponent("-Users-me")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = "7b236dc9-0839-4de5-942b-49ea7585b3a0"
        let transcript = project.appendingPathComponent("\(id).jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        try FileManager.default.setAttributes([.modificationDate: Self.saved], ofItemAtPath: transcript.path)
        #expect(RunReport.sessionActiveAt(sessionID: id, projectsDirectory: projects) == Self.saved)
    }
}
