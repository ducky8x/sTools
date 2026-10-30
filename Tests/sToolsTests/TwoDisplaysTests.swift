import AppKit
@testable import Crosshair
import Foundation
@testable import NBBOverlay
@testable import STPlatform
import Testing
@testable import TimerOverlay
@testable import sTools

// QA matrix (spec 9.2): "one and two displays" and "Retina, non-Retina, scaled resolution", with every overlay real, on
// displays that exist only in the test and sit far outside the real screens (EverythingSupport.swift).

/// The displays a Mac can have, as the matrix names them: a plain 1x display, a Retina one that looks like it (a 4K monitor
/// at 2x), and the MacBook's built-in screen at a scaled resolution (1147 x 745 points on a 3024 x 1964 panel).
enum QADisplayKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case nonRetina, retina, scaled

    var testDescription: String { rawValue }

    func display(id: UInt32, origin: CGPoint) -> DisplayInfo {
        switch self {
        case .nonRetina:
            QADisplays.display(id: id, origin: origin)
        case .retina:
            QADisplays.display(id: id, origin: origin, scale: 2, nativePixelSize: CGSize(width: 3840, height: 2160))
        case .scaled:
            QADisplays.display(id: id, origin: origin, size: CGSize(width: 1147, height: 745), scale: 2,
                               nativePixelSize: CGSize(width: 3024, height: 1964))
        }
    }
}

@MainActor
@Suite("Overlays on one and two displays", .serialized)
struct TwoDisplaysTests {
    private func switchEverythingOn(_ harness: EverythingHarness) {
        for tool in [ToolID.crosshair, .timerOverlay, .nbbOverlay, .windowBackdrop] { harness.model.userSwitched(tool, on: true) }
    }

    /// Waits until `display` holds exactly this many overlay windows of each kind.
    private func settle(_ harness: EverythingHarness, _ display: DisplayInfo, topmost: Int, backdrops: Int) async -> Bool {
        await waitUntil(timeout: .seconds(10)) {
            let panels = harness.panels(on: display)
            return panels.filter { $0.role == .topmost }.count == topmost && panels.filter { $0.role == .backdrop }.count == backdrops
        }
    }

    // MARK: One display, each kind

    /// All four overlays land inside whichever display they're on, whatever it is, and the Crosshair is on its exact middle.
    @Test(arguments: QADisplayKind.allCases)
    func everyOverlayFitsOnADisplayOfEachKind(kind: QADisplayKind) async throws {
        let display = kind.display(id: 1, origin: QADisplays.newOrigin())
        let harness = EverythingHarness(displays: [display])
        // The NBB Overlay's saved position is an offset from the display's center, 750 points right of it unless the
        // person changes it; a screen narrower than about 1,500 points needs it moved in, as its owner would do.
        harness.nbb.settings.offsetX = min(750, Int(display.frame.width / 2) - 200)
        switchEverythingOn(harness)
        #expect(await settle(harness, display, topmost: 3, backdrops: 1))
        let panels = harness.panels(on: display)
        // Every window is on the display; the Timer Overlay's is the plate plus the margin its motion needs, which may
        // reach past the display's edge when the plate is flush with it, so its plate is what has to be inside.
        for panel in panels where panel.role == .topmost && panel !== harness.presenter.panel {
            #expect(display.frame.contains(panel.frame))
        }
        #expect(display.frame.contains(try #require(harness.presenter.plateFrame)))
        #expect(panels.filter { $0.role == .backdrop }.allSatisfy { $0.frame == display.frame })

        // The Crosshair's window sits on whole pixels of this display, and holds its middle pixel.
        let crosshair = harness.crosshair.panel
        let scale = display.backingScale
        let left = (crosshair.frame.minX - display.frame.minX) * scale
        let top = (display.frame.maxY - crosshair.frame.maxY) * scale
        #expect(left == left.rounded() && top == top.rounded(), "on the pixel grid at \(scale)x")
        #expect(crosshair.frame.contains(CGPoint(x: display.frame.midX, y: display.frame.midY)))

        // The Timer Overlay's plate and the NBB Overlay keep clear of the middle where the crosshair is.
        let others = panels.filter { $0.role == .topmost && $0 !== crosshair }
        #expect(others.count == 2)
        #expect(others.allSatisfy { !$0.frame.contains(CGPoint(x: display.frame.midX, y: display.frame.midY)) || $0 === harness.nbb.panel })
        await harness.finish()
    }

    // MARK: Two displays

    @Test func everyOverlayFollowsMinecraftToTheOtherDisplayAndBack() async {
        let origin = QADisplays.newOrigin()
        let main = QADisplayKind.nonRetina.display(id: 1, origin: origin)
        let side = QADisplayKind.retina.display(id: 2, origin: origin)
        let harness = EverythingHarness(displays: [main, side], instances: [QADisplays.minecraft(on: side)])
        switchEverythingOn(harness)
        #expect(await settle(harness, side, topmost: 3, backdrops: 1))
        #expect(harness.panels(on: main).isEmpty, "nothing on the display Minecraft isn't on")

        harness.source.instances = [QADisplays.minecraft(on: main)]
        harness.model.minecraft.refresh()
        #expect(await settle(harness, main, topmost: 3, backdrops: 1))
        #expect(await settle(harness, side, topmost: 0, backdrops: 0))

        harness.source.instances = [QADisplays.minecraft(on: side)]
        harness.model.minecraft.refresh()
        #expect(await settle(harness, side, topmost: 3, backdrops: 1))
        #expect(await settle(harness, main, topmost: 0, backdrops: 0))
        await harness.finish()
    }

    /// The backdrop can cover the other display too, each with its own fill; the overlays stay with the game.
    @Test func theBackdropCoversTheOtherDisplayWhenAskedAndTheOverlaysStayWithTheGame() async {
        let origin = QADisplays.newOrigin()
        let main = QADisplayKind.nonRetina.display(id: 1, origin: origin)
        let side = QADisplayKind.retina.display(id: 2, origin: origin)
        let harness = EverythingHarness(displays: [main, side], instances: [QADisplays.minecraft(on: main)])
        switchEverythingOn(harness)
        #expect(await settle(harness, main, topmost: 3, backdrops: 1))
        #expect(harness.panels(on: side).isEmpty)

        harness.backdrop.setCovered(true, displayID: 2)
        #expect(await settle(harness, side, topmost: 0, backdrops: 1))
        #expect(await settle(harness, main, topmost: 3, backdrops: 1))

        harness.backdrop.setCovered(false, displayID: 2)
        #expect(await settle(harness, side, topmost: 0, backdrops: 0))
        await harness.finish()
    }

    /// A monitor taken out from under the game: the overlays go to the main display at once, and stay with Minecraft once
    /// its window has moved there. Plugged in again, and the game moved back, they follow it.
    @Test func aMonitorUnpluggedMidRunSendsTheOverlaysToTheMainDisplay() async {
        let origin = QADisplays.newOrigin()
        let main = QADisplayKind.nonRetina.display(id: 1, origin: origin)
        let side = QADisplayKind.retina.display(id: 2, origin: origin)
        let harness = EverythingHarness(displays: [main, side], instances: [QADisplays.minecraft(on: side)])
        switchEverythingOn(harness)
        #expect(await settle(harness, side, topmost: 3, backdrops: 1))

        harness.displayBox.displays = [main]
        harness.displaysChanged()
        // Before Accessibility reports the window moved, the overlays that follow the game fall back to the main display;
        // the backdrop covers only Minecraft's display, which is gone, so it waits for the window.
        #expect(await settle(harness, main, topmost: 3, backdrops: 0))

        harness.source.instances = [QADisplays.minecraft(on: main)]
        harness.model.minecraft.refresh()
        #expect(await settle(harness, main, topmost: 3, backdrops: 1))

        harness.displayBox.displays = [main, side]
        harness.displaysChanged()
        harness.source.instances = [QADisplays.minecraft(on: side)]
        harness.model.minecraft.refresh()
        #expect(await settle(harness, side, topmost: 3, backdrops: 1))
        #expect(await settle(harness, main, topmost: 0, backdrops: 0))
        await harness.finish()
    }

    /// Two games on two displays (the conflict rule): the overlays follow the one sTools follows, and the other goes on
    /// without them until it becomes the one followed.
    @Test func twoGamesOnTwoDisplaysAreFollowedByTheRule() async {
        let origin = QADisplays.newOrigin()
        let main = QADisplayKind.nonRetina.display(id: 1, origin: origin)
        let side = QADisplayKind.retina.display(id: 2, origin: origin)
        let first = QADisplays.minecraft(on: main, pid: 100, launched: 10)
        let second = QADisplays.minecraft(on: side, pid: 200, launched: 20)
        let harness = EverythingHarness(displays: [main, side], instances: [first, second])
        switchEverythingOn(harness)
        #expect(harness.model.minecraft.active?.id == 100 && harness.model.minecraft.conflict != .none)
        #expect(await settle(harness, main, topmost: 3, backdrops: 1))
        #expect(harness.panels(on: side).isEmpty)

        // The first game closes: the second becomes the one followed, on the other display.
        harness.source.instances = [second]
        harness.model.minecraft.refresh()
        #expect(await settle(harness, side, topmost: 3, backdrops: 1))
        #expect(await settle(harness, main, topmost: 0, backdrops: 0))
        await harness.finish()
    }

    /// A game on another version loses to one on 1.16.1 whichever opened first, so the overlays go to the 1.16.1 game's display.
    @Test func the116GameWinsTheOverlaysEvenWhenItOpenedLater() async {
        let origin = QADisplays.newOrigin()
        let main = QADisplayKind.nonRetina.display(id: 1, origin: origin)
        let side = QADisplayKind.retina.display(id: 2, origin: origin)
        let other = QADisplays.minecraft(on: main, pid: 100, title: "Minecraft* 1.20.4", launched: 10)
        let speedrun = QADisplays.minecraft(on: side, pid: 200, title: "Minecraft* 1.16.1", launched: 20)
        let harness = EverythingHarness(displays: [main, side], instances: [other, speedrun])
        switchEverythingOn(harness)
        #expect(harness.model.minecraft.active?.id == 200)
        #expect(await settle(harness, side, topmost: 3, backdrops: 1))
        #expect(harness.panels(on: main).isEmpty)
        await harness.finish()
    }

    /// A key's confirmation goes to the game's display, whichever display that is.
    @Test func theConfirmationAppearsOnMinecraftsDisplay() async {
        let origin = QADisplays.newOrigin()
        let main = QADisplayKind.nonRetina.display(id: 1, origin: origin)
        let side = QADisplayKind.retina.display(id: 2, origin: origin)
        let harness = EverythingHarness(displays: [main, side], instances: [QADisplays.minecraft(on: side)])
        harness.model.hotkeys.isEnabled = true
        let id = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 96, modifiers: []), actions: [.toggle(.crosshair)])
        harness.registrar.onPress?(id)
        #expect(harness.hud.presented.last?.displayID == 2)

        harness.source.instances = [QADisplays.minecraft(on: main)]
        harness.model.minecraft.refresh()
        harness.registrar.onPress?(id)
        #expect(harness.hud.presented.last?.displayID == 1)
        await harness.finish()
    }
}
