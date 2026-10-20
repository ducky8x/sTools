import SwiftUI

public extension Color {
    /// `#RRGGBB` to sRGB color. Invalid input yields black.
    init(hex: String) {
        let channels = STPalette.rgb(hex) ?? (0, 0, 0)
        self.init(.sRGB,
                  red: Double(channels.red) / 255,
                  green: Double(channels.green) / 255,
                  blue: Double(channels.blue) / 255,
                  opacity: 1)
    }
}

public enum STColor {
    public static let background = Color(hex: STPalette.background)
    public static let surface = Color(hex: STPalette.surface)
    public static let raised = Color(hex: STPalette.raised)
    public static let ink = Color(hex: STPalette.ink)
    public static let inkSecondary = Color(hex: STPalette.inkSecondary)
    public static let inkTertiary = Color(hex: STPalette.inkTertiary)
    public static let gold = Color(hex: STPalette.gold)
    public static let goldStroke = Color(hex: STPalette.goldStroke)
    public static let stroke = Color(hex: STPalette.stroke)
    public static let rule = Color(hex: STPalette.rule)
    public static let danger = Color(hex: STPalette.danger)
    public static let success = Color(hex: STPalette.success)
}
