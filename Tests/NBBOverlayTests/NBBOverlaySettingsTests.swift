import Foundation
import STPlatform
import Testing
@testable import NBBOverlay

@Suite("NBB overlay settings")
struct NBBOverlaySettingsTests {
    @Test func defaultsMatchTheSpec() {
        let settings = NBBOverlaySettings.defaultValue
        #expect(settings.offsetX == 750 && settings.offsetY == 0)
        #expect(settings.width == 320)
        #expect(settings.aspectRatio == 1.6)
        #expect(settings.plateOpacityPercent == 85)
        #expect(settings.requiresData)
        #expect(!settings.requiresMinecraftFocus)
        #expect(!settings.placementModeEnabled)
        #expect(settings.snappingEnabled)
        #expect(settings.showsPredictions && settings.showsEyeThrows && settings.showsBoatState && settings.showsInformationMessages)
        #expect(settings.showsLocationColumn && settings.showsCertaintyColumn && settings.showsDistanceColumn)
        #expect(settings.maxPredictionRows == 5)
        #expect(settings.fadeOnResetEnabled)
        #expect(settings.fadeSeconds == 0.25)
        #expect(NBBOverlaySettings.name == "nbbOverlay")
        #expect(NBBOverlaySettings.version == 1)
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = NBBOverlaySettings.defaultValue
        settings.offsetX = 42
        settings.offsetY = -11
        settings.width = 400
        settings.aspectRatio = 2.0
        settings.placementModeEnabled = true
        settings.snappingEnabled = false
        settings.requiresData = false
        settings.requiresMinecraftFocus = true
        settings.showsBoatState = false
        settings.maxPredictionRows = 2
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(NBBOverlaySettings.self, from: data) == settings)
    }

    @Test func missingKeysTakeDefaults() throws {
        let decoded = try JSONDecoder().decode(NBBOverlaySettings.self, from: Data(#"{"width":400}"#.utf8))
        var expected = NBBOverlaySettings.defaultValue
        expected.width = 400
        #expect(decoded == expected)
    }

    @Test func outOfRangeValuesAreClampedOnLoad() throws {
        let json = #"{"width": 9000, "aspectRatio": 100, "plateOpacityPercent": 1, "maxPredictionRows": 99, "fadeSeconds": -5}"#
        let decoded = try JSONDecoder().decode(NBBOverlaySettings.self, from: Data(json.utf8))
        #expect(decoded.width == NBBOverlaySettings.widthRange.upperBound)
        #expect(decoded.aspectRatio == NBBOverlaySettings.aspectRatioRange.upperBound)
        #expect(decoded.plateOpacityPercent == NBBOverlaySettings.plateOpacityRange.lowerBound)
        #expect(decoded.maxPredictionRows == NBBOverlaySettings.maxPredictionRowsRange.upperBound)
        #expect(decoded.fadeSeconds == NBBOverlaySettings.fadeSecondsRange.lowerBound)
    }

    @Test func unusableValuesFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(NBBOverlaySettings.self, from: Data(#"{"requiresData":"sometimes"}"#.utf8))
        #expect(decoded == NBBOverlaySettings.defaultValue)
    }

    @Test func bothVisibilityRestrictionsCanBeOnAtOnce() throws {
        var settings = NBBOverlaySettings.defaultValue
        settings.requiresData = true
        settings.requiresMinecraftFocus = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(NBBOverlaySettings.self, from: data)
        #expect(decoded.requiresData && decoded.requiresMinecraftFocus)
    }

    @Test func aspectRatioPresetMatchesTheDefaultToNinjabrainBot() {
        #expect(NBBAspectRatioPreset.matching(NBBOverlaySettings.defaultValue.aspectRatio) == .ninjabrainBot)
        #expect(NBBAspectRatioPreset.matching(1.0) == .square)
        #expect(NBBAspectRatioPreset.matching(4.0 / 3.0) == .fourByThree)
        #expect(NBBAspectRatioPreset.matching(16.0 / 9.0) == .sixteenByNine)
    }

    @Test func aspectRatioPresetFallsBackToCustomForAnUnmatchedRatio() {
        #expect(NBBAspectRatioPreset.matching(2.37) == .custom)
        #expect(NBBAspectRatioPreset.custom.ratio == nil)
    }

    @MainActor
    @Test func theStoreReturnsClampedValuesFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "nbb-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = #"{"version": 1, "value": {"width": -5}}"#
        try Data(file.utf8).write(to: directory.appending(path: "nbbOverlay.json"))
        let loaded = SettingsStore(directory: directory).load(NBBOverlaySettings.self)
        #expect(loaded.width == NBBOverlaySettings.widthRange.lowerBound)
    }
}
