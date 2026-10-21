import SwiftUI

/// Hosts the finished crosshair bitmap at its exact pixel position inside the overlay panel, one sprite pixel
/// on each backing pixel of the display, never resampled.
struct CrosshairOverlayView: View {
    let image: CGImage
    let spriteOrigin: PixelPoint
    let canvasSize: PixelSize
    /// Backing pixels per point on the display the canvas is shown on. The canvas and the sprite are measured
    /// in pixels, but SwiftUI lays out in points: on a 2x display, a 34-pixel canvas is 17 points.
    let scale: CGFloat

    var body: some View {
        Canvas { context, _ in
            let rect = CGRect(
                x: CGFloat(spriteOrigin.x) / scale, y: CGFloat(spriteOrigin.y) / scale,
                width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            context.draw(Image(image, scale: 1, label: Text("")).interpolation(.none), in: rect)
        }
        .frame(width: CGFloat(canvasSize.width) / scale, height: CGFloat(canvasSize.height) / scale)
        .allowsHitTesting(false)
    }
}
