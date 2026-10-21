import AppKit
import CoreGraphics
import STDesign
import STPlatform
import Testing
@testable import sTools

private let hasDisplay: Bool = {
    var count: UInt32 = 0
    return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
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

    @Test(.enabled(if: hasDisplay))
    func showsLowOnTheDisplayLeavesRecordingsAloneAndFadesAway() async throws {
        let display = offScreenDisplay
        let hud = HotkeyHUD(theme: STTheme(), hold: .milliseconds(150), fadeInDuration: 0.01, fadeOutDuration: 0.05)
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

        #expect(await waitUntil { !hud.isShowing })
    }

    @Test(.enabled(if: hasDisplay))
    func aNewPressStartsItOver() async throws {
        let display = offScreenDisplay
        let hud = HotkeyHUD(theme: STTheme(), hold: .milliseconds(300), fadeInDuration: 0.01, fadeOutDuration: 0.05)
        hud.present("Crosshair on", sealed: true, on: display)
        defer { hud.panel.hide() }
        try await Task.sleep(for: .milliseconds(200))
        hud.present("Crosshair off", sealed: true, on: display)
        // Past the first press's hold and fade: the second press keeps it up.
        try await Task.sleep(for: .milliseconds(200))
        #expect(hud.isShowing)
        #expect(await waitUntil { !hud.isShowing })
    }
}
