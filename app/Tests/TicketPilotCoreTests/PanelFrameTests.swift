import CoreGraphics
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct PanelFrameTests {
    @Test func test_shorterContent_thenShrinksKeepingTheTopEdge() {
        let fitted = PanelFrame.fitted(CGRect(x: 995, y: 452, width: 300, height: 497), contentHeight: 321)

        #expect(fitted == CGRect(x: 995, y: 628, width: 300, height: 321))
        #expect(fitted?.maxY == 949)
    }

    @Test func test_tallerContent_thenGrowsKeepingTheTopEdge() {
        let fitted = PanelFrame.fitted(CGRect(x: 992, y: 735, width: 300, height: 214), contentHeight: 307)

        #expect(fitted == CGRect(x: 992, y: 642, width: 300, height: 307))
    }

    @Test func test_sameHeight_thenNothingToDo() {
        #expect(PanelFrame.fitted(CGRect(x: 0, y: 100, width: 300, height: 200), contentHeight: 200.2) == nil)
    }

    @Test func test_noHeightYet_thenNothingToDo() {
        #expect(PanelFrame.fitted(CGRect(x: 0, y: 100, width: 300, height: 200), contentHeight: 0) == nil)
    }
}
