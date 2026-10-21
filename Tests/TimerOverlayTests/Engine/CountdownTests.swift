import Foundation
import Testing
@testable import TimerOverlay

private func near(_ a: Double, _ b: Double, within tolerance: Double = 1e-9) -> Bool { abs(a - b) < tolerance }

/// Drives `countdown` the way the engine does: wake after each delay, update, and stop when no wake is due.
/// Returns the text shown after each wake, in order.
private func run(_ countdown: inout Countdown, from start: TimeInterval, tenths: Bool) -> [String] {
    var now = start
    var shown: [String] = []
    while let delay = countdown.delayToNextDisplayChange(at: now, tenths: tenths) {
        now += delay
        countdown.update(at: now)
        shown.append(ClockFormat.string(remaining: countdown.remaining(at: now), format: .minutesAndSeconds, tenths: tenths))
    }
    return shown
}

@Suite("Countdown")
struct CountdownTests {
    // MARK: Ported from the merged timer app's checks

    @Test func runsAndFinishesExactlyOnce() {
        var countdown = Countdown(duration: 10)
        let started = countdown.start(at: 100)
        let early = countdown.update(at: 109.9)
        let onTime = countdown.update(at: 110)
        let again = countdown.update(at: 111)
        #expect(started)
        #expect(!early)
        #expect(onTime)
        #expect(!again)
        #expect(countdown.phase == .finished)
        #expect(countdown.displaySeconds(at: 111) == 0)
    }

    @Test func pauseFreezesAndResumeContinues() {
        var countdown = Countdown(duration: 60)
        countdown.start(at: 0)
        let paused = countdown.pause(at: 20)
        #expect(paused)
        #expect(near(countdown.remaining(at: 500), 40))
        let resumed = countdown.resume(at: 500)
        #expect(resumed)
        #expect(near(countdown.remaining(at: 510), 30))
        let finished = countdown.update(at: 540)
        #expect(finished)
    }

    @Test func anExpiredRunMustFinishNotFreezeAtZero() {
        var countdown = Countdown(duration: 5)
        countdown.start(at: 0)
        let paused = countdown.pause(at: 5.001)
        let finished = countdown.update(at: 5.001)
        #expect(!paused)
        #expect(finished)
        #expect(countdown.phase == .finished)
    }

    @Test func cancelGoesBackToIdleAtTheFullDuration() {
        var countdown = Countdown(duration: 30)
        countdown.start(at: 0)
        countdown.cancel()
        #expect(countdown.phase == .idle)
        #expect(countdown.displaySeconds(at: 99) == 30)
        #expect(countdown.progress(at: 99) == 1)
    }

    @Test func invalidTransitionsAreRefused() {
        var countdown = Countdown(duration: 5)
        let pausedWhileIdle = countdown.pause(at: 0)
        let resumedWhileIdle = countdown.resume(at: 0)
        #expect(!pausedWhileIdle)
        #expect(!resumedWhileIdle)

        countdown.start(at: 0)
        let restarted = countdown.start(at: 3)
        #expect(restarted)
        #expect(near(countdown.remaining(at: 4), 4))
        countdown.pause(at: 4)
        let restartedWhilePaused = countdown.start(at: 50)
        #expect(restartedWhilePaused)
        #expect(countdown.phase == .running)
        #expect(near(countdown.remaining(at: 50), 5))

        var zero = Countdown(duration: 0)
        let zeroStarted = zero.start(at: 0)
        #expect(!zero.canStart)
        #expect(!zeroStarted)
        #expect(zero.phase == .idle)
    }

    @Test func aDurationChangeAppliesToTheNextRunOnly() {
        var finished = Countdown(duration: 3)
        finished.start(at: 0)
        finished.update(at: 3)
        finished.duration = 8
        let restarted = finished.start(at: 10)
        #expect(restarted)
        #expect(near(finished.remaining(at: 10), 8))

        var running = Countdown(duration: 10)
        running.start(at: 0)
        running.duration = 99
        #expect(near(running.remaining(at: 4), 6))
        #expect(near(running.progress(at: 5), 0.5))
    }

    @Test func theShownSecondsRoundUp() {
        var countdown = Countdown(duration: 3)
        countdown.start(at: 0)
        #expect(countdown.displaySeconds(at: 0) == 3)
        #expect(countdown.displaySeconds(at: 0.4) == 3)
        #expect(countdown.displaySeconds(at: 2.99) == 1)
    }

    @Test func wakesLandJustPastEachChange() throws {
        var countdown = Countdown(duration: 10)
        countdown.start(at: 0)
        let delay = try #require(countdown.delayToNextDisplayChange(at: 0.25))
        #expect(delay > 0.75 && delay < 0.77)
        #expect(countdown.displaySeconds(at: 0.25 + delay) == 9)
        let onBoundary = try #require(countdown.delayToNextDisplayChange(at: 1))
        #expect(onBoundary > 1 && onBoundary < 1.01)
        countdown.pause(at: 1)
        #expect(countdown.delayToNextDisplayChange(at: 1) == nil)
    }

    // MARK: Starting and restarting

    @Test func restartsFromEveryPhase() {
        var countdown = Countdown(duration: 20)
        countdown.start(at: 0)
        let whileRunning = countdown.start(at: 5)
        #expect(whileRunning && near(countdown.remaining(at: 5), 20))

        countdown.pause(at: 6)
        let whilePaused = countdown.start(at: 7)
        #expect(whilePaused && countdown.phase == .running && near(countdown.remaining(at: 7), 20))

        countdown.update(at: 30)
        #expect(countdown.phase == .finished)
        let whileFinished = countdown.start(at: 31)
        #expect(whileFinished && countdown.phase == .running && near(countdown.remaining(at: 31), 20))
    }

    @Test func aRunOfItsOwnLengthLeavesTheDurationAlone() {
        var countdown = Countdown(duration: 150)
        let test = countdown.start(at: 0, length: 5)
        #expect(test)
        #expect(countdown.duration == 150)
        #expect(countdown.length == 5)
        #expect(near(countdown.remaining(at: 1), 4))
        let finished = countdown.update(at: 5)
        #expect(finished)

        let real = countdown.start(at: 10)
        #expect(real)
        #expect(countdown.length == 150)
        let empty = countdown.start(at: 20, length: 0)
        #expect(!empty)
    }

    @Test func aNegativeOrNonFiniteDurationCannotStart() {
        var countdown = Countdown(duration: -4)
        #expect(countdown.duration == 0)
        countdown.duration = .nan
        #expect(countdown.duration == 0)
        let started = countdown.start(at: 0)
        let infinite = countdown.start(at: 0, length: .infinity)
        #expect(!started)
        #expect(!infinite)
    }

    @Test func idleShowsTheDurationAndPausedShowsTheFrozenTime() {
        var countdown = Countdown(duration: 150)
        #expect(countdown.remaining(at: 1234) == 150)
        countdown.start(at: 0)
        countdown.pause(at: 62.4)
        #expect(near(countdown.remaining(at: 9999), 87.6))
        #expect(countdown.displaySeconds(at: 9999) == 88)
    }

    // MARK: Zero and sleep

    @Test func finishesExactlyAtTheDeadline() {
        var countdown = Countdown(duration: 150)
        countdown.start(at: 1000)
        let early = countdown.update(at: 1149.999_999)
        #expect(!early)
        #expect(countdown.phase == .running)
        let onTime = countdown.update(at: 1150)
        #expect(onTime)
        #expect(countdown.phase == .finished)
        #expect(countdown.remaining(at: 1150) == 0)
    }

    @Test func sleepingAcrossZeroFinishesOnTheNextUpdate() {
        var countdown = Countdown(duration: 150)
        countdown.start(at: 0)
        // The Mac sleeps at 1:40 left and wakes an hour later; the monotonic clock counted through it.
        let finished = countdown.update(at: 3700)
        #expect(finished)
        #expect(countdown.phase == .finished)
        #expect(countdown.displaySeconds(at: 3700) == 0)
        #expect(near(countdown.timeSinceZero(at: 3700), 3550))
    }

    @Test func timeSinceZeroCountsOnlyAfterZero() {
        var countdown = Countdown(duration: 10)
        #expect(countdown.timeSinceZero(at: 50) == 0)
        countdown.start(at: 0)
        #expect(countdown.timeSinceZero(at: 5) == 0)
        countdown.update(at: 10.002)
        #expect(near(countdown.timeSinceZero(at: 17.5), 7.5))
        countdown.cancel()
        #expect(countdown.timeSinceZero(at: 20) == 0)
    }

    // MARK: Progress

    @Test func progressRunsFromOneToZero() {
        var countdown = Countdown(duration: 100)
        #expect(countdown.progress(at: 0) == 1)
        countdown.start(at: 0)
        #expect(near(countdown.progress(at: 25), 0.75))
        countdown.update(at: 100)
        #expect(countdown.progress(at: 100) == 0)
    }

    @Test func steppedProgressStepsOnceASecond() {
        var countdown = Countdown(duration: 10)
        countdown.start(at: 0)
        #expect(countdown.steppedProgress(at: 0) == 1)
        #expect(countdown.steppedProgress(at: 0.9) == 1)
        #expect(near(countdown.steppedProgress(at: 1.01), 0.9))
        #expect(near(countdown.steppedProgress(at: 1.99), 0.9))
        #expect(near(countdown.steppedProgress(at: 9.5), 0.1))
        countdown.update(at: 10)
        #expect(countdown.steppedProgress(at: 10) == 0)
    }

    // MARK: Wakes

    @Test func noWakeWhileIdlePausedOrAfterZeroWithoutOvertime() {
        var countdown = Countdown(duration: 10)
        #expect(countdown.delayToNextDisplayChange(at: 0) == nil)
        countdown.start(at: 0)
        countdown.pause(at: 3.3)
        #expect(countdown.delayToNextDisplayChange(at: 3.3, tenths: true, overtime: true) == nil)
        countdown.resume(at: 4)
        countdown.update(at: 10.7)
        #expect(countdown.phase == .finished)
        #expect(countdown.delayToNextDisplayChange(at: 10.7) == nil)
        #expect(countdown.delayToNextDisplayChange(at: 10.7, tenths: true) == nil)
    }

    @Test func aRunPastItsDeadlineAsksForAnImmediateWake() {
        var countdown = Countdown(duration: 10)
        countdown.start(at: 0)
        #expect(countdown.delayToNextDisplayChange(at: 12) == 0)
    }

    @Test func tenthsStepEveryTenthInTheLastTenSeconds() throws {
        var countdown = Countdown(duration: 30)
        countdown.start(at: 0)
        // 19.002 s in, 10.998 s left: the next change is at 10 s left, where the tenths begin.
        let toTenths = try #require(countdown.delayToNextDisplayChange(at: 19.002, tenths: true))
        #expect(near(toTenths, 1.0, within: 1e-6))
        let tenth = try #require(countdown.delayToNextDisplayChange(at: 20.002, tenths: true))
        #expect(near(tenth, 0.1, within: 1e-6))
        let wholeSecond = try #require(countdown.delayToNextDisplayChange(at: 20.002))
        #expect(near(wholeSecond, 1.0, within: 1e-6))
        let early = try #require(countdown.delayToNextDisplayChange(at: 5.002, tenths: true))
        #expect(near(early, 1.0, within: 1e-6))
    }

    @Test func overtimeKeepsWakingOnceASecondAfterZero() throws {
        var countdown = Countdown(duration: 10)
        countdown.start(at: 0)
        countdown.update(at: 10.002)
        let first = try #require(countdown.delayToNextDisplayChange(at: 10.002, overtime: true))
        #expect(near(first, 1.0, within: 1e-6))
        let later = try #require(countdown.delayToNextDisplayChange(at: 15.5, overtime: true))
        #expect(near(later, 0.502, within: 1e-6))
    }

    /// Start times include ones where `(start + 150) - start` comes out a hair above 150 in floating point.
    @Test(arguments: [0.0, 154.417_132, 1001.002, 4093.603_385, 86_400.123_456, 524_251.887_634, 9_000_000.987_654])
    func aRunWakesOncePerShownChange(start: TimeInterval) {
        var plain = Countdown(duration: 150)
        plain.start(at: start)
        let seconds = run(&plain, from: start, tenths: false)
        #expect(seconds.count == 150)
        #expect(seconds.first == "02:29")
        #expect(seconds.last == "00:00")
        #expect(Set(seconds).count == seconds.count, "every wake shows something new")
        #expect(plain.phase == .finished)

        var tenths = Countdown(duration: 150)
        tenths.start(at: start)
        let shown = run(&tenths, from: start, tenths: true)
        #expect(shown.count == 240)
        #expect(shown.contains("00:11") && shown.contains("00:10.0") && shown.contains("00:09.9"))
        #expect(!shown.contains("00:10"))
        #expect(shown.last == "00:00.0")
        #expect(Set(shown).count == shown.count, "every wake shows something new")
    }

    /// `(start + 150) - start` comes out a hair above 150 for the middle three of these.
    @Test(arguments: [0.1, 154.417_132, 2032.796_854, 4093.603_385, 9_000_000.987_654])
    func theStartShowsTheFullDurationNotOneSecondMore(start: TimeInterval) {
        var countdown = Countdown(duration: 150)
        countdown.start(at: start)
        #expect(countdown.displaySeconds(at: start) == 150)
        #expect(ClockFormat.string(remaining: countdown.remaining(at: start), format: .minutesAndSeconds, tenths: false) == "02:30")
        let delay = countdown.delayToNextDisplayChange(at: start) ?? 0
        #expect(delay > 1 && delay < 1.01)
    }

    @Test func aShortRunWithTenthsShowsTenthsFromItsStart() {
        var countdown = Countdown(duration: 150)
        countdown.start(at: 0, length: 5)
        #expect(ClockFormat.string(remaining: countdown.remaining(at: 0), format: .minutesAndSeconds, tenths: true) == "00:05.0")
        #expect(run(&countdown, from: 0, tenths: true).count == 50)
    }

    @Test func aResumedRunWakesAtItsNextChange() throws {
        var countdown = Countdown(duration: 60)
        countdown.start(at: 0)
        countdown.pause(at: 12.7)
        countdown.resume(at: 100)
        // 47.3 s left: the next change, to 47, is 0.3 s away.
        let delay = try #require(countdown.delayToNextDisplayChange(at: 100))
        #expect(near(delay, 0.302, within: 1e-6))
    }
}
