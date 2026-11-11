import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct ProcessRunningTests {
    @Test func systemRunnerCapturesLargeOutputAndFailures() throws {
        let runner = SystemProcessRunner()
        let big = try runner.run("/bin/sh", ["-c", "/usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' x; echo err >&2; exit 3"], currentDirectory: nil)
        #expect(big.status == 3)
        #expect(big.output.count == 300000)
        #expect(big.error == "err\n")
        #expect(throws: (any Error).self) {
            try runner.run("/nonexistent/binary", [], currentDirectory: nil)
        }
    }

    @Test func systemRunnerWithTimeoutKeepsAllOfALargeOutput() throws {
        let runner = SystemProcessRunner(timeout: 30)
        let result = try runner.run("/bin/sh", ["-c", "/usr/bin/head -c 1000000 /dev/zero | /usr/bin/tr '\\0' x"], currentDirectory: nil)
        #expect(result.status == 0)
        #expect(result.output.count == 1_000_000)
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
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ticket-pilot-pids-\(UUID().uuidString)").path
        defer {
            // Do not leave the sleeping grandchildren behind: they hold the runner's pipes.
            let pids = ((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            for pid in pids { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(atPath: pidFile)
        }
        let runner = SystemProcessRunner(timeout: 0.5)
        let start = Date()
        let script = "sleep 30 & echo $! >> \"$1\"; sleep 30 & echo $! >> \"$1\"; wait"
        let result = try runner.run("/bin/sh", ["-c", script, "sh", pidFile], currentDirectory: nil)
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
