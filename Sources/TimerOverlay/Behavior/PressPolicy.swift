import Foundation

/// Turns Start-timer presses and releases into what the timer does: the press table of spec 5.6.2 with every
/// Advanced variant, plus the cancel gestures.
///
/// A small value the controller keeps. It remembers only the last press, to tell a double press (0.4 s) and a
/// hold (1 s), and reads no clock: the controller stamps each input with its own. A press always acts at once;
/// a gesture cancels afterwards.
/// - Double press: a second press within 0.4 s of the last one cancels a run that's under way (counting,
///   paused, ringing or lingering). With nothing under way, as when the first press silenced and hid the alarm,
///   it does nothing. The press after a double press is a first press again, so a third quick press starts a
///   countdown (decision 15).
/// - Hold: releasing the key 1 s or more after its press cancels a run that's under way.
///
/// A press while leaving counts as one while idle. Key repeats are filtered before they get here.
public struct PressPolicy: Equatable, Sendable {
    public enum Input: Equatable, Sendable {
        case press
        case release
    }

    public enum Action: String, Sendable, CaseIterable {
        /// Start a countdown of the saved duration, switching the tool on first if needed.
        case start
        /// Start the running or paused countdown again from the full duration.
        case restart
        /// Cancel the run and hide the overlay, stopping the alarm if it rings.
        case cancel
        /// Pause the running countdown.
        case pause
        /// Resume the paused countdown.
        case resume
        /// Stop the alarm and hide the overlay.
        case silenceAndHide
        /// Stop the alarm and start a new countdown.
        case newCountdown
        /// Do nothing.
        case ignore
    }

    /// A second press this soon after the last one is a double press.
    public static let doublePressWindow: TimeInterval = 0.4
    /// A press held this long cancels when it's released.
    public static let holdDuration: TimeInterval = 1

    /// Absorbs float noise in the input times, so a press exactly 0.4 s later still counts as quick.
    private static let timeSlack: TimeInterval = 1e-9

    private var lastPress: TimeInterval?
    /// Whether the last press was the second of a double press, so the next one starts afresh.
    private var lastPressEndedDoublePress = false

    public init() {}

    /// What `input` at `time` does in `phase`, remembering it for the next input.
    public mutating func handle(
        _ input: Input, at time: TimeInterval, phase: TimerPhase, settings: TimerOverlaySettings
    ) -> Action {
        switch input {
        case .press: press(at: time, phase: phase, settings: settings)
        case .release: release(at: time, phase: phase, settings: settings)
        }
    }

    /// Forgets the last press, as when the tool is switched off.
    public mutating func reset() {
        lastPress = nil
        lastPressEndedDoublePress = false
    }

    /// What a lone press does in `phase` under `settings`: the press table, without gestures.
    public static func action(forPressIn phase: TimerPhase, settings: TimerOverlaySettings) -> Action {
        switch phase {
        case .idle, .leaving:
            return .start
        case .counting, .paused:
            switch settings.pressWhileCounting {
            case .restart: return .restart
            case .cancel: return .cancel
            case .pauseOrResume: return phase == .counting ? .pause : .resume
            case .ignore: return .ignore
            }
        case .ringing, .lingering:
            switch settings.pressWhileRinging {
            case .newCountdown: return .newCountdown
            case .silenceAndHide: return .silenceAndHide
            case .ignore: return .ignore
            }
        }
    }

    private mutating func press(at time: TimeInterval, phase: TimerPhase, settings: TimerOverlaySettings) -> Action {
        let isQuick = lastPress.map { time >= $0 && time - $0 <= Self.doublePressWindow + Self.timeSlack } ?? false
        let endsDoublePress = settings.cancelGesture == .doublePress && isQuick && !lastPressEndedDoublePress
        lastPress = time
        lastPressEndedDoublePress = endsDoublePress
        if endsDoublePress {
            return Self.hasRunUnderWay(phase) ? .cancel : .ignore
        }
        return Self.action(forPressIn: phase, settings: settings)
    }

    private func release(at time: TimeInterval, phase: TimerPhase, settings: TimerOverlaySettings) -> Action {
        guard settings.cancelGesture == .hold, let pressed = lastPress,
              time - pressed >= Self.holdDuration - Self.timeSlack,
              Self.hasRunUnderWay(phase)
        else { return .ignore }
        return .cancel
    }

    /// A run the cancel gestures can cancel: counting, paused, ringing or lingering.
    private static func hasRunUnderWay(_ phase: TimerPhase) -> Bool {
        switch phase {
        case .counting, .paused, .ringing, .lingering: true
        case .idle, .leaving: false
        }
    }
}
