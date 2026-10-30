import AppKit
import STPlatform

/// Plays an animation file the way the backdrop's panel does, for `Benchmarks/BackdropBench`: the same player, the same
/// view and the same fit, in a panel that is never ordered onto a screen, or, when asked, ordered in far outside every
/// display, where nothing is drawn. Nothing in the app uses it.
@MainActor
public final class BackdropBenchHost {
    private let player: any BackdropPlayer
    private let panel: OverlayPanel

    /// - Parameters:
    ///   - url: a GIF or a video.
    ///   - size: the view's size in points, a display's.
    ///   - orderedInFarOffScreen: also order the panel in, at coordinates no display reaches.
    public init(url: URL, size: CGSize, orderedInFarOffScreen: Bool = false) {
        player = BackdropAnimationFile.makePlayer(for: url, clock: DispatchFrameClock())
        let view = BackdropMediaView(player: player, mode: .fill)
        panel = OverlayPanel(role: .backdrop)
        panel.setFrame(CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height), display: false)
        panel.contentView = view
        view.layoutSubtreeIfNeeded()
        if orderedInFarOffScreen { panel.orderBack(nil) }
    }

    /// The picture's size in pixels, once the file has been opened.
    public var pictureSize: CGSize? { player.naturalSize }
    /// Why the file can't be played, once that's known.
    public var failure: String? { player.failure }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func stop() {
        player.stop()
        panel.orderOut(nil)
        panel.contentView = nil
    }
}
