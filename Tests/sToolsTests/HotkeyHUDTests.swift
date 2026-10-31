import AppKit
import CoreGraphics
import STDesign
import STPlatform
import Testing
@testable import sTools

/// Counts sleeping displays, which the active list leaves out: the window server still takes windows while they sleep.
private let hasDisplay: Bool = {
    var count: UInt32 = 0
    return CGGetOnlineDisplayList(0, nil, &count) == .success && count > 0
}()

/// A display far outside every real one, so ordering the panel in never shows anything on screen.
private let offScreenDisplay = DisplayInfo(
    id: 999, name: "Off screen", frame: CGRect(x: -8000, y: -8000, width: 1512, height: 982),
    bounds: CGRect(x: -8000, y: 8000, width: 1512, height: 982), backingScale: 2,
    pixelSize: CGSize(width: 3024, height: 1964), isMain: false)

@Suite("Hotkey confirmation panel", .serialized)
@MainActor
struct HotkeyHUDTests {
    init() { _ = NSApplication.shared }

    @Test func isClickThroughTopmostAndNeverKey() {
        let hud = HotkeyHUD(theme: STTheme())
        #expect(hud.panel.role == .topmost)
        #expect(hud.panel.ignoresMouseEvents)
        #expect(!hud.panel.canBecomeKey)
        #expect(!hud.panel.canBecomeMain)
        #expect(hud.panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test func staysOutOfRecordings() {
        let hud = HotkeyHUD(theme: STTheme())
        #expect(hud.panel.isExcludedFromCapture)
        #expect(hud.panel.sharingType == NSWindow.SharingType.none)
    }

    // Both tests below move the HUD's clock by hand, so neither depends on how long a real wait takes.

    @Test(.enabled(if: hasDisplay))
    func showsLowOnTheDisplayLeavesRecordingsAloneAndFadesAway() async {
        let display = offScreenDisplay
        let clock = ManualClock()
        let hud = HotkeyHUD(theme: STTheme(), hold: .milliseconds(150), fadeInDuration: 0.01, fadeOutDuration: 0.05,
                            clock: clock)
        hud.present("Crosshair on \u{00B7} NBB Overlay on", sealed: true, on: display)
        defer { hud.panel.hide() }

        #expect(hud.isShowing)
        #expect(!hud.panel.isKeyWindow)
        #expect(!OverlayPanel.visibleWindowNumbers().contains(UInt32(hud.panel.windowNumber)))
        #expect(OverlayPanel.captureExcludedWindowNumbers().contains(UInt32(hud.panel.windowNumber)))
        let frame = hud.panel.frame
        #expect(frame.width > 100 && frame.height > 20)
        #expect(display.frame.contains(frame))
        #expect(frame.maxY < display.frame.midY)
        #expect(abs(frame.midX - display.frame.midX) <= 1)

        #expect(await clock.waitForWakes(.milliseconds(150)), "the hold waits on the clock")
        clock.advance(by: .milliseconds(150))
        #expect(await clock.waitForWakes(.milliseconds(200)), "the fade-out wait is on the clock too")
        #expect(hud.isShowing, "fading out, not gone")
        clock.advance(by: .milliseconds(50))
        #expect(await waitUntil(timeout: .seconds(60)) { !hud.isShowing })
    }

    @Test(.enabled(if: hasDisplay))
    func aNewPressStartsItOver() async {
        let display = offScreenDisplay
        let clock = ManualClock()
        let hud = HotkeyHUD(theme: STTheme(), hold: .milliseconds(300), fadeInDuration: 0.01, fadeOutDuration: 0.05,
                            clock: clock)
        hud.present("Crosshair on", sealed: true, on: display)
        defer { hud.panel.hide() }
        #expect(await clock.waitForWakes(.milliseconds(300)), "the hold waits on the clock")
        clock.advance(by: .milliseconds(200))
        hud.present("Crosshair off", sealed: true, on: display)
        #expect(await clock.waitForWakes(.milliseconds(500)), "the first hold is gone; the second counts from its own press")

        // Past the first press's hold and fade: the second press keeps it up.
        clock.advance(by: .milliseconds(200))
        #expect(hud.isShowing)
        clock.advance(by: .milliseconds(100))
        #expect(await clock.waitForWakes(.milliseconds(550)), "the second hold ends and its fade-out wait begins")
        clock.advance(by: .milliseconds(50))
        #expect(await waitUntil(timeout: .seconds(60)) { !hud.isShowing })
    }
}
