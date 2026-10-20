import SwiftUI
import STDesign

/// A small mock display, with the crosshair drawn at its true pixel size — unless it's too big to fit,
/// in which case it's shrunk down so the user can still see its whole shape — so the user can judge it
/// without needing Minecraft open.
struct CrosshairPreview: View {
    let settings: CrosshairSettings
    let customImage: CGImage?

    private let mockDisplay = PixelSize(width: 320, height: 200)
    /// Empty space kept between the sprite and the mock box's own (rounded) edge, so a sprite scaled to
    /// just barely fit never touches the rounded-corner clip.
    private let margin = 16

    var body: some View {
        let sprite: CrosshairSprite = {
            if settings.shape == .image, let customImage {
                return CrosshairRenderer.image(customImage, settings: settings)
            }
            return CrosshairRenderer.builtIn(settings: settings)
        }()
        // `fittedOffset` only repositions the sprite — it keeps the *target* pixel on screen, but can't
        // make an oversized sprite smaller. A crosshair whose true pixel size exceeds this small mock box
        // (an easy thing to reach: size goes up to 200) would otherwise just overflow it and get clipped
        // by the box's rounded corners — the reported "cropped in the top-left and top-right" bug.
        let fitScale = CrosshairGeometry.fitScale(spriteSize: sprite.size, within: mockDisplay, margin: margin)

        // The user's offset is clamped to stay inside this small mock box (see `fittedOffset`), so a big
        // offset can never push the (now always-fitting) sprite's aim point off the box's edge.
        let fitted = CrosshairGeometry.fittedOffset(
            displaySize: mockDisplay, spriteSize: sprite.size, hotPixel: sprite.hot,
            offsetX: settings.offsetX, offsetY: settings.offsetY, side: settings.centerSide)
        // The target (aim) pixel, worked out directly in the mock box's own top-left-origin grid — the
        // same grid Canvas draws in. (The real overlay panel places itself the same direct way, via
        // `CrosshairOverlayView`'s `spriteOrigin`/`canvasSize`.) This mock box is never a real AppKit
        // window, so there's no reason to round-trip through `CrosshairGeometry.placement()`'s
        // bottom-left-origin window frame and flip it back — that detour was real but needless.
        let targetX = CrosshairGeometry.centerIndex(count: mockDisplay.width, side: settings.centerSide) + fitted.x
        let targetY = CrosshairGeometry.centerIndex(count: mockDisplay.height, side: settings.centerSide) + fitted.y

        ZStack {
            STColor.raised
            Canvas { context, size in
                let scale = size.width / CGFloat(mockDisplay.width) * fitScale
                // Scaled around the target point (not the sprite's top-left corner), so shrinking a big
                // sprite to fit still keeps its aim point exactly where the offset placed it.
                let targetScreen = CGPoint(
                    x: CGFloat(targetX) * size.width / CGFloat(mockDisplay.width),
                    y: CGFloat(targetY) * size.height / CGFloat(mockDisplay.height))
                let rect = CGRect(
                    x: targetScreen.x - CGFloat(sprite.hot.x) * scale, y: targetScreen.y - CGFloat(sprite.hot.y) * scale,
                    width: CGFloat(sprite.size.width) * scale, height: CGFloat(sprite.size.height) * scale)
                context.draw(Image(sprite.image, scale: 1, label: Text("")), in: rect)
            }
        }
        .frame(width: 320, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Crosshair preview")
    }
}
