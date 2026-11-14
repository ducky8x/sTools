import Foundation

/// Turns Start-timer presses and releases into what the timer does: the press table of spec 5.6.2 with every
/// Advanced variant, plus the cancel gestures.
///
/// A small value the controller keeps. It remembers only the last press, to tell a double press (0.4 s) and a
/// hold (1 s), and reads no clock: the controller stamps each input with its own, at the moment the key moved. A
/// press always acts at once; a gesture cancels afterwards. The controller forgets the last press (`reset()`) when
/// the switch or the page acts, but not when the key itself switches the tool off.
/// - Double press: a second press within 0.4 s of the last one cancels whatever is under way (counting, paused,
///   ringing or lingering) and switches the tool off. It switches the tool off even when the first press left
///   nothing to cancel, as when it cancelled (Advanced). When the first press already switched the tool off by
///   silencing the alarm, the second has nothing left to do and the tool stays off: the controller asks
///   `isSecondOfDoublePress` before it switches the tool on. The press after a double press is a first press
///   again: it switches the tool back on and starts a countdown, so a third quick press starts one (decision 15).
/// - Hold: releasing the key 1 s or more after its press cancels and switches the tool off, as the double press
///   does.
///
/// The gestures switch the tool off, and so does a single press that silences the alarm (Advanced's "Silences and
/// hides", spec 5.6.2, revision 67), so letting the alarm run out and silencing it end the same way. Pausing keeps
/// the tool on, and so does a single press that cancels (Advanced). A press while leaving counts as one while idle.
/// Key repeats are filtered before they get here.
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
        /// Cancel the run and hide the overlay, stopping the alarm if it rings. The tool stays on.
        case cancel
        /// Cancel whatever is under way, hide the overlay and switch the tool off: what the cancel gestures do
        /// (spec 5.6.2). The next press switches the tool back on and starts a countdown.
        case cancelAndSwitchOff
        /// Pause the running countdown.
        case pause
        /// Resume the paused countdown.
        case resume
        /// Stop the alarm, hide the overlay and switch the tool off, as letting the alarm run out does (revision 67).
        /// A quick press after it is the double press's second half and leaves the tool off.
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

    /// When the last press came, as its input was stamped; nil before the first and after `reset()`.
    public private(set) var lastPress: TimeInterval?
    /// Whether the last press was the second of a double press, so the next one starts afresh.
    private var lastPressEndedDoublePress = false

    public init() {}

    /// What `input` at `time` does in `phase`, remembering it for the next input.
    public mutating func handle(
        _ input: Input, at time: TimeInterval, phase: TimerPhase, settings: TimerOverlaySettings
    ) -> Action {
        switch input {
        case .press: press(at: time, phase: phase, settings: settings)
        case .release: release(at: time, settings: settings)
        }
    }

    /// Forgets the last press, as when the tool's switch or the page acts: the next press is a first press.
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

    /// Whether a press at `time` would be the second of a double press: the double press is the cancel gesture, and
    /// the press comes within 0.4 s of the last one, which didn't end a double press itself. Asking remembers nothing.
    public func isSecondOfDoublePress(at time: TimeInterval, settings: TimerOverlaySettings) -> Bool {
        guard settings.cancelGesture == .doublePress, !lastPressEndedDoublePress, let lastPress else { return false }
        return time >= lastPress && time - lastPress <= Self.doublePressWindow + Self.timeSlack
    }

    private mutating func press(at time: TimeInterval, phase: TimerPhase, settings: TimerOverlaySettings) -> Action {
        let endsDoublePress = isSecondOfDoublePress(at: time, settings: settings)
        lastPress = time
        lastPressEndedDoublePress = endsDoublePress
        if endsDoublePress { return .cancelAndSwitchOff }
        return Self.action(forPressIn: phase, settings: settings)
    }

    private func release(at time: TimeInterval, settings: TimerOverlaySettings) -> Action {
        guard settings.cancelGesture == .hold, let pressed = lastPress,
              time - pressed >= Self.holdDuration - Self.timeSlack
        else { return .ignore }
        return .cancelAndSwitchOff
    }
}
