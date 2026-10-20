import SwiftUI

/// Hosts the finished crosshair bitmap at its exact pixel position inside the overlay panel.
struct CrosshairOverlayView: View {
    let image: CGImage
    let spriteOrigin: PixelPoint
    let canvasSize: PixelSize

    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / CGFloat(canvasSize.width)
            let scaleY = size.height / CGFloat(canvasSize.height)
            let rect = CGRect(
                x: CGFloat(spriteOrigin.x) * scaleX, y: CGFloat(spriteOrigin.y) * scaleY,
                width: CGFloat(image.width) * scaleX, height: CGFloat(image.height) * scaleY)
            context.draw(Image(image, scale: 1, label: Text("")), in: rect)
        }
        .frame(width: CGFloat(canvasSize.width), height: CGFloat(canvasSize.height))
        .allowsHitTesting(false)
    }
}
