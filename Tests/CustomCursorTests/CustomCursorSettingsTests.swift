import Foundation
import STPlatform
import Testing
@testable import CustomCursor

@Suite("Custom Cursor settings")
struct CustomCursorSettingsTests {
    @Test func defaultsMatchTheSpec() {
        let settings = CustomCursorSettings.defaultValue
        #expect(CustomCursorSettings.name == "cursor")
        #expect(CustomCursorSettings.version == 1)
        #expect(settings.shape == .dot)
        #expect(settings.fillHex == "#FFFFFF")
        #expect(settings.outlineEnabled)
        #expect(settings.outlineHex == "#000000")
        #expect(settings.outlineWidth == 2)
        #expect(settings.size == 12)
        #expect(settings.thickness == 3)
        #expect(settings.imageName == nil)
        #expect(settings.imageScalePercent == 100)
        #expect(settings.clickPoint == .center)
        #expect(settings.where == .whileMinecraftInFront)
        #expect(CustomCursorSettings.sizeRange == 4...64)
        #expect(CustomCursorSettings.imageScaleRange == 10...400)
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = CustomCursorSettings.defaultValue
        settings.shape = .image
        settings.fillHex = "#E4BC62"
        settings.outlineEnabled = false
        settings.size = 30
        settings.thickness = 5
        settings.imageName = "Images/0F0E0D0C-0000-0000-0000-000000000001.png"
        settings.imageScalePercent = 250
        settings.clickPoint = .bottomRight
        settings.where = .everywhere
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(CustomCursorSettings.self, from: data) == settings)
    }

    /// A value out of range is brought into it, and one that can't be read is the default, field by field.
    @Test func decodingClampsAndFallsBack() throws {
        let json = """
            {"shape": "star", "fillHex": "not a color", "outlineEnabled": "yes", "outlineHex": "#00ff00", "outlineWidth": 40,
             "size": 900, "thickness": 0, "imageName": "../../etc/passwd", "imageScalePercent": 2,
             "clickPoint": "middle", "where": 3}
            """
        let settings = try JSONDecoder().decode(CustomCursorSettings.self, from: Data(json.utf8))
        #expect(settings.shape == .dot)
        #expect(settings.fillHex == "#FFFFFF")
        #expect(settings.outlineEnabled)
        #expect(settings.outlineHex == "#00FF00")
        #expect(settings.outlineWidth == CustomCursorSettings.outlineWidthRange.upperBound)
        #expect(settings.size == 64)
        #expect(settings.thickness == 1)
        #expect(settings.imageName == nil)
        #expect(settings.imageScalePercent == 10)
        #expect(settings.clickPoint == .center)
        #expect(settings.where == .whileMinecraftInFront)
    }

    @Test func anEmptyDocumentIsTheDefault() throws {
        let settings = try JSONDecoder().decode(CustomCursorSettings.self, from: Data("{}".utf8))
        #expect(settings == .defaultValue)
    }

    @Test func aTinySizeGrowsToTheSmallest() {
        var settings = CustomCursorSettings()
        settings.size = 1
        settings.imageScalePercent = 9000
        let clamped = settings.clamped()
        #expect(clamped.size == 4)
        #expect(clamped.imageScalePercent == 400)
    }

    @MainActor
    @Test func savesAndLoadsThroughTheStore() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sTools-cursor-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory, debounce: .milliseconds(1))
        var settings = CustomCursorSettings()
        settings.size = 20
        settings.where = .everywhere
        store.save(settings)
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "cursor.json").path))
        #expect(SettingsStore(directory: directory).load(CustomCursorSettings.self) == settings)
    }

    /// Where's choices, in the page's words.
    @Test func whereReadsAsThePageSaysIt() {
        #expect(CustomCursorSettings.Where.allCases.map(\.title) == ["While Minecraft is in front", "Everywhere"])
    }
}
