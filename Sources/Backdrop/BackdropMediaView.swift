import AppKit
import QuartzCore
import SwiftUI

/// Holds an animated fill's layer and places it by the fit mode: the rect `BackdropImageLayout` works out for an image of
/// the same size, so the two fills fit alike, and what spills over the view's edge is clipped. It has no drawing or
/// events of its own; the player owns what plays, and whoever made the player starts and stops it.
@MainActor
final class BackdropMediaView: NSView {
    private let player: any BackdropPlayer

    var mode: BackdropSettings.ImageContentMode {
        didSet { if mode != oldValue { needsLayout = true } }
    }

    init(player: any BackdropPlayer, mode: BackdropSettings.ImageContentMode) {
        self.player = player
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(player.mediaLayer)
        player.observe { [weak self] in self?.needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("BackdropMediaView is made in code") }

    override func layout() {
        super.layout()
        // Placing the layer is never animated: Core Animation would slide it into place over a quarter of a second.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let size = player.naturalSize, player.failure == nil else {
            player.mediaLayer.isHidden = true
            return
        }
        player.mediaLayer.isHidden = false
        player.mediaLayer.frame = BackdropImageLayout.rect(imageSize: size, containerSize: bounds.size, mode: mode)
    }
}

/// An animated fill inside the SwiftUI backdrop view, so it crossfades in and out like any other fill.
struct BackdropAnimationHost: NSViewRepresentable {
    let player: any BackdropPlayer
    let mode: BackdropSettings.ImageContentMode

    func makeNSView(context: Context) -> BackdropMediaView {
        BackdropMediaView(player: player, mode: mode)
    }

    func updateNSView(_ view: BackdropMediaView, context: Context) {
        view.mode = mode
    }
}
