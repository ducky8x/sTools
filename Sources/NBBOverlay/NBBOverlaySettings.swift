import Foundation
import STPlatform

/// The NBB Overlay tool's persisted settings (spec 5.1.5).
///
/// Position and size are settable two ways, both always live here: typed X/Y, width and aspect ratio
/// (`offsetX`/`offsetY`/`width`/`aspectRatio`), or — when `placementModeEnabled` is on — by dragging
/// the overlay itself and its resize handle on screen, with edge/center snapping
/// (`snappingEnabled`). Dragging writes back to the same typed fields, so either path always reflects
/// the other.
///
/// The predictions table also leaves out the "nether coordinates" and "angle and turn hint" columns
/// spec 5.1.3 describes: the API gives chunk coordinates and overworld distance directly, but not a
/// nether conversion or a travel bearing, and spec 5.1.3 itself requires checking any such derived
/// value "against a running Ninjabrain Bot 1.5.2 so the overlay never shows a value Ninjabrain Bot
/// wouldn't" — a live check this build couldn't do. Showing only the API's own fields keeps the
/// speedrun-rule guardrail (5.1.4) unambiguous until that check happens.
public struct NBBOverlaySettings: SettingsDocument {
    public static let name = "nbbOverlay"
    public static let version = 1
    public static var defaultValue: NBBOverlaySettings { NBBOverlaySettings() }

    public static let widthRange = 160...900
    public static let aspectRatioRange = 0.4...4.0
    public static let plateOpacityRange = 60...100
    public static let maxPredictionRowsRange = 1...5
    public static let fadeSecondsRange = 0.0...2.0

    /// Pixels right (+) or left (-) of the display's center.
    public var offsetX = -568
    /// Pixels down (+) or up (-) from the display's center; the spec default sits at the vertical
    /// center of Minecraft's display, so this starts at 0.
    public var offsetY = 0
    /// The plate's width in points; height follows from `aspectRatio`. Content scales to fit.
    public var width = 320
    /// Width \u{00f7} height.
    public var aspectRatio = 1.6
    public var plateOpacityPercent = 85

    /// When on, the overlay can be dragged and its handle resized directly on screen instead of (or
    /// alongside) the typed fields above.
    public var placementModeEnabled = false
    /// Snaps the dragged overlay to the display's edges and center (spec 5.1.5).
    public var snappingEnabled = true

    /// Independent restrictions — any mix can be on (feedback: these used to be one exclusive choice).
    public var requiresData = true
    public var requiresMinecraftFocus = false

    public var showsPredictions = true
    public var showsEyeThrows = true
    public var showsBoatState = true
    public var showsInformationMessages = true

    public var showsLocationColumn = true
    public var showsCertaintyColumn = true
    public var showsDistanceColumn = true
    public var maxPredictionRows = 5

    public var fadeOnResetEnabled = true
    public var fadeSeconds: Double = 0.25

    public init() {}

    /// This value with every field inside its range.
    public func clamped() -> NBBOverlaySettings {
        var result = self
        result.width = width.clamped(to: Self.widthRange)
        result.aspectRatio = aspectRatio.clamped(to: Self.aspectRatioRange)
        result.plateOpacityPercent = plateOpacityPercent.clamped(to: Self.plateOpacityRange)
        result.maxPredictionRows = maxPredictionRows.clamped(to: Self.maxPredictionRowsRange)
        result.fadeSeconds = fadeSeconds.clamped(to: Self.fadeSecondsRange)
        return result
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NBBOverlaySettings()
        offsetX = container.lossy(Int.self, .offsetX) ?? defaults.offsetX
        offsetY = container.lossy(Int.self, .offsetY) ?? defaults.offsetY
        width = container.lossy(Int.self, .width) ?? defaults.width
        aspectRatio = container.lossy(Double.self, .aspectRatio) ?? defaults.aspectRatio
        plateOpacityPercent = container.lossy(Int.self, .plateOpacityPercent) ?? defaults.plateOpacityPercent
        placementModeEnabled = container.lossy(Bool.self, .placementModeEnabled) ?? defaults.placementModeEnabled
        snappingEnabled = container.lossy(Bool.self, .snappingEnabled) ?? defaults.snappingEnabled
        requiresData = container.lossy(Bool.self, .requiresData) ?? defaults.requiresData
        requiresMinecraftFocus = container.lossy(Bool.self, .requiresMinecraftFocus) ?? defaults.requiresMinecraftFocus
        showsPredictions = container.lossy(Bool.self, .showsPredictions) ?? defaults.showsPredictions
        showsEyeThrows = container.lossy(Bool.self, .showsEyeThrows) ?? defaults.showsEyeThrows
        showsBoatState = container.lossy(Bool.self, .showsBoatState) ?? defaults.showsBoatState
        showsInformationMessages = container.lossy(Bool.self, .showsInformationMessages) ?? defaults.showsInformationMessages
        showsLocationColumn = container.lossy(Bool.self, .showsLocationColumn) ?? defaults.showsLocationColumn
        showsCertaintyColumn = container.lossy(Bool.self, .showsCertaintyColumn) ?? defaults.showsCertaintyColumn
        showsDistanceColumn = container.lossy(Bool.self, .showsDistanceColumn) ?? defaults.showsDistanceColumn
        maxPredictionRows = container.lossy(Int.self, .maxPredictionRows) ?? defaults.maxPredictionRows
        fadeOnResetEnabled = container.lossy(Bool.self, .fadeOnResetEnabled) ?? defaults.fadeOnResetEnabled
        fadeSeconds = container.lossy(Double.self, .fadeSeconds) ?? defaults.fadeSeconds
        self = clamped()
    }
}

/// Named choices for `NBBOverlaySettings.aspectRatio` (feedback: typing an arbitrary ratio was less
/// discoverable than picking a familiar shape). `.custom` has no fixed ratio — picking it leaves
/// `aspectRatio` wherever it was and reveals the free-form slider; dragging the resize handle to a
/// ratio that doesn't match any preset also reads back as `.custom`, which is correct (it *is* one).
public enum NBBAspectRatioPreset: String, CaseIterable, Sendable {
    case square, fourByThree, sixteenByNine, ninjabrainBot, custom

    /// `nil` for `.custom`, which has no single fixed ratio.
    public var ratio: Double? {
        switch self {
        case .square: 1.0
        case .fourByThree: 4.0 / 3.0
        case .sixteenByNine: 16.0 / 9.0
        case .ninjabrainBot: 1.6
        case .custom: nil
        }
    }

    public var title: String {
        switch self {
        case .square: "Square"
        case .fourByThree: "4:3"
        case .sixteenByNine: "16:9"
        case .ninjabrainBot: "Ninjabrain Bot"
        case .custom: "Custom"
        }
    }

    /// The preset `ratio` is closest to, or `.custom` if it doesn't match one closely enough.
    public static func matching(_ ratio: Double) -> NBBAspectRatioPreset {
        allCases.first { preset in
            guard let value = preset.ratio else { return false }
            return abs(value - ratio) < 0.005
        } ?? .custom
    }
}

extension KeyedDecodingContainer {
    fileprivate func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
