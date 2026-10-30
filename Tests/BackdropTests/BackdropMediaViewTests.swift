import AppKit
import QuartzCore
import Testing
@testable import Backdrop

/// The view that holds an animated fill's layer, sized and placed by the fit mode, in a window that is never shown.
@MainActor
@Suite("Animated fill view")
struct BackdropMediaViewTests {
    private let picture = CGSize(width: 100, height: 50)

    private func view(for player: FakePlayer, mode: BackdropSettings.ImageContentMode, size: CGSize = CGSize(width: 200, height: 200)) -> BackdropMediaView {
        let view = BackdropMediaView(player: player, mode: mode)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test(arguments: BackdropSettings.ImageContentMode.allCases)
    func theLayerFollowsTheFitModeLikeAnImageDoes(mode: BackdropSettings.ImageContentMode) {
        let player = FakePlayer(naturalSize: picture)
        let view = view(for: player, mode: mode, size: CGSize(width: 300, height: 200))
        let expected = BackdropImageLayout.rect(imageSize: picture, containerSize: CGSize(width: 300, height: 200), mode: mode)
        #expect(player.mediaLayer.frame == expected)
        #expect(player.mediaLayer.superlayer === view.layer)
        #expect(!player.mediaLayer.isHidden)
    }

    @Test func theFourModesMeanWhatTheySayOnAKnownPicture() {
        // A 100 x 50 picture in a 200 x 200 view.
        func frame(_ mode: BackdropSettings.ImageContentMode) -> CGRect {
            let player = FakePlayer(naturalSize: picture)
            _ = view(for: player, mode: mode)
            return player.mediaLayer.frame
        }
        #expect(frame(.fit) == CGRect(x: 0, y: 50, width: 200, height: 100), "all of it, the view's width")
        #expect(frame(.fill) == CGRect(x: -100, y: 0, width: 400, height: 200), "covers the view, overflowing the sides")
        #expect(frame(.stretch) == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(frame(.center) == CGRect(x: 50, y: 75, width: 100, height: 50), "its own size, in the middle")
    }

    @Test func whatOverflowsTheViewIsClipped() {
        let player = FakePlayer(naturalSize: picture)
        let view = view(for: player, mode: .fill)
        #expect(view.layer?.masksToBounds == true)
    }

    @Test func nothingShowsUntilThePictureSizeIsKnownThenItDoes() {
        let player = FakePlayer()
        let view = view(for: player, mode: .fit)
        #expect(player.mediaLayer.isHidden)
        player.learn(size: picture)
        #expect(view.needsLayout, "learning the size lays the view out again")
        view.layoutSubtreeIfNeeded()
        #expect(!player.mediaLayer.isHidden)
        #expect(player.mediaLayer.frame == CGRect(x: 0, y: 50, width: 200, height: 100))
    }

    @Test func aFailedFileShowsNothingAtAll() {
        let player = FakePlayer(naturalSize: picture)
        let view = view(for: player, mode: .fit)
        player.fail("no")
        view.layoutSubtreeIfNeeded()
        #expect(player.mediaLayer.isHidden, "the fill falls back to its background color, the way a missing image does")
    }

    @Test func changingTheModeOrTheSizeLaysItOutAgain() {
        let player = FakePlayer(naturalSize: picture)
        let view = view(for: player, mode: .fit)
        view.mode = .stretch
        view.layoutSubtreeIfNeeded()
        #expect(player.mediaLayer.frame == CGRect(x: 0, y: 0, width: 200, height: 200))
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        view.layoutSubtreeIfNeeded()
        #expect(player.mediaLayer.frame == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func movingTheLayerNeverAnimatesIt() {
        let player = FakePlayer(naturalSize: picture)
        let view = view(for: player, mode: .fit)
        view.mode = .center
        view.layoutSubtreeIfNeeded()
        #expect(player.mediaLayer.animationKeys() == nil || player.mediaLayer.animationKeys()?.isEmpty == true)
    }
}
