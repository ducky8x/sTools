import Foundation
import Testing

// `waitUntil` is how the app-level tests wait for a window, a result or a recording, all of which need the main actor, as
// every other test of the bundle does. Suites run at the same time in one process, and at the start of a run on a busy Mac
// the page-render tests hold the main actor for ten seconds and more. A wait then looked twice, once before and once
// after that pause, and the pause had used up its bound: `TwoDisplaysTests.everyOverlayFitsOnADisplayOfEachKind` gave up
// after 13 seconds with the overlays it waited for still queued behind it.

@MainActor
@Suite("Waiting in the app tests")
struct WaitUntilTests {
    /// Holds the main actor for `duration`, as a page render does.
    private static func hold(_ duration: Duration) {
        let end = SuspendingClock.now.advanced(by: duration)
        while SuspendingClock.now < end {}
    }

    @Test func aPauseLongerThanTheBoundDoesNotUseItUp() async {
        var ready = false
        Task { @MainActor in
            Self.hold(.milliseconds(1_200))
            // What the wait is for comes after the pause, behind the wait's next look.
            Task { @MainActor in ready = true }
        }
        let came = await waitUntil(timeout: .seconds(1)) { ready }
        #expect(came, "the pause was another test's, so it is not the wait's time")
    }

    @Test func aConditionThatNeverComesTrueStillEndsTheWait() async {
        let start = SuspendingClock.now
        let came = await waitUntil(timeout: .milliseconds(300)) { false }
        #expect(!came)
        #expect(SuspendingClock.now - start < .seconds(60), "the wait ended")
    }

    @Test func aConditionThatIsTrueAtOnceEndsTheWaitAtOnce() async {
        let start = SuspendingClock.now
        let came = await waitUntil(timeout: .seconds(20)) { true }
        #expect(came)
        #expect(SuspendingClock.now - start < .seconds(5))
    }
}
