import Foundation

/// The text of the page's Custom duration field (spec 5.6.3): `H:MM:SS`, limited to 1 s – 99:59:59.
public enum DurationText {
    /// The durations the field accepts: the settings' own range.
    public static let range = TimerOverlaySettings.durationRange

    /// `H:MM:SS`, such as `0:02:30`.
    public static func format(_ seconds: Int) -> String {
        let total = max(0, seconds)
        return "\(total / 3600):\(twoDigits((total % 3600) / 60)):\(twoDigits(total % 60))"
    }

    /// The seconds `text` names, kept within `range`, or nil when it isn't a duration.
    ///
    /// Takes `H:MM:SS`, `M:SS` or plain seconds, so `0:02:30`, `2:30` and `150` all mean two and a half minutes.
    /// Fields after a colon are one or two digits below 60; the first field can be any size (`90:00`). A
    /// duration below 1 s becomes 1 s and one past 99:59:59 becomes 99:59:59, as a slider's typed value is
    /// clamped.
    public static func parse(_ text: String) -> Int? {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }
        var total = 0
        for (index, field) in fields.enumerated() {
            let maxDigits = index == 0 ? 9 : 2
            guard (1...maxDigits).contains(field.utf8.count),
                  field.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  let value = Int(field)
            else { return nil }
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return min(max(total, range.lowerBound), range.upperBound)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
