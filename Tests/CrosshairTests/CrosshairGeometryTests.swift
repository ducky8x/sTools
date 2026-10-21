import CoreGraphics
import Testing

@testable import Crosshair

@Suite("Crosshair geometry")
struct CrosshairGeometryTests {
    typealias Anchor = CrosshairSettings.ImageAnchor

    // MARK: center index

    // Minecraft centers its crosshair just left of (and above) the middle of an even width, so sTools does too.
    @Test(arguments: [(1, 0), (2, 0), (3, 1), (4, 1), (1920, 959), (1921, 960)])
    func centerIndexTakesThePixelLeftOfTheMiddleOnEvenCounts(count: Int, expected: Int) {
        #expect(CrosshairGeometry.centerIndex(count: count) == expected)
    }

    // MARK: anchors

    @Test func anchorsPickTheRightSpritePixel() {
        let size = PixelSize(width: 8, height: 6)
        #expect(CrosshairGeometry.hotPixel(spriteSize: size, anchor: .topLeft) == PixelPoint(x: 0, y: 0))
        #expect(CrosshairGeometry.hotPixel(spriteSize: size, anchor: .topRight) == PixelPoint(x: 7, y: 0))
        #expect(CrosshairGeometry.hotPixel(spriteSize: size, anchor: .bottomLeft) == PixelPoint(x: 0, y: 5))
        #expect(CrosshairGeometry.hotPixel(spriteSize: size, anchor: .bottomRight) == PixelPoint(x: 7, y: 5))
        #expect(CrosshairGeometry.hotPixel(spriteSize: size, anchor: .center) == PixelPoint(x: 3, y: 2))
        let odd = PixelSize(width: 7, height: 5)
        #expect(CrosshairGeometry.hotPixel(spriteSize: odd, anchor: .center) == PixelPoint(x: 3, y: 2))
    }

    // MARK: placement

    private func place(
        frame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: CGFloat = 1,
        sprite: PixelSize = PixelSize(width: 22, height: 22), anchor: Anchor = .center,
        offset: (Int, Int) = (0, 0)
    ) -> CrosshairGeometry.Placement {
        let hot = CrosshairGeometry.hotPixel(spriteSize: sprite, anchor: anchor)
        return CrosshairGeometry.placement(
            displayFrame: frame, scale: scale, spriteSize: sprite, hotPixel: hot,
            offsetX: offset.0, offsetY: offset.1)
    }

    @Test func evenSpriteOnEvenDisplayIsCenteredExactlyAtScaleOne() {
        let placement = place()
        #expect(placement.windowFrame == CGRect(x: 949, y: 529, width: 22, height: 22))
        #expect(placement.canvasSize == PixelSize(width: 22, height: 22))
        #expect(placement.spriteOrigin == PixelPoint(x: 0, y: 0))
    }

    @Test func oddSpriteOnEvenDisplayAimsJustLeftOfAndAboveTheMiddle() {
        let placement = place(sprite: PixelSize(width: 21, height: 21))
        #expect(placement.targetPixel == PixelPoint(x: 959, y: 539))
        #expect(placement.windowFrame == CGRect(x: 949, y: 530, width: 21, height: 21))
    }

    @Test func oddDisplayHasASingleCenterPixel() {
        let frame = CGRect(x: 0, y: 0, width: 1365, height: 767)
        let placement = place(frame: frame, sprite: PixelSize(width: 11, height: 11))
        #expect(placement.targetPixel == PixelPoint(x: 682, y: 383))
        #expect(placement.windowFrame == CGRect(x: 677, y: 767 - 383 - 6, width: 11, height: 11))
    }

    @Test func scaleTwoWorksInWholePointsByPaddingTheCanvas() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let placement = place(frame: frame, scale: 2, sprite: PixelSize(width: 21, height: 21))
        #expect(placement.targetPixel == PixelPoint(x: 1511, y: 981))
        // The sprite's top-left lands on display pixel (1501, 971); the window starts on a whole point, one
        // pixel earlier.
        #expect(placement.spriteOrigin == PixelPoint(x: 1, y: 1))
        #expect(placement.canvasSize == PixelSize(width: 22, height: 22))
        #expect(placement.windowFrame == CGRect(x: 750, y: 982 - 485 - 11, width: 11, height: 11))
    }

    @Test func scaleTwoOddOriginGetsLeadingPadding() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let placement = place(frame: frame, scale: 2, sprite: PixelSize(width: 20, height: 20))
        #expect(placement.targetPixel == PixelPoint(x: 1511, y: 981))
        // Origin = 1511 - 9 = 1502 (even), 981 - 9 = 972 (even): no padding.
        #expect(placement.spriteOrigin == PixelPoint(x: 0, y: 0))
        let shifted = place(frame: frame, scale: 2, sprite: PixelSize(width: 20, height: 20), offset: (1, 1))
        #expect(shifted.spriteOrigin == PixelPoint(x: 1, y: 1))
        #expect(shifted.canvasSize == PixelSize(width: 22, height: 22))
        #expect(shifted.windowFrame == CGRect(x: 751, y: 982 - 486 - 11, width: 11, height: 11))
    }

    @Test func spriteHotPixelAlwaysLandsOnTheTargetPixel() {
        let offsets = [(0, 0), (3, -2), (-7, 5), (-1, -1), (101, 0)]
        for scale in [CGFloat(1), CGFloat(2)] {
            for offset in offsets { checkHotPixel(scale: scale, offset: offset) }
        }
    }

    private func checkHotPixel(scale: CGFloat, offset: (Int, Int)) {
        let frame = CGRect(x: 100, y: 50, width: 1440, height: 900)
        let sprites = [PixelSize(width: 1, height: 1), PixelSize(width: 22, height: 22),
                       PixelSize(width: 21, height: 14), PixelSize(width: 33, height: 7)]
        for sprite in sprites {
            let placement = place(frame: frame, scale: scale, sprite: sprite, offset: offset)
            let hot = CrosshairGeometry.hotPixel(spriteSize: sprite, anchor: .center)
            let windowLeftPx = Int(((placement.windowFrame.minX - frame.minX) * scale).rounded())
            let windowTopPx = Int(((frame.maxY - placement.windowFrame.maxY) * scale).rounded())
            #expect(windowLeftPx + placement.spriteOrigin.x + hot.x == placement.targetPixel.x)
            #expect(windowTopPx + placement.spriteOrigin.y + hot.y == placement.targetPixel.y)
            #expect(placement.windowFrame.width * scale == CGFloat(placement.canvasSize.width))
            #expect(placement.canvasSize.width % Int(scale) == 0 && placement.canvasSize.height % Int(scale) == 0)
            #expect(placement.windowFrame.minX == placement.windowFrame.minX.rounded())
            #expect(placement.windowFrame.minY == placement.windowFrame.minY.rounded())
            #expect(placement.canvasSize.width >= placement.spriteOrigin.x + sprite.width)
            #expect(placement.spriteOrigin.x >= 0 && placement.spriteOrigin.x < Int(scale))
        }
    }

    // AppKit floors a window's origin to whole points, even on a 2x display. A display with an odd pixel count
    // at 2x has an edge on a half point, so the canvas reaches back to the whole point before the sprite
    // rather than to a multiple of two pixels from that edge.
    @Test(arguments: [CGRect(x: 0, y: 0, width: 1365.5, height: 767.5), CGRect(x: -1365.5, y: -767.5, width: 1365.5, height: 767.5)])
    func aDisplayEdgeOnAHalfPointStillGetsAPanelOnWholePoints(frame: CGRect) {
        for offset in [(0, 0), (-1, -1), (1, 2)] {
            let sprite = PixelSize(width: 17, height: 17)
            let placement = place(frame: frame, scale: 2, sprite: sprite, offset: offset)
            #expect(placement.targetPixel == PixelPoint(x: 1365 + offset.0, y: 767 + offset.1))
            #expect(placement.windowFrame.integral == placement.windowFrame)
            let windowLeftPx = Int(((placement.windowFrame.minX - frame.minX) * 2).rounded())
            let windowTopPx = Int(((frame.maxY - placement.windowFrame.maxY) * 2).rounded())
            #expect(windowLeftPx + placement.spriteOrigin.x + 8 == placement.targetPixel.x)
            #expect(windowTopPx + placement.spriteOrigin.y + 8 == placement.targetPixel.y)
            #expect(placement.spriteOrigin.x >= 0 && placement.spriteOrigin.x < 2)
            #expect(placement.spriteOrigin.y >= 0 && placement.spriteOrigin.y < 2)
            #expect(placement.canvasSize.width >= placement.spriteOrigin.x + sprite.width)
            #expect(placement.canvasSize.height >= placement.spriteOrigin.y + sprite.height)
        }
    }

    @Test func positiveOffsetsMoveRightAndDown() {
        let base = place()
        let moved = place(offset: (5, 7))
        #expect(moved.targetPixel == PixelPoint(x: base.targetPixel.x + 5, y: base.targetPixel.y + 7))
        #expect(moved.windowFrame.minX == base.windowFrame.minX + 5)
        #expect(moved.windowFrame.minY == base.windowFrame.minY - 7)
    }

    @Test func negativeOffsetsMoveLeftAndUp() {
        let base = place(scale: 2, offset: (0, 0))
        let moved = place(scale: 2, offset: (-10, -4))
        #expect(moved.targetPixel == PixelPoint(x: base.targetPixel.x - 10, y: base.targetPixel.y - 4))
        #expect(moved.windowFrame.minX == base.windowFrame.minX - 5)
        #expect(moved.windowFrame.minY == base.windowFrame.minY + 2)
    }

    @Test func offsetsAreClampedToTheDisplay() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let far = place(frame: frame, offset: (50_000, -50_000))
        #expect(far.targetPixel == PixelPoint(x: 1919, y: 0))
        let near = place(frame: frame, offset: (-50_000, 50_000))
        #expect(near.targetPixel == PixelPoint(x: 0, y: 1079))
    }

    @Test func secondaryDisplayFramesKeepTheirGlobalOrigin() {
        let frame = CGRect(x: -2560, y: 200, width: 2560, height: 1440)
        let placement = place(frame: frame, sprite: PixelSize(width: 20, height: 20))
        #expect(placement.windowFrame == CGRect(x: -2560 + 1270, y: 200 + 1440 - 730, width: 20, height: 20))
    }

    @Test(arguments: [Anchor.center, .topLeft, .topRight, .bottomLeft, .bottomRight])
    func imageAnchorPutsItsPointOnTheCenterPixel(anchor: Anchor) {
        let sprite = PixelSize(width: 40, height: 30)
        let placement = place(sprite: sprite, anchor: anchor)
        let hot = CrosshairGeometry.hotPixel(spriteSize: sprite, anchor: anchor)
        let windowLeft = Int(placement.windowFrame.minX)
        let windowTop = 1080 - Int(placement.windowFrame.maxY)
        #expect(windowLeft + hot.x == 959)
        #expect(windowTop + hot.y == 539)
    }

    @Test func gridSizeUsesTheBackingScale() {
        #expect(CrosshairGeometry.gridSize(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
            == PixelSize(width: 3024, height: 1964))
        #expect(CrosshairGeometry.gridSize(frame: CGRect(x: 0, y: 0, width: 1365.5, height: 700), scale: 2)
            == PixelSize(width: 2731, height: 1400))
    }

    @Test func oddPixelWidthAtScaleTwoHasACenterPixel() {
        let frame = CGRect(x: 0, y: 0, width: 1365.5, height: 700)
        let placement = place(frame: frame, scale: 2, sprite: PixelSize(width: 5, height: 5))
        #expect(placement.targetPixel == PixelPoint(x: 1365, y: 699))
    }

    // MARK: fitted offset (bounded preview box)

    @Test func fittedOffsetLeavesSmallOffsetsUntouched() {
        let fitted = CrosshairGeometry.fittedOffset(
            displaySize: PixelSize(width: 320, height: 200), spriteSize: PixelSize(width: 20, height: 20),
            hotPixel: PixelPoint(x: 10, y: 10), offsetX: 5, offsetY: -3)
        #expect(fitted == (5, -3))
    }

    @Test func fittedOffsetPullsTheSpriteBackInsideTheBox() {
        // Reported bug: size 60 (hot at its center, 30) with offset (150, 90) in a 320x200 mock box
        // pushed most of the sprite past the box's right/bottom edge, where Canvas clipped it.
        let displaySize = PixelSize(width: 320, height: 200)
        let sprite = PixelSize(width: 60, height: 60)
        let hot = PixelPoint(x: 30, y: 30)
        let fitted = CrosshairGeometry.fittedOffset(
            displaySize: displaySize, spriteSize: sprite, hotPixel: hot, offsetX: 150, offsetY: 90)
        let placement = CrosshairGeometry.placement(
            displayFrame: CGRect(x: 0, y: 0, width: displaySize.width, height: displaySize.height), scale: 1,
            spriteSize: sprite, hotPixel: hot, offsetX: fitted.x, offsetY: fitted.y)
        #expect(placement.windowFrame.minX >= 0)
        #expect(placement.windowFrame.minY >= 0)
        #expect(placement.windowFrame.maxX <= CGFloat(displaySize.width))
        #expect(placement.windowFrame.maxY <= CGFloat(displaySize.height))
    }

    @Test func fittedOffsetCentersASpriteThatCannotFit() {
        let displaySize = PixelSize(width: 320, height: 200)
        let sprite = PixelSize(width: 500, height: 500)
        let hot = PixelPoint(x: 250, y: 250)
        let fitted = CrosshairGeometry.fittedOffset(
            displaySize: displaySize, spriteSize: sprite, hotPixel: hot, offsetX: 1000, offsetY: -1000)
        #expect(fitted == (320 / 2 - CrosshairGeometry.centerIndex(count: 320),
                           200 / 2 - CrosshairGeometry.centerIndex(count: 200)))
    }

    // MARK: fit scale (bounded preview box)

    @Test func fitScaleIsOneWhenTheSpriteAlreadyFitsWithMargin() {
        let scale = CrosshairGeometry.fitScale(
            spriteSize: PixelSize(width: 60, height: 60), within: PixelSize(width: 320, height: 200), margin: 16)
        #expect(scale == 1.0)
    }

    @Test func fitScaleShrinksASpriteWiderThanTheBox() {
        // Regression: a size-180 X sprite (reach past 300pt wide) used to overflow this 320x200 mock
        // box and get clipped by its rounded corners — "cropped in the top-left and top-right."
        let spriteSize = PixelSize(width: 400, height: 400)
        let displaySize = PixelSize(width: 320, height: 200)
        let scale = CrosshairGeometry.fitScale(spriteSize: spriteSize, within: displaySize, margin: 16)
        #expect(scale < 1.0)
        #expect(Double(spriteSize.width) * scale <= Double(displaySize.width - 16 * 2) + 0.001)
        #expect(Double(spriteSize.height) * scale <= Double(displaySize.height - 16 * 2) + 0.001)
    }

    @Test func fitScalePicksTheTighterDimension() {
        // Taller than it is wide, relative to a wide-but-short box: height is the binding constraint.
        let scale = CrosshairGeometry.fitScale(
            spriteSize: PixelSize(width: 100, height: 300), within: PixelSize(width: 320, height: 200), margin: 16)
        #expect(abs(scale - Double(200 - 32) / 300) < 0.0001)
    }

    // MARK: scaled modes

    @Test func scaledModesAreRecognizedFromThePixelRatio() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(!CrosshairGeometry.isScaledMode(frame: frame, backingScale: 2, pixelSize: CGSize(width: 2880, height: 1800)))
        #expect(CrosshairGeometry.isScaledMode(frame: frame, backingScale: 2, pixelSize: CGSize(width: 2560, height: 1600)))
        #expect(!CrosshairGeometry.isScaledMode(frame: frame, backingScale: 1, pixelSize: CGSize(width: 1440, height: 900)))
        #expect(CrosshairGeometry.isScaledMode(frame: frame, backingScale: 1, pixelSize: CGSize(width: 1920, height: 1200)))
    }
}
