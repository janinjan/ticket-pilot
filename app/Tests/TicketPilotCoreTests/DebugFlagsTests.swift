import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct DebugFlagsTests {
    @Test func test_noVariable_thenEverythingOff() {
        let flags = DebugFlags(environment: [:])

        #expect(flags == DebugFlags(environment: ["TICKET_PILOT_DEBUG_OPEN_PANEL": "0"]))
        #expect(!flags.opensPanel)
        #expect(!flags.skipsKeychain)
        #expect(flags.fakeTicketCount == nil)
    }

    @Test func test_openPanelAndNoKeychain_thenOn() {
        let flags = DebugFlags(environment: [
            "TICKET_PILOT_DEBUG_OPEN_PANEL": "1", "TICKET_PILOT_DEBUG_NO_KEYCHAIN": "1",
        ])

        #expect(flags.opensPanel)
        #expect(flags.skipsKeychain)
    }

    @Test func test_fakeTickets_thenSkipsKeychain() {
        let flags = DebugFlags(environment: ["TICKET_PILOT_DEBUG_FAKE_TICKETS": "12"])

        #expect(flags.fakeTicketCount == 12)
        #expect(flags.skipsKeychain)
    }

    @Test func test_invalidFakeTickets_thenIgnored() {
        #expect(DebugFlags(environment: ["TICKET_PILOT_DEBUG_FAKE_TICKETS": "many"]).fakeTicketCount == nil)
        #expect(DebugFlags(environment: ["TICKET_PILOT_DEBUG_FAKE_TICKETS": "-1"]).fakeTicketCount == nil)
    }

    @Test func test_fakeIssues_thenReadyAndBacklog() {
        let issues = DebugFlags.fakeIssues(count: 3)

        #expect(issues.map(\.key) == ["FAKE-1", "FAKE-2", "FAKE-3"])
        #expect(issues.map(\.statusName) == ["To Start", "Backlog", "To Start"])
    }
}
