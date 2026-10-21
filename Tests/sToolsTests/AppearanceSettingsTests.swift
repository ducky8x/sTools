import Foundation
import STDesign
import STPlatform
import Testing
@testable import sTools

@MainActor
@Suite("AppearanceSettings")
struct AppearanceSettingsTests {
    @Test func defaultsMatchTheSpec() {
        let settings = AppearanceSettings.defaultValue
        #expect(settings.soundsEnabled)
        #expect(settings.soundVolume == 0.7)
        #expect(settings.motionMode == .full)
        #expect(settings.textScale == 1.0)
        #expect(settings.accentHex == STPalette.gold)
        #expect(AppearanceSettings.name == "appearance")
        #expect(AppearanceSettings.version == 1)
    }

    @Test func applyingPushesEveryValueIntoTheTheme() {
        var settings = AppearanceSettings()
        settings.soundsEnabled = false
        settings.soundVolume = 0.25
        settings.motionMode = .reduced
        settings.textScale = 1.2
        settings.accentHex = "#7DBF86"
        let theme = STTheme()
        settings.apply(to: theme)
        #expect(!theme.soundsEnabled)
        #expect(theme.soundVolume == 0.25)
        #expect(theme.motionMode == .reduced)
        #expect(theme.textScale == 1.2)
        #expect(theme.accentHex == "#7DBF86")
        #expect(AppearanceSettings(theme: theme) == settings)
    }

    @Test func readingBackFromTheThemeReportsClampedValues() {
        var settings = AppearanceSettings()
        settings.textScale = 3
        settings.soundVolume = 4
        settings.accentHex = "not a color"
        let theme = STTheme()
        settings.apply(to: theme)
        let stored = AppearanceSettings(theme: theme)
        #expect(stored.textScale == 1.3)
        #expect(stored.soundVolume == 1)
        #expect(stored.accentHex == STPalette.gold)
    }

    @Test func roundTripsThroughTheSettingsStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sTools-appearance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory, debounce: .milliseconds(10))
        var settings = AppearanceSettings()
        settings.soundsEnabled = false
        settings.soundVolume = 0.35
        settings.motionMode = .reduced
        settings.textScale = 1.1
        settings.accentHex = "#7DBF86"
        store.save(settings)
        await store.flush()
        let reopened = SettingsStore(directory: directory)
        #expect(reopened.load(AppearanceSettings.self) == settings)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"soundVolume": 0.4}"#.utf8))
        #expect(decoded.soundVolume == 0.4)
        #expect(decoded.soundsEnabled)
        #expect(decoded.accentHex == STPalette.gold)
        #expect(!decoded.reducesAnimations)
    }

    @Test(arguments: [#""motionMode": "sideways""#, #""motionMode": 1"#, #""motionMode": null"#, #""motionMode": true"#])
    func aBadKeyFallsBackAloneAndKeepsTheRest(badKey: String) throws {
        let json = ##"{"soundVolume": 0.4, "soundsEnabled": false, "accentHex": "#7DBF86", "textScale": 1.2, "##
            + badKey + "}"
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data(json.utf8))
        #expect(decoded.motionMode == .full)
        #expect(decoded.soundVolume == 0.4)
        #expect(!decoded.soundsEnabled)
        #expect(decoded.accentHex == "#7DBF86")
        #expect(decoded.textScale == 1.2)
    }

    @Test func everyKeyOfTheWrongTypeFallsBackToItsDefault() throws {
        let json = #"{"soundVolume": "loud", "soundsEnabled": "yes", "accentHex": 7, "textScale": [], "motionMode": {}}"#
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: Data(json.utf8)) == AppearanceSettings.defaultValue)
    }

    @Test func aFileThatChoseReducedMotionKeepsReduceAnimationsOn() throws {
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"motionMode": "reduced"}"#.utf8))
        #expect(decoded.reducesAnimations)
    }

    @Test func aBadFileOnDiskStillLoadsWhatItCan() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sTools-appearance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = #"{"version": 1, "value": {"motionMode": "reduced", "soundVolume": "loud", "textScale": 1.1}}"#
        try Data(file.utf8).write(to: directory.appending(path: "appearance.json"))
        let loaded = SettingsStore(directory: directory).load(AppearanceSettings.self)
        #expect(loaded.reducesAnimations)
        #expect(loaded.soundVolume == AppearanceSettings.defaultValue.soundVolume)
        #expect(loaded.textScale == 1.1)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "appearance.json").path),
                "not moved aside as corrupt")
    }

    @Test func theSwitchIsTheMotionMode() {
        var settings = AppearanceSettings()
        #expect(!settings.reducesAnimations)
        settings.reducesAnimations = true
        #expect(settings.motionMode == .reduced)
        settings.reducesAnimations = false
        #expect(settings.motionMode == .full)
        settings.motionMode = .reduced
        #expect(settings.reducesAnimations)
    }

    @Test func percentTextAndParseAgree() {
        for percent in stride(from: 0.0, through: 100.0, by: 5.0) {
            #expect(PercentFormat.parse(PercentFormat.text(percent)) == percent)
        }
        #expect(PercentFormat.text(70) == "70%")
        #expect(PercentFormat.parse(" 85 % ") == 85)
        #expect(PercentFormat.parse("85") == 85)
        #expect(PercentFormat.parse("loud") == nil)
    }
}
