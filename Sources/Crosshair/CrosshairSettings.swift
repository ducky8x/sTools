import Foundation
import STDesign
import STPlatform

/// The Crosshair tool's persisted settings (spec 5.3.2). Every size and offset is in physical pixels.
///
/// Values read from disk are clamped into their ranges and unusable values fall back to the
/// defaults, so a hand-edited or damaged file can never produce an unrenderable crosshair.
public struct CrosshairSettings: SettingsDocument {
    public static let name = "crosshair"
    public static let version = 1
    public static var defaultValue: CrosshairSettings { CrosshairSettings() }

    public enum Shape: String, Codable, CaseIterable, Sendable {
        case plus, dot, circle, x, image
    }

    /// Which point of an image lands on the center pixel.
    public enum ImageAnchor: String, Codable, CaseIterable, Sendable {
        case center, topLeft, topRight, bottomLeft, bottomRight
    }

    /// Which pixel counts as the center when a width or height is even.
    public enum CenterSide: String, Codable, CaseIterable, Sendable {
        /// The pixel just right of (or below) the true center.
        case rightDown
        /// The pixel just left of (or above) the true center.
        case leftUp
    }


    public enum DisplayChoice: String, Codable, CaseIterable, Sendable {
        case followMinecraft
        case specific
    }

    public static let sizeRange = 1...200
    public static let thicknessRange = 1...50
    public static let outlineWidthRange = 1...16
    public static let gapRange = 0...100
    public static let opacityRange = 10...100
    public static let imageScaleRange = 10...400
    /// Offsets are clamped to the display at placement time; this bound only keeps stored values sane.
    public static let offsetLimit = 16_384

    public var shape: Shape = .plus
    public var fillHex = "#FFFFFF"
    public var outlineEnabled = true
    public var outlineHex = "#000000"
    public var outlineWidth = 2
    /// Arm length for Plus and X, diameter for Dot and Circle.
    public var size = 10
    public var thickness = 2
    /// Positive moves the crosshair right.
    public var offsetX = 0
    /// Positive moves the crosshair down.
    public var offsetY = 0
    /// The imported image, relative to the sTools support folder (`Images/<uuid>.<ext>`).
    public var imageName: String?
    public var imageScalePercent = 100
    public var imageAnchor: ImageAnchor = .center
    public var gap = 0
    public var opacityPercent = 100
    public var centerSide: CenterSide = .rightDown
    /// An independent restriction, not an alternative to being "on" (spec 5.3.2's Visibility setting,
    /// reshaped per feedback: a single on/off switch rather than exclusive options, so it composes
    /// cleanly with the same setting on other tools).
    public var visibleOnlyWhileMinecraftFocused = false
    public var displayChoice: DisplayChoice = .followMinecraft
    public var specificDisplayID: UInt32?

    public init() {}

    /// This value with every field inside its range.
    public func clamped() -> CrosshairSettings {
        var result = self
        result.fillHex = STColorWellHex.normalized(fillHex) ?? "#FFFFFF"
        result.outlineHex = STColorWellHex.normalized(outlineHex) ?? "#000000"
        result.outlineWidth = outlineWidth.clamped(to: Self.outlineWidthRange)
        result.size = size.clamped(to: Self.sizeRange)
        result.thickness = thickness.clamped(to: Self.thicknessRange)
        result.offsetX = offsetX.clamped(to: -Self.offsetLimit...Self.offsetLimit)
        result.offsetY = offsetY.clamped(to: -Self.offsetLimit...Self.offsetLimit)
        result.imageName = imageName.flatMap(Self.validImageName)
        result.imageScalePercent = imageScalePercent.clamped(to: Self.imageScaleRange)
        result.gap = gap.clamped(to: Self.gapRange)
        result.opacityPercent = opacityPercent.clamped(to: Self.opacityRange)
        return result
    }

    /// `Images/<file>` with a plain file name, nothing else.
    static func validImageName(_ name: String) -> String? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Images", !parts[1].isEmpty, parts[1] != ".", parts[1] != ".." else { return nil }
        return name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CrosshairSettings()
        shape = container.lossy(Shape.self, .shape) ?? defaults.shape
        fillHex = container.lossy(String.self, .fillHex) ?? defaults.fillHex
        outlineEnabled = container.lossy(Bool.self, .outlineEnabled) ?? defaults.outlineEnabled
        outlineHex = container.lossy(String.self, .outlineHex) ?? defaults.outlineHex
        outlineWidth = container.lossy(Int.self, .outlineWidth) ?? defaults.outlineWidth
        size = container.lossy(Int.self, .size) ?? defaults.size
        thickness = container.lossy(Int.self, .thickness) ?? defaults.thickness
        offsetX = container.lossy(Int.self, .offsetX) ?? defaults.offsetX
        offsetY = container.lossy(Int.self, .offsetY) ?? defaults.offsetY
        imageName = container.lossy(String.self, .imageName)
        imageScalePercent = container.lossy(Int.self, .imageScalePercent) ?? defaults.imageScalePercent
        imageAnchor = container.lossy(ImageAnchor.self, .imageAnchor) ?? defaults.imageAnchor
        gap = container.lossy(Int.self, .gap) ?? defaults.gap
        opacityPercent = container.lossy(Int.self, .opacityPercent) ?? defaults.opacityPercent
        centerSide = container.lossy(CenterSide.self, .centerSide) ?? defaults.centerSide
        visibleOnlyWhileMinecraftFocused = container.lossy(Bool.self, .visibleOnlyWhileMinecraftFocused) ?? defaults.visibleOnlyWhileMinecraftFocused
        displayChoice = container.lossy(DisplayChoice.self, .displayChoice) ?? defaults.displayChoice
        specificDisplayID = container.lossy(UInt32.self, .specificDisplayID)
        self = clamped()
    }
}

extension KeyedDecodingContainer {
    /// The decoded value, or nil when the key is missing, null or of the wrong type.
    fileprivate func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
