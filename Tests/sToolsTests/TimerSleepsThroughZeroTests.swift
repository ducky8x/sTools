import Foundation
@testable import STPlatform
import Testing
@testable import TimerOverlay
@testable import sTools

// QA matrix (spec 9.2): "a Timer Overlay countdown that sleeps through zero". The engine's and the controller's own tests
// cover the clock and the wake; this runs the whole app: the switch that starts the countdown, the Dock badge, the alarm,
// the overlay, the status in the sidebar and the key that starts the next one, with the Mac "asleep" for an hour in the
// middle (the test's clock jumps and the wake notification is sent). Whether a real Mac's monotonic clock counts the sleep
// and wakes the app on time is the hand check in the M8 plan.

@MainActor
@Suite("Timer Overlay sleeping through zero", .serialized)
struct TimerSleepsThroughZeroTests {
    /// A countdown of `seconds` started the way the owner starts it, from the switch, with the Dock countdown on.
    private func start(_ harness: EverythingHarness, seconds: Int = 150) {
        harness.timer.settings.durationSeconds = seconds
        harness.timer.settings.showsDockCountdown = true
        harness.model.userSwitched(.timerOverlay, on: true)
    }

    @Test func aMacThatSleepsThroughZeroRingsOnceOnWakeAndTheNextPressStartsFresh() async throws {
        let harness = EverythingHarness()
        let display = harness.display(1)
        start(harness)
        #expect(harness.timer.phase == .counting && harness.wakeSimulator.isWatching)
        #expect(harness.model.timerDockBadge == "2:30")

        // Ten seconds go by awake...
        harness.runTimerWakes(until: { harness.timerClock.time >= 1000 + 10 })
        #expect(harness.timer.content.text == "02:20")
        #expect(harness.alarm.rings == 0)

        // ...then the Mac sleeps for an hour and wakes.
        harness.timerClock.time += 3600
        harness.wakeSimulator.macWoke()
        #expect(harness.timer.phase == .ringing, "the run finished on wake")
        #expect(harness.alarm.rings == 1, "and rings, once")
        #expect(harness.timer.status == .timesUp)
        #expect(harness.model.timerDockBadge == "0:00")
        #expect(harness.model.status(of: .timerOverlay) == .timer("Time\u{2019}s up"))
        #expect(harness.timerAnnouncer.announcements.last == .timesUp)
        #expect(harness.presenter.isShowing && !harness.panels(on: display).isEmpty)

        // The alarm and the overlay's exit count from the wake, so the person hears it all, and then it is over.
        harness.runTimerWakes(until: { !harness.presenter.isShowing && harness.timer.phase == .idle })
        #expect(harness.timer.phase == .idle && !harness.presenter.isShowing)
        #expect(harness.alarm.rings == 1, "never a second ring for one run")
        #expect(harness.model.isOn(.timerOverlay), "the tool stays on")
        #expect(harness.model.timerDockBadge == nil)
        #expect(!harness.wakeSimulator.isWatching && harness.timerScheduler.pending.isEmpty, "nothing left running")

        // The Start-timer key then starts a fresh countdown of the full length.
        harness.model.hotkeys.isEnabled = true
        let id = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 97, modifiers: []), actions: [.startTimer])
        harness.registrar.onPress?(id)
        #expect(harness.timer.phase == .counting && harness.timer.content.text == "02:30")
        #expect(harness.model.timerDockBadge == "2:30")
        await harness.finish()
    }

    /// Sleeping before zero only moves the clock: the countdown goes on from the real time left, and cues that fell in the
    /// sleep are skipped, not played late.
    @Test func aMacThatSleepsBeforeZeroCountsOnFromTheTimeLeft() async {
        let harness = EverythingHarness()
        start(harness)
        harness.runTimerWakes(until: { harness.timerClock.time >= 1000 + 10 })

        harness.timerClock.time += 130
        harness.wakeSimulator.macWoke()
        #expect(harness.timer.phase == .counting)
        #expect(harness.timer.content.text == "00:10")
        #expect(harness.model.timerDockBadge == "0:10")
        #expect(harness.alarm.rings == 0)

        harness.runTimerWakes(until: { harness.timer.phase == .ringing })
        #expect(harness.timer.phase == .ringing && harness.alarm.rings == 1)
        await harness.finish()
    }

    /// Switched off in its sleep, the timer has nothing to ring when the Mac wakes: no alarm, no overlay, no badge.
    @Test func aCountdownSwitchedOffBeforeSleepStaysQuietOnWake() async {
        let harness = EverythingHarness()
        start(harness)
        harness.runTimerWakes(until: { harness.timerClock.time >= 1000 + 5 })
        harness.model.setTool(.timerOverlay, on: false)
        #expect(!harness.wakeSimulator.isWatching, "an idle timer doesn't listen for the Mac waking")

        harness.timerClock.time += 3600
        harness.wakeSimulator.macWoke()
        #expect(harness.alarm.rings == 0 && !harness.presenter.isShowing)
        #expect(harness.model.timerDockBadge == nil && harness.model.status(of: .timerOverlay) == .off)
        await harness.finish()
    }
}
