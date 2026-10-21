import Foundation

/// When the alarm rings, the overlay pulses and the overlay leaves (spec 5.6.1, 5.6.4, 5.6.6), plus the cues
/// before zero. Pure values: nothing here plays, waits or reads a clock.
///
/// Times after zero are offsets from the alarm's start. That is zero itself, unless the Mac slept past zero:
/// then the alarm rings on wake, and "a set time after zero" counts from then, so the alarm is still heard
/// (decision 15). Cue times are seconds left on the countdown.
public struct AlarmSchedule: Equatable, Sendable {
    /// The silence after each ring before the next one starts, as in the merged timer app. Fixed, not a setting.
    public static let ringGap: TimeInterval = 0.35
    /// The least time between two quick flashes, so no second ever holds more than 3 (WCAG 2.3.1).
    public static let flashSpacing: TimeInterval = 0.4
    /// Quick flashes per ring, each `flashSpacing` after the last.
    public static let flashesPerRing = 3

    /// The sound's length in seconds.
    public let soundLength: TimeInterval
    /// When each ring starts: every `soundLength + ringGap`. With "a set time after zero", rings that would
    /// start once the overlay has left are dropped.
    public let ringStarts: [TimeInterval]
    /// When the sound ends: the last ring's end, or the leave time if that comes first (the alarm stops with
    /// the overlay).
    public let alarmEnd: TimeInterval
    /// When the overlay starts to leave.
    public let leaveTime: TimeInterval
    /// When the overlay pulses or flashes: one pulse as each ring starts, or a few flashes per ring (never more
    /// than 3 in a second, none once the overlay leaves). Empty for "time's-up look only". Reduced motion is
    /// the presenter's to apply, not the schedule's.
    public let pulseTimes: [TimeInterval]

    public init(
        soundLength: TimeInterval, rings: Int, leave: TimerOverlaySettings.Leave,
        leaveAfterLastRing: TimeInterval, leaveAfterZero: TimeInterval, whileRinging: TimerOverlaySettings.WhileRinging
    ) {
        let length = Self.nonNegative(soundLength)
        let period = length + Self.ringGap
        let allStarts = (0..<max(1, rings)).map { Double($0) * period }
        let naturalEnd = (allStarts.last ?? 0) + length

        let leaveTime: TimeInterval
        let starts: [TimeInterval]
        switch leave {
        case .afterLastRing:
            leaveTime = naturalEnd + Self.nonNegative(leaveAfterLastRing)
            starts = allStarts
        case .afterZero:
            leaveTime = Self.nonNegative(leaveAfterZero)
            starts = allStarts.filter { $0 < leaveTime }
        }

        self.soundLength = length
        ringStarts = starts
        self.leaveTime = leaveTime
        alarmEnd = min(starts.last.map { $0 + length } ?? 0, leaveTime)

        switch whileRinging {
        case .pulsePerRing:
            pulseTimes = starts
        case .timesUpLookOnly:
            pulseTimes = []
        case .quickFlashes:
            var flashes: [TimeInterval] = []
            for start in starts {
                for index in 0..<Self.flashesPerRing {
                    let time = start + Double(index) * Self.flashSpacing
                    guard time < leaveTime else { break }
                    if let last = flashes.last, time < last + Self.flashSpacing - 1e-9 { continue }
                    flashes.append(time)
                }
            }
            pulseTimes = flashes
        }
    }

    /// The schedule `settings` ask for, for a sound `soundLength` seconds long.
    public init(soundLength: TimeInterval, settings: TimerOverlaySettings) {
        self.init(
            soundLength: soundLength, rings: settings.rings, leave: settings.leave,
            leaveAfterLastRing: settings.leaveAfterLastRingSeconds, leaveAfterZero: settings.leaveAfterZeroSeconds,
            whileRinging: settings.whileRinging)
    }

    private static func nonNegative(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(0, seconds) : 0
    }
}

// MARK: - Cues before zero

extension AlarmSchedule {
    /// A sound before zero (spec 5.6.6, Timer round G2), played at the alarm's volume.
    public enum Cue: String, Sendable, CaseIterable {
        /// sTools' chime, once.
        case chime
        /// A soft tick.
        case tick
    }

    /// A cue, and the seconds left on the countdown when it plays.
    public struct TimedCue: Equatable, Sendable {
        public let cue: Cue
        public let remaining: TimeInterval

        public init(cue: Cue, remaining: TimeInterval) {
            self.cue = cue
            self.remaining = remaining
        }
    }

    /// The ticks' times: each second of the last 5 s.
    public static let tickSeconds = [5, 4, 3, 2, 1]
    /// How late a cue may still play. A cue further back passed while the Mac slept, and is skipped rather
    /// than played late.
    public static let cueTolerance: TimeInterval = 0.25

    /// Every cue of a run `length` seconds long, in the order they play. A cue at or before the run's start is
    /// left out: a 30 s countdown has no chime at 0:30, and a 5 s one ticks only 4 times.
    public static func cues(_ beforeZero: TimerOverlaySettings.BeforeZero, chimeAtSeconds: Int, length: TimeInterval) -> [TimedCue] {
        let all: [TimedCue] = switch beforeZero {
        case .nothing: []
        case .chime: [TimedCue(cue: .chime, remaining: TimeInterval(chimeAtSeconds))]
        case .ticks: tickSeconds.map { TimedCue(cue: .tick, remaining: TimeInterval($0)) }
        }
        return all.filter { $0.remaining > 0 && $0.remaining < length }
    }

    /// The cues `settings` ask for, for a run `length` seconds long.
    public static func cues(settings: TimerOverlaySettings, length: TimeInterval) -> [TimedCue] {
        cues(settings.beforeZero, chimeAtSeconds: settings.chimeAtSeconds, length: length)
    }

    /// The cues to play now, as the time left has gone from `previousRemaining` (the last check) down to
    /// `remaining`: those it passed, at most `tolerance` late. A cue exactly at `previousRemaining` was due at
    /// the last check, so none plays twice.
    public static func cuesDue(
        _ cues: [TimedCue], from previousRemaining: TimeInterval, to remaining: TimeInterval,
        tolerance: TimeInterval = cueTolerance
    ) -> [TimedCue] {
        cues.filter { $0.remaining < previousRemaining && $0.remaining >= remaining && $0.remaining - remaining <= tolerance }
    }
}
