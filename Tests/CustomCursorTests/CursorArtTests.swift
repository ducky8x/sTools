import CoreGraphics
import Crosshair
import Foundation
import Testing
@testable import CustomCursor

/// The pointer as macOS gets it: one image per scale, 1×, 2× and 4×, each its point size times the scale, and the click
/// point in points (spec 5.7.1, 5.7.3).
@Suite("Custom Cursor: the pointer's images")
struct CursorArtTests {
    private func settings(_ shape: CustomCursorSettings.Shape, size: Int = 12, thickness: Int = 3, outline: Bool = true) -> CustomCursorSettings {
        var settings = CustomCursorSettings()
        settings.shape = shape
        settings.size = size
        settings.thickness = thickness
        settings.outlineEnabled = outline
        return settings
    }

    @Test func thereIsOneImagePerScale() throws {
        let cursor = try #require(CursorArt.cursor(for: CustomCursorSettings(), image: nil))
        #expect(CursorArt.scales == [1, 2, 4])
        #expect(cursor.images.count == 3)
        for (image, scale) in zip(cursor.images, CursorArt.scales) {
            #expect(image.width == Int(cursor.size.width) * scale)
            #expect(image.height == Int(cursor.size.height) * scale)
        }
    }

    /// The default, a 12 pt dot with a 2 pt outline: an even width, so its middle falls between two pixels and the click
    /// point is a whole point.
    @Test func theDefaultDotClicksAtItsCenter() throws {
        let cursor = try #require(CursorArt.cursor(for: CustomCursorSettings(), image: nil))
        #expect(cursor.size == CGSize(width: 18, height: 18))
        #expect(cursor.hotSpot == CGPoint(x: 9, y: 9))
    }

    /// An odd width has a middle pixel, so the click point is on its middle, half a point in.
    @Test func anOddWidthClicksOnItsMiddlePixel() throws {
        let dot = try #require(CursorArt.cursor(for: settings(.dot, size: 11), image: nil))
        #expect(dot.size == CGSize(width: 19, height: 19))
        #expect(dot.hotSpot == CGPoint(x: 9.5, y: 9.5))
        let plus = try #require(CursorArt.cursor(for: settings(.plus, size: 12, thickness: 3), image: nil))
        #expect(plus.size == CGSize(width: 35, height: 35))
        #expect(plus.hotSpot == CGPoint(x: 17.5, y: 17.5))
    }

    /// Every shape, odd and even, at every scale: what's drawn is centered on the click point, so the click lands on the
    /// shape's middle at any Pointer size and on any display.
    @Test(arguments: [CustomCursorSettings.Shape.plus, .dot, .circle, .x])
    func eachScaleIsCenteredOnTheClickPoint(shape: CustomCursorSettings.Shape) throws {
        for (size, thickness) in [(12, 3), (11, 2), (5, 1), (64, 16)] {
            let cursor = try #require(CursorArt.cursor(for: settings(shape, size: size, thickness: thickness), image: nil))
            for (image, scale) in zip(cursor.images, CursorArt.scales) {
                let bounds = try #require(Bitmap(image).drawnBounds, "\(shape) \(size) at \(scale)×")
                let middle = Int(cursor.hotSpot.x * CGFloat(scale) * 2)
                #expect(bounds.minX + bounds.maxX + 1 == middle, "\(shape) \(size)/\(thickness) at \(scale)×")
                #expect(bounds.minY + bounds.maxY + 1 == middle, "\(shape) \(size)/\(thickness) at \(scale)×")
                #expect(bounds.minX > 0 && bounds.maxX < image.width - 1, "room on every side")
            }
        }
    }

    /// At 1× the pointer is the Crosshair's own sprite, pixel for pixel, so a shape looks the same in both tools.
    @Test(arguments: [CustomCursorSettings.Shape.plus, .dot, .circle, .x])
    func atOneTimesItIsTheCrosshairsShape(shape: CustomCursorSettings.Shape) throws {
        var settings = settings(shape, size: 12, thickness: 3)
        settings.fillHex = "#E4BC62"
        let cursor = try #require(CursorArt.cursor(for: settings, image: nil))
        let drawn = CrosshairShapes.draw(shape, size: 12, thickness: 3, fillHex: "#E4BC62", outlineHex: "#000000", outlineWidth: 2)
        let sprite = Bitmap(drawn.image)
        let pointer = Bitmap(cursor.images[0])
        let originX = Int(cursor.hotSpot.x - drawn.center.x)
        let originY = Int(cursor.hotSpot.y - drawn.center.y)
        for y in 0..<pointer.height {
            for x in 0..<pointer.width {
                #expect(pointer[x, y] == sprite[x - originX, y - originY], "\(shape) at (\(x), \(y))")
            }
        }
    }

    /// The 2× and 4× images are drawn at that size, not blown up from 1×: a 12 pt dot covers 24 and 48 pixels across.
    @Test func largerScalesAreDrawnSharp() throws {
        let cursor = try #require(CursorArt.cursor(for: settings(.dot, size: 12, outline: false), image: nil))
        for (image, scale) in zip(cursor.images, CursorArt.scales) {
            let bounds = try #require(Bitmap(image).drawnBounds)
            #expect(bounds.maxX - bounds.minX + 1 == 12 * scale)
        }
    }

    @Test func theImagesAreTaggedSRGB() throws {
        let cursor = try #require(CursorArt.cursor(for: CustomCursorSettings(), image: nil))
        for image in cursor.images {
            #expect(image.colorSpace?.name == CGColorSpace.sRGB)
        }
    }

    // MARK: Images

    @Test func anImageIsItsPixelsInPointsTimesTheScale() throws {
        var settings = CustomCursorSettings()
        settings.shape = .image
        let source = makeImage(width: 20, height: 10)
        let cursor = try #require(CursorArt.cursor(for: settings, image: source))
        #expect(cursor.size == CGSize(width: 20, height: 10))
        #expect(cursor.images.map(\.width) == [20, 40, 80])
        #expect(cursor.images.map(\.height) == [10, 20, 40])
        settings.imageScalePercent = 250
        let bigger = try #require(CursorArt.cursor(for: settings, image: source))
        #expect(bigger.size == CGSize(width: 50, height: 25))
    }

    /// Each click point is the image's point under the mouse: its middle, or the top-left corner of a corner pixel.
    @Test func everyClickPointIsWhereTheImageClicks() throws {
        var settings = CustomCursorSettings()
        settings.shape = .image
        let source = makeImage(width: 20, height: 10)
        let expected: [CustomCursorSettings.ClickPoint: CGPoint] = [
            .center: CGPoint(x: 10, y: 5), .topLeft: .zero, .topRight: CGPoint(x: 19, y: 0),
            .bottomLeft: CGPoint(x: 0, y: 9), .bottomRight: CGPoint(x: 19, y: 9),
        ]
        for point in CustomCursorSettings.ClickPoint.allCases {
            settings.clickPoint = point
            let cursor = try #require(CursorArt.cursor(for: settings, image: source))
            #expect(cursor.hotSpot == expected[point], "\(point)")
        }
    }

    /// A shape always clicks at its center, whatever the image's click point says.
    @Test func aShapeIgnoresTheImagesClickPoint() throws {
        var settings = CustomCursorSettings()
        settings.clickPoint = .topLeft
        let cursor = try #require(CursorArt.cursor(for: settings, image: makeImage(width: 20, height: 10)))
        #expect(cursor.hotSpot == CGPoint(x: 9, y: 9))
    }

    /// A pointer bigger than 128 points on its longer side is scaled down to fit, keeping its shape.
    @Test func aHugeImageFitsInsideTheLargestPointer() throws {
        var settings = CustomCursorSettings()
        settings.shape = .image
        settings.imageScalePercent = 400
        let cursor = try #require(CursorArt.cursor(for: settings, image: makeImage(width: 200, height: 100)))
        #expect(cursor.size == CGSize(width: 128, height: 64))
        #expect(cursor.images.map(\.width) == [128, 256, 512])
    }

    @Test func theImageShapeWithoutAnImageDrawsNothing() {
        var settings = CustomCursorSettings()
        settings.shape = .image
        #expect(CursorArt.cursor(for: settings, image: nil) == nil)
    }
}

/// A `width` × `height` opaque red image.
func makeImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// An image's pixels as premultiplied RGBA bytes, top row first, read back without resampling or color matching.
struct Bitmap {
    struct Pixel: Equatable {
        var red, green, blue, alpha: UInt8
    }

    let width: Int
    let height: Int
    private var bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let (width, height) = (self.width, self.height)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The pixel at `(x, y)`, top-left origin; clear outside the image.
    subscript(x: Int, y: Int) -> Pixel {
        guard x >= 0, y >= 0, x < width, y < height else { return Pixel(red: 0, green: 0, blue: 0, alpha: 0) }
        let index = (y * width + x) * 4
        return Pixel(red: bytes[index], green: bytes[index + 1], blue: bytes[index + 2], alpha: bytes[index + 3])
    }

    /// The bounds of the pixels that aren't fully clear.
    var drawnBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<height {
            for x in 0..<width where self[x, y].alpha > 0 {
                bounds = (min(bounds?.minX ?? x, x), min(bounds?.minY ?? y, y), max(bounds?.maxX ?? x, x), max(bounds?.maxY ?? y, y))
            }
        }
        return bounds
    }
}
