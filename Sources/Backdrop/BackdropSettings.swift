import Foundation
import STDesign
import STPlatform

/// The Window Backdrop tool's persisted settings (spec 5.2.4).
///
/// Values read from disk are clamped into their ranges and unusable values fall back to the
/// defaults, so a hand-edited or damaged file can never produce an unrenderable backdrop.
public struct BackdropSettings: SettingsDocument {
    public static let name = "backdrop"
    /// Version 2 adds the Animated fill (`FillKind.animated`, `Fill.animationName`; spec revision 46). A version 1 file
    /// loads as it is, so the migration is the default one that changes nothing; the bump is for the other direction:
    /// a build that reads up to version 1 moves a version 2 file aside instead of reading `animated` as a color and
    /// saving that over the person's animation.
    public static let version = 2
    public static var defaultValue: BackdropSettings { BackdropSettings() }

    public enum FillKind: String, Codable, CaseIterable, Sendable {
        case color, linearGradient, radialGradient, image
        /// A GIF or a video, looped and muted (spec 5.2.3).
        case animated
    }

    public enum ImageContentMode: String, Codable, CaseIterable, Sendable {
        case fill, fit, stretch, center
    }

    public enum FullScreenScope: String, Codable, CaseIterable, Sendable {
        case thisDisplay, allDisplays
    }

    public struct Fill: Codable, Equatable, Sendable {
        public var kind: FillKind = .color
        public var color = "#15120F"
        public var gradientStartColor = "#0B0A09"
        public var gradientEndColor = "#2A241C"
        /// Linear gradient direction, 0 = left to right, increasing clockwise.
        public var gradientAngleDegrees: Double = 0
        /// Radial gradient center, 0...1 of the display in each axis.
        public var gradientCenterX: Double = 0.5
        public var gradientCenterY: Double = 0.5
        /// Radial gradient radius, a fraction of the display's diagonal.
        public var gradientRadius: Double = 0.75
        /// The imported image, relative to the sTools support folder (`Images/<uuid>.<ext>`).
        public var imageName: String?
        /// The imported GIF or video, stored like `imageName` (`Images/<uuid>.<ext>`).
        public var animationName: String?
        /// How the image or the animation is fitted (spec 5.2.3: the Animated fill has "the same fit modes"), and the
        /// color behind it for Fit and Center. The two fills share them, so these keep their image-fill names.
        public var imageContentMode: ImageContentMode = .fill
        public var imageBackgroundColor = "#0B0A09"

        public init() {}

        /// Decoded field by field, like `BackdropSettings` itself: one bad or missing key (an older
        /// file, a hand edit) falls back to that field's default instead of discarding the whole fill.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Fill()
            kind = container.lossy(FillKind.self, .kind) ?? defaults.kind
            color = container.lossy(String.self, .color) ?? defaults.color
            gradientStartColor = container.lossy(String.self, .gradientStartColor) ?? defaults.gradientStartColor
            gradientEndColor = container.lossy(String.self, .gradientEndColor) ?? defaults.gradientEndColor
            gradientAngleDegrees = container.lossy(Double.self, .gradientAngleDegrees) ?? defaults.gradientAngleDegrees
            gradientCenterX = container.lossy(Double.self, .gradientCenterX) ?? defaults.gradientCenterX
            gradientCenterY = container.lossy(Double.self, .gradientCenterY) ?? defaults.gradientCenterY
            gradientRadius = container.lossy(Double.self, .gradientRadius) ?? defaults.gradientRadius
            imageName = container.lossy(String.self, .imageName)
            animationName = container.lossy(String.self, .animationName)
            imageContentMode = container.lossy(ImageContentMode.self, .imageContentMode) ?? defaults.imageContentMode
            imageBackgroundColor = container.lossy(String.self, .imageBackgroundColor) ?? defaults.imageBackgroundColor
        }
    }

    /// A display's fill, when it differs from `fill` (the one used for Minecraft's own display and
    /// the default for any newly-covered display).
    public struct DisplayFill: Codable, Equatable, Sendable, Identifiable {
        public var displayID: UInt32
        public var fill: Fill
        public var id: UInt32 { displayID }

        public init(displayID: UInt32, fill: Fill = Fill()) {
            self.displayID = displayID
            self.fill = fill
        }
    }

    public static let opacityRange = 10...100
    public static let fillTransitionRange = 0.0...2.0

    /// Displays covered besides Minecraft's own (spec 5.2.1: "Other displays can be covered too,
    /// checkbox per display"). Minecraft's display is always covered while the tool is on.
    public var additionalDisplayIDs: [UInt32] = []
    /// The fill for Minecraft's own display, and the default for a newly-covered display.
    public var fill = Fill()
    /// Per-display overrides for displays in `additionalDisplayIDs` that use their own fill.
    public var displayFills: [DisplayFill] = []
    public var opacityPercent = 100
    public var hideOnFullScreenScope: FullScreenScope = .thisDisplay
    public var fillTransitionSeconds: Double = 0.3
    /// An independent restriction (not an alternative to being "on"): every covered display hides
    /// whenever Minecraft isn't the frontmost app. Same setting shape as Crosshair's and NBB Overlay's.
    public var hidesWhenMinecraftNotFocused = false

    public init() {}

    /// The fill to draw on `displayID`: its own override if one exists, otherwise `fill`.
    public func fill(for displayID: UInt32) -> Fill {
        displayFills.first { $0.displayID == displayID }?.fill ?? fill
    }

    /// This value with every field inside its range and no duplicate display entries.
    public func clamped() -> BackdropSettings {
        var result = self
        result.additionalDisplayIDs = Array(Set(additionalDisplayIDs)).sorted()
        var seen = Set<UInt32>()
        result.displayFills = displayFills.filter { seen.insert($0.displayID).inserted }
        result.fill = fill.clamped()
        result.displayFills = result.displayFills.map { DisplayFill(displayID: $0.displayID, fill: $0.fill.clamped()) }
        result.opacityPercent = opacityPercent.clamped(to: Self.opacityRange)
        result.fillTransitionSeconds = fillTransitionSeconds.clamped(to: Self.fillTransitionRange)
        return result
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BackdropSettings()
        additionalDisplayIDs = container.lossy([UInt32].self, .additionalDisplayIDs) ?? defaults.additionalDisplayIDs
        fill = container.lossy(Fill.self, .fill) ?? defaults.fill
        displayFills = container.lossy([DisplayFill].self, .displayFills) ?? defaults.displayFills
        opacityPercent = container.lossy(Int.self, .opacityPercent) ?? defaults.opacityPercent
        hideOnFullScreenScope = container.lossy(FullScreenScope.self, .hideOnFullScreenScope) ?? defaults.hideOnFullScreenScope
        fillTransitionSeconds = container.lossy(Double.self, .fillTransitionSeconds) ?? defaults.fillTransitionSeconds
        hidesWhenMinecraftNotFocused = container.lossy(Bool.self, .hidesWhenMinecraftNotFocused) ?? defaults.hidesWhenMinecraftNotFocused
        self = clamped()
    }
}

extension BackdropSettings.Fill {
    /// This fill with every numeric field inside its sane range; hex colors normalized or defaulted;
    /// an `imageName` or `animationName` outside the Images folder dropped.
    func clamped() -> Self {
        var result = self
        result.color = STColorWellHex.normalized(color) ?? "#0B0A09"
        result.gradientStartColor = STColorWellHex.normalized(gradientStartColor) ?? "#0B0A09"
        result.gradientEndColor = STColorWellHex.normalized(gradientEndColor) ?? "#2A241C"
        result.imageBackgroundColor = STColorWellHex.normalized(imageBackgroundColor) ?? "#0B0A09"
        result.gradientAngleDegrees = gradientAngleDegrees.truncatingRemainder(dividingBy: 360)
        result.gradientCenterX = gradientCenterX.clamped(to: 0...1)
        result.gradientCenterY = gradientCenterY.clamped(to: 0...1)
        result.gradientRadius = gradientRadius.clamped(to: 0.05...2)
        result.imageName = imageName.flatMap(Self.validImageName)
        result.animationName = animationName.flatMap(Self.validImageName)
        return result
    }

    /// `Images/<file>` with a plain file name, nothing else.
    static func validImageName(_ name: String) -> String? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Images", !parts[1].isEmpty, parts[1] != ".", parts[1] != ".." else { return nil }
        return name
    }
}

extension KeyedDecodingContainer {
    /// The decoded value, or nil when the key is missing, null or of the wrong type.
    fileprivate func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
