import Foundation
import Testing
@testable import TimerOverlay

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
private func near(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { near($0, $1) } }

/// Ping and Glass, measured with `afinfo` (spec 5.6.6).
private let ping = 1.5
private let glass = 1.65

private func schedule(
    length: TimeInterval = ping, rings: Int = 3, leave: TimerOverlaySettings.Leave = .afterLastRing,
    afterLastRing: TimeInterval = 2, afterZero: TimeInterval = 5,
    whileRinging: TimerOverlaySettings.WhileRinging = .pulsePerRing
) -> AlarmSchedule {
    AlarmSchedule(
        soundLength: length, rings: rings, leave: leave, leaveAfterLastRing: afterLastRing,
        leaveAfterZero: afterZero, whileRinging: whileRinging)
}

@Suite("Alarm schedule")
struct AlarmScheduleTests {
    // MARK: Rings and leaving

    @Test func pingThreeTimesEndsAt5_2AndLeavesAt7_2() {
        let alarm = schedule()
        #expect(near(alarm.ringStarts, [0, 1.85, 3.7]))
        #expect(near(alarm.alarmEnd, 5.2))
        #expect(near(alarm.leaveTime, 7.2))
        #expect(near(alarm.pulseTimes, alarm.ringStarts))
    }

    @Test func glassThreeTimesEndsAt5_65() {
        let alarm = schedule(length: glass)
        #expect(near(alarm.ringStarts, [0, 2.0, 4.0]))
        #expect(near(alarm.alarmEnd, 5.65))
        #expect(near(alarm.leaveTime, 7.65))
    }

    @Test(arguments: [(1, 1.5, 3.5), (3, 5.2, 7.2), (10, 18.15, 20.15)])
    func theLeaveTimeFollowsTheRings(rings: Int, end: TimeInterval, leave: TimeInterval) {
        let alarm = schedule(rings: rings)
        #expect(alarm.ringStarts.count == rings)
        #expect(near(alarm.alarmEnd, end))
        #expect(near(alarm.leaveTime, leave))
    }

    @Test(arguments: [1, 3, 10])
    func aSetTimeAfterZeroLeavesThenWhateverTheRings(rings: Int) {
        let alarm = schedule(rings: rings, leave: .afterZero)
        #expect(near(alarm.leaveTime, 5))
        #expect(alarm.alarmEnd <= alarm.leaveTime)
        #expect(alarm.ringStarts.allSatisfy { $0 < 5 })
    }

    @Test func anAlarmLongerThanTheSetTimeStopsWithTheOverlay() {
        let alarm = schedule(rings: 10, leave: .afterZero)
        #expect(near(alarm.ringStarts, [0, 1.85, 3.7]))
        #expect(near(alarm.alarmEnd, 5))
        #expect(near(alarm.leaveTime, 5))
    }

    @Test func aShortAlarmEndsBeforeTheSetTime() {
        let alarm = schedule(rings: 1, leave: .afterZero)
        #expect(near(alarm.alarmEnd, 1.5))
        #expect(near(alarm.leaveTime, 5))
    }

    @Test func theLeaveDelayIsSettable() {
        #expect(near(schedule(afterLastRing: 0).leaveTime, 5.2))
        #expect(near(schedule(afterLastRing: 10).leaveTime, 15.2))
        #expect(near(schedule(leave: .afterZero, afterZero: 12).leaveTime, 12))
    }

    @Test func theSettingsBuildTheSameSchedule() {
        var settings = TimerOverlaySettings.defaultValue
        #expect(AlarmSchedule(soundLength: ping, settings: settings) == schedule())
        settings.rings = 5
        settings.leave = .afterZero
        settings.leaveAfterZeroSeconds = 8
        settings.whileRinging = .quickFlashes
        #expect(AlarmSchedule(soundLength: glass, settings: settings)
            == schedule(length: glass, rings: 5, leave: .afterZero, afterZero: 8, whileRinging: .quickFlashes))
    }

    @Test func unusableInputsAreKeptInBounds() {
        let alarm = schedule(length: -1, rings: 0, afterLastRing: -4)
        #expect(alarm.soundLength == 0)
        #expect(near(alarm.ringStarts, [0]))
        #expect(alarm.alarmEnd == 0)
        #expect(alarm.leaveTime == 0)
        #expect(schedule(length: .nan).soundLength == 0)
    }

    // MARK: Pulses and flashes

    @Test func theTimesUpLookOnlyNeverPulses() {
        #expect(schedule(whileRinging: .timesUpLookOnly).pulseTimes.isEmpty)
    }

    @Test func quickFlashesComeAFewPerRing() {
        let alarm = schedule(whileRinging: .quickFlashes)
        #expect(near(alarm.pulseTimes, [0, 0.4, 0.8, 1.85, 2.25, 2.65, 3.7, 4.1, 4.5]))
    }

    @Test(arguments: [0.05, 0.2, 0.5, 1.5, 3.0], [1, 3, 10])
    func quickFlashesNeverExceedThreeASecond(length: TimeInterval, rings: Int) {
        let flashes = schedule(length: length, rings: rings, whileRinging: .quickFlashes).pulseTimes
        #expect(!flashes.isEmpty)
        for start in flashes {
            #expect(flashes.filter { $0 >= start && $0 < start + 1 }.count <= 3)
        }
        #expect(zip(flashes, flashes.dropFirst()).allSatisfy { $1 - $0 >= AlarmSchedule.flashSpacing - 1e-9 })
    }

    @Test func flashesStopWhenTheOverlayLeaves() {
        let alarm = schedule(rings: 10, leave: .afterZero, afterZero: 1, whileRinging: .quickFlashes)
        #expect(near(alarm.pulseTimes, [0, 0.4, 0.8]))
    }

    // MARK: Cues before zero

    @Test func theChimePlaysAtItsTimeLeft() {
        let cues = AlarmSchedule.cues(.chime, chimeAtSeconds: 30, length: 150)
        #expect(cues == [AlarmSchedule.TimedCue(cue: .chime, remaining: 30)])
    }

    @Test func ticksPlayEachSecondOfTheLastFive() {
        let cues = AlarmSchedule.cues(.ticks, chimeAtSeconds: 30, length: 150)
        #expect(cues.map(\.cue) == Array(repeating: .tick, count: 5))
        #expect(cues.map(\.remaining) == [5, 4, 3, 2, 1])
    }

    @Test func nothingPlaysNoCues() {
        #expect(AlarmSchedule.cues(.nothing, chimeAtSeconds: 30, length: 150).isEmpty)
    }

    @Test func aCueAtOrBeforeTheRunsStartIsSkipped() {
        #expect(AlarmSchedule.cues(.chime, chimeAtSeconds: 30, length: 30).isEmpty)
        #expect(AlarmSchedule.cues(.chime, chimeAtSeconds: 30, length: 20).isEmpty)
        #expect(AlarmSchedule.cues(.chime, chimeAtSeconds: 30, length: 31).count == 1)
        #expect(AlarmSchedule.cues(.ticks, chimeAtSeconds: 30, length: 5).map(\.remaining) == [4, 3, 2, 1])
        #expect(AlarmSchedule.cues(.ticks, chimeAtSeconds: 30, length: 2.5).map(\.remaining) == [2, 1])
    }

    @Test func theSettingsChooseTheCues() {
        var settings = TimerOverlaySettings.defaultValue
        #expect(AlarmSchedule.cues(settings: settings, length: 150).isEmpty)
        settings.beforeZero = .chime
        settings.chimeAtSeconds = 45
        #expect(AlarmSchedule.cues(settings: settings, length: 150) == [.init(cue: .chime, remaining: 45)])
    }

    @Test func aCueJustPassedPlaysOnce() {
        let cues = AlarmSchedule.cues(.ticks, chimeAtSeconds: 30, length: 150)
        // The engine wakes 2 ms past each change.
        #expect(AlarmSchedule.cuesDue(cues, from: 5.998, to: 4.998) == [.init(cue: .tick, remaining: 5)])
        #expect(AlarmSchedule.cuesDue(cues, from: 4.998, to: 3.998) == [.init(cue: .tick, remaining: 4)])
        #expect(AlarmSchedule.cuesDue(cues, from: 6.998, to: 5.998).isEmpty)
        // A cue exactly at the previous check's time left was due then, not now.
        #expect(AlarmSchedule.cuesDue(cues, from: 5, to: 4.998).isEmpty)
    }

    @Test func aCueThatPassedDuringSleepIsSkipped() {
        let chime = AlarmSchedule.cues(.chime, chimeAtSeconds: 30, length: 150)
        // Slept from 0:40 left to 0:12 left.
        #expect(AlarmSchedule.cuesDue(chime, from: 40, to: 12).isEmpty)
        let ticks = AlarmSchedule.cues(.ticks, chimeAtSeconds: 30, length: 150)
        // Woke at 3.5 s left: 5 and 4 passed during sleep and are skipped.
        #expect(AlarmSchedule.cuesDue(ticks, from: 8, to: 3.5).isEmpty)
        // Woke 0.1 s after 4 s left, within the tolerance: 4 still plays, 5 doesn't.
        #expect(AlarmSchedule.cuesDue(ticks, from: 8, to: 3.9) == [.init(cue: .tick, remaining: 4)])
        #expect(AlarmSchedule.cuesDue(ticks, from: 8, to: 3.9, tolerance: 0.05).isEmpty)
    }

    @Test func noCueWhileTheTimeLeftStandsStill() {
        let cues = AlarmSchedule.cues(.ticks, chimeAtSeconds: 30, length: 150)
        #expect(AlarmSchedule.cuesDue(cues, from: 3.5, to: 3.5).isEmpty)
    }
}
