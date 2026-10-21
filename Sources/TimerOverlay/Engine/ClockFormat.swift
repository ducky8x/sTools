import Foundation

/// How the countdown's time is written (spec 5.6.1, 5.6.7): the merged timer app's `MM:SS` / `H:MM:SS`, plus
/// the Advanced formats: `M:SS`, seconds only, tenths in the last 10 s, overtime and a word at zero.
public enum ClockFormat {
    /// `MM:SS`, or `H:MM:SS` from one hour up.
    public static func string(seconds: Int) -> String {
        string(seconds: seconds, format: .minutesAndSeconds)
    }

    /// Whole seconds in `format`: `02:30`, `2:30` or `150`; both minute formats switch to `H:MM:SS` from one hour.
    public static func string(seconds: Int, format: TimerOverlaySettings.TimeFormat) -> String {
        let total = max(0, seconds)
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        switch format {
        case .minutesAndSeconds:
            return hours > 0 ? "\(hours):\(twoDigits(minutes)):\(twoDigits(rest))" : "\(twoDigits(minutes)):\(twoDigits(rest))"
        case .shortMinutes:
            return hours > 0 ? "\(hours):\(twoDigits(minutes)):\(twoDigits(rest))" : "\(minutes):\(twoDigits(rest))"
        case .secondsOnly:
            return "\(total)"
        }
    }

    /// Tenths of a second in `format`: `00:09.9`, `0:09.9` or `9.9`.
    public static func string(tenths: Int, format: TimerOverlaySettings.TimeFormat) -> String {
        let total = max(0, tenths)
        return string(seconds: total / 10, format: format) + ".\(total % 10)"
    }

    /// The time left as the overlay shows it: rounded up, so zero appears only at zero, and with tenths in the
    /// last 10 s when `tenths` is on. The rounding is `Countdown`'s, so the text changes exactly when the
    /// engine wakes.
    public static func string(remaining: TimeInterval, format: TimerOverlaySettings.TimeFormat, tenths: Bool) -> String {
        if Countdown.showsTenths(remaining, tenths: tenths) {
            return string(tenths: Countdown.unitsShown(remaining, perSecond: 10), format: format)
        }
        return string(seconds: Countdown.unitsShown(remaining, perSecond: 1), format: format)
    }

    /// The time since zero, counting up in whole seconds: `+0:07`, `+1:02:03`, or `+7` with seconds only.
    public static func overtime(_ sinceZero: TimeInterval, format: TimerOverlaySettings.TimeFormat) -> String {
        let seconds = sinceZero > 0 ? Int(min((sinceZero + Countdown.slack).rounded(.down), 1e15)) : 0
        switch format {
        case .secondsOnly: return "+\(seconds)"
        case .minutesAndSeconds, .shortMinutes: return "+" + string(seconds: seconds, format: .shortMinutes)
        }
    }

    /// What the overlay shows from zero until it leaves ("At zero, show"). Holding zero uses the countdown's own
    /// zero, tenths included, so the plate keeps its width; a blank word holds zero instead.
    public static func atZero(
        _ choice: TimerOverlaySettings.AtZero, word: String, sinceZero: TimeInterval,
        format: TimerOverlaySettings.TimeFormat, tenths: Bool
    ) -> String {
        let zero = string(remaining: 0, format: format, tenths: tenths)
        switch choice {
        case .holdZero:
            return zero
        case .word:
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? zero : trimmed
        case .overtime:
            return overtime(sinceZero, format: format)
        }
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
