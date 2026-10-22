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

/// A frame far outside every display, so a panel ordered in at it never shows on a real screen: tests never put
/// windows on the visible screen. The window server still lists the panel, with its level, as on screen. Fails the
/// test before anything is ordered in if a display ever reaches that far.
@MainActor
private func offScreenFrame(dx: CGFloat = 0, dy: CGFloat = 0) throws -> CGRect {
    let frame = CGRect(x: -9000 + dx, y: -9000 + dy, width: 120, height: 80)
    try #require(!NSScreen.screens.contains { $0.frame.intersects(frame) }, "a display reaches \(frame)")
    return frame
}

/// The few tests that must order a window onto a real display run only when `STOOLS_TESTS_ON_SCREEN=1` is set.
private let onScreenTestsAllowed = ProcessInfo.processInfo.environment["STOOLS_TESTS_ON_SCREEN"] == "1"

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

    /// The window server reports a window's level wherever it sits, so the panel stays far off every display.
    @Test func showPlacesThePanelAboveTheMenuBarAndDockAndHideRemovesIt() throws {
        let panel = OverlayPanel()
        panel.setContent(Color.clear)
        panel.show(frame: try offScreenFrame())
        defer { panel.hide() }

        let record = try #require(waitForRecord(panel.windowNumber))
        #expect(record.isOnScreen)
        #expect(record.layer > Int(CGWindowLevelForKey(.mainMenuWindow)))
        #expect(record.layer > Int(CGWindowLevelForKey(.dockWindow)))
        #expect(record.layer == panel.level.rawValue)

        panel.hide()
        #expect(waitForRecord(panel.windowNumber, present: false) == nil)
    }

    @Test func showDoesNotActivateTheApplicationOrBecomeKey() throws {
        let panel = OverlayPanel()
        panel.show(frame: try offScreenFrame())
        defer { panel.hide() }
        #expect(!panel.isKeyWindow)
        #expect(!panel.isMainWindow)
        #expect(panel.isVisible)
    }

    @Test func showAppliesTheRequestedFrame() throws {
        let panel = OverlayPanel()
        let frame = try offScreenFrame()
        panel.show(frame: frame)
        defer { panel.hide() }
        #expect(panel.frame == frame)
    }

    /// AppKit's default moves a window that sits below the menu bar's level, as the backdrop does, and pokes above a
    /// display's top edge down under the menu bar; every panel keeps the frame it was given. Asked of every real
    /// display directly, so nothing is ordered in.
    @Test(arguments: [OverlayPanel.Role.topmost, .backdrop])
    func aFrameCoveringTheMenuBarIsNotConstrained(role: OverlayPanel.Role) {
        let panel = OverlayPanel(role: role)
        for screen in NSScreen.screens {
            let acrossTheTopEdge = CGRect(x: screen.frame.minX + 40, y: screen.frame.maxY - 10, width: 120, height: 80)
            for frame in [screen.frame, acrossTheTopEdge] {
                #expect(panel.constrainFrameRect(frame, to: screen) == frame)
            }
        }
    }

    /// The same, end to end, as AppKit orders the panel in over a real display's menu bar, which no frame off every
    /// display can stand in for. This puts a clear panel over the whole main display, and tests never put windows
    /// on the visible screen, so it runs only when `STOOLS_TESTS_ON_SCREEN=1` is set.
    @Test(.enabled(if: onScreenTestsAllowed, "orders a panel onto the main display; set STOOLS_TESTS_ON_SCREEN=1"))
    func aPanelShownOverTheWholeMainDisplayIsNotConstrained() throws {
        let screen = try #require(NSScreen.main)
        let panel = OverlayPanel()
        panel.show(frame: screen.frame)
        defer { panel.hide() }
        #expect(panel.frame == screen.frame)
    }

    @Test func showingAgainMovesAndKeepsItVisible() throws {
        let panel = OverlayPanel()
        panel.show(frame: try offScreenFrame())
        let moved = try offScreenFrame(dx: 30, dy: 10)
        panel.show(frame: moved)
        defer { panel.hide() }
        #expect(panel.frame == moved)
        #expect(try #require(waitForRecord(panel.windowNumber)).isOnScreen)
    }

    /// What Screen Recording reads for its base layer (rule R5) and its display sources.
    @Test func recordingListsLeaveOutPanelsExcludedFromCapture() throws {
        let overlay = OverlayPanel()
        let hidden = OverlayPanel(isExcludedFromCapture: true)
        overlay.show(frame: try offScreenFrame())
        hidden.show(frame: try offScreenFrame(dx: 140))
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

    @Test func hidingTwiceIsHarmless() throws {
        let panel = OverlayPanel()
        panel.hide()
        panel.show(frame: try offScreenFrame())
        panel.hide()
        panel.hide()
        #expect(!panel.isVisible)
    }
}

/// Counts one notification's posts for one panel, `capturableVisibilityDidChange` by default. Posts arrive
/// synchronously on the main thread.
@MainActor
private final class VisibilityPosts {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init(for panel: OverlayPanel, name: Notification.Name = OverlayPanel.capturableVisibilityDidChange) {
        token = NotificationCenter.default.addObserver(
            forName: name, object: panel, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

/// Screen Recording's base layer refreshes on these posts (plan decision 1). Panels are ordered in only far off
/// every display.
@Suite(
    "OverlayPanel visibility posts",
    .serialized,
    .enabled(if: hasWindowServerDisplay)
)
@MainActor
struct OverlayPanelVisibilityPostTests {
    init() { prepareApplication() }

    @Test func showingTwicePostsOnceAndHidingPostsOnce() throws {
        let panel = OverlayPanel()
        let posts = VisibilityPosts(for: panel)
        defer { posts.stop(); panel.hide() }

        panel.show(frame: try offScreenFrame())
        #expect(posts.count == 1)
        panel.show(frame: try offScreenFrame(dx: 20))
        #expect(posts.count == 1)

        panel.hide()
        #expect(posts.count == 2)
        panel.hide()
        #expect(posts.count == 2)

        panel.show(frame: try offScreenFrame())
        #expect(posts.count == 3)
    }

    @Test func movesAndReordersPostNothing() throws {
        let panel = OverlayPanel()
        let other = OverlayPanel()
        let posts = VisibilityPosts(for: panel)
        defer { posts.stop(); panel.hide(); other.hide() }

        panel.show(frame: try offScreenFrame())
        other.show(frame: try offScreenFrame(dx: 140))
        #expect(posts.count == 1)
        panel.moveTo(frame: try offScreenFrame(dy: 30))
        panel.showBelow(frame: try offScreenFrame(dy: 30), windowNumber: other.windowNumber)
        panel.orderFrontRegardless()
        #expect(posts.count == 1)
    }

    @Test func closingAShownPanelPostsItsHiding() throws {
        let panel = OverlayPanel()
        let posts = VisibilityPosts(for: panel)
        defer { posts.stop() }
        panel.show(frame: try offScreenFrame())
        panel.close()
        #expect(posts.count == 2)
    }

    @Test func aPanelExcludedFromCaptureNeverPosts() throws {
        let panel = OverlayPanel(isExcludedFromCapture: true)
        let posts = VisibilityPosts(for: panel)
        defer { posts.stop(); panel.hide() }
        panel.show(frame: try offScreenFrame())
        panel.hide()
        #expect(posts.count == 0)
    }

    /// A whole-display source leaves out each one as it shows.
    @Test func aPanelExcludedFromCapturePostsOnlyItsShowing() throws {
        let panel = OverlayPanel(isExcludedFromCapture: true)
        let shows = VisibilityPosts(for: panel, name: OverlayPanel.excludedFromCaptureDidShow)
        defer { shows.stop(); panel.hide() }
        panel.show(frame: try offScreenFrame())
        panel.show(frame: try offScreenFrame(dx: 20))
        #expect(shows.count == 1)
        panel.hide()
        #expect(shows.count == 1)
        panel.show(frame: try offScreenFrame())
        #expect(shows.count == 2)
    }

    @Test func aCapturablePanelNeverPostsTheExcludedShowing() throws {
        let panel = OverlayPanel()
        let shows = VisibilityPosts(for: panel, name: OverlayPanel.excludedFromCaptureDidShow)
        defer { shows.stop(); panel.hide() }
        panel.show(frame: try offScreenFrame())
        panel.hide()
        #expect(shows.count == 0)
    }

    @Test func aBackdropPostsLikeAnOverlay() throws {
        let anchor = OverlayPanel()
        let backdrop = OverlayPanel(role: .backdrop)
        let posts = VisibilityPosts(for: backdrop)
        defer { posts.stop(); backdrop.hide(); anchor.hide() }
        anchor.show(frame: try offScreenFrame())
        backdrop.showBelow(frame: try offScreenFrame(), windowNumber: anchor.windowNumber)
        #expect(posts.count == 1)
        backdrop.hide()
        #expect(posts.count == 2)
    }
}
