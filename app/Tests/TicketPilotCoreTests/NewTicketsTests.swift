import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct NewTicketsTests {
    @Test func test_aTicketShownInAnOpenPanelLeavesAtTheClose() {
        var tickets = NewTickets()
        tickets.add(["ABC-1"])
        #expect(tickets.keys == ["ABC-1"])
        #expect(tickets.hasUnshown)

        tickets.panelOpened()
        #expect(!tickets.hasUnshown)
        #expect(tickets.keys == ["ABC-1"])

        tickets.panelClosed()
        #expect(tickets.keys.isEmpty)
        #expect(!tickets.hasUnshown)
    }

    @Test func test_aTicketArrivingWhileThePanelIsOpenLeavesAtTheNextClose() {
        var tickets = NewTickets()
        tickets.panelOpened()
        tickets.add(["ABC-1"])
        #expect(tickets.keys == ["ABC-1"])
        #expect(!tickets.hasUnshown)

        tickets.panelClosed()
        #expect(tickets.keys.isEmpty)
    }

    @Test func test_aTicketNeverShownStaysAfterAClose() {
        var tickets = NewTickets()
        tickets.panelOpened()
        tickets.panelClosed()
        tickets.add(["ABC-1"])
        tickets.panelClosed()
        #expect(tickets.keys == ["ABC-1"])
        #expect(tickets.hasUnshown)
    }

    @Test func test_onlyTheTicketsShownLeave() {
        var tickets = NewTickets()
        tickets.add(["ABC-1"])
        tickets.panelOpened()
        tickets.panelClosed()
        tickets.add(["ABC-2"])
        #expect(tickets.keys == ["ABC-2"])
    }

    @Test func test_aTicketNoLongerListedIsDroppedForGood() {
        var tickets = NewTickets()
        tickets.add(["ABC-1", "ABC-2"])
        tickets.keepOnly(["ABC-2"])
        #expect(tickets.keys == ["ABC-2"])

        // Listed again (its run was released): it is not new any more.
        tickets.keepOnly(["ABC-1", "ABC-2"])
        #expect(tickets.keys == ["ABC-2"])
    }

    /// Before Jira first answered, the listed tickets are unknown: the saved ones are kept.
    @Test func test_nothingIsDroppedBeforeJiraAnswered() {
        var tickets = NewTickets(keys: ["ABC-1"])
        tickets.keepOnly(nil)
        #expect(tickets.keys == ["ABC-1"])
        #expect(tickets.hasUnshown)
    }

    @Test func test_aDroppedTicketIsNoLongerCountedAsShown() {
        var tickets = NewTickets()
        tickets.add(["ABC-1"])
        tickets.panelOpened()
        tickets.keepOnly([])
        tickets.add(["ABC-1"])
        tickets.panelClosed()
        // Added again while the panel was open: shown, so it leaves.
        #expect(tickets.keys.isEmpty)
    }

    @Test func test_theKeysSurviveARelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/new.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = SeenStore(file: file)
        #expect(NewTickets.load(from: store).keys.isEmpty)

        var tickets = NewTickets()
        tickets.add(["ABC-2", "ABC-1"])
        try tickets.save(to: store)
        #expect(NewTickets.load(from: store) == NewTickets(keys: ["ABC-1", "ABC-2"]))

        try Data("not json".utf8).write(to: file)
        #expect(NewTickets.load(from: store).keys.isEmpty)
    }
}
