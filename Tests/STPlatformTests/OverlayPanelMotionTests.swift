import AppKit
import Testing

@testable import STPlatform

/// Overlays never animate in or out on their own (spec 3.4): AppKit's window animations are off for every role, so
/// an overlay appears and leaves exactly when asked, with or without Reduce animations.
@Suite("OverlayPanel motion")
@MainActor
struct OverlayPanelMotionTests {
    init() { _ = NSApplication.shared }

    @Test(arguments: [OverlayPanel.Role.topmost, .backdrop])
    func appKitNeverAnimatesAnOverlay(role: OverlayPanel.Role) {
        #expect(OverlayPanel(role: role).animationBehavior == .none)
        #expect(OverlayPanel(role: role, isExcludedFromCapture: true).animationBehavior == .none)
    }

    @Test func movingNeverAnimates() {
        let panel = OverlayPanel()
        let frame = CGRect(x: -9000, y: -9000, width: 120, height: 80)
        panel.setFrame(frame, display: false)
        let moved = frame.offsetBy(dx: 40, dy: 20)
        panel.moveTo(frame: moved)
        #expect(panel.frame == moved, "the new frame is there at once")
    }
}
