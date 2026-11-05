import CoreGraphics
import Foundation
import Testing
@testable import Crosshair
@testable import STPlatform

/// Minecraft's menus: Hide in Minecraft's menus and Be the pointer in Minecraft's menus, with a fake pointer watch and a
/// fake swapper. No test reads or changes the real pointer, and no panel is ordered onto a screen.
@MainActor
@Suite("Crosshair: Minecraft's menus", .serialized)
struct CrosshairMenuTests {
    // MARK: Hide in Minecraft's menus

    /// In the game the pointer is hidden and the overlay shows; in a menu the pointer shows and the overlay hides. The
    /// pointer stays macOS's arrow.
    @Test func hidingAloneHidesTheOverlayInMenusAndNeverTouchesThePointer() {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.hidesInMinecraftMenus = true
        rig.controller.setEnabled(true)
        #expect(rig.watch.isWatching)
        #expect(rig.controller.isOverlayShown, "in the game")

        rig.watch.pointerShows = true
        #expect(!rig.controller.isOverlayShown, "in a menu")
        rig.watch.pointerShows = false
        #expect(rig.controller.isOverlayShown, "back in the game")
        #expect(rig.swapper.calls.isEmpty, "the arrow is never swapped")
        #expect(!rig.controller.isThePointer)
    }

    /// Switched on over a menu, the overlay never shows: the first reading comes before it would.
    @Test func switchingOnOverAMenuKeepsTheOverlayHidden() {
        let rig = MenuRig(watch: FakePointerWatch(pointerShows: true))
        defer { rig.stop() }
        rig.controller.settings.hidesInMinecraftMenus = true
        rig.controller.setEnabled(true)
        #expect(!rig.controller.isOverlayShown)
        #expect(rig.controller.drawCount == 1, "drawn, ready for the game")
    }

    @Test func withBothOffNothingIsWatched() {
        let rig = MenuRig(watch: FakePointerWatch(pointerShows: true))
        defer { rig.stop() }
        rig.controller.setEnabled(true)
        #expect(!rig.watch.isWatching)
        #expect(rig.watch.startCount == 0)
        #expect(rig.controller.isOverlayShown, "a menu changes nothing")
        #expect(rig.swapper.calls.isEmpty)
    }

    // MARK: When the watch runs

    /// It watches only while a menu setting is on, the Crosshair is on and Minecraft is in front.
    @Test(arguments: [
        // hides, is the pointer, Minecraft in front, Crosshair on, watching
        (false, false, true, true, false),
        (true, false, true, true, true),
        (false, true, true, true, true),
        (true, true, true, true, true),
        (true, false, false, true, false),
        (false, true, false, true, false),
        (true, true, true, false, false),
    ])
    func itWatchesOnlyWhenEveryConditionHolds(hides: Bool, isPointer: Bool, inFront: Bool, on: Bool, watching: Bool) {
        let rig = MenuRig(minecraftInFront: inFront)
        defer { rig.stop() }
        rig.controller.settings.hidesInMinecraftMenus = hides
        rig.controller.settings.isPointerInMinecraftMenus = isPointer
        rig.controller.setEnabled(on)
        #expect(rig.watch.isWatching == watching)
        #expect(rig.controller.isThePointer == (watching && isPointer))
    }

    @Test func theWatchStopsWhenMinecraftLeavesTheFrontAndStartsWhenItComesBack() async {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.hidesInMinecraftMenus = true
        rig.controller.setEnabled(true)
        rig.watch.pointerShows = true
        #expect(!rig.controller.isOverlayShown)

        rig.setMinecraft(inFront: false)
        #expect(await waitUntil { !rig.watch.isWatching })
        #expect(rig.controller.isOverlayShown, "outside Minecraft the overlay shows as it always has")

        rig.setMinecraft(inFront: true)
        #expect(await waitUntil { rig.watch.isWatching })
        #expect(!rig.controller.isOverlayShown, "still in the menu")
        #expect(rig.watch.startCount == 2)
    }

    @Test func theWatchStopsWhenTheCrosshairOrTheSettingGoesOff() {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.hidesInMinecraftMenus = true
        rig.controller.setEnabled(true)
        rig.controller.setEnabled(false)
        #expect(!rig.watch.isWatching)

        rig.controller.setEnabled(true)
        #expect(rig.watch.isWatching)
        rig.watch.pointerShows = true
        rig.controller.settings.hidesInMinecraftMenus = false
        #expect(!rig.watch.isWatching)
        #expect(rig.controller.isOverlayShown)
    }

    /// Show only while Minecraft is focused keeps working beside them.
    @Test func showOnlyWhileMinecraftIsFocusedStillHolds() async {
        let rig = MenuRig(minecraftInFront: false)
        defer { rig.stop() }
        rig.controller.settings.visibleOnlyWhileMinecraftFocused = true
        rig.controller.settings.hidesInMinecraftMenus = true
        rig.controller.setEnabled(true)
        #expect(!rig.controller.isOverlayShown)
        #expect(!rig.watch.isWatching)

        rig.setMinecraft(inFront: true)
        #expect(await waitUntil { rig.controller.isOverlayShown })
        #expect(rig.watch.isWatching)
        rig.watch.pointerShows = true
        #expect(!rig.controller.isOverlayShown)
        rig.setMinecraft(inFront: false)
        #expect(await waitUntil { !rig.watch.isWatching })
        #expect(!rig.controller.isOverlayShown, "Minecraft isn't focused")
    }

    // MARK: Be the pointer in Minecraft's menus

    /// Being the pointer hides the overlay in a menu too, with the hide setting itself left off.
    @Test func beingThePointerHidesTheOverlayInMenus() {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.setEnabled(true)
        #expect(!rig.controller.settings.hidesInMinecraftMenus)
        #expect(rig.controller.isOverlayShown)
        #expect(rig.controller.isThePointer)
        #expect(rig.swapper.applyCount == 1)

        rig.watch.pointerShows = true
        #expect(!rig.controller.isOverlayShown)
        #expect(rig.swapper.applyCount == 1, "the arrow is already the crosshair: opening a menu swaps nothing")
        rig.watch.pointerShows = false
        #expect(rig.controller.isOverlayShown)
        #expect(rig.swapper.restoreCount == 0)
    }

    @Test func minecraftLeavingTheFrontPutsTheArrowBack() async {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.setEnabled(true)
        #expect(rig.swapper.showsTheCrosshair)

        rig.setMinecraft(inFront: false)
        #expect(await waitUntil { !rig.swapper.showsTheCrosshair })
        #expect(rig.swapper.restoreCount == 1)
        #expect(rig.controller.isOverlayShown)

        rig.setMinecraft(inFront: true)
        #expect(await waitUntil { rig.swapper.showsTheCrosshair })
        #expect(rig.swapper.applyCount == 2)

        rig.quitMinecraft()
        #expect(await waitUntil { !rig.swapper.showsTheCrosshair })
    }

    @Test func switchingTheCrosshairOffPutsTheArrowBack() {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.setEnabled(true)
        rig.controller.setEnabled(false)
        #expect(!rig.swapper.showsTheCrosshair)
        #expect(rig.swapper.restoreCount == 1)
        #expect(!rig.controller.isThePointer)
    }

    /// Turning the setting off puts the arrow back; with Hide in Minecraft's menus still on, the overlay goes on hiding
    /// in the menus.
    @Test func turningTheSettingOffPutsTheArrowBack() {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.hidesInMinecraftMenus = true
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.setEnabled(true)
        rig.watch.pointerShows = true
        rig.controller.settings.isPointerInMinecraftMenus = false
        #expect(!rig.swapper.showsTheCrosshair)
        #expect(rig.watch.isWatching)
        #expect(!rig.controller.isOverlayShown)

        rig.controller.settings.hidesInMinecraftMenus = false
        #expect(rig.controller.isOverlayShown)
        #expect(rig.swapper.restoreCount == 1)
    }

    /// Quitting and Reset sTools put the arrow back for good: nothing swaps it again in this run.
    @Test func restoringForGoodKeepsTheArrow() async {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.setEnabled(true)
        rig.controller.restorePointerForGood()
        #expect(!rig.swapper.showsTheCrosshair)
        #expect(!rig.watch.isWatching)

        rig.controller.settings.fillHex = "#E4BC62"
        rig.setMinecraft(inFront: false)
        rig.setMinecraft(inFront: true)
        let looks = rig.controller.placementCount
        #expect(await waitUntil { rig.controller.placementCount > looks })
        #expect(rig.swapper.applyCount == 1)
        rig.controller.restorePointerForGood()
        #expect(rig.swapper.restoreCount == 1)
    }

    /// A change to how the crosshair looks re-applies at once, without restoring first; one that only moves it or
    /// changes when it shows swaps nothing.
    @Test func aChangeToItsLookReappliesAtOnce() {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.setEnabled(true)
        rig.controller.settings.fillHex = "#E4BC62"
        #expect(rig.swapper.applyCount == 2)
        rig.controller.settings.size = 20
        #expect(rig.swapper.applyCount == 3)
        rig.controller.settings.offsetX = 4
        rig.controller.settings.hidesInMinecraftMenus = true
        #expect(rig.swapper.applyCount == 3)
        #expect(rig.swapper.restoreCount == 0)
    }

    /// The Image shape with no image draws nothing, so the arrow stays macOS's; once an image is chosen, it's the image.
    @Test func theImageShapeNeedsAnImage() throws {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.settings.shape = .image
        rig.controller.setEnabled(true)
        #expect(!rig.swapper.showsTheCrosshair)

        let picked = rig.services.settings.directory.appending(path: "picked.png")
        writeTestImage(to: picked)
        rig.controller.importImage(from: picked)
        #expect(rig.swapper.showsTheCrosshair)
        let cursor = try #require(rig.swapper.applied.last)
        #expect(cursor.size == CGSize(width: 9, height: 7))
        #expect(cursor.hotSpot == CGPoint(x: 4.5, y: 3.5), "its anchor, the middle")
        rig.controller.settings.imageAnchor = .topLeft
        #expect(rig.swapper.applied.last?.hotSpot == .zero)
    }

    /// The arrow the menus show is the overlay's own sprite, at its on-screen size on a 2x display, clicking at its center.
    @Test func thePointerIsTheOverlaysSprite() throws {
        let display = syntheticDisplay(frame: CGRect(x: -9000, y: -9000, width: 1920, height: 1080), scale: 2)
        let rig = MenuRig(display: display)
        defer { rig.stop() }
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.setEnabled(true)
        let cursor = try #require(rig.swapper.applied.last)
        let sprite = try #require(rig.controller.sprite)
        #expect(cursor.size == CGSize(width: CGFloat(sprite.size.width) / 2, height: CGFloat(sprite.size.height) / 2))
        #expect(cursor.images.map(\.width) == [1, 2, 4].map { sprite.size.width * $0 / 2 })
        #expect(rawPixels(cursor.images[1]) == rawPixels(sprite.image), "its 2× image is the overlay's sprite")
        // The default's 3 px line centers on its hot pixel's middle.
        #expect(cursor.hotSpot == CGPoint(x: (CGFloat(sprite.hot.x) + 0.5) / 2, y: (CGFloat(sprite.hot.y) + 0.5) / 2))
    }

    /// Moving to a display of another scale draws the pointer for it.
    @Test func anotherDisplaysScaleReapplies() async throws {
        let retina = syntheticDisplay(id: 1, frame: CGRect(x: -9000, y: -9000, width: 1920, height: 1080), scale: 2)
        let plain = syntheticDisplay(id: 2, frame: CGRect(x: -7000, y: -9000, width: 1920, height: 1080), scale: 1, isMain: false)
        let source = StaticMinecraftWindowSource(instances: [menuRigMinecraft(frontmost: true, display: retina)])
        let directory = tempDirectory()
        let services = makeServices(tempDirectory: directory, source: source, displays: [retina, plain])
        services.minecraft.start()
        defer { services.minecraft.stop() }
        let swapper = FakeCursorSwapper()
        let controller = CrosshairController(
            services: services, imagesDirectory: directory.appending(path: "Images"), showsPanel: false,
            pointer: PointerSwap(swapper: swapper, supportDirectory: directory), pointerWatch: FakePointerWatch())
        defer { controller.setEnabled(false) }
        controller.settings.isPointerInMinecraftMenus = true
        controller.setEnabled(true)
        let onRetina = try #require(swapper.applied.last)

        source.instances = [menuRigMinecraft(frontmost: true, display: plain)]
        services.minecraft.refresh()
        #expect(await waitUntil { swapper.applyCount == 2 })
        let onPlain = try #require(swapper.applied.last)
        #expect(onPlain.size.width == onRetina.size.width * 2, "the same pixels are twice the points at 1x")
    }

    // MARK: When it can't

    /// Without the pointer calls, being the pointer still hides the overlay in the menus, but the arrow stays macOS's.
    @Test func withoutTheSwapTheArrowStays() {
        let rig = MenuRig(swapper: FakeCursorSwapper(isSupported: false))
        defer { rig.stop() }
        #expect(rig.controller.canHideInMinecraftMenus)
        #expect(!rig.controller.canBeThePointer)
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.setEnabled(true)
        rig.watch.pointerShows = true
        #expect(!rig.controller.isOverlayShown)
        #expect(rig.swapper.calls.isEmpty)
    }

    /// Without a way to watch the pointer, neither setting does anything: the overlay shows as it always has.
    @Test func withoutTheWatchNothingChanges() {
        let rig = MenuRig(watch: FakePointerWatch(pointerShows: true, isSupported: false))
        defer { rig.stop() }
        #expect(!rig.controller.canHideInMinecraftMenus)
        #expect(!rig.controller.canBeThePointer)
        rig.controller.settings.hidesInMinecraftMenus = true
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.setEnabled(true)
        #expect(rig.controller.isOverlayShown)
        #expect(rig.swapper.calls.isEmpty)
    }

    /// A controller built without them, as before, never watches or swaps.
    @Test func aControllerWithoutThemIgnoresTheSettings() {
        let controller = makeController(makeServices(tempDirectory: tempDirectory(), instances: [menuRigMinecraft(frontmost: true)]))
        controller.settings.isPointerInMinecraftMenus = true
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        #expect(!controller.canHideInMinecraftMenus)
        #expect(controller.isOverlayShown)
        #expect(!controller.isThePointer)
    }

    /// The settings are saved, and Reset to default turns them off and puts the arrow back.
    @Test func theSettingsAreSavedAndReset() async {
        let rig = MenuRig()
        defer { rig.stop() }
        rig.controller.settings.hidesInMinecraftMenus = true
        rig.controller.settings.isPointerInMinecraftMenus = true
        rig.controller.setEnabled(true)
        await rig.services.settings.flush()
        let saved = SettingsStore(directory: rig.services.settings.directory).load(CrosshairSettings.self)
        #expect(saved.hidesInMinecraftMenus && saved.isPointerInMinecraftMenus)

        rig.controller.resetToDefault()
        #expect(!rig.controller.settings.hidesInMinecraftMenus)
        #expect(!rig.controller.settings.isPointerInMinecraftMenus)
        #expect(!rig.swapper.showsTheCrosshair)
        #expect(!rig.watch.isWatching)
    }
}
