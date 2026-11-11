import Foundation
import Testing
@testable import TicketPilotCore

@Suite struct ProcessRunningTests {
    @Test func systemRunnerCapturesLargeOutputAndFailures() throws {
        let runner = SystemProcessRunner()
        let big = try runner.run("/bin/sh", ["-c", "yes x | head -c 300000; echo err >&2; exit 3"], currentDirectory: nil)
        #expect(big.status == 3)
        #expect(big.output.count == 300000)
        #expect(big.error == "err\n")
        #expect(throws: (any Error).self) {
            try runner.run("/nonexistent/binary", [], currentDirectory: nil)
        }
    }

    @Test func systemRunnerTerminatesAProcessThatOutlivesItsTimeout() throws {
        let runner = SystemProcessRunner(timeout: 0.5)
        let start = Date()
        let result = try runner.run("/bin/sleep", ["5"], currentDirectory: nil)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(result.status != 0)
        #expect(result.error.contains("timed out"))
    }

    @Test func systemRunnerReturnsEvenWhenAGrandchildKeepsThePipesOpen() throws {
        let runner = SystemProcessRunner(timeout: 0.5)
        let start = Date()
        let result = try runner.run("/bin/sh", ["-c", "sleep 30 & sleep 30"], currentDirectory: nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(result.status != 0)
        #expect(result.error.contains("timed out"))
    }

    @Test func systemRunnerWithTimeoutLetsAFastProcessFinish() throws {
        let runner = SystemProcessRunner(timeout: 5)
        let result = try runner.run("/bin/echo", ["hi"], currentDirectory: nil)
        #expect(result.status == 0)
        #expect(result.output == "hi\n")
    }
}
