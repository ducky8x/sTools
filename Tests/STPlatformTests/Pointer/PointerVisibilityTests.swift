import Foundation
import Synchronization
import Testing
@testable import STPlatform

/// Waits, without blocking the main actor, until `condition` holds or `timeout` of awake time passes.
@MainActor
private func waitUntil(timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// The pointer's state as a test sets it, read from any thread like the real call.
final class FakePointerReader: PointerVisibilityReading {
    private let state: Mutex<(visible: Bool, reads: Int)>
    let isSupported: Bool

    init(visible: Bool, isSupported: Bool = true) {
        state = Mutex((visible, 0))
        self.isSupported = isSupported
    }

    var visible: Bool {
        get { state.withLock { $0.visible } }
        set { state.withLock { $0.visible = newValue } }
    }

    var reads: Int { state.withLock { $0.reads } }

    func isPointerVisible() -> Bool? {
        guard isSupported else { return nil }
        return state.withLock { state in
            state.reads += 1
            return state.visible
        }
    }
}

/// What a watch reported, in order.
@MainActor
private final class Readings {
    var values: [Bool] = []
    var record: @MainActor @Sendable (Bool) -> Void { { [weak self] in self?.values.append($0) } }
}

/// Watching whether the pointer shows, with a reader the test sets: the real call is never made here.
@MainActor
@Suite("Watching the pointer")
struct PointerVisibilityTests {
    @Test func itPollsEveryFiftyMilliseconds() {
        #expect(PointerVisibilityPoller.interval == .milliseconds(50))
    }

    /// The state comes before `start` returns, so the Crosshair never shows over a menu while waiting for a tick.
    @Test func theFirstReadingComesAtOnce() {
        let reader = FakePointerReader(visible: true)
        let poller = PointerVisibilityPoller(reader: reader, interval: .milliseconds(5))
        let seen = Readings()
        poller.start(seen.record)
        #expect(seen.values == [true])
        #expect(poller.isWatching)
        poller.stop()
        #expect(!poller.isWatching)
    }

    /// Each change is reported once, on the main actor; a reading that matches the last one isn't.
    @Test func itReportsEachChange() async {
        let reader = FakePointerReader(visible: false)
        let poller = PointerVisibilityPoller(reader: reader, interval: .milliseconds(5))
        let seen = Readings()
        poller.start(seen.record)
        #expect(seen.values == [false])

        reader.visible = true
        #expect(await waitUntil { seen.values == [false, true] })
        let reads = reader.reads
        #expect(await waitUntil { reader.reads > reads + 3 }, "it keeps reading")
        #expect(seen.values == [false, true], "the same reading again says nothing")

        reader.visible = false
        #expect(await waitUntil { seen.values == [false, true, false] })
        poller.stop()
    }

    /// Once stopped it reads nothing more, and a change read before the stop never arrives.
    @Test func stoppingEndsTheReads() async throws {
        let reader = FakePointerReader(visible: false)
        let poller = PointerVisibilityPoller(reader: reader, interval: .milliseconds(5))
        let seen = Readings()
        poller.start(seen.record)
        #expect(await waitUntil { reader.reads > 2 })
        poller.stop()
        reader.visible = true
        let reads = reader.reads
        try await Task.sleep(for: .milliseconds(60))
        #expect(reader.reads <= reads + 1, "at most a tick already under way")
        #expect(seen.values == [false])
    }

    /// Starting again starts over: the old watch's changes are dropped, and the new one reads the state at once.
    @Test func startingAgainReplacesTheWatch() async {
        let reader = FakePointerReader(visible: false)
        let poller = PointerVisibilityPoller(reader: reader, interval: .milliseconds(5))
        let first = Readings()
        let second = Readings()
        poller.start(first.record)
        poller.start(second.record)
        reader.visible = true
        #expect(await waitUntil { second.values == [false, true] })
        #expect(first.values == [false])
        poller.stop()
    }

    /// Without the call there's nothing to watch: it never starts.
    @Test func withoutTheCallItNeverStarts() {
        let reader = FakePointerReader(visible: true, isSupported: false)
        let poller = PointerVisibilityPoller(reader: reader, interval: .milliseconds(5))
        #expect(!poller.isSupported)
        let seen = Readings()
        poller.start(seen.record)
        #expect(!poller.isWatching)
        #expect(seen.values.isEmpty)
        #expect(reader.reads == 0)
    }
}
