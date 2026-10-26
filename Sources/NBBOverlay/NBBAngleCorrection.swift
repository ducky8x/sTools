import Foundation

/// The angle adjustment Ninjabrain Bot shows beside each eye throw's angle (`ThrowPanel.updateCorrection` in 1.5.2):
/// the throw's angle before the correction, then the correction with its sign, green when it's up and red when it's
/// down, and nothing when the angle wasn't adjusted. Written as an angle change ("+0.01", or three decimals when two
/// don't hold it) or as the number of adjustments ("+6"), Ninjabrain Bot's Adjustment display type.
enum NBBAngleCorrection {
    /// What's written beside the angle, or nil when Ninjabrain Bot writes nothing there.
    static func text(_ eyeThrow: NBBEvents.EyeThrow, display: NBBCorrectionDisplay) -> String? {
        if let shown = eyeThrow.shownCorrection { return shown.isEmpty ? nil : shown }
        if display == .increments, let increments = eyeThrow.correctionIncrements {
            return increments == 0 ? nil : String(format: "%+d", increments)
        }
        let correction = eyeThrow.correction
        guard abs(correction) >= 1e-7 else { return nil }
        // Two decimals when they hold the correction exactly, else three (Ninjabrain Bot's own test).
        let twoPlaces = Double(NBBJavaFormat.fixed(correction, places: 2)) ?? correction
        return NBBJavaFormat.fixed(correction, places: abs(twoPlaces - correction) < 1e-7 ? 2 : 3, plusSign: true)
    }

    /// The angle Ninjabrain Bot shows for the throw: before the correction, to two decimals.
    static func angleText(_ eyeThrow: NBBEvents.EyeThrow) -> String {
        NBBJavaFormat.fixed(eyeThrow.angleWithoutCorrection, places: 2)
    }

    /// Ninjabrain Bot's dark theme's Subpixel + (up) and Subpixel − (down) colors.
    static func colorHex(_ text: String) -> String {
        text.hasPrefix("-") ? "#CC6E72" : "#75CC6C"
    }
}

/// How the angle adjustment is written, as Ninjabrain Bot's Settings ▸ Angle adjustment ▸ Adjustment display type.
/// Ninjabrain Bot 1.5.2's default (`angle_adjustment_display_type`) is the angle change.
public enum NBBCorrectionDisplay: String, Codable, CaseIterable, Sendable {
    case angleChange, increments

    /// Ninjabrain Bot's own names for the choices.
    public var title: String {
        switch self {
        case .angleChange: "Angle change"
        case .increments: "Number of adjustments"
        }
    }
}

/// Java's `String.format(Locale.US, "%.Nf", value)`, which Ninjabrain Bot writes its numbers with: the shortest decimal
/// that reads back as the double, rounded half away from zero. C's printf rounds the binary value instead, so a value
/// like 0.0105 (just below the tie in binary) would come out a digit lower.
enum NBBJavaFormat {
    static func fixed(_ value: Double, places: Int, plusSign: Bool = false) -> String {
        guard value.isFinite, var decimal = Decimal(string: "\(value)", locale: Locale(identifier: "en_US_POSIX")) else {
            return String(format: "%.\(places)f", value)
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, places, .plain)
        let magnitude = NSDecimalNumber(decimal: rounded.magnitude).stringValue
        let parts = magnitude.split(separator: ".", omittingEmptySubsequences: false)
        var text = String(parts[0])
        if places > 0 {
            let fraction = parts.count > 1 ? String(parts[1]) : ""
            text += "." + fraction + String(repeating: "0", count: max(0, places - fraction.count))
        }
        let sign = value.sign == .minus ? "-" : (plusSign ? "+" : "")
        return sign + text
    }
}
