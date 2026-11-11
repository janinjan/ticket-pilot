import Foundation
import Testing
@testable import TicketPilotCore

/// Touches the real Keychain: only runs when `TICKET_PILOT_KEYCHAIN_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TICKET_PILOT_KEYCHAIN_TESTS"] == "1"), .timeLimit(.minutes(1)))
struct KeychainTests {
    @Test func setPasswordAddsThenReplaces() throws {
        let service = "ticket-pilot-test-\(UUID().uuidString)"
        defer { Keychain.deletePassword(service: service, account: "tester") }

        try Keychain.setPassword("first", service: service, account: "tester")
        #expect(try Keychain.password(service: service) == "first")

        try Keychain.setPassword("second", service: service, account: "tester")
        #expect(try Keychain.password(service: service) == "second")

        // An item stored under another account is replaced, not duplicated.
        try Keychain.setPassword("third", service: service, account: "other")
        #expect(try Keychain.password(service: service) == "third")

        Keychain.deletePassword(service: service, account: "tester")
        Keychain.deletePassword(service: service, account: "other")
        #expect(throws: KeychainError.notFound) { try Keychain.password(service: service) }
    }
}
