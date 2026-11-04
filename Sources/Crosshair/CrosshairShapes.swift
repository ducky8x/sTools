import CoreGraphics
import Foundation

/// The Crosshair's built-in shapes and image import, for another tool that draws the same shapes (Custom Cursor, spec
/// 5.7.3). The masks and the renderer are the Crosshair's own, so a shape looks the same wherever it's drawn. Sizes are in
/// pixels, as the Crosshair's are.
public enum CrosshairShapes {
    /// `shape` at full opacity, outline first and fill on top, with no gap, and where its center falls, in pixels from
    /// the image's top-left corner. `outlineHex` nil draws no outline.
    public static func draw(_ shape: CrosshairSettings.Shape, size: Int, thickness: Int, fillHex: String, outlineHex: String?,
                            outlineWidth: Int) -> (image: CGImage, center: CGPoint) {
        var settings = CrosshairSettings()
        settings.shape = shape
        settings.size = size
        settings.thickness = thickness
        settings.fillHex = fillHex
        settings.outlineEnabled = outlineHex != nil
        settings.outlineHex = outlineHex ?? settings.outlineHex
        settings.outlineWidth = outlineWidth
        settings.gap = 0
        settings.opacityPercent = 100
        let sprite = CrosshairRenderer.builtIn(settings: settings)
        let fraction = CrosshairShapeMath.centerFraction(shape: shape, size: size, thickness: thickness)
        return (sprite.image, CGPoint(x: Double(sprite.hot.x) + fraction, y: Double(sprite.hot.y) + fraction))
    }

    /// Pixels from the shape's center to the farthest point it covers, outline left out.
    public static func reach(_ shape: CrosshairSettings.Shape, size: Int, thickness: Int) -> Double {
        CrosshairShapeMath.halfExtent(shape: shape, size: size, thickness: thickness, gap: 0)
    }

    /// Whether the shape's middle falls on the middle of a pixel (an odd line or diameter) rather than between two pixels.
    public static func centersOnAPixel(_ shape: CrosshairSettings.Shape, size: Int, thickness: Int) -> Bool {
        CrosshairShapeMath.centeringLength(shape: shape, size: size, thickness: thickness) % 2 != 0
    }

    /// Copies `url` into `directory` under a fresh name, as the Crosshair's Choose image… does, and returns the stored
    /// name (`Images/<uuid>.<ext>`) or a sentence saying why it couldn't.
    public static func importImage(from url: URL, into directory: URL) -> Result<String, ImportError> {
        CrosshairImageImport.importImage(from: url, into: directory).mapError { ImportError(message: $0.message) }
    }

    /// Reads an image file, or nil if it isn't one.
    public static func loadImage(at url: URL) -> CGImage? {
        CrosshairImageImport.loadImage(at: url)
    }

    /// Why an image couldn't be imported, in a sentence for the page.
    public struct ImportError: Error, Equatable, Sendable {
        public let message: String
    }
}
