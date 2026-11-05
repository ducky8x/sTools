import CoreGraphics
import Foundation
import Testing
@testable import Crosshair
@testable import STPlatform

/// The crosshair drawn as macOS's pointer: the overlay's sprite at the display's scale, the same size on screen, clicking
/// at its center or an image's anchor.
@Suite("Crosshair: the pointer's look")
struct CrosshairPointerArtTests {
    private func cursor(_ settings: CrosshairSettings, scale: Int) -> (CursorImage, CrosshairSprite) {
        let sprite = CrosshairRenderer.builtIn(settings: settings)
        let click = CrosshairPointerArt.clickPoint(of: sprite, settings: settings, isImage: false)
        return (CrosshairPointerArt.cursor(sprite: sprite, click: click, displayScale: scale), sprite)
    }

    /// At 1x the sprite's pixels are points, and the 1× image is the sprite itself.
    @Test func atOneXThePointerIsTheSprite() {
        let (cursor, sprite) = cursor(.defaultValue, scale: 1)
        #expect(cursor.size == CGSize(width: sprite.size.width, height: sprite.size.height))
        #expect(cursor.images.map(\.width) == [1, 2, 4].map { sprite.size.width * $0 })
        #expect(cursor.images.map(\.height) == [1, 2, 4].map { sprite.size.height * $0 })
        #expect(rawPixels(cursor.images[0]) == rawPixels(sprite.image))
    }

    /// At 2x the 2× image is the sprite itself, so the pointer is as big on screen as the overlay.
    @Test func atTwoXTheRetinaImageIsTheSprite() {
        let (cursor, sprite) = cursor(.defaultValue, scale: 2)
        #expect(sprite.size.width % 2 == 0, "a shape's canvas is always even")
        #expect(cursor.size == CGSize(width: sprite.size.width / 2, height: sprite.size.height / 2))
        #expect(cursor.images.map(\.width) == [1, 2, 4].map { sprite.size.width * $0 / 2 })
        #expect(rawPixels(cursor.images[1]) == rawPixels(sprite.image))
    }

    /// A bigger scale repeats each pixel, so the pointer keeps the crosshair's hard edges.
    @Test func aBiggerScaleRepeatsEachPixel() {
        let (cursor, sprite) = cursor(.defaultValue, scale: 1)
        let original = RGBABitmap(sprite.image)
        let doubled = RGBABitmap(cursor.images[1])
        for y in 0..<doubled.height {
            for x in 0..<doubled.width {
                #expect(doubled[x, y] == original[x / 2, y / 2], "(\(x), \(y))")
                if doubled[x, y] != original[x / 2, y / 2] { return }
            }
        }
    }

    /// It clicks at the crosshair's center: the middle of the hot pixel for an odd line, its far edge for an even one.
    @Test(arguments: [(3, 0.5), (4, 1.0)])
    func itClicksAtTheCenter(thickness: Int, fraction: Double) {
        var settings = CrosshairSettings.defaultValue
        settings.thickness = thickness
        for scale in [1, 2] {
            let (cursor, sprite) = cursor(settings, scale: scale)
            let center = CGPoint(x: Double(sprite.hot.x) + fraction, y: Double(sprite.hot.y) + fraction)
            #expect(cursor.hotSpot == CGPoint(x: center.x / CGFloat(scale), y: center.y / CGFloat(scale)))
        }
    }

    /// The gap and opacity are the overlay's too: the pointer is its finished sprite.
    @Test func itKeepsTheGapAndOpacity() {
        var settings = CrosshairSettings.defaultValue
        settings.gap = 4
        settings.opacityPercent = 50
        let (cursor, sprite) = cursor(settings, scale: 1)
        #expect(rawPixels(cursor.images[0]) == rawPixels(sprite.image))
        let center = RGBABitmap(cursor.images[0])[sprite.hot.x, sprite.hot.y]
        #expect(center.alpha == 0, "the gap leaves the middle clear")
    }

    // MARK: Images

    /// An image clicks at its anchor: its middle, or a corner pixel's top-left corner.
    @Test(arguments: [
        (CrosshairSettings.ImageAnchor.center, CGPoint(x: 4.5, y: 3.5)), (.topLeft, CGPoint(x: 0, y: 0)), (.topRight, CGPoint(x: 8, y: 0)),
        (.bottomLeft, CGPoint(x: 0, y: 6)), (.bottomRight, CGPoint(x: 8, y: 6)),
    ])
    func anImageClicksAtItsAnchor(anchor: CrosshairSettings.ImageAnchor, click: CGPoint) throws {
        var settings = CrosshairSettings.defaultValue
        settings.shape = .image
        settings.imageAnchor = anchor
        let sprite = CrosshairRenderer.image(testImage(), settings: settings)
        #expect(sprite.size == PixelSize(width: 9, height: 7))
        #expect(CrosshairPointerArt.clickPoint(of: sprite, settings: settings, isImage: true) == click)
        let cursor = CrosshairPointerArt.cursor(sprite: sprite, click: click, displayScale: 1)
        #expect(cursor.size == CGSize(width: 9, height: 7))
        #expect(cursor.hotSpot == click)
    }

    /// At 2x an odd-sized image gets a clear column and row, so the pointer is a whole number of points; the image keeps
    /// its pixels and its place.
    @Test func atTwoXAnOddImageIsPadded() {
        var settings = CrosshairSettings.defaultValue
        settings.shape = .image
        let sprite = CrosshairRenderer.image(testImage(), settings: settings)
        let click = CrosshairPointerArt.clickPoint(of: sprite, settings: settings, isImage: true)
        let cursor = CrosshairPointerArt.cursor(sprite: sprite, click: click, displayScale: 2)
        #expect(cursor.size == CGSize(width: 5, height: 4))
        #expect(cursor.hotSpot == CGPoint(x: 2.25, y: 1.75))
        let retina = RGBABitmap(cursor.images[1])
        let original = RGBABitmap(sprite.image)
        #expect(retina.width == 10 && retina.height == 8)
        #expect(retina[0, 0] == original[0, 0])
        #expect(retina[8, 6] == original[8, 6])
        #expect(retina[9, 3].alpha == 0 && retina[4, 7].alpha == 0, "the padding is clear")
    }

    /// A crosshair bigger than a pointer can be is scaled down to fit, still clicking at its center.
    @Test func aHugeCrosshairFits() {
        var settings = CrosshairSettings.defaultValue
        settings.size = 200
        settings.thickness = 9
        let (cursor, sprite) = cursor(settings, scale: 1)
        #expect(sprite.size.width > 256)
        #expect(cursor.size.width == CrosshairPointerArt.largestSide)
        #expect(cursor.images.map(\.width) == [128, 256, 512])
        #expect(abs(cursor.hotSpot.x - cursor.size.width / 2) < 1)
    }

    private func testImage() -> CGImage {
        let url = FileManager.default.temporaryDirectory.appending(path: "pointer-art-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        writeTestImage(to: url)
        return CrosshairImageImport.loadImage(at: url)!
    }
}

/// An image's bytes as premultiplied RGBA, read in its own color space so nothing is converted.
func rawPixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}
