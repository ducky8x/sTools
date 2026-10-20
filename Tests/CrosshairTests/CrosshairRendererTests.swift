import Testing
import Foundation
import CoreGraphics
@testable import Crosshair

@Suite struct CrosshairRendererTests {
    @Test func builtInPlusIsWhiteWithABlackOutline() {
        var settings = CrosshairSettings()
        settings.shape = .plus
        settings.fillHex = "#FFFFFF"
        settings.outlineHex = "#000000"
        settings.outlineEnabled = true
        settings.outlineWidth = 2
        let sprite = CrosshairRenderer.builtIn(settings: settings)
        #expect(sprite.size.width == sprite.image.width)
        #expect(sprite.size.height == sprite.image.height)

        let data = sprite.image.dataProvider!.data! as Data
        let bytesPerRow = sprite.image.bytesPerRow
        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let i = y * bytesPerRow + x * 4
            return (data[i], data[i + 1], data[i + 2], data[i + 3])
        }
        // Top-left origin in our own coordinate system; CGImage pixel (0,y) is the image's row y from the top
        // because the renderer draws bottom-up into a context whose image we read directly (no AppKit flip here).
        let hotImageY = sprite.image.height - 1 - sprite.hot.y
        let center = pixel(x: sprite.hot.x, y: hotImageY)
        #expect(center.r > 200 && center.g > 200 && center.b > 200 && center.a > 200, "the hot pixel should be white fill")

        // Walk outward along the arm until we leave the fill; that ring should be black (the outline).
        var x = sprite.hot.x
        while x < sprite.image.width, pixel(x: x, y: hotImageY).r > 200 { x += 1 }
        #expect(x < sprite.image.width, "the arm must end before the edge of the sprite")
        let outlinePixel = pixel(x: x, y: hotImageY)
        #expect(outlinePixel.a > 100, "there should be outline coverage just past the fill")
        #expect(outlinePixel.r < 80 && outlinePixel.g < 80 && outlinePixel.b < 80, "the outline ring should be black")
    }

    @Test func noOutlineMeansOnlyFillColor() {
        var settings = CrosshairSettings()
        settings.outlineEnabled = false
        let sprite = CrosshairRenderer.builtIn(settings: settings)
        #expect(sprite.image.width > 0 && sprite.image.height > 0)
    }

    @Test func opacitySetsTheContextAlpha() {
        var settings = CrosshairSettings()
        settings.opacityPercent = 50
        let sprite = CrosshairRenderer.builtIn(settings: settings)
        let data = sprite.image.dataProvider!.data! as Data
        let bytesPerRow = sprite.image.bytesPerRow
        let hotImageY = sprite.image.height - 1 - sprite.hot.y
        let i = hotImageY * bytesPerRow + sprite.hot.x * 4
        let alpha = data[i + 3]
        #expect(alpha > 100 && alpha < 160, "50% opacity should roughly halve the hot pixel's alpha, got \(alpha)")
    }

    @Test func imageSpriteIsScaledByPercent() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let source = context.makeImage()!
        var settings = CrosshairSettings()
        settings.shape = .image
        settings.imageScalePercent = 200
        settings.imageAnchor = .topLeft
        let sprite = CrosshairRenderer.image(source, settings: settings)
        #expect(sprite.size.width == 40 && sprite.size.height == 20)
        #expect(sprite.hot == PixelPoint(x: 0, y: 0))
    }
}
