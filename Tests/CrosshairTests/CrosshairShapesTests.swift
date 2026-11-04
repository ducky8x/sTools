import CoreGraphics
import Foundation
import Testing
@testable import Crosshair

/// The shapes another tool draws (`CrosshairShapes`) are the Crosshair's own: the same masks and renderer.
@Suite struct CrosshairShapesTests {
    @Test(arguments: CrosshairSettings.Shape.allCases.filter { $0 != .image })
    func aShapeHasTheCrosshairsOwnPixels(shape: CrosshairSettings.Shape) {
        var settings = CrosshairSettings()
        settings.shape = shape
        settings.size = 12
        settings.thickness = 3
        settings.fillHex = "#E4BC62"
        settings.outlineHex = "#101010"
        settings.outlineWidth = 2
        settings.offsetX = 0
        settings.offsetY = 0
        let sprite = CrosshairRenderer.builtIn(settings: settings)
        let drawn = CrosshairShapes.draw(shape, size: 12, thickness: 3, fillHex: "#E4BC62", outlineHex: "#101010", outlineWidth: 2)

        #expect(RGBABitmap(drawn.image).bytes == RGBABitmap(sprite.image).bytes)
    }

    /// The center is where the shape's middle falls: on a pixel's middle for an odd width, between two pixels for an even
    /// one, measured from the image's top-left corner.
    @Test func theCenterIsTheShapesMiddle() {
        let odd = CrosshairShapes.draw(.dot, size: 11, thickness: 3, fillHex: "#FFFFFF", outlineHex: nil, outlineWidth: 2)
        let even = CrosshairShapes.draw(.dot, size: 12, thickness: 3, fillHex: "#FFFFFF", outlineHex: nil, outlineWidth: 2)
        #expect(odd.center.x.truncatingRemainder(dividingBy: 1) == 0.5)
        #expect(even.center.x.truncatingRemainder(dividingBy: 1) == 0)
        let bitmap = RGBABitmap(even.image)
        let middle = Int(even.center.x)
        // A 12 px dot covers six whole pixels each side of its center.
        #expect(bitmap[middle - 6, middle - 1].alpha > 0)
        #expect(bitmap[middle + 5, middle - 1].alpha > 0)
        #expect(bitmap[middle - 7, middle - 1].alpha == 0)
        #expect(bitmap[middle + 6, middle - 1].alpha == 0)
    }

    @Test func withoutAnOutlineOnlyTheFillIsDrawn() {
        let drawn = CrosshairShapes.draw(.plus, size: 8, thickness: 2, fillHex: "#FFFFFF", outlineHex: nil, outlineWidth: 2)
        let bitmap = RGBABitmap(drawn.image)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap[x, y].alpha > 0 {
                #expect(bitmap[x, y].red == bitmap[x, y].alpha, "only white, at any coverage")
            }
        }
    }

    @Test func theReachAndWidthAreTheCrosshairs() {
        #expect(CrosshairShapes.reach(.plus, size: 12, thickness: 3) == 13.5)
        #expect(CrosshairShapes.reach(.dot, size: 12, thickness: 3) == 6)
        #expect(CrosshairShapes.centersOnAPixel(.plus, size: 12, thickness: 3))
        #expect(!CrosshairShapes.centersOnAPixel(.dot, size: 12, thickness: 3))
        #expect(CrosshairShapes.centersOnAPixel(.circle, size: 11, thickness: 2))
    }
}
