import AppKit
import Foundation
import Observation
import os
import Testing
@testable import TimerOverlay

// MARK: - Fakes (private to this file; shared fakes start in the controller's TestSupport)

@MainActor
private final class FakeClock: TimerClock {
    var time: TimeInterval
    init(_ time: TimeInterval = 5000) { self.time = time }
    func now() -> TimeInterval { time }
}

@MainActor
private final class FakeWake: TimerScheduledWake {
    let due: TimeInterval
    let action: @MainActor () -> Void
    var isCancelled = false
    var hasFired = false

    init(due: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.due = due
        self.action = action
    }

    func cancel() { isCancelled = true }
}

/// Wakes only when the test fires them, moving the fake clock to each wake's due time.
@MainActor
private final class FakeScheduler: TimerScheduling {
    let clock: FakeClock
    private(set) var wakes: [FakeWake] = []
    private(set) var mostPendingAtOnce = 0
    private(set) var fired = 0

    init(clock: FakeClock) { self.clock = clock }

    var pending: [FakeWake] { wakes.filter { !$0.isCancelled && !$0.hasFired } }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledWake {
        let wake = FakeWake(due: clock.time + max(0, delay), action: action)
        wakes.append(wake)
        mostPendingAtOnce = max(mostPendingAtOnce, pending.count)
        return wake
    }

    /// Moves the clock to the earliest pending wake and fires it. False when nothing is pending.
    @discardableResult
    func fireNext() -> Bool {
        guard let next = pending.min(by: { $0.due < $1.due }) else { return false }
        clock.time = max(clock.time, next.due)
        next.hasFired = true
        fired += 1
        next.action()
        return true
    }

    /// Fires wakes until none is pending, or `limit` have fired. Returns how many fired.
    @discardableResult
    func fireAll(limit: Int = 10_000) -> Int {
        var count = 0
        while count < limit, fireNext() { count += 1 }
        return count
    }
}

@MainActor
private final class FakeActivity: TimerActivity {
    private(set) var isHeld = false
    private(set) var begins = 0
    private(set) var unbalanced = false

    func begin() {
        if isHeld { unbalanced = true }
        isHeld = true
        begins += 1
    }

    func end() {
        if !isHeld { unbalanced = true }
        isHeld = false
    }
}

@MainActor
private final class FakeWakeWatcher: TimerWakeWatching {
    private var handler: (@MainActor () -> Void)?
    private(set) var starts = 0
    var isWatching: Bool { handler != nil }

    func start(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        starts += 1
    }

    func stop() { handler = nil }

    /// What `NSWorkspace.didWakeNotification` would do.
    func macWoke() { handler?() }
}

@MainActor
private struct Rig {
    let clock = FakeClock()
    let scheduler: FakeScheduler
    let activity = FakeActivity()
    let watcher = FakeWakeWatcher()
    let engine: TimerEngine
    var ticks: [TimeInterval] { recorder.ticks }
    var finishes: [TimeInterval] { recorder.finishes }
    private let recorder = Recorder()

    init(duration: TimeInterval = 150, tenths: Bool = false, overtime: Bool = false) {
        scheduler = FakeScheduler(clock: clock)
        engine = TimerEngine(duration: duration, clock: clock, scheduler: scheduler, activity: activity, wakeWatcher: watcher)
        engine.showsTenths = tenths
        engine.showsOvertime = overtime
        let recorder = recorder
        engine.onTick = { recorder.ticks.append($0) }
        engine.onFinish = { recorder.finishes.append($0) }
    }

    /// The text the overlay would show now.
    var shown: String {
        ClockFormat.string(remaining: engine.countdown.remaining(at: clock.time), format: .minutesAndSeconds, tenths: engine.showsTenths)
    }

    /// Nothing scheduled, held or watched.
    var isQuiet: Bool { !engine.hasPendingWake && scheduler.pending.isEmpty && !activity.isHeld && !watcher.isWatching }
}

@MainActor
private final class Recorder {
    var ticks: [TimeInterval] = []
    var finishes: [TimeInterval] = []
}

/// A value closures can change, for counting what they did.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Waits, without blocking the main actor, until `condition` holds or `timeout` of awake time passes. The bound is a
/// clock, not a count of polls, so a busy Mac that polls less often still gets the whole time; `SuspendingClock`
/// stops while the Mac sleeps, so a sleep mid-test doesn't use it up.
@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

// MARK: - Tests

@MainActor
@Suite("Timer engine")
struct TimerEngineTests {
    // MARK: Cost (the plan's Acceptance)

    @Test func idleRunsNothing() {
        let rig = Rig()
        #expect(rig.isQuiet)
        #expect(rig.activity.begins == 0 && rig.watcher.starts == 0 && rig.scheduler.wakes.isEmpty)
        rig.engine.refresh()
        rig.engine.showsTenths = true
        rig.engine.duration = 300
        #expect(rig.isQuiet)
        #expect(rig.scheduler.wakes.isEmpty)
    }

    @Test func aTwoThirtyCountdownWakesOncePerShownChange() {
        let rig = Rig()
        rig.engine.start()
        let wakes = rig.scheduler.fireAll()
        #expect(wakes == 150)
        #expect(wakes <= 151)
        #expect(rig.scheduler.mostPendingAtOnce == 1)
        #expect(rig.engine.phase == .finished)
        #expect(rig.ticks.count == 149)
        #expect(rig.finishes.count == 1)
    }

    @Test func withTenthsItWakesAtMost241Times() {
        let rig = Rig(tenths: true)
        rig.engine.start()
        let wakes = rig.scheduler.fireAll()
        #expect(wakes == 240)
        #expect(wakes <= 241)
        #expect(rig.scheduler.mostPendingAtOnce == 1)
        #expect(rig.finishes.count == 1)
    }

    @Test func eachTickShowsSomethingNew() {
        let rig = Rig(duration: 20, tenths: true)
        rig.engine.start()
        let shown = Box([rig.shown])
        rig.engine.onTick = { _ in shown.value.append(rig.shown) }
        rig.engine.onFinish = { _ in shown.value.append(rig.shown) }
        rig.scheduler.fireAll()
        #expect(shown.value.first == "00:20")
        #expect(shown.value.contains("00:11") && shown.value.contains("00:10.0") && shown.value.contains("00:00.1"))
        #expect(shown.value.last == "00:00.0")
        #expect(shown.value.count == 1 + 110, "9 whole seconds, 10.0, 99 tenths and zero")
        #expect(Set(shown.value).count == shown.value.count, "no wake repeats what's already shown")
    }

    @Test func noWakeIsPendingWhileIdlePausedOrAfterZero() {
        let rig = Rig(duration: 30)
        #expect(!rig.engine.hasPendingWake)
        rig.engine.start()
        #expect(rig.scheduler.pending.count == 1)
        rig.scheduler.fireNext()
        rig.scheduler.fireNext()
        rig.clock.time += 0.4
        let paused = rig.engine.pause()
        #expect(paused)
        #expect(!rig.engine.hasPendingWake && rig.scheduler.pending.isEmpty)
        rig.clock.time += 600
        let resumed = rig.engine.resume()
        #expect(resumed)
        #expect(rig.scheduler.pending.count == 1)
        rig.scheduler.fireAll()
        #expect(rig.engine.phase == .finished)
        #expect(!rig.engine.hasPendingWake && rig.scheduler.pending.isEmpty)
        #expect(rig.scheduler.mostPendingAtOnce == 1)
    }

    @Test func theActivityIsHeldFromStartToCancelExceptWhilePaused() {
        let rig = Rig(duration: 10)
        #expect(!rig.activity.isHeld)
        rig.engine.start()
        #expect(rig.activity.isHeld && rig.engine.isHoldingActivity)
        rig.scheduler.fireNext()
        rig.engine.pause()
        #expect(!rig.activity.isHeld && !rig.engine.isHoldingActivity)
        rig.engine.resume()
        #expect(rig.activity.isHeld)
        rig.scheduler.fireAll()
        #expect(rig.engine.phase == .finished)
        #expect(rig.activity.isHeld, "held through the alarm and the exit, until the run is cancelled")
        rig.engine.cancel()
        #expect(!rig.activity.isHeld && !rig.engine.isHoldingActivity)
        #expect(rig.activity.begins == 2)
        #expect(!rig.activity.unbalanced)
    }

    @Test func theWakeWatcherRunsOnlyWhileCounting() {
        let rig = Rig(duration: 10)
        #expect(!rig.watcher.isWatching)
        rig.engine.start()
        #expect(rig.watcher.isWatching && rig.engine.isWatchingForWake)
        rig.engine.pause()
        #expect(!rig.watcher.isWatching)
        rig.engine.resume()
        #expect(rig.watcher.isWatching)
        rig.scheduler.fireAll()
        #expect(!rig.watcher.isWatching && !rig.engine.isWatchingForWake)
        rig.engine.start()
        #expect(rig.watcher.isWatching)
        rig.engine.cancel()
        #expect(!rig.watcher.isWatching)
        #expect(rig.watcher.starts == 3)
    }

    @Test(arguments: [false, true])
    func cancellingFromAnyPhaseLeavesNothingRunning(overtime: Bool) {
        let running = Rig(overtime: overtime)
        running.engine.start()
        running.scheduler.fireNext()
        running.engine.cancel()
        #expect(running.isQuiet)

        let paused = Rig(overtime: overtime)
        paused.engine.start()
        paused.engine.pause()
        paused.engine.cancel()
        #expect(paused.isQuiet)

        let finished = Rig(duration: 3, overtime: overtime)
        finished.engine.start()
        finished.scheduler.fireAll(limit: 10)
        #expect(finished.engine.phase == .finished)
        finished.engine.cancel()
        #expect(finished.isQuiet)
        #expect(finished.engine.phase == .idle)
    }

    @Test func observersSeeTheCountdownChangeOnlyWithItsRun() {
        let rig = Rig(duration: 5)
        rig.engine.start()
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = rig.engine.countdown } onChange: { changes.withLock { $0 += 1 } }
        rig.scheduler.fireNext()
        rig.scheduler.fireNext()
        rig.engine.refresh()
        #expect(changes.withLock { $0 } == 0, "a plain tick doesn't touch the observed countdown")
        rig.scheduler.fireAll()
        #expect(changes.withLock { $0 } == 1, "reaching zero does")
    }

    // MARK: Ticks and zero

    @Test func zeroIsReportedOnceWithTheTimeItWasNoticed() throws {
        let rig = Rig(duration: 10)
        rig.engine.start()
        let started = rig.clock.time
        rig.scheduler.fireAll()
        let finish = try #require(rig.finishes.first)
        #expect(rig.finishes.count == 1)
        #expect(finish >= started + 10 && finish < started + 10.01)
        #expect(rig.ticks.allSatisfy { $0 < started + 10 })
    }

    @Test func sleepingAcrossZeroRingsOnWake() throws {
        let rig = Rig()
        rig.engine.start()
        for _ in 0..<10 { rig.scheduler.fireNext() }
        // The Mac sleeps with 2:20 left and wakes an hour later; the pending wake hasn't fired yet.
        rig.clock.time += 3600
        rig.watcher.macWoke()
        #expect(rig.finishes == [rig.clock.time])
        #expect(rig.engine.phase == .finished)
        #expect(rig.scheduler.pending.isEmpty, "the stale wake was cancelled")
        #expect(rig.activity.isHeld && !rig.watcher.isWatching)
        rig.scheduler.fireAll()
        #expect(rig.finishes.count == 1)
    }

    @Test func wakingBeforeZeroCountsOnFromTheNewTime() throws {
        let rig = Rig(duration: 150)
        rig.engine.start()
        let started = rig.clock.time
        rig.clock.time += 42.5
        rig.watcher.macWoke()
        #expect(rig.ticks == [started + 42.5])
        #expect(rig.shown == "01:48")
        #expect(rig.scheduler.pending.count == 1)
        let next = try #require(rig.scheduler.pending.first)
        #expect(abs(next.due - (started + 43.002)) < 1e-6)
        #expect(rig.scheduler.mostPendingAtOnce == 1)
    }

    @Test func overtimeKeepsWakingOnceASecondUntilCancelled() {
        let rig = Rig(duration: 5, overtime: true)
        rig.engine.start()
        let started = rig.clock.time
        while rig.engine.phase != .finished { rig.scheduler.fireNext() }
        #expect(rig.finishes.count == 1)
        let ticksAtZero = rig.ticks.count
        for _ in 0..<7 { rig.scheduler.fireNext() }
        #expect(rig.ticks.count == ticksAtZero + 7)
        #expect(ClockFormat.overtime(rig.engine.countdown.timeSinceZero(at: rig.clock.time), format: .minutesAndSeconds) == "+0:07")
        #expect(rig.clock.time - started < 12.1)
        #expect(rig.scheduler.mostPendingAtOnce == 1)
        rig.engine.cancel()
        #expect(rig.isQuiet)
    }

    @Test func turningOvertimeOffAfterZeroStopsTheWakes() {
        let rig = Rig(duration: 2, overtime: true)
        rig.engine.start()
        while rig.engine.phase != .finished { rig.scheduler.fireNext() }
        #expect(rig.engine.hasPendingWake)
        rig.engine.showsOvertime = false
        #expect(!rig.engine.hasPendingWake && rig.scheduler.pending.isEmpty)
        rig.engine.showsOvertime = true
        #expect(rig.scheduler.pending.count == 1)
    }

    @Test func tenthsSwitchedOnMidRunTakeEffectAtOnce() {
        let rig = Rig(duration: 30)
        rig.engine.start()
        for _ in 0..<25 { rig.scheduler.fireNext() }
        #expect(rig.shown == "00:05")
        rig.engine.showsTenths = true
        #expect(rig.scheduler.pending.count == 1)
        rig.scheduler.fireNext()
        #expect(rig.shown == "00:04.9")
    }

    // MARK: Runs

    @Test func aRunOfItsOwnLengthLeavesTheDurationAlone() {
        let rig = Rig(duration: 150)
        let started = rig.engine.start(length: 5)
        #expect(started)
        #expect(rig.engine.duration == 150)
        #expect(rig.scheduler.fireAll() == 5)
        #expect(rig.engine.phase == .finished)
    }

    @Test func restartingKeepsOneWake() {
        let rig = Rig()
        rig.engine.start()
        rig.scheduler.fireNext()
        rig.clock.time += 0.3
        rig.engine.start()
        rig.engine.start()
        #expect(rig.scheduler.pending.count == 1)
        #expect(rig.scheduler.mostPendingAtOnce == 1)
        #expect(rig.shown == "02:30")
        #expect(rig.activity.begins == 1 && !rig.activity.unbalanced)
    }

    @Test func aDurationChangeAppliesToTheNextRun() {
        let rig = Rig(duration: 60)
        rig.engine.start()
        rig.engine.duration = 10
        rig.scheduler.fireNext()
        #expect(rig.shown == "00:59")
        rig.engine.cancel()
        rig.engine.start()
        #expect(rig.shown == "00:10")
    }

    @Test func aZeroLengthRunDoesNotStart() {
        let rig = Rig(duration: 0)
        let started = rig.engine.start()
        #expect(!started)
        #expect(rig.isQuiet && rig.scheduler.wakes.isEmpty)
    }

    @Test func pauseIsRefusedOnceZeroHasPassed() {
        let rig = Rig(duration: 3)
        rig.engine.start()
        rig.clock.time += 3.001
        let paused = rig.engine.pause()
        #expect(!paused)
        #expect(rig.engine.phase == .running)
        rig.scheduler.fireNext()
        #expect(rig.engine.phase == .finished)
        #expect(rig.finishes.count == 1)
    }

    @Test func pauseAndResumeOutsideARunAreRefused() {
        let rig = Rig()
        let pausedIdle = rig.engine.pause()
        let resumedIdle = rig.engine.resume()
        #expect(!pausedIdle && !resumedIdle)
        rig.engine.start()
        let resumedRunning = rig.engine.resume()
        #expect(!resumedRunning)
        #expect(rig.engine.phase == .running)
    }

    // MARK: The live seams

    @Test func theMonotonicClockMovesForward() {
        let clock = MonotonicClock()
        let first = clock.now()
        let second = clock.now()
        #expect(first > 0)
        #expect(second >= first)
        #expect(abs(first - Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9) < 1)
    }

    @Test func theLiveSchedulerRunsAnActionOnceAndNeverACancelledOne() async throws {
        let scheduler = DispatchTimerScheduler()
        let fired = Box(0)
        let cancelledFired = Box(false)
        let wake = scheduler.schedule(after: 0.01) { fired.value += 1 }
        let cancelled = scheduler.schedule(after: 0.01) { cancelledFired.value = true }
        cancelled.cancel()
        #expect(await waitUntil { fired.value > 0 }, "the live wake fires")
        // The cancelled wake was due at the same moment, so a moment more is when it would have fired.
        try await Task.sleep(for: .milliseconds(50))
        #expect(fired.value == 1)
        #expect(!cancelledFired.value)
        wake.cancel()
    }

    @Test func theLiveActivityIsHeldBetweenBeginAndEnd() {
        let activity = ProcessTimerActivity()
        #expect(!activity.isHeld)
        activity.begin()
        activity.begin()
        #expect(activity.isHeld)
        activity.end()
        #expect(!activity.isHeld)
        activity.end()
        #expect(!activity.isHeld)
    }

    @Test func theLiveWakeWatcherHearsTheWakeNotificationUntilStopped() {
        let center = NotificationCenter()
        let watcher = WorkspaceWakeWatcher(center: center)
        let wakes = Box(0)
        watcher.start { wakes.value += 1 }
        #expect(watcher.isWatching)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(wakes.value == 1)
        watcher.stop()
        #expect(!watcher.isWatching)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(wakes.value == 1)
    }
}
