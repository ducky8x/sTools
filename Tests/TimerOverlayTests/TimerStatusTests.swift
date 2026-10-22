import Foundation
import Testing
@testable import TimerOverlay

@Suite("Timer status")
struct TimerStatusTests {
    @Test func theWordsForEachState() {
        #expect(TimerStatus.off.text == "Off")
        #expect(TimerStatus.ready.text == "Ready")
        #expect(TimerStatus.counting(secondsLeft: 134).text == "2:14 left")
        #expect(TimerStatus.counting(secondsLeft: 5).text == "0:05 left")
        #expect(TimerStatus.paused(secondsLeft: 62).text == "Paused, 1:02")
        #expect(TimerStatus.paused(secondsLeft: 359_999).text == "Paused, 99:59:59", "the longest status")
        #expect(TimerStatus.timesUp.text == "Time\u{2019}s up")
    }

    @Test func theDockBadgeShowsTheTimeLeftOnlyWhileARunIsUnderWay() {
        #expect(TimerStatus.off.badgeText == nil && TimerStatus.ready.badgeText == nil)
        #expect(TimerStatus.counting(secondsLeft: 134).badgeText == "2:14")
        #expect(TimerStatus.paused(secondsLeft: 3_723).badgeText == "1:02:03")
        #expect(TimerStatus.timesUp.badgeText == "0:00")
    }
}
