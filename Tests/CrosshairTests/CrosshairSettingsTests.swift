import Foundation
import STPlatform
import Testing

@testable import Crosshair

@Suite("Crosshair settings")
struct CrosshairSettingsTests {
    @Test func defaultsMatchTheSpec() {
        let settings = CrosshairSettings.defaultValue
        #expect(settings.shape == .plus)
        #expect(settings.fillHex == "#FFFFFF")
        #expect(settings.outlineEnabled)
        #expect(settings.outlineHex == "#000000")
        #expect(settings.outlineWidth == 2)
        #expect(settings.size == 10)
        #expect(settings.thickness == 3)
        #expect(settings.offsetX == 0 && settings.offsetY == 0)
        #expect(settings.imageName == nil)
        #expect(settings.imageScalePercent == 100)
        #expect(settings.imageAnchor == .center)
        #expect(settings.gap == 0)
        #expect(settings.opacityPercent == 100)
        #expect(settings.visibleOnlyWhileMinecraftFocused == false)
        #expect(settings.displayChoice == .followMinecraft)
        #expect(settings.specificDisplayID == nil)
        #expect(CrosshairSettings.name == "crosshair")
        #expect(CrosshairSettings.version == 1)
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = CrosshairSettings.defaultValue
        settings.shape = .circle
        settings.fillHex = "#FF8800"
        settings.offsetX = -37
        settings.offsetY = 12
        settings.imageName = "Images/0F0E0D0C-0000-0000-0000-000000000001.png"
        settings.imageAnchor = .bottomRight
        settings.visibleOnlyWhileMinecraftFocused = true
        settings.displayChoice = .specific
        settings.specificDisplayID = 77
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(CrosshairSettings.self, from: data) == settings)
    }

    @Test func missingKeysTakeDefaults() throws {
        let decoded = try JSONDecoder().decode(CrosshairSettings.self, from: Data(#"{"shape":"dot"}"#.utf8))
        var expected = CrosshairSettings.defaultValue
        expected.shape = .dot
        #expect(decoded == expected)
    }

    @Test func outOfRangeValuesAreClampedOnLoad() throws {
        let json = """
        {"size": 5000, "thickness": -4, "outlineWidth": 99, "gap": -1, "opacityPercent": 0,
         "imageScalePercent": 9000, "offsetX": 999999, "offsetY": -999999}
        """
        let decoded = try JSONDecoder().decode(CrosshairSettings.self, from: Data(json.utf8))
        #expect(decoded.size == CrosshairSettings.sizeRange.upperBound)
        #expect(decoded.thickness == CrosshairSettings.thicknessRange.lowerBound)
        #expect(decoded.outlineWidth == CrosshairSettings.outlineWidthRange.upperBound)
        #expect(decoded.gap == CrosshairSettings.gapRange.lowerBound)
        #expect(decoded.opacityPercent == CrosshairSettings.opacityRange.lowerBound)
        #expect(decoded.imageScalePercent == 400)
        #expect(decoded.offsetX == CrosshairSettings.offsetLimit)
        #expect(decoded.offsetY == -CrosshairSettings.offsetLimit)
    }

    @Test func imageScaleRangeIsTenToFourHundred() {
        #expect(CrosshairSettings.imageScaleRange == 10...400)
        var settings = CrosshairSettings.defaultValue
        settings.imageScalePercent = 3
        #expect(settings.clamped().imageScalePercent == 10)
    }

    @Test func unusableValuesFallBackToDefaults() throws {
        let json = """
        {"shape": "hexagon", "fillHex": "red", "outlineHex": "#12", "imageAnchor": 7,
         "visibleOnlyWhileMinecraftFocused": "sometimes", "displayChoice": "all", "size": "big"}
        """
        let decoded = try JSONDecoder().decode(CrosshairSettings.self, from: Data(json.utf8))
        #expect(decoded == CrosshairSettings.defaultValue)
    }

    @Test func olderFilesWithACenterSideStillLoad() throws {
        // Center side was a setting before crosshairs always centered the way Minecraft's does.
        let decoded = try JSONDecoder().decode(CrosshairSettings.self, from: Data(#"{"centerSide":"rightDown","size":12}"#.utf8))
        var expected = CrosshairSettings.defaultValue
        expected.size = 12
        #expect(decoded == expected)
    }

    @Test func hexColorsAreNormalizedToUppercase() throws {
        let decoded = try JSONDecoder().decode(
            CrosshairSettings.self, from: Data(##"{"fillHex":"#aabbcc","outlineHex":"112233"}"##.utf8))
        #expect(decoded.fillHex == "#AABBCC")
        #expect(decoded.outlineHex == "#112233")
    }

    @Test(arguments: [
        "../secret.png", "Images/../../x.png", "/etc/passwd", "Images/sub/dir.png", "other/file.png", "Images/", "",
    ])
    func imageNamesOutsideTheImagesFolderAreDropped(name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["imageName": name])
        let decoded = try JSONDecoder().decode(CrosshairSettings.self, from: data)
        #expect(decoded.imageName == nil)
    }

    @Test func validImageNamesSurvive() throws {
        let data = try JSONSerialization.data(withJSONObject: ["imageName": "Images/abc.svg"])
        #expect(try JSONDecoder().decode(CrosshairSettings.self, from: data).imageName == "Images/abc.svg")
    }

    @MainActor
    @Test func theStoreReturnsClampedValuesFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "crosshair-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = #"{"version": 1, "value": {"size": 100000, "shape": "x"}}"#
        try Data(file.utf8).write(to: directory.appending(path: "crosshair.json"))
        let loaded = SettingsStore(directory: directory).load(CrosshairSettings.self)
        #expect(loaded.shape == .x)
        #expect(loaded.size == CrosshairSettings.sizeRange.upperBound)
    }
}
