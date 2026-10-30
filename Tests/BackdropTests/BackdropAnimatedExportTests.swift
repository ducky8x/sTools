import Foundation
import STPlatform
import Testing
@testable import Backdrop

/// An Animated fill through Settings ▸ Export and Import, with the real `SettingsBackup` on temporary folders: the file
/// the fill refers to travels with it, because it lives in `Images/` like an image.
@MainActor
@Suite("Animated fill in export and import", .serialized)
struct BackdropAnimatedExportTests {
    private func versions(backdrop: Int = BackdropSettings.version) -> [String: Int] { [BackdropSettings.name: backdrop] }

    @Test func theAnimationsTravelWithTheSettings() async throws {
        let source = AnimatedRig(displays: [displayOne, displayTwo])
        let gif = TestMedia.writeGIF(to: source.folder.file("loop.gif"), colors: [.green, .red], delays: [0.1, 0.1])
        let movie = try await TestMedia.writeMovie(to: source.folder.file("clip.mp4"), colors: [.blue, .red])
        await source.controller.importAnimation(from: gif)
        source.controller.setCovered(true, displayID: displayTwo.id)
        await source.controller.importAnimation(from: movie, forDisplayID: displayTwo.id)
        await source.services.settings.flush()

        let exported = source.folder.file("everything.stools-settings")
        let summary = try await SettingsBackup(directory: source.folder.url, store: source.services.settings).export(to: exported)
        #expect(summary.documentNames.contains(BackdropSettings.name))
        #expect(summary.imageCount == 2, "both files are carried, the GIF and the video")

        let target = TempFolder()
        let report = try await SettingsBackup(directory: target.url).importSettings(from: exported, knownVersions: versions())
        #expect(report.documents.contains(.init(name: BackdropSettings.name, outcome: .applied)))
        #expect(report.images.count == 2)
        #expect(report.images.allSatisfy { $0.outcome == .applied })

        let loaded = SettingsStore(directory: target.url).load(BackdropSettings.self)
        #expect(loaded == source.controller.settings)
        for fill in [loaded.fill, loaded.fill(for: displayTwo.id)] {
            let name = try #require(fill.animationName)
            let original = source.folder.url.appending(path: name)
            let restored = target.url.appending(path: name)
            #expect(try Data(contentsOf: restored) == Data(contentsOf: original), "\(name) comes back byte for byte")
        }
    }

    @Test func theImportedFillPlaysItsFileOnTheNewFolder() async throws {
        let source = AnimatedRig()
        await source.controller.importAnimation(from: TestMedia.writeGIF(to: source.folder.file("loop.gif"), colors: [.green, .red], delays: [0.1, 0.1]))
        await source.services.settings.flush()
        let exported = source.folder.file("everything.stools-settings")
        try await SettingsBackup(directory: source.folder.url, store: source.services.settings).export(to: exported)

        let target = TempFolder()
        _ = try await SettingsBackup(directory: target.url).importSettings(from: exported, knownVersions: versions())
        let restored = AnimatedRig(folder: target)
        #expect(restored.controller.settings.fill.kind == .animated)
        restored.controller.setEnabled(true)
        defer { restored.controller.setEnabled(false) }
        #expect(restored.log.urls.count == 1)
        let url = try #require(restored.log.urls.first)
        #expect(FileManager.default.fileExists(atPath: url.path), "the player is pointed at a file that is there")
        #expect(restored.player.isPlaying)
    }

    @Test func aBuildThatReadsOnlyVersion1SkipsTheNewDocument() async throws {
        let source = AnimatedRig()
        await source.controller.importAnimation(from: TestMedia.writeGIF(to: source.folder.file("loop.gif"), colors: [.green, .red], delays: [0.1, 0.1]))
        await source.services.settings.flush()
        let exported = source.folder.file("everything.stools-settings")
        try await SettingsBackup(directory: source.folder.url, store: source.services.settings).export(to: exported)

        let target = TempFolder()
        let report = try await SettingsBackup(directory: target.url).importSettings(from: exported, knownVersions: versions(backdrop: 1))
        let backdrop = try #require(report.documents.first { $0.name == BackdropSettings.name })
        #expect(backdrop.outcome == .skipped(.newerVersion(found: 2, supported: 1)))
        #expect(!FileManager.default.fileExists(atPath: target.url.appending(path: "backdrop.json").path))
    }

    @Test func anExportMadeBeforeTheAnimatedFillStillImports() async throws {
        let target = TempFolder()
        let old = target.file("old.stools-settings")
        let file = """
        {"format": 1, "app": "sTools", "createdAt": "2026-10-20T10:00:00Z",
         "documents": {"backdrop": {"version": 1, "value": {"opacityPercent": 70, "fill": {"kind": "image", "imageName": "Images/a.png"}}}},
         "images": {"a.png": "aGVsbG8="}}
        """
        try Data(file.utf8).write(to: old)
        let report = try await SettingsBackup(directory: target.url).importSettings(from: old, knownVersions: versions())
        #expect(report.documents.contains(.init(name: BackdropSettings.name, outcome: .applied)))
        let loaded = SettingsStore(directory: target.url).load(BackdropSettings.self)
        #expect(loaded.opacityPercent == 70)
        #expect(loaded.fill.kind == .image && loaded.fill.imageName == "Images/a.png")
        #expect(loaded.fill.animationName == nil)
    }

    @Test func aNameThatLeavesTheImagesFolderIsNotImported() async throws {
        let target = TempFolder()
        let bad = target.file("bad.stools-settings")
        let file = """
        {"format": 1, "app": "sTools", "documents": {}, "images": {"../outside.mp4": "aGVsbG8="}}
        """
        try Data(file.utf8).write(to: bad)
        let report = try await SettingsBackup(directory: target.url).importSettings(from: bad, knownVersions: versions())
        #expect(report.images.first?.outcome == .skipped(.invalidName))
    }
}
