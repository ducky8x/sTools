import CoreGraphics
import STPlatform

/// The crosshair as macOS's pointer, for Be the pointer in Minecraft's menus. The pointer is the overlay's own bitmap: at
/// the scale of the Crosshair's display, its image is the overlay's sprite pixel for pixel and its size in points is the
/// sprite's on that display, so it looks the same as the overlay there. The other scales are the same bitmap resampled:
/// blown up pixel by pixel, or smoothed down. The click point is the crosshair's center, or an image's anchor.
enum CrosshairPointerArt {
    /// The longest side a pointer is drawn at, in points; other cursor tools keep to it too. A bigger crosshair is scaled
    /// down to fit, so it no longer matches the overlay.
    static let largestSide: CGFloat = 128

    /// The pointer for `sprite`, the overlay's bitmap for a display with `displayScale` pixels to the point, clicking at
    /// `click`, in the sprite's pixels from its top-left corner.
    static func cursor(sprite: CrosshairSprite, click: CGPoint, displayScale: Int) -> CursorImage {
        let scale = max(1, displayScale)
        // Whole points: at 2× an odd-sized image gets a clear column on its right or row at its bottom.
        let padded = PixelSize(width: roundUp(sprite.size.width, to: scale), height: roundUp(sprite.size.height, to: scale))
        let points = CGSize(width: padded.width / scale, height: padded.height / scale)
        let fit = min(1, largestSide / max(points.width, points.height))
        let size = fit < 1
            ? CGSize(width: max(1, (points.width * fit).rounded()), height: max(1, (points.height * fit).rounded()))
            : points
        let hotSpot = CGPoint(x: click.x / CGFloat(scale) * size.width / points.width,
                              y: click.y / CGFloat(scale) * size.height / points.height)
        let images = CursorImage.scales.map { target in
            resampled(sprite.image, canvas: padded, to: PixelSize(width: Int(size.width) * target, height: Int(size.height) * target))
        }
        return CursorImage(size: size, hotSpot: hotSpot, images: images)
    }

    /// Where `sprite` clicks, in its pixels from the top-left corner: a shape's center (between two pixels for an even
    /// width), or for an image its anchor, the middle or a corner pixel's top-left corner.
    static func clickPoint(of sprite: CrosshairSprite, settings: CrosshairSettings, isImage: Bool) -> CGPoint {
        guard isImage else {
            let fraction = CrosshairShapeMath.centerFraction(shape: settings.shape, size: settings.size, thickness: settings.thickness)
            return CGPoint(x: Double(sprite.hot.x) + fraction, y: Double(sprite.hot.y) + fraction)
        }
        let (width, height) = (CGFloat(sprite.size.width), CGFloat(sprite.size.height))
        let (right, bottom) = (max(width - 1, 0), max(height - 1, 0))
        return switch settings.imageAnchor {
        case .center: CGPoint(x: width / 2, y: height / 2)
        case .topLeft: .zero
        case .topRight: CGPoint(x: right, y: 0)
        case .bottomLeft: CGPoint(x: 0, y: bottom)
        case .bottomRight: CGPoint(x: right, y: bottom)
        }
    }

    /// `image` placed at the top left of a `canvas` (its own size or a little bigger), drawn at `size`: copied pixel for
    /// pixel when that's the canvas's size, each pixel repeated when it's bigger, smoothed when it's smaller. Drawn in the
    /// renderer's device RGB so its pixels are copied as they are, then tagged sRGB, which the window server reads
    /// pointer images as.
    private static func resampled(_ image: CGImage, canvas: PixelSize, to size: PixelSize) -> CGImage {
        let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let scaleX = CGFloat(size.width) / CGFloat(canvas.width)
        let scaleY = CGFloat(size.height) / CGFloat(canvas.height)
        context.interpolationQuality = scaleX >= 1 && scaleY >= 1 ? .none : .high
        let width = CGFloat(image.width) * scaleX
        let height = CGFloat(image.height) * scaleY
        // Bottom-left origin: the image's top edge on the canvas's.
        context.draw(image, in: CGRect(x: 0, y: CGFloat(size.height) - height, width: width, height: height))
        let drawn = context.makeImage()!
        return drawn.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? drawn
    }

    private static func roundUp(_ value: Int, to unit: Int) -> Int {
        (max(value, 1) + unit - 1) / unit * unit
    }
}
