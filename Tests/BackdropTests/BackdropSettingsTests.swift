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
        #expect(BackdropSettings.version == 2)
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

    // MARK: - The Animated fill (spec 5.2.3), settings version 2

    @Test func theAnimatedFillRoundTripsThroughJSON() throws {
        var settings = BackdropSettings.defaultValue
        settings.fill.kind = .animated
        settings.fill.animationName = "Images/loop.mp4"
        settings.fill.imageContentMode = .fit
        settings.fill.imageBackgroundColor = "#112233"
        var other = BackdropSettings.Fill()
        other.kind = .animated
        other.animationName = "Images/loop.gif"
        other.imageContentMode = .center
        settings.displayFills = [.init(displayID: 2, fill: other)]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BackdropSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.fill(for: 2).animationName == "Images/loop.gif")
        #expect(decoded.fill(for: 9).animationName == "Images/loop.mp4", "a display without its own fill uses the main one")
    }

    @Test func animatedIsAFillKindAndAFillStartsWithoutAFile() throws {
        #expect(BackdropSettings.FillKind.allCases.contains(.animated))
        #expect(BackdropSettings.Fill().animationName == nil)
        let json = #"{"fill": {"kind": "animated"}}"#
        let decoded = try JSONDecoder().decode(BackdropSettings.self, from: Data(json.utf8))
        #expect(decoded.fill.kind == .animated, "no file chosen yet is still an Animated fill: it draws its background")
        #expect(decoded.fill.animationName == nil)
    }

    /// The image's fit and background are the animation's too: "same fit modes" (spec 5.2.3).
    @Test func theAnimatedFillUsesTheFitAndBackgroundOfTheImageFill() throws {
        let json = ##"{"fill": {"kind": "animated", "animationName": "Images/a.gif", "imageContentMode": "fit", "imageBackgroundColor": "#aabbcc"}}"##
        let fill = try JSONDecoder().decode(BackdropSettings.self, from: Data(json.utf8)).fill
        #expect(fill.imageContentMode == .fit)
        #expect(fill.imageBackgroundColor == "#AABBCC")
    }

    @Test(arguments: [
        "../secret.mp4", "Images/../../x.mov", "/etc/passwd", "Images/sub/dir.gif", "other/file.gif", "Images/", "",
    ])
    func animationNamesOutsideTheImagesFolderAreDropped(name: String) throws {
        let json = try JSONSerialization.data(withJSONObject: ["fill": ["kind": "animated", "animationName": name]])
        let decoded = try JSONDecoder().decode(BackdropSettings.self, from: json)
        #expect(decoded.fill.animationName == nil)
        #expect(decoded.fill.kind == .animated)
    }

    @Test func validAnimationNamesSurvive() throws {
        let json = try JSONSerialization.data(withJSONObject: ["displayFills": [["displayID": 4, "fill": ["animationName": "Images/abc.mov"]]]])
        #expect(try JSONDecoder().decode(BackdropSettings.self, from: json).fill(for: 4).animationName == "Images/abc.mov")
    }

    /// Version 2 only adds the Animated fill, so nothing in a version 1 file changes when it loads.
    @MainActor
    @Test func aVersion1FileLoadsUnchangedUnderVersion2() throws {
        try withFileOnDisk(#"{"version": 1, "value": {"opacityPercent": 60, "fill": {"kind": "image", "imageName": "Images/a.png", "imageContentMode": "stretch"}, "fillTransitionSeconds": 1.5}}"#) { loaded, _ in
            #expect(loaded.opacityPercent == 60)
            #expect(loaded.fill.kind == .image && loaded.fill.imageName == "Images/a.png" && loaded.fill.imageContentMode == .stretch)
            #expect(loaded.fill.animationName == nil)
            #expect(loaded.fillTransitionSeconds == 1.5)
        }
        let migrated = try BackdropSettings.migrate(from: 1, ["opacityPercent": 60])
        #expect(migrated["opacityPercent"] as? Int == 60 && migrated.count == 1)
    }

    @MainActor
    @Test func aVersion2FileKeepsItsAnimatedFill() throws {
        try withFileOnDisk(#"{"version": 2, "value": {"fill": {"kind": "animated", "animationName": "Images/a.mp4"}}}"#) { loaded, _ in
            #expect(loaded.fill.kind == .animated && loaded.fill.animationName == "Images/a.mp4")
        }
    }

    /// An older build, which reads up to version 1, must not read an Animated fill as a color and save that over it:
    /// the store moves a file from a newer version aside and starts from the defaults (the same happens to this build
    /// with a file from a build after it).
    @MainActor
    @Test func aFileFromANewerVersionIsMovedAside() throws {
        try withFileOnDisk(#"{"version": 3, "value": {"opacityPercent": 40}}"#) { loaded, directory in
            #expect(loaded == BackdropSettings.defaultValue)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(names == ["backdrop.newer-v3.json"])
        }
    }

    /// Loads `backdrop.json` with `file` as its contents from a temporary settings folder, hands the result and the
    /// folder to `body`, then removes the folder.
    @MainActor
    private func withFileOnDisk(_ file: String, _ body: (BackdropSettings, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "backdrop-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(file.utf8).write(to: directory.appending(path: "backdrop.json"))
        try body(SettingsStore(directory: directory).load(BackdropSettings.self), directory)
    }
}
