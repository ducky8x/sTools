import Foundation
import Testing
@testable import ScreenRecording

/// The base layer's refresh on overlay posts (plan decision 1), driven by a fake clock: plain seconds.
@Suite("Overlay refresh debounce")
struct OverlayRefreshDebounceTests {
    /// Which of `posts` (times in seconds) scheduled a refresh of their own.
    private func refreshes(_ posts: [TimeInterval], in debounce: inout OverlayRefreshDebounce) -> [Bool] {
        posts.map { debounce.noteChange(at: $0) }
    }

    @Test func theFirstPostSchedulesARefreshAboutFiftyMillisecondsLater() {
        var debounce = OverlayRefreshDebounce()
        #expect(debounce.delay == 0.05)
        #expect(refreshes([10], in: &debounce) == [true])
        #expect(debounce.dueTime == 10.05)
    }

    @Test func postsBeforeTheRefreshReadsTheListJoinIt() {
        var debounce = OverlayRefreshDebounce()
        #expect(refreshes([0, 0.01, 0.049], in: &debounce) == [true, false, false])
        #expect(debounce.dueTime == 0.05)
    }

    /// The refresh may already have read the window list by then, so a later post needs one of its own.
    @Test func aPostOnceTheRefreshIsDueSchedulesAnother() {
        var debounce = OverlayRefreshDebounce()
        #expect(refreshes([0, 0.05, 0.08, 3], in: &debounce) == [true, true, false, true])
        #expect(debounce.dueTime == 3.05)
    }

    @Test func aShowAndAHideInOneBurstMakeOneRefresh() {
        var debounce = OverlayRefreshDebounce()
        #expect(refreshes([1.000, 1.002, 1.020, 1.040], in: &debounce) == [true, false, false, false])
    }

    @Test func aNegativeDelayIsTreatedAsNone() {
        var debounce = OverlayRefreshDebounce(delay: -1)
        #expect(debounce.delay == 0)
        #expect(refreshes([2, 2], in: &debounce) == [true, true])
    }
}
