import Crosshair
import Foundation
import STDesign
import STPlatform

/// The Custom Cursor tool's persisted settings (spec 5.7.3). Sizes are in points: the pointer is drawn at each scale
/// macOS shows it at.
///
/// Values read from disk are clamped into their ranges and unusable values fall back to the defaults, field by field, so
/// a hand-edited or damaged file never gives a pointer that can't be drawn.
public struct CustomCursorSettings: SettingsDocument {
    public static let name = "cursor"
    public static let version = 1
    public static var defaultValue: CustomCursorSettings { CustomCursorSettings() }

    /// The Crosshair's shapes, drawn by its renderer.
    public typealias Shape = CrosshairSettings.Shape

    /// The point of an image that clicks. A shape clicks at its center.
    public enum ClickPoint: String, Codable, CaseIterable, Sendable {
        case center, topLeft, topRight, bottomLeft, bottomRight

        public var title: String {
            switch self {
            case .center: "Center"
            case .topLeft: "Top left"
            case .topRight: "Top right"
            case .bottomLeft: "Bottom left"
            case .bottomRight: "Bottom right"
            }
        }
    }

    /// Where the custom pointer replaces macOS's arrow.
    public enum Where: String, Codable, CaseIterable, Sendable {
        case whileMinecraftInFront, everywhere

        public var title: String {
            switch self {
            case .whileMinecraftInFront: "While Minecraft is in front"
            case .everywhere: "Everywhere"
            }
        }
    }

    public static let sizeRange = 4...64
    public static let thicknessRange = 1...16
    public static let outlineWidthRange = 1...8
    public static let imageScaleRange = 10...400

    public var shape: Shape = .dot
    public var fillHex = "#FFFFFF"
    public var outlineEnabled = true
    public var outlineHex = "#000000"
    public var outlineWidth = 2
    /// Arm length for Plus and X, diameter for Dot and Circle.
    public var size = 12
    /// The line's width for Plus, X and Circle.
    public var thickness = 3
    /// The chosen image, relative to the sTools support folder (`Images/<uuid>.<ext>`), as the Crosshair keeps its own.
    public var imageName: String?
    public var imageScalePercent = 100
    /// Used by the Image shape only. A newly chosen image starts at the top left, where an arrow's tip is.
    public var clickPoint: ClickPoint = .center
    public var `where`: Where = .whileMinecraftInFront

    public init() {}

    /// This value with every field inside its range.
    public func clamped() -> CustomCursorSettings {
        var result = self
        result.fillHex = STColorWellHex.normalized(fillHex) ?? "#FFFFFF"
        result.outlineHex = STColorWellHex.normalized(outlineHex) ?? "#000000"
        result.outlineWidth = outlineWidth.clamped(to: Self.outlineWidthRange)
        result.size = size.clamped(to: Self.sizeRange)
        result.thickness = thickness.clamped(to: Self.thicknessRange)
        result.imageName = imageName.flatMap(Self.validImageName)
        result.imageScalePercent = imageScalePercent.clamped(to: Self.imageScaleRange)
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
        let defaults = CustomCursorSettings()
        shape = container.lossy(Shape.self, .shape) ?? defaults.shape
        fillHex = container.lossy(String.self, .fillHex) ?? defaults.fillHex
        outlineEnabled = container.lossy(Bool.self, .outlineEnabled) ?? defaults.outlineEnabled
        outlineHex = container.lossy(String.self, .outlineHex) ?? defaults.outlineHex
        outlineWidth = container.lossy(Int.self, .outlineWidth) ?? defaults.outlineWidth
        size = container.lossy(Int.self, .size) ?? defaults.size
        thickness = container.lossy(Int.self, .thickness) ?? defaults.thickness
        imageName = container.lossy(String.self, .imageName)
        imageScalePercent = container.lossy(Int.self, .imageScalePercent) ?? defaults.imageScalePercent
        clickPoint = container.lossy(ClickPoint.self, .clickPoint) ?? defaults.clickPoint
        `where` = container.lossy(Where.self, .where) ?? defaults.where
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
