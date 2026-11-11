import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct PollScheduleTests {
    @Test func test_backoffDoublesFromOneMinuteUpToThirty() {
        var schedule = PollSchedule(pollMinutes: 5)
        #expect(schedule.nextDelay == .seconds(300))
        #expect(schedule.isFailing == false)

        var delays: [Duration] = []
        for _ in 1...7 {
            schedule.recordFailure()
            delays.append(schedule.nextDelay)
        }
        #expect(delays == [60, 120, 240, 480, 960, 1800, 1800].map { Duration.seconds($0) })
        #expect(schedule.isFailing == true)

        schedule.recordSuccess()
        #expect(schedule.nextDelay == .seconds(300))
        #expect(schedule.isFailing == false)

        #expect(PollSchedule(pollMinutes: 0).nextDelay == .seconds(60))
    }
}
