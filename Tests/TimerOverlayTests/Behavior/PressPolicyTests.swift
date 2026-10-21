import Foundation
import Testing
@testable import TimerOverlay

private func settings(
    counting: TimerOverlaySettings.PressWhileCounting = .restart, ringing: TimerOverlaySettings.PressWhileRinging = .newCountdown,
    gesture: TimerOverlaySettings.CancelGesture = .doublePress
) -> TimerOverlaySettings {
    var settings = TimerOverlaySettings.defaultValue
    settings.pressWhileCounting = counting
    settings.pressWhileRinging = ringing
    settings.cancelGesture = gesture
    return settings
}

/// Sends one input and returns what it did.
private func send(
    _ policy: inout PressPolicy, _ input: PressPolicy.Input, at time: TimeInterval, in phase: TimerPhase,
    _ settings: TimerOverlaySettings = .defaultValue
) -> PressPolicy.Action {
    policy.handle(input, at: time, phase: phase, settings: settings)
}

@Suite("Press policy")
struct PressPolicyTests {
    // MARK: The press table (spec 5.6.2), one press at a time

    @Test(arguments: TimerOverlaySettings.PressWhileCounting.allCases, TimerOverlaySettings.PressWhileRinging.allCases)
    func aPressWhileIdleOrLeavingStarts(counting: TimerOverlaySettings.PressWhileCounting, ringing: TimerOverlaySettings.PressWhileRinging) {
        let chosen = settings(counting: counting, ringing: ringing)
        #expect(PressPolicy.action(forPressIn: .idle, settings: chosen) == .start)
        #expect(PressPolicy.action(forPressIn: .leaving, settings: chosen) == .start)
    }

    @Test func theDefaultsRestartAndStartANewCountdown() {
        let defaults = TimerOverlaySettings.defaultValue
        #expect(PressPolicy.action(forPressIn: .counting, settings: defaults) == .restart)
        #expect(PressPolicy.action(forPressIn: .paused, settings: defaults) == .restart)
        #expect(PressPolicy.action(forPressIn: .ringing, settings: defaults) == .newCountdown)
        #expect(PressPolicy.action(forPressIn: .lingering, settings: defaults) == .newCountdown)
    }

    @Test(arguments: [
        (TimerOverlaySettings.PressWhileCounting.restart, PressPolicy.Action.restart, PressPolicy.Action.restart),
        (.cancel, .cancel, .cancel),
        (.pauseOrResume, .pause, .resume),
        (.ignore, .ignore, .ignore),
    ])
    func aPressWhileCountingOrPaused(
        choice: TimerOverlaySettings.PressWhileCounting, whileCounting: PressPolicy.Action, whilePaused: PressPolicy.Action
    ) {
        let chosen = settings(counting: choice)
        #expect(PressPolicy.action(forPressIn: .counting, settings: chosen) == whileCounting)
        #expect(PressPolicy.action(forPressIn: .paused, settings: chosen) == whilePaused)
    }

    @Test(arguments: [
        (TimerOverlaySettings.PressWhileRinging.newCountdown, PressPolicy.Action.newCountdown),
        (.silenceAndHide, .silenceAndHide),
        (.ignore, .ignore),
    ])
    func aPressWhileRingingOrLingering(choice: TimerOverlaySettings.PressWhileRinging, action: PressPolicy.Action) {
        let chosen = settings(ringing: choice)
        #expect(PressPolicy.action(forPressIn: .ringing, settings: chosen) == action)
        #expect(PressPolicy.action(forPressIn: .lingering, settings: chosen) == action)
    }

    @Test func spacedPressesFollowTheTable() {
        var policy = PressPolicy()
        #expect(send(&policy, .press, at: 0, in: .idle) == .start)
        #expect(send(&policy, .press, at: 10, in: .counting) == .restart)
        #expect(send(&policy, .press, at: 20, in: .paused) == .restart)
        #expect(send(&policy, .press, at: 200, in: .ringing) == .newCountdown)
        #expect(send(&policy, .press, at: 300, in: .lingering) == .newCountdown)
    }

    // MARK: Double press (0.4 s)

    @Test(arguments: [TimerPhase.counting, .paused, .ringing, .lingering])
    func aSecondPressWithin0_4sCancelsALiveRun(phase: TimerPhase) {
        var policy = PressPolicy()
        _ = send(&policy, .press, at: 100, in: phase)
        #expect(send(&policy, .press, at: 100.3, in: phase) == .cancel)
    }

    @Test func theFirstPressHasAlreadyActed() {
        var policy = PressPolicy()
        #expect(send(&policy, .press, at: 0, in: .idle) == .start)
        #expect(send(&policy, .press, at: 0.25, in: .counting) == .cancel)
    }

    @Test func theWindowIs0_4s() {
        var onTheEdge = PressPolicy()
        _ = send(&onTheEdge, .press, at: 50, in: .counting)
        #expect(send(&onTheEdge, .press, at: 50.4, in: .counting) == .cancel)

        var tooSlow = PressPolicy()
        _ = send(&tooSlow, .press, at: 50, in: .counting)
        #expect(send(&tooSlow, .press, at: 50.41, in: .counting) == .restart)
    }

    @Test func aThirdQuickPressStartsACountdownAgain() {
        var policy = PressPolicy()
        #expect(send(&policy, .press, at: 0, in: .idle) == .start)
        #expect(send(&policy, .press, at: 0.2, in: .counting) == .cancel)
        #expect(send(&policy, .press, at: 0.4, in: .leaving) == .start)
        #expect(send(&policy, .press, at: 0.6, in: .counting) == .cancel)
        #expect(send(&policy, .press, at: 0.8, in: .idle) == .start)
    }

    @Test func aQuickSecondPressWithNothingLiveDoesNothing() {
        // The first press silenced and hid the alarm, so the second has nothing left to cancel.
        var policy = PressPolicy()
        let quiet = settings(ringing: .silenceAndHide)
        #expect(send(&policy, .press, at: 0, in: .ringing, quiet) == .silenceAndHide)
        #expect(send(&policy, .press, at: 0.3, in: .leaving, quiet) == .ignore)
        #expect(send(&policy, .press, at: 0.6, in: .leaving, quiet) == .start)
    }

    @Test func aDoublePressCancelsEvenWhenOnePressIsIgnored() {
        var policy = PressPolicy()
        let steady = settings(counting: .ignore)
        #expect(send(&policy, .press, at: 30, in: .counting, steady) == .ignore)
        #expect(send(&policy, .press, at: 30.2, in: .counting, steady) == .cancel)
    }

    @Test func aDoublePressAfterAPauseCancels() {
        var policy = PressPolicy()
        let toggle = settings(counting: .pauseOrResume)
        #expect(send(&policy, .press, at: 30, in: .counting, toggle) == .pause)
        #expect(send(&policy, .press, at: 30.3, in: .paused, toggle) == .cancel)
    }

    @Test(arguments: [TimerOverlaySettings.CancelGesture.hold, .off])
    func withoutTheDoublePressGestureEveryPressFollowsTheTable(gesture: TimerOverlaySettings.CancelGesture) {
        var policy = PressPolicy()
        let chosen = settings(gesture: gesture)
        #expect(send(&policy, .press, at: 0, in: .idle, chosen) == .start)
        #expect(send(&policy, .press, at: 0.1, in: .counting, chosen) == .restart)
        #expect(send(&policy, .press, at: 0.2, in: .counting, chosen) == .restart)
    }

    @Test func resetForgetsTheLastPress() {
        var policy = PressPolicy()
        _ = send(&policy, .press, at: 0, in: .idle)
        policy.reset()
        #expect(send(&policy, .press, at: 0.1, in: .counting) == .restart)
        #expect(policy == {
            var fresh = PressPolicy()
            _ = send(&fresh, .press, at: 0.1, in: .counting)
            return fresh
        }())
    }

    // MARK: Hold (1 s)

    @Test(arguments: [TimerPhase.counting, .paused, .ringing, .lingering])
    func holdingOneSecondCancelsOnRelease(phase: TimerPhase) {
        var policy = PressPolicy()
        let hold = settings(gesture: .hold)
        _ = send(&policy, .press, at: 10, in: phase, hold)
        #expect(send(&policy, .release, at: 11, in: phase, hold) == .cancel)
    }

    @Test func thePressActsAtOnceAndATapNeverCancels() {
        var policy = PressPolicy()
        let hold = settings(gesture: .hold)
        #expect(send(&policy, .press, at: 0, in: .counting, hold) == .restart)
        #expect(send(&policy, .release, at: 0.99, in: .counting, hold) == .ignore)
        #expect(send(&policy, .press, at: 5, in: .counting, hold) == .restart)
        #expect(send(&policy, .release, at: 7.5, in: .counting, hold) == .cancel)
    }

    @Test func aHoldWithNothingLiveDoesNothing() {
        var policy = PressPolicy()
        let hold = settings(gesture: .hold)
        _ = send(&policy, .press, at: 0, in: .idle, hold)
        #expect(send(&policy, .release, at: 2, in: .idle, hold) == .ignore)
        _ = send(&policy, .press, at: 10, in: .leaving, hold)
        #expect(send(&policy, .release, at: 12, in: .leaving, hold) == .ignore)
    }

    @Test(arguments: [TimerOverlaySettings.CancelGesture.doublePress, .off])
    func releasesDoNothingWithoutTheHoldGesture(gesture: TimerOverlaySettings.CancelGesture) {
        var policy = PressPolicy()
        let chosen = settings(gesture: gesture)
        _ = send(&policy, .press, at: 0, in: .counting, chosen)
        #expect(send(&policy, .release, at: 3, in: .counting, chosen) == .ignore)
    }

    @Test func aReleaseWithoutAPressDoesNothing() {
        var policy = PressPolicy()
        #expect(send(&policy, .release, at: 9, in: .counting, settings(gesture: .hold)) == .ignore)
    }

    @Test func aReleaseDoesNotCountAsAPress() {
        var policy = PressPolicy()
        #expect(send(&policy, .press, at: 0, in: .idle) == .start)
        _ = send(&policy, .release, at: 0.1, in: .counting)
        #expect(send(&policy, .press, at: 0.3, in: .counting) == .cancel)
    }
}
