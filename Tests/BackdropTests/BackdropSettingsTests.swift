import Foundation
import STPlatform
import Testing
@testable import Backdrop

@Suite("Backdrop settings")
struct BackdropSettingsTests {
    @Test func defaultsMatchTheSpec() {
        let settings = BackdropSettings.defaultValue
        #expect(settings.additionalDisplayIDs.isEmpty)
        #expect(settings.fill.kind == .color)
        #expect(settings.fill.color == "#15120F")
        #expect(settings.displayFills.isEmpty)
        #expect(settings.opacityPercent == 100)
        #expect(settings.hideOnFullScreenScope == .thisDisplay)
        #expect(settings.fillTransitionSeconds == 0.3)
        #expect(BackdropSettings.name == "backdrop")
        #expect(BackdropSettings.version == 1)
    }

    @Test func fillForUncoveredDisplayFallsBackToTheMainFill() {
        var settings = BackdropSettings.defaultValue
        settings.fill.color = "#FF0000"
        #expect(settings.fill(for: 99).color == "#FF0000")
    }

    @Test func fillForADisplayWithAnOverrideUsesIt() {
        var settings = BackdropSettings.defaultValue
        var override = BackdropSettings.Fill()
        override.color = "#00FF00"
        settings.displayFills = [.init(displayID: 5, fill: override)]
        #expect(settings.fill(for: 5).color == "#00FF00")
        #expect(settings.fill(for: 6).color == settings.fill.color)
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = BackdropSettings.defaultValue
        settings.additionalDisplayIDs = [2, 3]
        settings.fill.kind = .linearGradient
        settings.fill.gradientAngleDegrees = 45
        settings.displayFills = [.init(displayID: 2, fill: BackdropSettings.Fill())]
        settings.opacityPercent = 80
        settings.hideOnFullScreenScope = .allDisplays
        settings.fillTransitionSeconds = 1.2
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(BackdropSettings.self, from: data) == settings)
    }

    @Test func missingKeysTakeDefaults() throws {
        let decoded = try JSONDecoder().decode(BackdropSettings.self, from: Data(#"{"opacityPercent":50}"#.utf8))
        var expected = BackdropSettings.defaultValue
        expected.opacityPercent = 50
        #expect(decoded == expected)
    }

    @Test func outOfRangeValuesAreClampedOnLoad() throws {
        let json = #"{"opacityPercent": -5, "fillTransitionSeconds": 99}"#
        let decoded = try JSONDecoder().decode(BackdropSettings.self, from: Data(json.utf8))
        #expect(decoded.opacityPercent == BackdropSettings.opacityRange.lowerBound)
        #expect(decoded.fillTransitionSeconds == BackdropSettings.fillTransitionRange.upperBound)
    }

    @Test func unusableValuesFallBackToDefaults() throws {
        let json = #"{"hideOnFullScreenScope": "everywhere", "fill": {"kind": "rainbow"}}"#
        let decoded = try JSONDecoder().decode(BackdropSettings.self, from: Data(json.utf8))
        #expect(decoded == BackdropSettings.defaultValue)
    }

    @Test func hexColorsAreNormalizedToUppercase() throws {
        let json = ##"{"fill": {"color": "#aabbcc"}}"##
        let decoded = try JSONDecoder().decode(BackdropSettings.self, from: Data(json.utf8))
        #expect(decoded.fill.color == "#AABBCC")
    }

    @Test func duplicateDisplayFillsAreCollapsedOnLoad() throws {
        var settings = BackdropSettings.defaultValue
        settings.displayFills = [
            .init(displayID: 1, fill: { var f = BackdropSettings.Fill(); f.color = "#111111"; return f }()),
            .init(displayID: 1, fill: { var f = BackdropSettings.Fill(); f.color = "#222222"; return f }()),
        ]
        let clamped = settings.clamped()
        #expect(clamped.displayFills.count == 1)
        #expect(clamped.displayFills.first?.fill.color == "#111111")
    }

    @Test(arguments: [
        "../secret.png", "Images/../../x.png", "/etc/passwd", "Images/sub/dir.png", "other/file.png", "Images/", "",
    ])
    func imageNamesOutsideTheImagesFolderAreDropped(name: String) throws {
        let json = try JSONSerialization.data(withJSONObject: ["fill": ["imageName": name]])
        let decoded = try JSONDecoder().decode(BackdropSettings.self, from: json)
        #expect(decoded.fill.imageName == nil)
    }

    @Test func validImageNamesSurvive() throws {
        let json = try JSONSerialization.data(withJSONObject: ["fill": ["imageName": "Images/abc.png"]])
        #expect(try JSONDecoder().decode(BackdropSettings.self, from: json).fill.imageName == "Images/abc.png")
    }

    @MainActor
    @Test func theStoreReturnsClampedValuesFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "backdrop-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = #"{"version": 1, "value": {"opacityPercent": -100}}"#
        try Data(file.utf8).write(to: directory.appending(path: "backdrop.json"))
        let loaded = SettingsStore(directory: directory).load(BackdropSettings.self)
        #expect(loaded.opacityPercent == BackdropSettings.opacityRange.lowerBound)
    }
}
