import Testing
@testable import Crosshair

@Suite struct CrosshairShapeMathTests {
    @Test func plusCoversItsOwnArmsOnly() {
        #expect(CrosshairShapeMath.covers(shape: .plus, size: 10, thickness: 2, gap: 0, u: 0, v: 0))
        #expect(CrosshairShapeMath.covers(shape: .plus, size: 10, thickness: 2, gap: 0, u: 9, v: 0))
        #expect(!CrosshairShapeMath.covers(shape: .plus, size: 10, thickness: 2, gap: 0, u: 9, v: 9))
        // halfExtent is 11 (thickness/2 + gap + size), so u=11 is the last covered column; u=12 is just outside.
        #expect(!CrosshairShapeMath.covers(shape: .plus, size: 10, thickness: 2, gap: 0, u: 12, v: 0))
    }

    @Test func plusGapLeavesTheCenterEmpty() {
        #expect(!CrosshairShapeMath.covers(shape: .plus, size: 10, thickness: 2, gap: 4, u: 0, v: 0))
        #expect(!CrosshairShapeMath.covers(shape: .plus, size: 10, thickness: 2, gap: 4, u: 3, v: 0))
        #expect(CrosshairShapeMath.covers(shape: .plus, size: 10, thickness: 2, gap: 4, u: 6, v: 0))
    }

    @Test func dotIsFilledWithinItsRadius() {
        #expect(CrosshairShapeMath.covers(shape: .dot, size: 10, thickness: 2, gap: 0, u: 0, v: 0))
        #expect(CrosshairShapeMath.covers(shape: .dot, size: 10, thickness: 2, gap: 0, u: 4, v: 0))
        #expect(!CrosshairShapeMath.covers(shape: .dot, size: 10, thickness: 2, gap: 0, u: 6, v: 0))
    }

    @Test func circleIsHollow() {
        #expect(!CrosshairShapeMath.covers(shape: .circle, size: 10, thickness: 2, gap: 0, u: 0, v: 0))
        #expect(CrosshairShapeMath.covers(shape: .circle, size: 10, thickness: 2, gap: 0, u: 5, v: 0))
        #expect(!CrosshairShapeMath.covers(shape: .circle, size: 10, thickness: 2, gap: 0, u: 9, v: 0))
    }

    @Test func xCoversItsDiagonalsOnly() {
        #expect(CrosshairShapeMath.covers(shape: .x, size: 10, thickness: 2, gap: 0, u: 0, v: 0))
        #expect(!CrosshairShapeMath.covers(shape: .x, size: 10, thickness: 2, gap: 0, u: 6, v: 0))
        let diag = 5.0 / 2.0.squareRoot()
        #expect(CrosshairShapeMath.covers(shape: .x, size: 10, thickness: 2, gap: 0, u: diag, v: diag))
    }

    @Test(arguments: [
        (CrosshairSettings.Shape.plus, 11, CrosshairSettings.CenterSide.rightDown, 5),
        (.plus, 11, .leftUp, 5),
        (.plus, 10, .rightDown, 5),
        (.plus, 10, .leftUp, 4),
    ])
    func centerIndexHandlesOddAndEvenCounts(shape: CrosshairSettings.Shape, count: Int, side: CrosshairSettings.CenterSide, expected: Int) {
        #expect(CrosshairGeometry.centerIndex(count: count, side: side) == expected)
    }

    @Test func maskIsSquareAndCenteredOnTheHotPixel() {
        let mask = CrosshairShapeMath.mask(shape: .dot, size: 8, thickness: 1, gap: 0, side: .rightDown, margin: 2)
        #expect(mask.width == mask.height)
        #expect(mask.coverage(x: mask.hot.x, y: mask.hot.y) > 200)
        #expect(mask.coverage(x: 0, y: 0) == 0)
        #expect(mask.coverage(x: mask.width - 1, y: mask.height - 1) == 0)
    }

    @Test func maskIsSymmetricAboutTheHotPixel() {
        // Odd thickness centers the shape exactly on the hot pixel in both axes (centerFraction 0.5),
        // so reflecting any pixel through the hot pixel (2*hot - coordinate) must hit equal coverage.
        let mask = CrosshairShapeMath.mask(shape: .plus, size: 12, thickness: 3, gap: 2, side: .rightDown, margin: 3)
        var checked = 0
        for y in 0..<mask.height {
            let mirroredY = 2 * mask.hot.y - y
            guard mirroredY >= 0, mirroredY < mask.height else { continue }
            for x in 0..<mask.width {
                let mirroredX = 2 * mask.hot.x - x
                guard mirroredX >= 0, mirroredX < mask.width else { continue }
                #expect(mask.coverage(x: x, y: y) == mask.coverage(x: mirroredX, y: mirroredY))
                checked += 1
            }
        }
        #expect(checked > mask.width * mask.height / 2, "the reflected region should cover most of the mask")
    }

    @Test func dilationNeverShrinksCoverageAndGrowsByItsWidth() {
        let base = CrosshairShapeMath.mask(shape: .dot, size: 6, thickness: 1, gap: 0, side: .rightDown, margin: 6)
        let grown = CrosshairOutline.dilated(base, width: 2)
        for y in 0..<base.height {
            for x in 0..<base.width where base.coverage(x: x, y: y) > 0 {
                #expect(grown.coverage(x: x, y: y) == 255)
            }
        }
        // The dot's own edge (antialiased) sits around offset 2-3; dilating by 2 reaches to about offset 4.
        #expect(grown.coverage(x: base.hot.x + 4, y: base.hot.y) > 0)
        #expect(grown.coverage(x: base.hot.x + 6, y: base.hot.y) == 0)
        #expect(grown.coverage(x: base.hot.x + 1, y: base.hot.y) == 255)
    }

    @Test func dilationByZeroIsUnchanged() {
        let base = CrosshairShapeMath.mask(shape: .x, size: 8, thickness: 2, gap: 1, side: .leftUp, margin: 3)
        #expect(CrosshairOutline.dilated(base, width: 0) == base)
    }

    @Test(arguments: CrosshairSettings.Shape.allCases)
    func everyShapeProducesANonEmptyMaskExceptImage(shape: CrosshairSettings.Shape) {
        let mask = CrosshairShapeMath.mask(shape: shape, size: 10, thickness: 2, gap: 0, side: .rightDown, margin: 2)
        let total = mask.alpha.reduce(0) { $0 + Int($1) }
        if shape == .image {
            #expect(total == 0)
        } else {
            #expect(total > 0)
        }
    }
}
