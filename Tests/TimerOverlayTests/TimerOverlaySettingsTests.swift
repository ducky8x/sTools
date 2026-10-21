import Foundation
import STPlatform
import Testing
@testable import TimerOverlay

@Suite("Timer Overlay settings")
struct TimerOverlaySettingsTests {
    @Test func defaultsAreTheOwnersSavedSetup() {
        let settings = TimerOverlaySettings.defaultValue
        #expect(TimerOverlaySettings.name == "timerOverlay")
        #expect(TimerOverlaySettings.version == 1)

        #expect(settings.durationSeconds == 150)
        #expect(settings.look == .plate)
        #expect(settings.digitSize == 40)
        #expect(settings.offsetX == 453 && settings.offsetY == -459)
        #expect(settings.fontFamily == "Source Serif 4")

        #expect(settings.plateColorHex == nil)
        #expect(settings.plateOpacityPercent == nil)
        #expect(settings.edgeColorHex == nil)
        #expect(settings.edgeWidth == nil)
        #expect(settings.cornerRadius == nil)
        #expect(settings.digitColorHex == nil)
        #expect(settings.timesUpPlateColorHex == nil)
        #expect(settings.timesUpDigitColorHex == nil)

        #expect(!settings.showsLabel)
        #expect(settings.labelText == "Fire res")
        #expect(settings.progress == .off)
        #expect(settings.nearZero == .off)
        #expect(settings.nearZeroGoldSeconds == 30)
        #expect(settings.nearZeroDangerSeconds == 10)
        #expect(settings.timeFormat == .minutesAndSeconds)
        #expect(!settings.showsTenths)

        #expect(settings.popUpMotion == .springPop)
        #expect(settings.atZero == .holdZero)
        #expect(settings.atZeroWord == "Time")
        #expect(settings.whileRinging == .pulsePerRing)
        #expect(settings.leave == .afterLastRing)
        #expect(settings.leaveAfterLastRingSeconds == 2)
        #expect(settings.leaveAfterZeroSeconds == 5)
        #expect(settings.whilePaused == .hideAfterDelay)

        #expect(settings.pressWhileCounting == .restart)
        #expect(settings.pressWhileRinging == .newCountdown)
        #expect(settings.cancelGesture == .doublePress)
        #expect(settings.beforeZero == .nothing)
        #expect(settings.chimeAtSeconds == 30)

        #expect(settings.soundID == "macOS:Ping")
        #expect(settings.volume == 0.8)
        #expect(settings.rings == 3)
        #expect(settings.showsInRecordings)
        #expect(!settings.alarmInRecordings)

        #expect(!settings.visibleOnlyWhileMinecraftFocused)
        #expect(!settings.pausesWhileMinecraftNotFocused)
        #expect(settings.displayChoice == .followMinecraft)
        #expect(settings.specificDisplayID == nil)
        #expect(settings.snappingEnabled)

        #expect(settings.showsRuleGuides)
        #expect(settings.guiScale == .fixed(3))
        #expect(settings.speedRunIGTCorner == .topRight)
        #expect(settings.ruleNote == .off)
        #expect(!settings.ruleNoticeDismissed)
        #expect(!settings.showsDockCountdown)
        #expect(!settings.placementModeEnabled)
    }

    @Test func thePresetsAreTheSevenChipsInOrder() {
        let presets = TimerOverlaySettings.defaultValue.presets
        #expect(presets.map(\.title) == ["30s", "1m", "2:30", "5m", "10m", "25m", "1h"])
        #expect(presets.map(\.seconds) == [30, 60, 150, 300, 600, 1500, 3600])
    }

    @Test func theRangesMatchTheSpec() {
        #expect(TimerOverlaySettings.durationRange == 1...359_999)
        #expect(TimerOverlaySettings.digitSizeRange == 28...140)
        #expect(TimerOverlaySettings.plateOpacityRange == 60...100)
        #expect(TimerOverlaySettings.ringsRange == 1...10)
        #expect(TimerOverlaySettings.volumeRange == 0...1)
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = TimerOverlaySettings.defaultValue
        settings.durationSeconds = 3 * 3600 + 25
        settings.presets = [.init(title: "Fire res", seconds: 180), .init(title: "Pearl", seconds: 20)]
        settings.look = .compactPill
        settings.digitSize = 72
        settings.offsetX = -120
        settings.offsetY = 300
        settings.fontFamily = "Bodoni Moda"
        settings.plateColorHex = "#112233"
        settings.plateOpacityPercent = 70
        settings.edgeColorHex = "#445566"
        settings.edgeWidth = 2.5
        settings.cornerRadius = 4
        settings.digitColorHex = "#778899"
        settings.timesUpPlateColorHex = "#AA0000"
        settings.timesUpDigitColorHex = "#00BB00"
        settings.showsLabel = true
        settings.labelText = "Pearl"
        settings.progress = .ring
        settings.nearZero = .goldThenDanger
        settings.nearZeroGoldSeconds = 45
        settings.nearZeroDangerSeconds = 15
        settings.timeFormat = .secondsOnly
        settings.showsTenths = true
        settings.popUpMotion = .slide
        settings.atZero = .overtime
        settings.atZeroWord = "Go"
        settings.whileRinging = .quickFlashes
        settings.leave = .afterZero
        settings.leaveAfterLastRingSeconds = 1.5
        settings.leaveAfterZeroSeconds = 9
        settings.whilePaused = .stayUp
        settings.pressWhileCounting = .pauseOrResume
        settings.pressWhileRinging = .silenceAndHide
        settings.cancelGesture = .hold
        settings.beforeZero = .ticks
        settings.chimeAtSeconds = 12
        settings.soundID = "file:alarm 2.wav"
        settings.volume = 0.35
        settings.rings = 7
        settings.showsInRecordings = false
        settings.alarmInRecordings = true
        settings.visibleOnlyWhileMinecraftFocused = true
        settings.pausesWhileMinecraftNotFocused = true
        settings.displayChoice = .specific
        settings.specificDisplayID = 42
        settings.snappingEnabled = false
        settings.showsRuleGuides = false
        settings.guiScale = .auto
        settings.speedRunIGTCorner = .bottomLeft
        settings.ruleNote = .lineAndNotice
        settings.ruleNoticeDismissed = true
        settings.showsDockCountdown = true
        settings.placementModeEnabled = true

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(TimerOverlaySettings.self, from: data) == settings)
    }

    @Test func unsetOverridesStayUnsetThroughJSON() throws {
        let data = try JSONEncoder().encode(TimerOverlaySettings.defaultValue)
        let decoded = try JSONDecoder().decode(TimerOverlaySettings.self, from: data)
        #expect(decoded == TimerOverlaySettings.defaultValue)
        #expect(decoded.plateColorHex == nil && decoded.edgeWidth == nil && decoded.specificDisplayID == nil)
    }

    @Test func missingKeysTakeDefaults() throws {
        let decoded = try JSONDecoder().decode(TimerOverlaySettings.self, from: Data(#"{"durationSeconds": 180}"#.utf8))
        var expected = TimerOverlaySettings.defaultValue
        expected.durationSeconds = 180
        #expect(decoded == expected)
    }

    @Test func anEmptyDocumentIsTheDefaults() throws {
        let decoded = try JSONDecoder().decode(TimerOverlaySettings.self, from: Data("{}".utf8))
        #expect(decoded == TimerOverlaySettings.defaultValue)
    }

    @Test func outOfRangeValuesAreClampedOnLoad() throws {
        let json = """
        {"durationSeconds": 0, "digitSize": 500, "offsetX": 999999, "offsetY": -999999,
         "plateOpacityPercent": 5, "edgeWidth": 40, "cornerRadius": -3,
         "nearZeroGoldSeconds": 0, "nearZeroDangerSeconds": 9999999,
         "leaveAfterLastRingSeconds": -1, "leaveAfterZeroSeconds": 1000, "chimeAtSeconds": -30,
         "volume": 3, "rings": 0, "guiScale": 99,
         "presets": [{"title": "Long", "seconds": 400000}, {"title": "None", "seconds": 0}]}
        """
        let decoded = try JSONDecoder().decode(TimerOverlaySettings.self, from: Data(json.utf8))
        #expect(decoded.durationSeconds == 1)
        #expect(decoded.digitSize == 140)
        #expect(decoded.offsetX == TimerOverlaySettings.offsetLimit)
        #expect(decoded.offsetY == -TimerOverlaySettings.offsetLimit)
        #expect(decoded.plateOpacityPercent == 60)
        #expect(decoded.edgeWidth == TimerOverlaySettings.edgeWidthRange.upperBound)
        #expect(decoded.cornerRadius == 0)
        #expect(decoded.nearZeroGoldSeconds == 1)
        #expect(decoded.nearZeroDangerSeconds == 359_999)
        #expect(decoded.leaveAfterLastRingSeconds == 0)
        #expect(decoded.leaveAfterZeroSeconds == TimerOverlaySettings.leaveAfterZeroRange.upperBound)
        #expect(decoded.chimeAtSeconds == 1)
        #expect(decoded.volume == 1)
        #expect(decoded.rings == 1)
        #expect(decoded.guiScale == .fixed(TimerOverlaySettings.guiScaleRange.upperBound))
        #expect(decoded.presets == [.init(title: "Long", seconds: 359_999), .init(title: "None", seconds: 1)])
    }

    @Test func unusableValuesFallBackToDefaults() throws {
        let json = """
        {"durationSeconds": "long", "look": "neon", "progress": 3, "timeFormat": "HH:MM",
         "popUpMotion": "explode", "atZero": null, "whileRinging": "siren", "leave": "never",
         "whilePaused": "dance", "pressWhileCounting": "explode", "pressWhileRinging": "",
         "cancelGesture": "triple", "beforeZero": "song", "nearZero": "red", "displayChoice": "all",
         "ruleNote": "loud", "speedRunIGTCorner": "middle", "guiScale": -2, "volume": "loud",
         "showsLabel": "yes", "presets": "many", "specificDisplayID": "main"}
        """
        let decoded = try JSONDecoder().decode(TimerOverlaySettings.self, from: Data(json.utf8))
        #expect(decoded == TimerOverlaySettings.defaultValue)
    }

    @Test func oneBadPresetDropsOnlyThatPreset() throws {
        let json = #"{"presets": [{"title": "A", "seconds": 10}, {"title": "B"}, 7, {"title": "C", "seconds": 20}]}"#
        let decoded = try JSONDecoder().decode(TimerOverlaySettings.self, from: Data(json.utf8))
        #expect(decoded.presets == [.init(title: "A", seconds: 10), .init(title: "C", seconds: 20)])
    }

    @Test func anEmptyPresetListStaysEmpty() throws {
        let decoded = try JSONDecoder().decode(TimerOverlaySettings.self, from: Data(#"{"presets": []}"#.utf8))
        #expect(decoded.presets.isEmpty)
    }

    @Test func theGUIScaleIsStoredAsMinecraftsOwnNumber() throws {
        var settings = TimerOverlaySettings.defaultValue
        settings.guiScale = .auto
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        #expect(object?["guiScale"] as? Int == 0)

        settings.guiScale = .fixed(4)
        object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        #expect(object?["guiScale"] as? Int == 4)

        let auto = try JSONDecoder().decode(TimerOverlaySettings.self, from: Data(#"{"guiScale": 0}"#.utf8))
        #expect(auto.guiScale == .auto)
    }

    @Test func hexColorsAreNormalizedAndInvalidOnesFallBackToTheLook() throws {
        let json = ##"{"plateColorHex": "aabbcc", "digitColorHex": "#12", "timesUpPlateColorHex": "red", "edgeColorHex": "#0a0B0c"}"##
        let decoded = try JSONDecoder().decode(TimerOverlaySettings.self, from: Data(json.utf8))
        #expect(decoded.plateColorHex == "#AABBCC")
        #expect(decoded.edgeColorHex == "#0A0B0C")
        #expect(decoded.digitColorHex == nil)
        #expect(decoded.timesUpPlateColorHex == nil)
    }

    @Test func aBlankFontFamilyFallsBackToSourceSerif4() throws {
        let decoded = try JSONDecoder().decode(TimerOverlaySettings.self, from: Data(#"{"fontFamily": "  "}"#.utf8))
        #expect(decoded.fontFamily == TimerOverlaySettings.defaultFontFamily)
    }

    @Test(arguments: ["", "  ", "file:", "file:../alarm.wav", "file:Sounds/alarm.wav", "file:.", "file:.."])
    func unusableSoundIDsFallBackToPing(id: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["soundID": id])
        #expect(try JSONDecoder().decode(TimerOverlaySettings.self, from: data).soundID == "macOS:Ping")
    }

    @Test(arguments: ["macOS:Glass", "sTools:Ember", "file:my alarm.m4a"])
    func usableSoundIDsSurvive(id: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["soundID": id])
        #expect(try JSONDecoder().decode(TimerOverlaySettings.self, from: data).soundID == id)
    }

    @Test func nonFiniteNumbersFallBackToDefaults() {
        var settings = TimerOverlaySettings.defaultValue
        settings.volume = .nan
        settings.leaveAfterZeroSeconds = .infinity
        settings.edgeWidth = .nan
        settings.cornerRadius = -.infinity
        let clamped = settings.clamped()
        #expect(clamped.volume == 0.8)
        #expect(clamped.leaveAfterZeroSeconds == 5)
        #expect(clamped.edgeWidth == nil)
        #expect(clamped.cornerRadius == nil)
    }

    @MainActor
    @Test func theStoreReturnsClampedValuesFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "timer-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = #"{"version": 1, "value": {"rings": 50, "look": "digitsOnly"}}"#
        try Data(file.utf8).write(to: directory.appending(path: "timerOverlay.json"))
        let loaded = SettingsStore(directory: directory).load(TimerOverlaySettings.self)
        #expect(loaded.look == .digitsOnly)
        #expect(loaded.rings == 10)
    }

    @MainActor
    @Test func theStoreWritesAndReadsTheDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "timer-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = TimerOverlaySettings.defaultValue
        settings.durationSeconds = 300
        settings.guiScale = .auto
        settings.timesUpDigitColorHex = "#101010"
        let writer = SettingsStore(directory: directory)
        writer.save(settings)
        await writer.flush()
        #expect(SettingsStore(directory: directory).load(TimerOverlaySettings.self) == settings)
    }
}
