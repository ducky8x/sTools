import Foundation

/// Single source of truth for the color tokens (hex strings). Values come from the design spec, section 3.3.
public enum STPalette {
    public static let background = "#0B0A09"
    public static let surface = "#15120F"
    public static let raised = "#1E1A16"
    public static let ink = "#F4EFE6"
    public static let inkSecondary = "#BDB3A4"
    public static let inkTertiary = "#9C9286"
    public static let gold = "#D9AE52"
    public static let goldStroke = "#C89A3A"
    public static let stroke = "#6E655B"
    public static let rule = "#2E2924"
    public static let danger = "#E07A6E"
    public static let success = "#7DBF86"

    /// Strict `#RRGGBB` parser (either letter case). Anything else, including shorthand and alpha forms, is `nil`.
    static func rgb(_ hex: String) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        let digits = Array(hex.utf8)
        guard digits.count == 7, digits[0] == UInt8(ascii: "#") else { return nil }
        var value: UInt32 = 0
        for digit in digits.dropFirst() {
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = value << 4 | UInt32(digit - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): value = value << 4 | UInt32(digit - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): value = value << 4 | UInt32(digit - UInt8(ascii: "A") + 10)
            default: return nil
            }
        }
        return (UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
    }

    /// `#RRGGBB` from channels, uppercase.
    static func hex(red: UInt8, green: UInt8, blue: UInt8) -> String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Linear blend of two `#RRGGBB` colors: `amount` 0 returns `base`, 1 returns `other`. Invalid input counts as black.
    static func mix(_ base: String, toward other: String, by amount: Double) -> String {
        let (a, b) = (rgb(base) ?? (0, 0, 0), rgb(other) ?? (0, 0, 0))
        func channel(_ from: UInt8, _ to: UInt8) -> UInt8 {
            UInt8((Double(from) + (Double(to) - Double(from)) * amount).rounded().clamped(to: 0...255))
        }
        return hex(red: channel(a.red, b.red), green: channel(a.green, b.green), blue: channel(a.blue, b.blue))
    }

    /// WCAG 2.x contrast ratio between two `#RRGGBB` colors (invalid input counts as black).
    public static func contrastRatio(_ first: String, _ second: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let value = rgb(hex) ?? (0, 0, 0)
            func channel(_ byte: UInt8) -> Double {
                let c = Double(byte) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(value.red) + 0.7152 * channel(value.green) + 0.0722 * channel(value.blue)
        }
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
