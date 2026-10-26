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
/// The predictions table's coordinate column shows Ninjabrain Bot's Location column in the Overworld and its Nether
/// column in the Nether, by the last F3+C's dimension (`NBBCoordinateColumn`), and its distance column follows the same
/// dimension. Its angle and turn hint come from Ninjabrain Bot's own formula over the API (`NBBTravelAngle`, from
/// 1.5.2's source) or straight from its window.
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
    public var offsetX = 750
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
    /// The boat indicator at the top of the overlay.
    public var showsBoatState = true
    /// Also shows the gray boat (no boat angle yet). Off, the gray boat is left out so the overlay stays clean for runs
    /// without a boat.
    public var showsGrayBoat = false
    /// Colors the plate blue, green or red with the boat.
    public var tintsPlateByBoat = true
    public var showsInformationMessages = true

    public var showsLocationColumn = true
    public var showsCertaintyColumn = true
    public var showsDistanceColumn = true
    /// The angle to travel at.
    public var showsAngleColumn = true
    /// The turn from where the player faces to that angle, with an arrow.
    public var showsAngleChangeColumn = true
    /// After an F3+C in the Nether, the coordinate column shows Ninjabrain Bot's Nether coordinates and the distance
    /// column its Nether distance. Off, the table always shows the Overworld location and distance.
    public var showsNetherCoordinatesInNether = true
    /// How the Overworld location is written, as Ninjabrain Bot's stronghold display choice. Ninjabrain Bot 1.5.2's
    /// default (`stronghold_display_type`) is the 4,4 block.
    public var locationDisplay: NBBLocationDisplay = .fourFour
    /// Each eye throw's angle adjustment beside its angle, as Ninjabrain Bot shows it.
    public var showsAngleCorrection = true
    /// How the angle adjustment is written, as Ninjabrain Bot's Adjustment display type. A window's own text is kept.
    public var correctionDisplay: NBBCorrectionDisplay = .angleChange
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
        showsGrayBoat = container.lossy(Bool.self, .showsGrayBoat) ?? defaults.showsGrayBoat
        tintsPlateByBoat = container.lossy(Bool.self, .tintsPlateByBoat) ?? defaults.tintsPlateByBoat
        showsInformationMessages = container.lossy(Bool.self, .showsInformationMessages) ?? defaults.showsInformationMessages
        showsLocationColumn = container.lossy(Bool.self, .showsLocationColumn) ?? defaults.showsLocationColumn
        showsCertaintyColumn = container.lossy(Bool.self, .showsCertaintyColumn) ?? defaults.showsCertaintyColumn
        showsDistanceColumn = container.lossy(Bool.self, .showsDistanceColumn) ?? defaults.showsDistanceColumn
        showsAngleColumn = container.lossy(Bool.self, .showsAngleColumn) ?? defaults.showsAngleColumn
        showsAngleChangeColumn = container.lossy(Bool.self, .showsAngleChangeColumn) ?? defaults.showsAngleChangeColumn
        showsNetherCoordinatesInNether = container.lossy(Bool.self, .showsNetherCoordinatesInNether) ?? defaults.showsNetherCoordinatesInNether
        locationDisplay = container.lossy(NBBLocationDisplay.self, .locationDisplay) ?? defaults.locationDisplay
        showsAngleCorrection = container.lossy(Bool.self, .showsAngleCorrection) ?? defaults.showsAngleCorrection
        correctionDisplay = container.lossy(NBBCorrectionDisplay.self, .correctionDisplay) ?? defaults.correctionDisplay
        maxPredictionRows = container.lossy(Int.self, .maxPredictionRows) ?? defaults.maxPredictionRows
        fadeOnResetEnabled = container.lossy(Bool.self, .fadeOnResetEnabled) ?? defaults.fadeOnResetEnabled
        fadeSeconds = container.lossy(Double.self, .fadeSeconds) ?? defaults.fadeSeconds
        self = clamped()
    }
}

/// Ninjabrain Bot's stronghold display choices (its Settings ▸ "Display stronghold location using"): the chunk's 4,4 block,
/// its 8,8 block, or the chunk itself.
public enum NBBLocationDisplay: String, Codable, CaseIterable, Sendable {
    case fourFour, eightEight, chunk

    /// Ninjabrain Bot's own names for the choices.
    public var title: String {
        switch self {
        case .fourFour: "(4, 4)"
        case .eightEight: "(8, 8)"
        case .chunk: "Chunk"
        }
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
