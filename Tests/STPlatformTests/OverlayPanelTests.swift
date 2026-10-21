import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import STPlatform

/// The on-screen window server entry for a window number, using metadata only (no capture, no permission).
private struct WindowRecord {
    let layer: Int
    let isOnScreen: Bool
}

private func onScreenWindowRecord(_ windowNumber: Int) -> WindowRecord? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    guard
        let entry = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowNumber }),
        let layer = entry[kCGWindowLayer as String] as? Int
    else { return nil }
    return WindowRecord(layer: layer, isOnScreen: (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false)
}

/// The window server learns about a window on a later run-loop turn, so metadata queries poll
/// while pumping the run loop.
@MainActor
private func waitForRecord(_ windowNumber: Int, present: Bool = true) -> WindowRecord? {
    let deadline = Date().addingTimeInterval(3)
    var record = onScreenWindowRecord(windowNumber)
    while (record != nil) != present, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        record = onScreenWindowRecord(windowNumber)
    }
    return record
}

@MainActor
private func prepareApplication() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
}

private func testFrame() -> CGRect {
    let origin = NSScreen.main?.frame.origin ?? .zero
    return CGRect(x: origin.x + 40, y: origin.y + 40, width: 120, height: 80)
}

@Suite("OverlayPanel configuration", .serialized)
@MainActor
struct OverlayPanelConfigurationTests {
    init() { prepareApplication() }

    @Test func isBorderlessAndNonActivating() {
        let panel = OverlayPanel()
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.styleMask.contains(.titled))
    }

    @Test func neverBecomesKeyOrMain() {
        let panel = OverlayPanel()
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test func isTransparentAndShadowless() {
        let panel = OverlayPanel()
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(!panel.hasShadow)
    }

    @Test func staysAboveTheMenuBarTheDockAndOrdinaryWindows() {
        let panel = OverlayPanel()
        let level = panel.level.rawValue
        #expect(level > Int(CGWindowLevelForKey(.mainMenuWindow)))
        #expect(level > Int(CGWindowLevelForKey(.dockWindow)))
        #expect(level > Int(CGWindowLevelForKey(.floatingWindow)))
        #expect(level > Int(CGWindowLevelForKey(.popUpMenuWindow)))
        #expect(level > Int(CGWindowLevelForKey(.normalWindow)))
    }

    @Test func collectionBehaviorCoversSpacesFullScreenAndCycling() {
        let behavior = OverlayPanel().collectionBehavior
        #expect(behavior.contains(.canJoinAllSpaces))
        #expect(behavior.contains(.fullScreenAuxiliary))
        #expect(behavior.contains(.stationary))
        #expect(behavior.contains(.ignoresCycle))
        #expect(!behavior.contains(.moveToActiveSpace))
        #expect(!behavior.contains(.fullScreenPrimary))
    }

    @Test func isClickThroughByDefaultAndTogglesMouseHandling() {
        let panel = OverlayPanel()
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.isMouseHandlingEnabled)
        panel.isMouseHandlingEnabled = true
        #expect(!panel.ignoresMouseEvents)
        #expect(panel.isMouseHandlingEnabled)
        panel.isMouseHandlingEnabled = false
        #expect(panel.ignoresMouseEvents)
    }

    @Test func remainsCapturableAndSurvivesDeactivation() {
        let panel = OverlayPanel()
        #expect(panel.sharingType == .readOnly)
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.isReleasedWhenClosed)
    }

    @Test func aPanelExcludedFromCaptureIsHiddenFromSharing() {
        #expect(!OverlayPanel().isExcludedFromCapture)
        let panel = OverlayPanel(role: .topmost, isExcludedFromCapture: true)
        #expect(panel.isExcludedFromCapture)
        #expect(panel.sharingType == NSWindow.SharingType.none)
        #expect(panel.ignoresMouseEvents)
    }

    @Test func hostsSwiftUIContentWithAClearBackground() throws {
        let panel = OverlayPanel()
        panel.setContent(Text("Hello"))
        let host = try #require(panel.contentView as? NSHostingView<Text>)
        #expect(host.sizingOptions.isEmpty)
        #expect(host.layer?.backgroundColor == nil || host.layer?.backgroundColor?.alpha == 0)
        #expect(!panel.isOpaque)
    }

    @Test func replacingContentSwapsTheHostedView() throws {
        let panel = OverlayPanel()
        panel.setContent(Text("One"))
        panel.setContent(Color.red)
        #expect(panel.contentView is NSHostingView<Color>)
    }
}

@Suite(
    "OverlayPanel window server",
    .serialized,
    .enabled(if: hasWindowServerDisplay)
)
@MainActor
struct OverlayPanelWindowServerTests {
    init() { prepareApplication() }

    @Test func showPlacesThePanelAboveTheMenuBarAndDockAndHideRemovesIt() throws {
        let panel = OverlayPanel()
        panel.setContent(Color.clear)
        panel.show(frame: testFrame())
        defer { panel.hide() }

        let record = try #require(waitForRecord(panel.windowNumber))
        #expect(record.isOnScreen)
        #expect(record.layer > Int(CGWindowLevelForKey(.mainMenuWindow)))
        #expect(record.layer > Int(CGWindowLevelForKey(.dockWindow)))
        #expect(record.layer == panel.level.rawValue)

        panel.hide()
        #expect(waitForRecord(panel.windowNumber, present: false) == nil)
    }

    @Test func showDoesNotActivateTheApplicationOrBecomeKey() {
        let panel = OverlayPanel()
        panel.show(frame: testFrame())
        defer { panel.hide() }
        #expect(!panel.isKeyWindow)
        #expect(!panel.isMainWindow)
        #expect(panel.isVisible)
    }

    @Test func showAppliesTheRequestedFrame() {
        let panel = OverlayPanel()
        let frame = testFrame()
        panel.show(frame: frame)
        defer { panel.hide() }
        #expect(panel.frame == frame)
    }

    @Test func aFrameCoveringTheMenuBarIsNotConstrained() throws {
        let screen = try #require(NSScreen.main)
        let panel = OverlayPanel()
        panel.show(frame: screen.frame)
        defer { panel.hide() }
        #expect(panel.frame == screen.frame)
    }

    @Test func showingAgainMovesAndKeepsItVisible() throws {
        let panel = OverlayPanel()
        panel.show(frame: testFrame())
        let moved = testFrame().offsetBy(dx: 30, dy: 10)
        panel.show(frame: moved)
        defer { panel.hide() }
        #expect(panel.frame == moved)
        #expect(try #require(waitForRecord(panel.windowNumber)).isOnScreen)
    }

    /// What Screen Recording reads for its base layer (rule R5) and its display sources. Both panels sit
    /// far outside every display, so nothing shows on a real screen.
    @Test func recordingListsLeaveOutPanelsExcludedFromCapture() {
        let overlay = OverlayPanel()
        let hidden = OverlayPanel(isExcludedFromCapture: true)
        let offScreen = CGRect(x: -8000, y: -8000, width: 120, height: 80)
        overlay.show(frame: offScreen)
        hidden.show(frame: offScreen.offsetBy(dx: 140, dy: 0))
        defer {
            overlay.hide()
            hidden.hide()
        }

        let visible = OverlayPanel.visibleWindowNumbers()
        #expect(visible.contains(UInt32(overlay.windowNumber)))
        #expect(!visible.contains(UInt32(hidden.windowNumber)))

        let excluded = OverlayPanel.captureExcludedWindowNumbers()
        #expect(excluded.contains(UInt32(hidden.windowNumber)))
        #expect(!excluded.contains(UInt32(overlay.windowNumber)))

        hidden.hide()
        #expect(OverlayPanel.captureExcludedWindowNumbers().contains(UInt32(hidden.windowNumber)))
    }

    @Test func hidingTwiceIsHarmless() {
        let panel = OverlayPanel()
        panel.hide()
        panel.show(frame: testFrame())
        panel.hide()
        panel.hide()
        #expect(!panel.isVisible)
    }
}
