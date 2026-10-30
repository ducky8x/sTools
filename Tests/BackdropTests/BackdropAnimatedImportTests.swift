import AVFoundation
import CoreGraphics
import Foundation
import STPlatform
import Testing
@testable import Backdrop

/// Choosing a GIF or a video for a fill: the real checks and the real copy, on files the tests generate, into a temporary
/// Images folder. The players are fakes.
@MainActor
@Suite("Choosing an animation", .serialized)
struct BackdropAnimatedImportTests {
    private func gif(in rig: AnimatedRig, named name: String = "loop.gif", colors: [RGB] = [.green, .red]) -> URL {
        TestMedia.writeGIF(to: rig.folder.file(name), colors: colors, delays: Array(repeating: 0.1, count: colors.count), width: 40, height: 20)
    }

    private func copy(_ name: String?, in rig: AnimatedRig) -> URL? {
        name.map { rig.imagesDirectory.appending(path: ($0 as NSString).lastPathComponent) }
    }

    private func exists(_ url: URL?) -> Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    // MARK: - Importing

    @Test func choosingAGIFMakesTheMainFillAnimatedWithItsCopy() async throws {
        let rig = AnimatedRig()
        await rig.controller.importAnimation(from: gif(in: rig))
        let fill = rig.controller.settings.fill
        #expect(fill.kind == .animated)
        let name = try #require(fill.animationName)
        #expect(name.hasPrefix("Images/") && name.hasSuffix(".gif"))
        #expect(exists(copy(name, in: rig)))
        #expect(rig.controller.animationImportError == nil)
    }

    @Test func choosingAVideoWorksAndKeepsItsFormat() async throws {
        let rig = AnimatedRig()
        let movie = try await TestMedia.writeMovie(to: rig.folder.file("clip.mov"), colors: [.red, .blue], fileType: .mov)
        await rig.controller.importAnimation(from: movie)
        let name = try #require(rig.controller.settings.fill.animationName)
        #expect(name.hasSuffix(".mov"))
        #expect(rig.controller.settings.fill.kind == .animated)
    }

    @Test func theFillChangesInOneStepSoItCrossfadesOnce() async {
        let rig = AnimatedRig()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let drawn = rig.controller.drawCount
        await rig.controller.importAnimation(from: gif(in: rig))
        #expect(rig.controller.drawCount == drawn + 1, "the kind and the file arrive together")
        #expect(rig.log.players.count == 1)
        #expect(rig.player.isPlaying)
    }

    @Test func aFileThatCantBePlayedLeavesTheFillAsItWasAndSaysWhy() async throws {
        let rig = AnimatedRig()
        let text = rig.folder.file("notes.mp4")
        try Data("hello".utf8).write(to: text)
        let before = rig.controller.settings
        await rig.controller.importAnimation(from: text)
        #expect(rig.controller.settings == before)
        #expect(rig.controller.animationImportError == BackdropAnimationFile.cantPlayMessage)
        #expect(!exists(rig.imagesDirectory), "nothing was copied, and no Images folder was made for it")
    }

    @Test func theNextGoodFileClearsTheError() async throws {
        let rig = AnimatedRig()
        let text = rig.folder.file("notes.mp4")
        try Data("hello".utf8).write(to: text)
        await rig.controller.importAnimation(from: text)
        #expect(rig.controller.animationImportError != nil)
        await rig.controller.importAnimation(from: gif(in: rig))
        #expect(rig.controller.animationImportError == nil)
    }

    @Test func choosingForAnotherDisplayMakesItsOwnFillAndLeavesTheMainOne() async throws {
        let rig = AnimatedRig(displays: [displayOne, displayTwo])
        rig.controller.setCovered(true, displayID: displayTwo.id)
        await rig.controller.importAnimation(from: gif(in: rig), forDisplayID: displayTwo.id)
        #expect(rig.controller.settings.fill(for: displayTwo.id).kind == .animated)
        #expect(rig.controller.settings.fill(for: displayTwo.id).animationName != nil)
        #expect(rig.controller.settings.fill.kind == .color, "the main fill is untouched")
        #expect(rig.controller.animationImportError(for: displayTwo.id) == nil)
    }

    @Test func aFileThatCantBePlayedForAnotherDisplayIsThatDisplaysError() async throws {
        let rig = AnimatedRig(displays: [displayOne, displayTwo])
        rig.controller.setCovered(true, displayID: displayTwo.id)
        let text = rig.folder.file("notes.gif")
        try Data("hello".utf8).write(to: text)
        await rig.controller.importAnimation(from: text, forDisplayID: displayTwo.id)
        #expect(rig.controller.animationImportError(for: displayTwo.id) == BackdropAnimationFile.cantPlayMessage)
        #expect(rig.controller.animationImportError == nil, "and not the main fill's")
    }

    @Test func aChosenAnimationIsSavedAndComesBack() async throws {
        let rig = AnimatedRig()
        await rig.controller.importAnimation(from: gif(in: rig))
        await rig.services.settings.flush()
        let reloaded = BackdropController(services: ToolServices(
            settings: SettingsStore(directory: rig.folder.url), displays: rig.services.displays,
            minecraft: rig.services.minecraft, permissions: rig.services.permissions))
        #expect(reloaded.settings.fill == rig.controller.settings.fill)
        #expect(reloaded.settings.fill.kind == .animated)
    }

    // MARK: - Copies that are no longer used

    @Test func replacingAnAnimationDeletesTheOldCopy() async throws {
        let rig = AnimatedRig()
        await rig.controller.importAnimation(from: gif(in: rig))
        let first = try #require(copy(rig.controller.settings.fill.animationName, in: rig))
        await rig.controller.importAnimation(from: gif(in: rig, named: "other.gif", colors: [.blue, .yellow]))
        let second = try #require(copy(rig.controller.settings.fill.animationName, in: rig))
        #expect(first != second)
        #expect(await waitUntil { !exists(first) }, "the replaced copy is deleted")
        #expect(exists(second))
    }

    @Test func aCopyAnotherFillStillUsesStays() async throws {
        let rig = AnimatedRig(displays: [displayOne, displayTwo])
        rig.controller.setCovered(true, displayID: displayTwo.id)
        await rig.controller.importAnimation(from: gif(in: rig))
        let shared = try #require(rig.controller.settings.fill.animationName)
        rig.controller.setDisplayFill(rig.controller.settings.fill, for: displayTwo.id)
        await rig.controller.importAnimation(from: gif(in: rig, named: "other.gif", colors: [.blue, .yellow]))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(exists(copy(shared, in: rig)), "the second display still plays it")
        rig.controller.setCovered(false, displayID: displayTwo.id)
        #expect(await waitUntil { !exists(copy(shared, in: rig)) }, "and nothing does once it's uncovered")
    }

    @Test func switchingTheFillToAnotherKindKeepsTheCopyForSwitchingBack() async throws {
        let rig = AnimatedRig()
        await rig.controller.importAnimation(from: gif(in: rig))
        let url = try #require(copy(rig.controller.settings.fill.animationName, in: rig))
        rig.controller.settings.fill.kind = .color
        try? await Task.sleep(for: .milliseconds(100))
        #expect(exists(url))
        rig.controller.settings.fill.kind = .animated
        #expect(rig.controller.settings.fill.animationName != nil)
    }

    @Test func resettingTheBackdropDeletesItsCopies() async throws {
        let rig = AnimatedRig()
        await rig.controller.importAnimation(from: gif(in: rig))
        let url = try #require(copy(rig.controller.settings.fill.animationName, in: rig))
        rig.controller.resetToDefault()
        #expect(await waitUntil { !exists(url) })
        #expect(rig.controller.settings == BackdropSettings.defaultValue)
    }

    @Test func aCopyIsDeletedByNameOnlyNeverAnotherFileInTheFolder() async throws {
        let rig = AnimatedRig()
        await rig.controller.importAnimation(from: gif(in: rig))
        let neighbor = rig.imagesDirectory.appending(path: "crosshair.png")
        try Data("not mine".utf8).write(to: neighbor)
        rig.controller.resetToDefault()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(exists(neighbor))
    }

    // MARK: - The first frame, for the page

    @Test func theFirstFrameOfAGIFComesInOffTheMainActorForThePage() async throws {
        let rig = AnimatedRig()
        await rig.controller.importAnimation(from: gif(in: rig, colors: [.green, .red]))
        let fill = rig.controller.settings.fill
        #expect(await waitUntil { rig.controller.image(for: fill) != nil })
        let poster = try #require(rig.controller.image(for: fill))
        #expect(TestMedia.color(of: poster) == .green)
        #expect(poster.width == 40 && poster.height == 20)
    }

    @Test func theFirstFrameOfAVideoComesInToo() async throws {
        let rig = AnimatedRig()
        let movie = try await TestMedia.writeMovie(to: rig.folder.file("clip.mp4"), colors: [.blue, .red])
        await rig.controller.importAnimation(from: movie)
        let fill = rig.controller.settings.fill
        #expect(await waitUntil { rig.controller.image(for: fill) != nil })
        let poster = try #require(rig.controller.image(for: fill))
        #expect(TestMedia.color(of: poster, x: 64, y: 48).isClose(to: .blue, tolerance: 48))
    }

    @Test func askingForTheFirstFrameAgainWhileItLoadsStartsNothingNew() async throws {
        let rig = AnimatedRig()
        await rig.controller.importAnimation(from: gif(in: rig))
        let fill = rig.controller.settings.fill
        for _ in 0..<5 { _ = rig.controller.image(for: fill) }
        #expect(await waitUntil { rig.controller.image(for: fill) != nil })
        #expect(rig.controller.loadedImageCount == 1)
    }

    @Test func aFillThatIsNotAnimatedLoadsNoFirstFrame() async {
        let rig = AnimatedRig()
        var fill = BackdropSettings.Fill()
        fill.animationName = "Images/left-over.gif"
        #expect(rig.controller.image(for: fill) == nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.controller.loadedImageCount == 0, "a color fill with an animation chosen before doesn't read it")
    }

    @Test func theAnimatedPanelDoesNotDecodeAFirstFrameItNeverShows() async throws {
        let rig = AnimatedRig()
        await rig.controller.importAnimation(from: gif(in: rig))
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.controller.loadedImageCount == 0, "the panel plays the file; only the page's preview needs the frame")
    }

    @Test func aFileThatCantBePlayedAnyMoreGetsAPlainLineOnThePage() async throws {
        let rig = AnimatedRig()
        await rig.controller.importAnimation(from: gif(in: rig))
        let fill = rig.controller.settings.fill
        try FileManager.default.removeItem(at: try #require(copy(fill.animationName, in: rig)))
        #expect(rig.controller.animationProblem(for: fill) == nil, "nothing is known until it's looked at")
        _ = rig.controller.image(for: fill)
        #expect(await waitUntil { rig.controller.animationProblem(for: fill) != nil })
        #expect(rig.controller.animationProblem(for: fill) == BackdropPlayerMessages.cantPlay)
        #expect(rig.controller.image(for: fill) == nil)
    }
}
