import AppKit
import SwiftUI

/// Pure conversion between `#RRGGBB` strings and colors, used by `STColorWell`.
public enum STColorWellHex {
    /// Parses `#RRGGBB` (the `#` is optional, case-insensitive) into 0...1 sRGB components.
    /// Returns nil for anything that is not exactly six hex digits.
    public static func components(from hex: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// Formats 0...1 sRGB components as uppercase `#RRGGBB`. Out-of-range and non-finite components are clamped.
    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ component: Double) -> Int {
            guard component.isFinite else { return 0 }
            return Int((min(max(component, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Uppercase `#RRGGBB` for a valid hex string in either spelling, nil otherwise.
    public static func normalized(_ hex: String) -> String? {
        guard let c = components(from: hex) else { return nil }
        return Self.hex(red: c.red, green: c.green, blue: c.blue)
    }

    /// The color for `hex`; invalid input shows black, matching `Color(hex:)`.
    public static func color(from hex: String) -> Color {
        let c = components(from: hex) ?? (0, 0, 0)
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }

    /// The opaque `#RRGGBB` for a color, converted through sRGB.
    public static func hex(from color: Color) -> String {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
        return hex(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }
}

/// A swatch framed in the theme stroke that opens the system color panel. Reads and writes opaque `#RRGGBB`.
public struct STColorWell: View {
    @Binding private var hex: String
    private let label: String
    @Environment(\.stTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    public init(hex: Binding<String>, label: String) {
        _hex = hex
        self.label = label
    }

    public var body: some View {
        ColorPicker(label, selection: color, supportsOpacity: false)
            .labelsHidden()
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.stroke, lineWidth: 1.5))
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityLabel(label)
            .accessibilityValue(hex)
    }

    private var color: Binding<Color> {
        Binding(
            get: { STColorWellHex.color(from: hex) },
            set: { hex = STColorWellHex.hex(from: $0) }
        )
    }
}
