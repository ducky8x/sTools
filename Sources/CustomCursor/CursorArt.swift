import CoreGraphics
import Crosshair
import Foundation

/// The pointer as macOS takes it (spec 5.7.1): its size and click point in points, top-left origin, and one image per
/// scale, each the size in points times the scale in pixels.
public struct CursorImage: @unchecked Sendable {
    public var size: CGSize
    public var hotSpot: CGPoint
    /// 1×, 2× and 4× (`CursorArt.scales`), so the pointer stays sharp on a Retina display and under macOS's Pointer size.
    public var images: [CGImage]

    public init(size: CGSize, hotSpot: CGPoint, images: [CGImage]) {
        self.size = size
        self.hotSpot = hotSpot
        self.images = images
    }
}

/// Draws the pointer the settings describe. A shape comes from the Crosshair's renderer at each scale, its size in points
/// times the scale in pixels, so it's drawn sharp rather than blown up, and its middle lands on the click point at every
/// scale. An image is drawn from its own pixels at each scale.
public enum CursorArt {
    public static let scales = [1, 2, 4]
    /// The longest side a pointer is drawn at, in points. Other cursor tools keep to it too; a bigger image is scaled down
    /// to fit.
    public static let largestSide: CGFloat = 128

    /// The pointer, or nil for the Image shape with no image to draw.
    public static func cursor(for settings: CustomCursorSettings, image: CGImage?) -> CursorImage? {
        if settings.shape == .image {
            return image.map { cursor(from: $0, settings: settings) }
        }
        return shapeCursor(settings)
    }

    // MARK: Shapes

    private static func shapeCursor(_ settings: CustomCursorSettings) -> CursorImage {
        let margin = settings.outlineEnabled ? settings.outlineWidth : 0
        let reach = CrosshairShapes.reach(settings.shape, size: settings.size, thickness: settings.thickness)
        // The canvas holds the shape, its outline and a point of room on every side. An odd width centers on a pixel's
        // middle, so its canvas is odd too and the click point sits half a point in.
        let radius = Int((reach + Double(margin)).rounded(.up)) + 1
        let oddWidth = CrosshairShapes.centersOnAPixel(settings.shape, size: settings.size, thickness: settings.thickness)
        let side = 2 * radius + (oddWidth ? 1 : 0)
        let hot = CGFloat(side) / 2
        let images = scales.map { scale in
            let drawn = CrosshairShapes.draw(
                settings.shape, size: settings.size * scale, thickness: settings.thickness * scale, fillHex: settings.fillHex,
                outlineHex: settings.outlineEnabled ? settings.outlineHex : nil, outlineWidth: margin * scale)
            // Whole pixels at every scale: an odd width's middle is a pixel's middle at 1×, and at 2× and 4× every width
            // is even.
            let origin = CGPoint(x: (hot * CGFloat(scale) - drawn.center.x).rounded(),
                                 y: (hot * CGFloat(scale) - drawn.center.y).rounded())
            return canvas(width: side * scale, height: side * scale) { context, height in
                context.interpolationQuality = .none
                context.draw(drawn.image, in: CGRect(
                    x: origin.x, y: CGFloat(height) - origin.y - CGFloat(drawn.image.height),
                    width: CGFloat(drawn.image.width), height: CGFloat(drawn.image.height)))
            }
        }
        return CursorImage(size: CGSize(width: side, height: side), hotSpot: CGPoint(x: hot, y: hot), images: images)
    }

    // MARK: Images

    /// The image's pixels count as points at 100%, then the scale, then whatever fits inside `largestSide`.
    private static func cursor(from source: CGImage, settings: CustomCursorSettings) -> CursorImage {
        let scale = Double(settings.imageScalePercent) / 100
        var width = Double(source.width) * scale
        var height = Double(source.height) * scale
        let fit = min(1, Double(largestSide) / max(width, height))
        width = max(1, (width * fit).rounded())
        height = max(1, (height * fit).rounded())
        let size = CGSize(width: width, height: height)
        let images = scales.map { scale in
            canvas(width: Int(width) * scale, height: Int(height) * scale) { context, _ in
                context.interpolationQuality = .high
                context.draw(source, in: CGRect(x: 0, y: 0, width: Int(width) * scale, height: Int(height) * scale))
            }
        }
        return CursorImage(size: size, hotSpot: hotSpot(settings.clickPoint, size: size), images: images)
    }

    /// The point under the mouse: the image's middle, or a corner pixel's top-left corner, so a corner click point is
    /// always on the image.
    static func hotSpot(_ point: CustomCursorSettings.ClickPoint, size: CGSize) -> CGPoint {
        let right = max(size.width - 1, 0)
        let bottom = max(size.height - 1, 0)
        return switch point {
        case .center: CGPoint(x: size.width / 2, y: size.height / 2)
        case .topLeft: .zero
        case .topRight: CGPoint(x: right, y: 0)
        case .bottomLeft: CGPoint(x: 0, y: bottom)
        case .bottomRight: CGPoint(x: right, y: bottom)
        }
    }

    /// A clear canvas drawn by `draw`, in the Crosshair renderer's device RGB so its pixels are copied as they are, then
    /// tagged sRGB, which the window server reads cursor images as.
    private static func canvas(width: Int, height: Int, draw: (CGContext, Int) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context, height)
        let image = context.makeImage()!
        return image.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? image
    }
}
