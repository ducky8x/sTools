import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import NBBOverlay
@testable import STPlatform

// Where the NBB Overlay's plate sits (spec 5.1.5): the stored X and Y are points from the display's center, and the plate
// is kept inside the display it is on, as the Timer Overlay's is. On the owner's 1920-point display the default, 750
// points right of center, fits; on a narrower screen (a MacBook's 1147, 1440 or 1512 points) the same offset put the
// plate half or wholly off the screen, where nothing could be seen or dragged.

/// The displays of a test, which the test changes the way plugging a monitor in or out does.
@MainActor
private final class Screens {
    var displays: [DisplayInfo]
    init(_ displays: [DisplayInfo]) { self.displays = displays }
}

/// A display far outside every real one, so the plate ordered in never shows on screen.
private func display(width: CGFloat, height: CGFloat) -> DisplayInfo {
    let frame = CGRect(x: -20_000, y: -20_000, width: width, height: height)
    return DisplayInfo(
        id: 1, name: "Display", frame: frame, bounds: CGRect(x: frame.minX, y: 1_080 - frame.maxY, width: width, height: height),
        backingScale: 1, pixelSize: CGSize(width: width, height: height), isMain: true)
}

private struct Granted: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// A controller showing the Prologue's sample result, so there is a plate to place without a Ninjabrain Bot.
@MainActor
private struct Rig {
    let screens: Screens
    let services: ToolServices
    let controller: NBBOverlayController
    let directory: URL

    init(_ displays: [DisplayInfo]) {
        screens = Screens(displays)
        directory = FileManager.default.temporaryDirectory.appending(path: "sTools-nbb-placement-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screens = screens
        services = ToolServices(
            settings: SettingsStore(directory: directory), displays: DisplayDirectory(screenProvider: { screens.displays }),
            minecraft: MinecraftLocator(source: StaticMinecraftWindowSource()), permissions: PermissionCenter(prober: Granted()))
        controller = NBBOverlayController(
            services: services, connection: NBBConnection(source: FakeEventSource([])),
            copies: NBBCopiesMonitor(scanner: NoNBBCopiesScanner()))
        controller.sample = try? JSONDecoder().decode(
            NBBEvents.Stronghold.self,
            from: Data(#"{"resultType":"TRIANGULATION","predictions":[{"chunkX":12,"chunkZ":-34,"certainty":0.87,"overworldDistance":512.3}],"eyeThrows":[]}"#.utf8))
    }

    var panelFrame: CGRect { controller.panel.frame }

    /// Tells the app the displays changed, as macOS does: the directory reads them again, then the observers look.
    func displaysChanged() {
        services.displays.refresh()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func remove() {
        controller.setEnabled(false)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite("NBB overlay placement", .serialized)
struct NBBOverlayPlacementTests {
    @Test func onTheOwnersDisplayThePlateSitsWhereItsOffsetPutsIt() {
        let rig = Rig([display(width: 1920, height: 1080)])
        defer { rig.remove() }
        rig.controller.setEnabled(true)
        let frame = rig.screens.displays[0].frame
        #expect(rig.panelFrame == CGRect(x: frame.midX + 750 - 160, y: frame.midY - 100, width: 320, height: 200))
    }

    /// A MacBook's built-in screens in their usual modes, and the 1147-point scaled one: every one is narrower than the
    /// 1,820 points the default offset needs, so the plate sits flush with the right edge instead of past it.
    @Test(arguments: [CGFloat(1147), 1280, 1440, 1512, 1728])
    func aNarrowerDisplayKeepsThePlateOnIt(width: CGFloat) {
        let rig = Rig([display(width: width, height: ((width * 0.65) / 2).rounded() * 2)])
        defer { rig.remove() }
        rig.controller.setEnabled(true)
        let frame = rig.screens.displays[0].frame
        #expect(frame.contains(rig.panelFrame), "\(rig.panelFrame) is not on \(frame)")
        #expect(rig.panelFrame.maxX == frame.maxX, "still at the right, as far as the display allows")
        #expect(rig.panelFrame.midY == frame.midY, "and in the vertical center")
        #expect(rig.controller.settings.offsetX == 750, "the stored offset is not rewritten for that")
    }

    @Test func anOffsetFarPastTheEdgeIsKeptOnTheDisplayInBothDirections() {
        let rig = Rig([display(width: 1920, height: 1080)])
        defer { rig.remove() }
        rig.controller.settings.offsetX = -5_000
        rig.controller.settings.offsetY = 5_000
        rig.controller.setEnabled(true)
        let frame = rig.screens.displays[0].frame
        #expect(frame.contains(rig.panelFrame))
        #expect(rig.panelFrame.minX == frame.minX && rig.panelFrame.minY == frame.minY, "left, and at the bottom (y is down)")
        rig.controller.settings.offsetX = 5_000
        rig.controller.settings.offsetY = -5_000
        #expect(frame.contains(rig.panelFrame))
        #expect(rig.panelFrame.maxX == frame.maxX && rig.panelFrame.maxY == frame.maxY, "right, and at the top")
    }

    /// A plate wider than the display (the width goes up to 900 points) keeps its top-left corner on it.
    @Test func aPlateWiderThanTheDisplayKeepsItsTopLeftCorner() {
        let rig = Rig([display(width: 800, height: 600)])
        defer { rig.remove() }
        rig.controller.settings.width = 900
        rig.controller.settings.offsetX = 0
        rig.controller.setEnabled(true)
        let frame = rig.screens.displays[0].frame
        #expect(rig.panelFrame.minX == frame.minX && rig.panelFrame.maxY <= frame.maxY)
    }

    /// The same stored offset puts the plate in the same place again when the display it was squeezed on goes.
    @Test func aDisplayChangeMovesThePlateInAndBack() {
        let wide = display(width: 1920, height: 1080)
        let rig = Rig([wide])
        defer { rig.remove() }
        rig.controller.setEnabled(true)
        let before = rig.panelFrame

        rig.screens.displays = [display(width: 1147, height: 745)]
        rig.displaysChanged()
        #expect(rig.screens.displays[0].frame.contains(rig.panelFrame))

        rig.screens.displays = [wide]
        rig.displaysChanged()
        #expect(rig.panelFrame == before)
    }

    /// Dragged past the display's edge in placement mode, the plate comes to rest inside, and the offset it stores is the
    /// one that puts it there again.
    @Test func aDragPastTheEdgeComesToRestInsideAndIsStoredSo() {
        let rig = Rig([display(width: 1920, height: 1080)])
        defer { rig.remove() }
        rig.controller.settings.placementModeEnabled = true
        rig.controller.setEnabled(true)
        rig.controller.placementMoveChanged(CGSize(width: 4_000, height: -4_000))
        rig.controller.placementMoveEnded()
        let frame = rig.screens.displays[0].frame
        let resting = rig.panelFrame
        #expect(frame.contains(resting))
        let stored = (rig.controller.settings.offsetX, rig.controller.settings.offsetY)

        rig.controller.settings.placementModeEnabled = false
        #expect(rig.panelFrame == resting, "storing the offset doesn't move the plate again")
        #expect(rig.controller.settings.offsetX == stored.0 && rig.controller.settings.offsetY == stored.1)
        #expect(abs(stored.0) <= 960 && abs(stored.1) <= 540, "the stored offset is on the display too")
    }
}
