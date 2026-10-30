import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Backdrop

/// The animation inside the real panel content: SwiftUI's crossfade view hosting the AppKit view that holds the player's
/// layer. The panel is made and sized but never ordered onto a screen.
@MainActor
@Suite("Animated fill in the panel's view", .serialized)
struct BackdropPanelHostingTests {
    private func mediaViews(in view: NSView) -> [BackdropMediaView] {
        var found: [BackdropMediaView] = []
        if let media = view as? BackdropMediaView { found.append(media) }
        for subview in view.subviews { found += mediaViews(in: subview) }
        return found
    }

    /// Lets SwiftUI build and lay out what the panel's hosting view holds.
    private func settle(_ panel: NSWindow) async {
        let end = SuspendingClock.now.advanced(by: .seconds(0.15))
        repeat {
            panel.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        } while SuspendingClock.now < end
    }

    @Test func thePanelHoldsTheAnimationsLayerFittedToTheDisplay() async throws {
        let rig = AnimatedRig()
        rig.animate("Images/loop.mp4", mode: .fit)
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let panel = try #require(rig.controller.existingPanel(for: displayOne.id))
        await settle(panel)
        let views = mediaViews(in: try #require(panel.contentView))
        #expect(views.count == 1)
        let player = rig.player
        let view = try #require(views.first)
        #expect(player.mediaLayer.superlayer === view.layer, "the player's layer is in the view")
        // 1920 x 1080 picture, 1920 x 1080 display: Fit covers it exactly.
        #expect(view.bounds.size == CGSize(width: 1920, height: 1080))
        #expect(player.mediaLayer.frame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test(arguments: BackdropSettings.ImageContentMode.allCases)
    func theFitModeReachesTheLayerThroughSwiftUI(mode: BackdropSettings.ImageContentMode) async throws {
        let rig = AnimatedRig()
        rig.animate("Images/loop.mp4", mode: .stretch)
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let panel = try #require(rig.controller.existingPanel(for: displayOne.id))
        await settle(panel)
        let player = rig.player
        player.learn(size: CGSize(width: 960, height: 1080))
        rig.controller.settings.fill.imageContentMode = mode
        await settle(panel)
        let views = mediaViews(in: try #require(panel.contentView))
        #expect(views.count == 1, "a change of fit alone keeps the one view")
        let expected = BackdropImageLayout.rect(
            imageSize: CGSize(width: 960, height: 1080), containerSize: CGSize(width: 1920, height: 1080), mode: mode)
        #expect(player.mediaLayer.frame == expected)
    }

    @Test func aNewFileGetsItsOwnViewWithTheNewPlayersLayer() async throws {
        let rig = AnimatedRig()
        rig.animate("Images/one.mp4")
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let panel = try #require(rig.controller.existingPanel(for: displayOne.id))
        await settle(panel)
        let first = rig.player
        rig.animate("Images/two.mp4")
        await settle(panel)
        let second = rig.player
        let views = mediaViews(in: try #require(panel.contentView))
        #expect(views.contains { second.mediaLayer.superlayer === $0.layer }, "the new fill is shown")
        // The old view may still be fading out; if it is, it holds the old player's layer, not the new one's.
        #expect(first.mediaLayer.superlayer !== second.mediaLayer.superlayer)
    }

    @Test func anAnimatedFillThatFailedDrawsNothingOfItsOwn() async throws {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let panel = try #require(rig.controller.existingPanel(for: displayOne.id))
        await settle(panel)
        rig.player.fail("no")
        await settle(panel)
        #expect(rig.player.mediaLayer.isHidden)
    }
}
