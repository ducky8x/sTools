import CoreGraphics
import Foundation
import Observation
import STDesign
@testable import STPlatform
import Testing
@testable import TimerOverlay

/// Whether an observation reported a change. Observation calls back from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var fired: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Brings a run of the rig's saved duration to `phase`: counting 3 s in, paused there, ringing, or lingering after
/// the alarm. Idle and leaving start nothing.
@MainActor
private func reach(_ phase: TimerPhase, on rig: TimerRig) {
    switch phase {
    case .idle, .leaving:
        return
    case .counting, .paused, .ringing, .lingering:
        rig.controller.start()
    }
    switch phase {
    case .counting:
        rig.scheduler.advance(by: 3)
    case .paused:
        rig.scheduler.advance(by: 3)
        rig.controller.pause()
    case .ringing:
        rig.runToZero()
    case .lingering:
        rig.runToZero()
        while rig.controller.phase == .ringing, rig.scheduler.fireNext() {}
    case .idle, .leaving:
        break
    }
}

@MainActor
@Suite("Timer Overlay controller")
struct TimerOverlayControllerTests {
    // MARK: - Cost (the plan's Acceptance)

    @Test func switchingOnRunsNothing() async {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        #expect(rig.isQuiet)
        #expect(rig.presenter.popIns.isEmpty && rig.scheduler.wakes.isEmpty && rig.activity.begins == 0)
        #expect(rig.alarm.rings.isEmpty && rig.alarm.cues.isEmpty)
        #expect(rig.controller.status == .ready)
        await rig.setMinecraft(on: timerTestDisplay)
        #expect(rig.controller.environmentChanges == 0, "nothing follows Minecraft while idle")
    }

    @Test func aRunThatHasLeftLeavesNothingRunning() async {
        let rig = TimerRig { $0.durationSeconds = 10 }
        rig.controller.setEnabled(true)
        #expect(rig.controller.press() == .acted)
        #expect(rig.presenter.isShowing && rig.activity.isHeld && rig.wakeWatcher.isWatching)
        #expect(rig.controller.isWatchingEnvironment)
        rig.scheduler.fireAll()
        #expect(rig.controller.phase == .idle)
        #expect(rig.alarm.rings.count == 1)
        #expect(rig.presenter.popOuts.count == 1, "the overlay left, releasing its panel")
        #expect(rig.isQuiet)
        await rig.setMinecraft(on: timerSecondTestDisplay)
        #expect(rig.controller.environmentChanges == 0)
    }

    @Test func aTenSecondCountdownUpdatesTheOverlayOncePerSecond() {
        let rig = TimerRig { $0.durationSeconds = 10 }
        rig.controller.setEnabled(true)
        rig.controller.start()
        #expect(rig.presenter.popIns.map(\.content.text) == ["00:10"])
        rig.runToZero()
        #expect(rig.presenter.updates.map(\.text)
            == ["00:09", "00:08", "00:07", "00:06", "00:05", "00:04", "00:03", "00:02", "00:01", "00:00"])
        #expect(rig.presenter.updates.last?.state == .timesUp)
        rig.scheduler.fireAll()
        #expect(rig.presenter.updates.count == 10, "the alarm and the exit change nothing the overlay shows")
    }

    @Test func theStatusChangesAtMostOnceASecondEvenWithTenths() {
        let rig = TimerRig { $0.durationSeconds = 20; $0.showsTenths = true }
        rig.controller.setEnabled(true)
        let flag = Flag()
        func watch() { withObservationTracking { _ = rig.controller.status } onChange: { flag.fired = true } }
        var changes = 0
        var badges: [String?] = []
        watch()
        rig.controller.start()
        repeat {
            if flag.fired {
                changes += 1
                flag.fired = false
                badges.append(rig.controller.status.badgeText)
            }
            watch()
        } while rig.controller.phase == .counting && rig.scheduler.fireNext()
        if flag.fired { changes += 1 }
        #expect(rig.controller.phase == .ringing)
        #expect(changes <= 21)
        #expect(changes == 21)
        #expect(rig.presenter.updates.count > 100, "the overlay shows tenths")
        #expect(badges.first == "0:20" && badges.contains("0:01"))
        #expect(rig.controller.status.badgeText == "0:00", "the Dock badge follows the status")
    }

    @Test func aReducedMotionRunMovesNothing() {
        let rig = TimerRig(reduceMotion: true) { $0.durationSeconds = 5 }
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.scheduler.fireAll()
        #expect(rig.presenter.popIns.count == 1 && rig.presenter.popOuts.count == 1)
        #expect(rig.presenter.pulses.count == 3)
        #expect(rig.presenter.popIns.allSatisfy { $0.reduceMotion })
        #expect(rig.presenter.popOuts.allSatisfy { $0 } && rig.presenter.pulses.allSatisfy { $0 })
        #expect(rig.presenter.movingSteps.isEmpty)
    }

    @Test func reducedMotionAppliesFromTheNextMotion() {
        let rig = TimerRig { $0.durationSeconds = 2; $0.whileRinging = .quickFlashes }
        rig.controller.setEnabled(true)
        rig.controller.start()
        #expect(!rig.presenter.movingSteps.isEmpty, "the pop-in moves")
        let moved = rig.presenter.movingSteps.count
        rig.theme.motionMode = .reduced
        rig.scheduler.fireAll()
        #expect(rig.presenter.pulses.count == 9, "three flashes per ring")
        #expect(rig.presenter.pulses.allSatisfy { $0 } && rig.presenter.popOuts == [true])
        #expect(rig.presenter.movingSteps.count == moved, "no flash and no exit moved")
    }

    // MARK: - The press table (spec 5.6.2)

    @Test func aPressWhileOffSwitchesTheToolOnAndStarts() {
        let rig = TimerRig()
        rig.controller.requestEnable = { [weak controller = rig.controller] in
            controller?.setEnabled(true)
            return true
        }
        #expect(rig.controller.press() == .acted)
        #expect(rig.controller.isEnabled && rig.controller.phase == .counting)
        #expect(rig.presenter.popIns.count == 1)
    }

    @Test func aPressWhileOffThatCantSwitchOnDoesNothing() {
        let rig = TimerRig()
        var asked = 0
        rig.controller.requestEnable = {
            asked += 1
            return false
        }
        #expect(rig.controller.press() == .couldNotStart)
        #expect(asked == 1)
        #expect(!rig.controller.isEnabled && rig.controller.phase == .idle && rig.controller.status == .off)
        #expect(rig.isQuiet && rig.presenter.popIns.isEmpty)
        #expect(!rig.controller.start() && !rig.controller.runTest())
        #expect(asked == 3)
    }

    @Test(arguments: TimerOverlaySettings.PressWhileCounting.allCases)
    func aPressWhileCounting(_ choice: TimerOverlaySettings.PressWhileCounting) {
        let rig = TimerRig { $0.pressWhileCounting = choice }
        rig.controller.setEnabled(true)
        #expect(rig.controller.press() == .acted)
        rig.scheduler.advance(by: 5.01)
        let result = rig.controller.press()
        switch choice {
        case .restart:
            #expect(result == .acted && rig.controller.phase == .counting)
            #expect(rig.controller.content.text == "02:30" && rig.presenter.popIns.count == 1)
            #expect(rig.announcer.announcements == [.started(seconds: 150), .started(seconds: 150)])
        case .cancel:
            #expect(result == .acted && rig.controller.phase == .idle && rig.presenter.popOuts.count == 1)
            #expect(rig.isQuiet)
            #expect(rig.controller.isEnabled && rig.controller.status == .ready, "a single press that cancels keeps the tool on")
        case .pauseOrResume:
            #expect(result == .acted && rig.controller.phase == .paused)
            #expect(rig.controller.status == .paused(secondsLeft: 145))
            #expect(rig.controller.isEnabled, "pausing keeps the tool on")
            rig.clock.time += 1
            #expect(rig.controller.press() == .acted && rig.controller.phase == .counting)
        case .ignore:
            #expect(result == .ignored && rig.controller.phase == .counting && rig.controller.content.text == "02:25")
        }
    }

    @Test func aPressWhilePausedRestarts() {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.scheduler.advance(by: 3)
        rig.controller.pause()
        #expect(rig.controller.press() == .acted)
        #expect(rig.controller.phase == .counting && rig.controller.content.text == "02:30")
    }

    @Test(arguments: TimerOverlaySettings.PressWhileRinging.allCases, [false, true])
    func aPressWhileRingingOrLingering(_ choice: TimerOverlaySettings.PressWhileRinging, lingering: Bool) {
        let rig = TimerRig { $0.durationSeconds = 2; $0.pressWhileRinging = choice }
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.runToZero()
        if lingering {
            while rig.controller.phase == .ringing { rig.scheduler.fireNext() }
            #expect(rig.controller.phase == .lingering && !rig.alarm.isPlaying)
        } else {
            #expect(rig.controller.phase == .ringing && rig.alarm.isPlaying)
        }
        let result = rig.controller.press()
        switch choice {
        case .newCountdown:
            #expect(result == .acted && rig.controller.phase == .counting && rig.controller.content.text == "00:02")
            #expect(!rig.alarm.isPlaying && rig.presenter.popIns.count == 1, "the same plate counts again")
        case .silenceAndHide:
            #expect(result == .acted && rig.controller.phase == .idle && !rig.alarm.isPlaying)
            #expect(rig.isQuiet)
            #expect(rig.controller.isEnabled && rig.controller.status == .ready, "a single press that silences keeps the tool on")
        case .ignore:
            #expect(result == .ignored && rig.controller.phase == (lingering ? .lingering : .ringing))
            #expect(rig.alarm.isPlaying == !lingering)
        }
    }

    @Test func aPressWhileLeavingStartsANewCountdown() {
        let rig = TimerRig()
        rig.presenter.exitsAtOnce = false
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.scheduler.advance(by: 2)
        rig.controller.cancel()
        #expect(rig.controller.phase == .leaving && rig.presenter.isLeaving)
        #expect(rig.controller.press() == .acted)
        #expect(rig.controller.phase == .counting && rig.presenter.popIns.count == 2)
        rig.presenter.finishExit()
        #expect(rig.controller.phase == .counting, "the overtaken exit finishes nothing")
    }

    // MARK: - The cancel gestures

    @Test func aDoublePressCancelsAndSwitchesOff() {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        #expect(rig.controller.press() == .acted)
        rig.clock.time += 0.3
        #expect(rig.controller.press() == .acted)
        #expect(rig.controller.phase == .idle && rig.presenter.popOuts.count == 1)
        #expect(!rig.controller.isEnabled && rig.controller.status == .off && rig.isQuiet)
    }

    /// Spec 5.6.2: a double press while counting, paused, ringing or lingering cancels the run and switches the tool
    /// off; the next press switches it back on and starts a fresh countdown.
    @Test(arguments: [TimerPhase.counting, .paused, .ringing, .lingering])
    func aDoublePressSwitchesOffAndTheNextPressStartsAfresh(from phase: TimerPhase) {
        let rig = TimerRig { $0.durationSeconds = 10 }
        rig.controller.setEnabled(true)
        reach(phase, on: rig)
        #expect(rig.controller.phase == phase && rig.presenter.isShowing)
        #expect(rig.controller.press() == .acted)
        rig.clock.time += 0.3
        #expect(rig.controller.press() == .acted)
        #expect(!rig.controller.isEnabled && rig.controller.status == .off)
        #expect(rig.controller.phase == .idle && !rig.alarm.isPlaying && rig.isQuiet)
        #expect(rig.presenter.popOuts.count == 1, "the overlay left the way it came")
        let popIns = rig.presenter.popIns.count

        var asked = 0
        rig.controller.requestEnable = { [weak controller = rig.controller] in
            asked += 1
            controller?.setEnabled(true)
            return true
        }
        rig.clock.time += 1
        #expect(rig.controller.press() == .acted)
        #expect(asked == 1, "the press switches the tool on through the app")
        #expect(rig.controller.isEnabled && rig.controller.phase == .counting)
        #expect(rig.controller.content.text == "00:10" && rig.controller.status == .counting(secondsLeft: 10))
        #expect(rig.presenter.popIns.count == popIns + 1 && rig.presenter.popIns.last?.content.text == "00:10")
        #expect(rig.announcer.announcements.last == .started(seconds: 10))
    }

    @Test func aDoublePressStopsTheAlarmEvenWhenAPressIsIgnored() {
        let rig = TimerRig { $0.durationSeconds = 2; $0.pressWhileRinging = .ignore }
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.runToZero()
        #expect(rig.controller.press() == .ignored && rig.alarm.isPlaying)
        rig.clock.time += 0.2
        #expect(rig.controller.press() == .acted)
        #expect(rig.alarm.stops == 1 && !rig.controller.isEnabled && rig.isQuiet)
    }

    @Test func aDoublePressSwitchesOffEvenWithNothingLeftToCancel() {
        let rig = TimerRig { $0.durationSeconds = 2; $0.pressWhileRinging = .silenceAndHide }
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.runToZero()
        #expect(rig.controller.press() == .acted && rig.controller.phase == .idle && rig.controller.isEnabled)
        rig.clock.time += 0.3
        #expect(rig.controller.press() == .acted)
        #expect(!rig.controller.isEnabled && rig.controller.status == .off && rig.isQuiet)
    }

    @Test func pausingKeepsTheToolOn() {
        let rig = TimerRig { $0.pressWhileCounting = .pauseOrResume }
        rig.controller.setEnabled(true)
        rig.controller.press()
        rig.clock.time += 2
        #expect(rig.controller.press() == .acted && rig.controller.phase == .paused)
        #expect(rig.controller.isEnabled && rig.controller.status == .paused(secondsLeft: 148))
        rig.controller.resume()
        rig.controller.pause()
        #expect(rig.controller.isEnabled, "the page's Pause keeps it on too")
    }

    @Test func aSecondPressAfterTheWindowRestarts() {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        rig.controller.press()
        rig.clock.time += 0.5
        #expect(rig.controller.press() == .acted)
        #expect(rig.controller.phase == .counting && rig.announcer.announcements.count == 2)
    }

    @Test func aThirdQuickPressStartsAgain() {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        rig.controller.press()
        rig.clock.time += 0.2
        rig.controller.press()
        #expect(rig.controller.phase == .idle && !rig.controller.isEnabled)
        rig.clock.time += 0.2
        #expect(rig.controller.press() == .acted)
        #expect(rig.controller.isEnabled && rig.controller.phase == .counting)
        rig.clock.time += 0.2
        #expect(rig.controller.press() == .acted, "the press after a fresh start can make a new double press")
        #expect(!rig.controller.isEnabled)
    }

    @Test func holdingTheKeyASecondCancelsAndSwitchesOff() {
        let rig = TimerRig { $0.cancelGesture = .hold }
        rig.controller.setEnabled(true)
        rig.controller.press()
        rig.clock.time += 0.5
        rig.controller.release()
        #expect(rig.controller.phase == .counting, "a short press only starts")
        rig.clock.time += 1
        rig.controller.press()
        rig.clock.time += 0.3
        #expect(rig.controller.phase == .counting, "a quick second press restarts while holding is the gesture")
        rig.clock.time += 0.7
        rig.controller.release()
        #expect(rig.controller.phase == .idle && !rig.controller.isEnabled && rig.controller.status == .off)
        #expect(rig.isQuiet)
        rig.clock.time += 1
        #expect(rig.controller.press() == .acted)
        #expect(rig.controller.isEnabled && rig.controller.phase == .counting && rig.controller.content.text == "02:30")
        rig.clock.time += 0.2
        rig.controller.release()
        #expect(rig.controller.isEnabled, "a tap starts and stays on")
    }

    @Test func aReleaseWhileOffDoesNothing() {
        let rig = TimerRig { $0.cancelGesture = .hold }
        rig.controller.setEnabled(true)
        rig.controller.press()
        rig.controller.setEnabled(false)
        rig.clock.time += 2
        rig.controller.release()
        #expect(!rig.controller.isEnabled && rig.controller.status == .off && rig.isQuiet)
    }

    @Test func withNoGestureADoublePressRestarts() {
        let rig = TimerRig { $0.cancelGesture = .off }
        rig.controller.setEnabled(true)
        rig.controller.press()
        rig.clock.time += 0.2
        #expect(rig.controller.press() == .acted)
        #expect(rig.controller.phase == .counting && rig.controller.isEnabled)
    }

    // MARK: - Zero, the alarm and the leave

    @Test(arguments: [1, 3, 10], TimerOverlaySettings.Leave.allCases)
    func theOverlayLeavesOnTime(rings: Int, leave: TimerOverlaySettings.Leave) throws {
        let rig = TimerRig { $0.durationSeconds = 3; $0.rings = rings; $0.leave = leave }
        rig.controller.settings.soundID = try rig.ownSound(seconds: 1.5)
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.runToZero()
        let zero = rig.clock.time
        #expect(rig.controller.phase == .ringing && rig.controller.status == .timesUp)
        while rig.presenter.popOuts.isEmpty, rig.scheduler.fireNext() {}
        let expected = switch leave {
        case .afterLastRing: Double(rings) * 1.5 + Double(rings - 1) * 0.35 + 2
        case .afterZero: 5.0
        }
        #expect(abs(rig.clock.time - zero - expected) < 1e-6)
        #expect(rig.controller.phase == .idle && rig.isQuiet)
        let heard = try #require(rig.alarm.rings.first)
        #expect(heard.sound.lastPathComponent == "Tone.caf" && abs(heard.volume - 0.8) < 1e-9)
        #expect(rig.alarm.ringStarts == Array(0..<heard.schedule.ringStarts.count))
        #expect(rig.presenter.pulses.count == heard.schedule.ringStarts.count, "one pulse per ring")
    }

    @Test(arguments: TimerOverlaySettings.Leave.allCases)
    func sleepingAcrossZeroRingsOnWake(leave: TimerOverlaySettings.Leave) throws {
        let rig = TimerRig { $0.leave = leave }
        rig.controller.settings.soundID = try rig.ownSound(seconds: 1.5)
        rig.controller.setEnabled(true)
        rig.controller.start()
        for _ in 0..<10 { rig.scheduler.fireNext() }
        rig.clock.time += 3600
        rig.wakeWatcher.macWoke()
        let woke = rig.clock.time
        #expect(rig.controller.phase == .ringing && rig.alarm.rings.count == 1)
        #expect(rig.announcer.announcements.last == .timesUp)
        while rig.presenter.popOuts.isEmpty, rig.scheduler.fireNext() {}
        #expect(abs(rig.clock.time - woke - (leave == .afterLastRing ? 7.2 : 5)) < 1e-6,
                "times after zero count from the wake, so the alarm is heard")
        #expect(rig.isQuiet)
    }

    @Test func theChimePlaysAtItsTime() {
        let rig = TimerRig { $0.durationSeconds = 60; $0.beforeZero = .chime }
        rig.controller.setEnabled(true)
        rig.controller.start()
        let started = rig.clock.time
        var chimedAt: TimeInterval?
        while rig.controller.phase == .counting, rig.scheduler.fireNext() {
            if chimedAt == nil, !rig.alarm.cues.isEmpty { chimedAt = rig.clock.time - started }
        }
        #expect(rig.alarm.cues == [.chime])
        #expect(chimedAt.map { abs($0 - 30) < 0.01 } == true)
    }

    @Test func ticksPlayInTheLastFiveSeconds() {
        let rig = TimerRig { $0.durationSeconds = 10; $0.beforeZero = .ticks; $0.showsTenths = true }
        rig.controller.setEnabled(true)
        rig.controller.start()
        let started = rig.clock.time
        var tickedAt: [TimeInterval] = []
        while rig.controller.phase == .counting, rig.scheduler.fireNext() {
            if rig.alarm.cues.count > tickedAt.count { tickedAt.append(rig.clock.time - started) }
        }
        #expect(rig.alarm.cues == Array(repeating: .tick, count: 5))
        #expect(zip(tickedAt, [5.0, 6, 7, 8, 9]).allSatisfy { abs($0 - $1) < 0.01 })
    }

    @Test func aCueWhoseTimePassedDuringSleepIsSkipped() {
        let rig = TimerRig { $0.beforeZero = .chime }
        rig.controller.setEnabled(true)
        rig.controller.start()
        for _ in 0..<10 { rig.scheduler.fireNext() }
        rig.clock.time += 130
        rig.wakeWatcher.macWoke()
        #expect(rig.controller.phase == .counting && rig.controller.content.text == "00:10")
        rig.runToZero()
        #expect(rig.alarm.cues.isEmpty, "the chime at 0:30 passed while the Mac slept")
    }

    @Test func overtimeCountsUpUntilTheOverlayLeaves() {
        let rig = TimerRig { $0.durationSeconds = 2; $0.atZero = .overtime }
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.runToZero()
        rig.scheduler.advance(by: 3.01)
        #expect(rig.controller.content.text == "+0:03" && rig.controller.content.state == .timesUp)
        #expect(rig.controller.status == .timesUp, "the status doesn't count up")
        rig.scheduler.fireAll()
        #expect(rig.controller.phase == .idle && rig.isQuiet, "the overtime wakes end with the run")
    }

    @Test func switchingOffWhileTheOverlayLeavesEndsTheRunAtOnce() {
        let rig = TimerRig()
        rig.presenter.exitsAtOnce = false
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.controller.cancel()
        #expect(rig.controller.phase == .leaving && rig.activity.isHeld, "the activity lasts through the exit")
        rig.controller.setEnabled(false)
        #expect(rig.controller.phase == .idle && !rig.activity.isHeld && rig.scheduler.pending.isEmpty)
        rig.presenter.finishExit()
        #expect(rig.controller.phase == .idle && rig.controller.status == .off && rig.isQuiet)
    }

    @Test func zeroAndTheStartAreAnnounced() {
        let rig = TimerRig { $0.durationSeconds = 3 }
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.scheduler.fireAll()
        #expect(rig.announcer.announcements == [.started(seconds: 3), .timesUp])
    }

    // MARK: - Pausing

    @Test func aPausedOverlayHidesAfterThreeSeconds() {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.scheduler.advance(by: 2)
        rig.controller.pause()
        #expect(rig.controller.phase == .paused && rig.controller.status == .paused(secondsLeft: 148))
        #expect(rig.presenter.updates.last?.state == .paused && !rig.activity.isHeld)
        rig.scheduler.advance(by: 2.9)
        #expect(rig.presenter.popOuts.isEmpty)
        rig.scheduler.advance(by: 0.2)
        #expect(rig.presenter.popOuts.count == 1 && rig.controller.phase == .paused)
        rig.controller.resume()
        #expect(rig.controller.phase == .counting && rig.presenter.popIns.count == 2)
        #expect(rig.presenter.popIns.last?.content.text == "02:28")
    }

    @Test(arguments: [TimerOverlaySettings.WhilePaused.stayUp, .hideAtOnce])
    func otherWaysToPause(_ choice: TimerOverlaySettings.WhilePaused) {
        let rig = TimerRig { $0.whilePaused = choice }
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.controller.pause()
        rig.scheduler.advance(by: 10)
        #expect(rig.presenter.popOuts.count == (choice == .hideAtOnce ? 1 : 0))
        #expect(rig.scheduler.pending.isEmpty)
    }

    // MARK: - Minecraft (decision 8)

    @Test func theOverlayFollowsMinecraftToAnotherDisplay() async {
        let rig = TimerRig()
        await rig.setMinecraft(on: timerTestDisplay)
        rig.controller.setEnabled(true)
        rig.controller.start()
        #expect(rig.presenter.popIns.first?.displayFrame == timerTestDisplay.frame)
        await rig.setMinecraft(on: timerSecondTestDisplay)
        let move = rig.presenter.moves.last
        #expect(move?.displayFrame == timerSecondTestDisplay.frame)
        #expect(move.map { $0.plateFrame.midX - timerSecondTestDisplay.frame.midX } == 453)
        #expect(move.map { $0.plateFrame.midY - timerSecondTestDisplay.frame.midY } == 459)
    }

    @Test func onlyWhileFocusedAppliesOnceMinecraftHasBeenInFront() async {
        let rig = TimerRig { $0.visibleOnlyWhileMinecraftFocused = true }
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: false)
        rig.controller.setEnabled(true)
        rig.controller.start()
        #expect(rig.presenter.popIns.count == 1, "started from the page, with sTools in front")
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: true)
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: false)
        #expect(rig.presenter.popOuts.count == 1 && rig.controller.phase == .counting)
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: true)
        #expect(rig.presenter.popIns.count == 2)
    }

    @Test func pausingWhileUnfocusedAppliesOnceMinecraftHasBeenInFront() async {
        let rig = TimerRig { $0.pausesWhileMinecraftNotFocused = true }
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: false)
        rig.controller.setEnabled(true)
        rig.controller.start()
        await rig.settle()
        #expect(rig.controller.phase == .counting)
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: true)
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: false)
        #expect(rig.controller.phase == .paused)
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: true)
        #expect(rig.controller.phase == .counting)
    }

    @Test func aManualPauseStaysPausedWhenMinecraftComesBack() async {
        let rig = TimerRig { $0.pausesWhileMinecraftNotFocused = true }
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: true)
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.controller.pause()
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: false)
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: true)
        #expect(rig.controller.phase == .paused)
    }

    @Test func testIgnoresTheFocusSettings() async {
        let rig = TimerRig {
            $0.visibleOnlyWhileMinecraftFocused = true
            $0.pausesWhileMinecraftNotFocused = true
        }
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: true)
        rig.controller.setEnabled(true)
        rig.controller.runTest()
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: false)
        #expect(rig.controller.phase == .counting && rig.presenter.popOuts.isEmpty)
    }

    // MARK: - Switching off

    @Test func turningOffWhileCountingCancelsAndHides() {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.scheduler.advance(by: 3)
        rig.controller.setEnabled(false)
        #expect(rig.controller.phase == .idle && rig.controller.status == .off)
        #expect(rig.presenter.popOuts.count == 1 && rig.isQuiet)
    }

    @Test func turningOffMidAlarmStopsIt() {
        let rig = TimerRig { $0.durationSeconds = 2 }
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.runToZero()
        rig.scheduler.fireNext()
        #expect(rig.alarm.isPlaying && rig.controller.phase == .ringing)
        rig.controller.setEnabled(false)
        #expect(rig.alarm.stops == 1 && rig.controller.phase == .idle && rig.isQuiet)
    }

    // MARK: - Test, duration and recordings

    @Test func testRunsFiveSecondsAndLeavesTheDurationAlone() {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        #expect(rig.controller.canRunTest)
        #expect(rig.controller.runTest())
        #expect(rig.controller.isTestRun && rig.presenter.popIns.first?.content.text == "00:05")
        let started = rig.clock.time
        rig.runToZero()
        #expect(abs(rig.clock.time - started - 5) < 0.01)
        rig.scheduler.fireAll()
        #expect(rig.controller.settings.durationSeconds == 150 && !rig.controller.isTestRun)
        #expect(rig.controller.phase == .idle && rig.isQuiet)
    }

    @Test func testSwitchesTheToolOnAndWaitsForACountdown() {
        let rig = TimerRig()
        #expect(rig.controller.runTest())
        #expect(rig.controller.isEnabled)
        rig.scheduler.fireAll()
        rig.controller.start()
        #expect(!rig.controller.canRunTest && !rig.controller.runTest() && !rig.controller.isTestRun)
        rig.controller.pause()
        #expect(!rig.controller.runTest())
    }

    @Test func aKeyPressDuringTestStartsTheSavedDuration() {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        rig.controller.runTest()
        rig.clock.time += 0.5
        #expect(rig.controller.press() == .acted)
        #expect(!rig.controller.isTestRun && rig.controller.content.text == "02:30")
    }

    @Test func aDurationChangeAppliesToTheNextRun() {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.scheduler.advance(by: 2)
        rig.controller.settings.durationSeconds = 10
        #expect(rig.controller.content.text == "02:28" && rig.controller.status == .counting(secondsLeft: 148))
        rig.controller.cancel()
        #expect(rig.controller.content.text == "00:10", "idle shows the saved duration")
        rig.controller.start()
        #expect(rig.presenter.popIns.last?.content.text == "00:10")
    }

    @Test func showInRecordingsAppliesAtTheNextPopUp() {
        let rig = TimerRig()
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.controller.settings.showsInRecordings = false
        #expect(rig.presenter.popIns.map(\.settings.showsInRecordings) == [true])
        rig.controller.cancel()
        rig.controller.start()
        #expect(rig.presenter.popIns.map(\.settings.showsInRecordings) == [true, false])
    }

    // MARK: - Settings

    @Test func settingsAreSavedAndPlacementModeNeverOutlastsALaunch() async {
        let rig = TimerRig()
        rig.controller.settings.durationSeconds = 300
        rig.controller.setPlacementMode(true)
        await rig.services.settings.flush()
        let again = TimerOverlayController(services: rig.services, theme: rig.theme, presenter: TestPresenter(),
                                           guides: TestGuides(), alarm: TestAlarm(scheduler: rig.scheduler),
                                           announcer: TestAnnouncer())
        #expect(again.settings.durationSeconds == 300)
        #expect(!again.settings.placementModeEnabled)
        rig.controller.setEnabled(false)
    }

    @Test func resettingKeepsTheOwnersSoundFiles() throws {
        let rig = TimerRig()
        let id = try rig.ownSound(seconds: 1)
        rig.controller.settings.soundID = id
        rig.controller.settings.rings = 7
        rig.controller.resetToDefault()
        #expect(rig.controller.settings == TimerOverlaySettings.defaultValue)
        #expect(rig.controller.sounds.contains { $0.id == id })
    }

    // MARK: - Sounds and Preview

    @Test func addingASoundCopiesItInAndPicksIt() throws {
        let rig = TimerRig()
        let picked = rig.directory.appending(path: "Bell.caf")
        try writeSilence(seconds: 1, to: picked)
        let sound = try rig.controller.addSound(from: picked)
        #expect(rig.controller.settings.soundID == sound.id && sound.id == "file:Bell.caf")
        #expect(rig.controller.sounds.contains(sound))
        #expect(rig.controller.sounds.contains { $0.source == .sTools })
        try rig.controller.removeSound(sound)
        #expect(rig.controller.settings.soundID == AlarmSound.fallbackID)
        #expect(!rig.controller.sounds.contains(sound))
        #expect(throws: OwnSoundsError.notASound) {
            let text = rig.directory.appending(path: "Notes.txt")
            try Data("not a sound".utf8).write(to: text)
            try rig.controller.addSound(from: text)
        }
    }

    @Test func aMissingFileIsNotedAndPingRingsInstead() {
        let rig = TimerRig { $0.durationSeconds = 1; $0.soundID = "file:Gone.caf" }
        #expect(rig.controller.missingSoundNote == "\u{201C}Gone\u{201D} is missing, so Ping plays instead.")
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.runToZero()
        #expect(rig.alarm.rings.first?.sound == AlarmSound.fallback().url)
        rig.controller.settings.soundID = AlarmSound.fallbackID
        #expect(rig.controller.missingSoundNote == nil)
    }

    @Test func previewPlaysTheAlarmsSoundUntilItEnds() {
        let rig = TimerRig { $0.rings = 2 }
        rig.controller.preview()
        #expect(rig.controller.isPreviewing && rig.alarm.previews.first?.rings == 2)
        rig.scheduler.fireAll()
        #expect(!rig.controller.isPreviewing)
        rig.controller.preview()
        rig.controller.stopPreview()
        #expect(!rig.controller.isPreviewing && !rig.alarm.isPlaying && rig.alarm.stops == 1)
    }

    @Test func aPreviewDuringTheAlarmEndsIt() {
        let rig = TimerRig { $0.durationSeconds = 1 }
        rig.controller.setEnabled(true)
        rig.controller.start()
        rig.runToZero()
        rig.controller.preview()
        #expect(rig.controller.phase == .lingering && rig.controller.isPreviewing)
        rig.scheduler.fireAll()
        #expect(rig.controller.phase == .idle && !rig.controller.isPreviewing)
    }

    // MARK: - The rule notice

    @Test func theRuleNoticeShowsOnceTheToolIsOnUntilDismissed() {
        let rig = TimerRig { $0.ruleNote = .lineAndNotice }
        #expect(!rig.controller.showsRuleNotice)
        rig.controller.setEnabled(true)
        #expect(rig.controller.showsRuleNotice)
        rig.controller.dismissRuleNotice()
        #expect(!rig.controller.showsRuleNotice && rig.controller.settings.ruleNoticeDismissed)
    }

    @Test func availabilityIsAccessibility() {
        #expect(TimerRig().controller.isAvailable)
        #expect(!TimerRig(accessibility: .denied).controller.isAvailable)
    }
}

@MainActor
@Suite("Timer Overlay placement mode")
struct TimerPlacementModeTests {
    /// The default plate's center on the test display: 453 right of and 459 above its center.
    private static let ownersCenter = CGPoint(x: timerTestDisplay.frame.midX + 453, y: timerTestDisplay.frame.midY + 459)

    @Test func placementModeSwitchesTheToolOnAndShowsTheSavedDuration() {
        let rig = TimerRig()
        rig.controller.setPlacementMode(true)
        #expect(rig.controller.isEnabled && rig.controller.isPlacing && rig.presenter.isPlacing)
        #expect(rig.presenter.popIns.map(\.content.text) == ["02:30"])
        #expect(rig.controller.phase == .idle && rig.controller.status == .ready)
        let plate = rig.presenter.popIns.first?.plateFrame
        #expect(plate.map { CGPoint(x: $0.midX, y: $0.midY) } == Self.ownersCenter)
        #expect(rig.controller.isWatchingEnvironment, "it follows the display while the plate is up")
    }

    @Test func placementModeStaysOffWhenTheToolCantSwitchOn() {
        let rig = TimerRig()
        rig.controller.requestEnable = { false }
        rig.controller.setPlacementMode(true)
        #expect(!rig.controller.settings.placementModeEnabled && !rig.controller.isPlacing)
        #expect(rig.presenter.popIns.isEmpty && !rig.presenter.isPlacing && rig.isQuiet)
    }

    @Test func aDragShowsTheGuidesAndSavesWhereThePlateSettles() {
        let rig = TimerRig()
        rig.controller.setPlacementMode(true)
        #expect(!rig.guides.isShowing)
        rig.presenter.drag(by: CGSize(width: -100, height: 40))
        rig.presenter.drag(by: CGSize(width: -200, height: 100))
        #expect(rig.guides.shown.count == 1, "the zones are worked out once per drag")
        #expect(rig.guides.marks.count == 2)
        let moved = rig.presenter.moves.last?.plateFrame
        #expect(moved.map { CGPoint(x: $0.midX, y: $0.midY) }
            == CGPoint(x: Self.ownersCenter.x - 200, y: Self.ownersCenter.y - 100))
        rig.presenter.endDrag()
        #expect(!rig.guides.isShowing && rig.guides.hides == 1)
        #expect(rig.controller.settings.offsetX == 253 && rig.controller.settings.offsetY == -359)
        #expect(rig.controller.phase == .idle && rig.presenter.isShowing)
    }

    @Test func coveringTheToastsTurnsThePlatesEdgeToDanger() {
        let rig = TimerRig()
        rig.controller.setPlacementMode(true)
        rig.presenter.drag(by: .zero)
        #expect(rig.guides.marks.last == [.toasts], "the owner's spot overlaps the toast column at GUI scale 3")
        #expect(rig.presenter.updates.last?.showsDangerEdge == true && rig.controller.content.showsDangerEdge)
        // Down and left, clear of the toasts and of Game Paused.
        rig.presenter.drag(by: CGSize(width: -300, height: 200))
        #expect(rig.guides.marks.last == [])
        #expect(rig.presenter.updates.last?.showsDangerEdge == false)
        rig.presenter.drag(by: .zero)
        rig.presenter.endDrag()
        #expect(!rig.controller.content.showsDangerEdge, "the edge goes with the guides")
    }

    @Test func snappingPullsADroppedPlateToTheEdge() {
        let rig = TimerRig()
        rig.controller.setPlacementMode(true)
        let start = rig.presenter.plateFrame ?? .zero
        let toRight = timerTestDisplay.frame.maxX - start.maxX - 6
        rig.presenter.drag(by: CGSize(width: toRight, height: 0))
        rig.presenter.endDrag()
        #expect(rig.presenter.moves.last?.plateFrame.maxX == timerTestDisplay.frame.maxX)
    }

    @Test func withoutGuidesADragShowsNone() {
        let rig = TimerRig { $0.showsRuleGuides = false }
        rig.controller.setPlacementMode(true)
        rig.presenter.drag(by: CGSize(width: -50, height: 0))
        rig.presenter.endDrag()
        #expect(rig.guides.shown.isEmpty && rig.guides.marks.isEmpty)
        #expect(rig.controller.settings.offsetX == 403)
    }

    @Test func typedXYMovesThePlate() {
        let rig = TimerRig()
        rig.controller.setPlacementMode(true)
        rig.controller.settings.offsetX = 0
        rig.controller.settings.offsetY = 0
        let plate = rig.presenter.moves.last?.plateFrame
        #expect(plate.map { CGPoint(x: $0.midX, y: $0.midY) }
            == CGPoint(x: timerTestDisplay.frame.midX, y: timerTestDisplay.frame.midY))
    }

    @Test func aCountdownSharesThePlate() {
        let rig = TimerRig { $0.durationSeconds = 3 }
        rig.controller.setPlacementMode(true)
        rig.controller.start()
        #expect(rig.presenter.popIns.count == 1, "the countdown counts on the sample's plate")
        #expect(rig.presenter.updates.isEmpty, "the first second looks like the sample")
        #expect(rig.controller.content.text == "00:03" && rig.controller.phase == .counting)
        rig.scheduler.fireNext()
        #expect(rig.presenter.updates.last?.text == "00:02")
        rig.scheduler.fireAll()
        #expect(rig.presenter.popOuts.isEmpty && rig.presenter.isShowing, "the plate stays")
        #expect(rig.controller.phase == .idle && rig.controller.content.text == "00:03")
        #expect(rig.presenter.pulses.count == 3 && rig.alarm.rings.count == 1)
        #expect(!rig.activity.isHeld && rig.scheduler.pending.isEmpty)
    }

    @Test func placementModeIgnoresTheFocusSettings() async {
        let rig = TimerRig { $0.visibleOnlyWhileMinecraftFocused = true; $0.pausesWhileMinecraftNotFocused = true }
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: true)
        rig.controller.setPlacementMode(true)
        rig.controller.start()
        await rig.setMinecraft(on: timerTestDisplay, isFrontmost: false)
        #expect(rig.presenter.popOuts.isEmpty && rig.controller.phase == .counting)
    }

    @Test func turningPlacementModeOffHidesTheSample() {
        let rig = TimerRig()
        rig.controller.setPlacementMode(true)
        rig.controller.setPlacementMode(false)
        #expect(!rig.presenter.isPlacing && rig.presenter.popOuts.count == 1)
        #expect(rig.controller.isEnabled && rig.isQuiet)
    }

    @Test func turningPlacementModeOffMidDragPutsThePlateBack() {
        let rig = TimerRig()
        rig.controller.setPlacementMode(true)
        rig.controller.start()
        rig.presenter.drag(by: CGSize(width: -300, height: 50))
        rig.controller.setPlacementMode(false)
        #expect(!rig.guides.isShowing && rig.controller.settings.offsetX == 453)
        let plate = rig.presenter.moves.last?.plateFrame
        #expect(plate.map { CGPoint(x: $0.midX, y: $0.midY) } == Self.ownersCenter)
        #expect(rig.presenter.isShowing && rig.controller.phase == .counting)
    }

    @Test func aDoublePressEndsPlacementModeWithTheTool() {
        let rig = TimerRig()
        rig.controller.setPlacementMode(true)
        rig.controller.press()
        rig.clock.time += 0.3
        rig.controller.press()
        #expect(!rig.controller.isEnabled && !rig.controller.settings.placementModeEnabled && !rig.presenter.isPlacing)
        #expect(rig.isQuiet)
        rig.clock.time += 1
        rig.controller.press()
        #expect(rig.controller.isEnabled && rig.controller.phase == .counting && !rig.controller.isPlacing)
    }

    @Test func turningTheToolOffEndsPlacementMode() {
        let rig = TimerRig()
        rig.controller.setPlacementMode(true)
        rig.controller.start()
        rig.presenter.drag(by: CGSize(width: -40, height: 0))
        rig.controller.setEnabled(false)
        #expect(!rig.controller.settings.placementModeEnabled && !rig.presenter.isPlacing)
        #expect(!rig.guides.isShowing && rig.controller.phase == .idle && rig.isQuiet)
        rig.controller.setEnabled(true)
        #expect(rig.presenter.popIns.count == 1, "no plate comes back")
    }
}

/// Hard limits on the whole module, read from its source.
@Suite("Timer Overlay hard limits")
struct TimerOverlayLimitsTests {
    private static let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/TimerOverlay", directoryHint: .isDirectory)

    private static func sourceTexts() throws -> [(name: String, text: String)] {
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Spec 5.6.8: the timer never reads Minecraft's files, screen or sound, and never sends keys, pauses the game or
    /// moves focus.
    @Test func itNeverReadsOrActsOnTheGame() throws {
        let texts = try Self.sourceTexts()
        #expect(texts.count > 20)
        for token in ["CGEvent", "options.txt", "ScreenCaptureKit", "SCStream", "SCShareableContent", "activate("] {
            #expect(texts.filter { $0.text.contains(token) }.map(\.name).isEmpty, "\(token)")
        }
    }

    /// The plan's cost rule: nothing runs all the time; one-shot wakes go through the injected scheduler.
    @Test func nothingRunsAllTheTime() throws {
        let texts = try Self.sourceTexts()
        for token in ["TimelineView", "CADisplayLink", "CVDisplayLink", "Timer.publish", "scheduledTimer",
                      "repeatForever", "Task.sleep", "Thread.sleep", "usleep("] {
            #expect(texts.filter { $0.text.contains(token) }.map(\.name).isEmpty, "\(token)")
        }
    }
}
