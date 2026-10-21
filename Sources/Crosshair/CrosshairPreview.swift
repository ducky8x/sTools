import SwiftUI
import STDesign

/// A small mock display showing the crosshair exactly as the overlay draws it, one sprite pixel on each
/// backing pixel of the screen the preview is on — unless it's too big to fit, in which case it's shrunk down
/// so the user can still see its whole shape — so the user can judge it without needing Minecraft open.
struct CrosshairPreview: View {
    let settings: CrosshairSettings
    let customImage: CGImage?

    @Environment(\.displayScale) private var displayScale

    /// The mock display, in points.
    private let mockFrame = CGRect(x: 0, y: 0, width: 320, height: 200)
    /// Empty space kept between the sprite and the mock box's own (rounded) edge, in points, so a sprite
    /// scaled to just barely fit never touches the rounded-corner clip.
    private let margin: CGFloat = 16

    var body: some View {
        let sprite: CrosshairSprite = {
            if settings.shape == .image, let customImage {
                return CrosshairRenderer.image(customImage, settings: settings)
            }
            return CrosshairRenderer.builtIn(settings: settings)
        }()
        // The mock display is measured in this screen's backing pixels, like a real display, so the sprite
        // keeps its true pixel size here too.
        let scale = max(1, displayScale.rounded())
        let mockDisplay = CrosshairGeometry.gridSize(frame: mockFrame, scale: scale)
        // `fittedOffset` only repositions the sprite — it keeps the *target* pixel on screen, but can't
        // make an oversized sprite smaller. A crosshair whose true pixel size exceeds this small mock box
        // (an easy thing to reach: size goes up to 200) would otherwise just overflow it and get clipped
        // by the box's rounded corners — the reported "cropped in the top-left and top-right" bug.
        let fitScale = CrosshairGeometry.fitScale(spriteSize: sprite.size, within: mockDisplay, margin: Int(margin * scale))

        // The user's offset is clamped to stay inside this small mock box (see `fittedOffset`), so a big
        // offset can never push the (now always-fitting) sprite's aim point off the box's edge.
        let fitted = CrosshairGeometry.fittedOffset(
            displaySize: mockDisplay, spriteSize: sprite.size, hotPixel: sprite.hot,
            offsetX: settings.offsetX, offsetY: settings.offsetY)
        // Placed by the same math as the real panel, with the mock box as its display, and drawn by the
        // overlay's own view, so the two can't drift apart.
        let placement = CrosshairGeometry.placement(
            displayFrame: mockFrame, scale: scale, spriteSize: sprite.size, hotPixel: sprite.hot,
            offsetX: fitted.x, offsetY: fitted.y)
        // Shrunk around the aim pixel (not the canvas's corner), so shrinking a big sprite to fit still keeps
        // its aim point exactly where the offset placed it.
        let aim = UnitPoint(
            x: (CGFloat(placement.spriteOrigin.x + sprite.hot.x) + 0.5) / CGFloat(placement.canvasSize.width),
            y: (CGFloat(placement.spriteOrigin.y + sprite.hot.y) + 0.5) / CGFloat(placement.canvasSize.height))

        // An overlay, not a ZStack: a canvas bigger than the box must not resize (and so re-center) it.
        STColor.raised
            .overlay(alignment: .topLeading) {
                CrosshairOverlayView(
                    image: sprite.image, spriteOrigin: placement.spriteOrigin, canvasSize: placement.canvasSize,
                    scale: scale)
                    .scaleEffect(fitScale, anchor: aim)
                    .offset(x: placement.windowFrame.minX - mockFrame.minX, y: mockFrame.maxY - placement.windowFrame.maxY)
            }
            .frame(width: mockFrame.width, height: mockFrame.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Crosshair preview")
    }
}
