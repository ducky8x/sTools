import CoreGraphics
import Foundation
import STDesign

/// The parts of the settings the overlay is drawn with: its look, size, font, progress shape and color overrides.
/// Changing anything else (the duration, the alarm, the keys) never redraws the overlay.
public struct TimerOverlayStyle: Equatable, Sendable {
    public var look: TimerOverlaySettings.Look
    /// The digits' size in points, inside `TimerOverlaySettings.digitSizeRange`.
    public var digitSize: Int
    public var fontFamily: String
    public var progress: TimerOverlaySettings.ProgressStyle
    /// Uppercase `#RRGGBB` or nil ("as the look sets it"), like the overrides below.
    public var plateColorHex: String?
    /// Inside `TimerOverlaySettings.plateOpacityRange`, or nil.
    public var plateOpacityPercent: Int?
    public var edgeColorHex: String?
    /// Points inside `TimerOverlaySettings.edgeWidthRange`; 0 draws no edge.
    public var edgeWidth: Double?
    /// Points inside `TimerOverlaySettings.cornerRadiusRange`.
    public var cornerRadius: Double?
    public var digitColorHex: String?
    public var timesUpPlateColorHex: String?
    public var timesUpDigitColorHex: String?

    /// `settings`' drawn parts, each kept inside its range; an unusable color or number counts as no override.
    public init(_ settings: TimerOverlaySettings) {
        look = settings.look
        digitSize = Self.clamp(settings.digitSize, TimerOverlaySettings.digitSizeRange)
        fontFamily = settings.fontFamily
        progress = settings.progress
        plateColorHex = settings.plateColorHex.flatMap(STColorWellHex.normalized)
        plateOpacityPercent = settings.plateOpacityPercent.map { Self.clamp($0, TimerOverlaySettings.plateOpacityRange) }
        edgeColorHex = settings.edgeColorHex.flatMap(STColorWellHex.normalized)
        edgeWidth = settings.edgeWidth.flatMap { $0.isFinite ? Self.clamp($0, TimerOverlaySettings.edgeWidthRange) : nil }
        cornerRadius = settings.cornerRadius.flatMap { $0.isFinite ? Self.clamp($0, TimerOverlaySettings.cornerRadiusRange) : nil }
        digitColorHex = settings.digitColorHex.flatMap(STColorWellHex.normalized)
        timesUpPlateColorHex = settings.timesUpPlateColorHex.flatMap(STColorWellHex.normalized)
        timesUpDigitColorHex = settings.timesUpDigitColorHex.flatMap(STColorWellHex.normalized)
    }

    private static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The overlay's colors and strokes for one look and one state (spec 5.6.4), with the Advanced overrides applied.
/// Pure: the theme's Increase Contrast comes in as a value, from the `STTheme` the app passes in, never from a
/// view's fallback theme.
///
/// | Look | Counting | At zero (the time's-up look) |
/// |---|---|---|
/// | sTools plate | `background` plate at 85%, `rule` hairline, 12 pt corners, `ink` digits | `gold` plate, `background` digits |
/// | Digits only | no plate; `ink` digits with a thin dark outline | `gold` digits |
/// | Compact pill | a capsule in the sTools plate's colors | as the sTools plate |
///
/// Near zero turns the digits `gold` or `danger`; paused dims them to `inkSecondary`. On a plate below 80% opacity
/// `gold` digits are drawn in `ink`, which keeps 4.5:1 over a white game frame (spec 3.3). Increase Contrast
/// thickens the edge and the outline, and raises the dimmed inks to `ink` as the theme does.
public struct TimerLook: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        /// A rounded rectangle with this corner radius in points.
        case rounded(CGFloat)
        /// Fully round ends.
        case capsule
    }

    public struct Plate: Equatable, Sendable {
        public var colorHex: String
        /// 0.6 to 1, for the plate's fill only: the digits and the edge are always opaque.
        public var opacity: Double
        public var edgeHex: String
        /// Points, drawn inside the plate; 0 draws no edge.
        public var edgeWidth: CGFloat
        public var shape: Shape
    }

    /// The dark line around the digits when there's no plate, so they read over snow and sky.
    public struct Outline: Equatable, Sendable {
        public var colorHex: String
        /// Points around each glyph.
        public var width: CGFloat
    }

    /// nil for Digits only.
    public var plate: Plate?
    public var digitHex: String
    /// The small-caps label and the *Paused* mark.
    public var captionHex: String
    public var outline: Outline?
    /// The `danger` edge's width while placing over a rule zone.
    public var dangerEdgeWidth: CGFloat

    /// The plate's own opacity in percent (spec 5.6.4).
    public static let defaultPlateOpacityPercent = 85
    /// Below this plate opacity, `gold` digits are drawn in `ink` (spec 3.3).
    public static let goldMinimumPlateOpacity = 0.80
    /// The sTools plate's corners, as on every sTools plate.
    public static let defaultCornerRadius: CGFloat = 12
    public static let hairline: CGFloat = 1
    /// What Increase Contrast adds to the edge, the outline and the `danger` edge.
    public static let increasedContrastExtraWidth: CGFloat = 1
    public static let dangerEdge: CGFloat = 2
    /// The outline's width as a share of the digit size: 1.4 pt at 40 pt, never under 1 pt.
    public static let outlineShare: CGFloat = 0.035

    public init(style: TimerOverlayStyle, state: TimerOverlayContent.State, increaseContrast: Bool) {
        let extra = increaseContrast ? Self.increasedContrastExtraWidth : 0
        let inkSecondary = increaseContrast ? STPalette.ink : STPalette.inkSecondary
        let timesUp = state == .timesUp
        dangerEdgeWidth = Self.dangerEdge + extra

        switch style.look {
        case .plate, .compactPill:
            let opacity = Double(style.plateOpacityPercent ?? Self.defaultPlateOpacityPercent) / 100
            let edgeWidth = CGFloat(style.edgeWidth ?? Double(Self.hairline))
            let shape: Shape = switch style.look {
            case .compactPill: style.cornerRadius.map { .rounded(CGFloat($0)) } ?? .capsule
            default: .rounded(style.cornerRadius.map { CGFloat($0) } ?? Self.defaultCornerRadius)
            }
            plate = Plate(
                colorHex: timesUp ? style.timesUpPlateColorHex ?? STPalette.gold : style.plateColorHex ?? STPalette.background,
                opacity: opacity,
                edgeHex: style.edgeColorHex ?? STPalette.rule,
                edgeWidth: edgeWidth > 0 ? edgeWidth + extra : 0,
                shape: shape)
            outline = nil
            var digits = Self.digitHex(style: style, state: state, inkSecondary: inkSecondary,
                                       timesUpDefault: STPalette.background)
            if digits == STPalette.gold, opacity < Self.goldMinimumPlateOpacity { digits = STPalette.ink }
            digitHex = digits
            captionHex = timesUp ? digits : inkSecondary
        case .digitsOnly:
            plate = nil
            let width = max(1, CGFloat(style.digitSize) * Self.outlineShare)
            outline = Outline(colorHex: STPalette.background, width: width + extra)
            digitHex = Self.digitHex(style: style, state: state, inkSecondary: inkSecondary, timesUpDefault: STPalette.gold)
            captionHex = digitHex
        }
    }

    /// The look `settings` draw for `state`.
    public init(settings: TimerOverlaySettings, state: TimerOverlayContent.State, increaseContrast: Bool) {
        self.init(style: TimerOverlayStyle(settings), state: state, increaseContrast: increaseContrast)
    }

    private static func digitHex(
        style: TimerOverlayStyle, state: TimerOverlayContent.State, inkSecondary: String, timesUpDefault: String
    ) -> String {
        switch state {
        case .counting: style.digitColorHex ?? STPalette.ink
        case .nearZeroGold: STPalette.gold
        case .nearZeroDanger: STPalette.danger
        case .paused: inkSecondary
        case .timesUp: style.timesUpDigitColorHex ?? timesUpDefault
        }
    }
}
