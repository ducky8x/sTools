import CoreGraphics

/// A whole-number pixel position, origin at the top left.
struct PixelPoint: Equatable, Sendable {
    var x: Int
    var y: Int
}

struct PixelSize: Equatable, Sendable {
    var width: Int
    var height: Int
}

/// Pure pixel math for placing the crosshair (spec 5.3.3). Nothing here touches AppKit state.
///
/// Everything is measured on the display's backing pixel grid: the display frame in points times the
/// backing scale. The window server maps one backing pixel to one bitmap pixel, so a bitmap placed
/// on whole backing pixels is pixel-exact. The scale is assumed to be a whole number (1 or 2).
enum CrosshairGeometry {
    /// Where the window goes and how the sprite sits inside it.
    struct Placement: Equatable, Sendable {
        /// The panel frame in AppKit global coordinates (bottom-left origin), in points.
        var windowFrame: CGRect
        /// The window's bitmap size in pixels. Always a whole number of points.
        var canvasSize: PixelSize
        /// The sprite's top-left pixel inside the canvas.
        var spriteOrigin: PixelPoint
        /// The display pixel (top-left origin) that the sprite's hot pixel covers.
        var targetPixel: PixelPoint
    }

    static func gridSize(frame: CGRect, scale: CGFloat) -> PixelSize {
        PixelSize(width: Int((frame.width * scale).rounded()), height: Int((frame.height * scale).rounded()))
    }

    /// The index of the center pixel among `count` pixels. With an even count there is no center
    /// pixel, so `side` picks the one just right of (or below) the true center, or just left of (or above) it.
    static func centerIndex(count: Int, side: CrosshairSettings.CenterSide) -> Int {
        let count = max(count, 1)
        switch side {
        case .rightDown: return count / 2
        case .leftUp: return (count - 1) / 2
        }
    }

    /// The sprite pixel that lands on the target pixel.
    static func hotPixel(
        spriteSize: PixelSize, anchor: CrosshairSettings.ImageAnchor, side: CrosshairSettings.CenterSide
    ) -> PixelPoint {
        let right = max(spriteSize.width, 1) - 1
        let bottom = max(spriteSize.height, 1) - 1
        switch anchor {
        case .center:
            return PixelPoint(
                x: centerIndex(count: spriteSize.width, side: side),
                y: centerIndex(count: spriteSize.height, side: side))
        case .topLeft: return PixelPoint(x: 0, y: 0)
        case .topRight: return PixelPoint(x: right, y: 0)
        case .bottomLeft: return PixelPoint(x: 0, y: bottom)
        case .bottomRight: return PixelPoint(x: right, y: bottom)
        }
    }

    /// Places a sprite so that `hotPixel` covers the display's center pixel plus the offset (right and down
    /// are positive). The target is kept on the display.
    ///
    /// The window starts on a whole point and covers a whole number of points, so the sprite is padded
    /// inside a slightly larger canvas rather than the window sitting on a half point.
    static func placement(
        displayFrame: CGRect, scale: CGFloat, spriteSize: PixelSize, hotPixel: PixelPoint,
        offsetX: Int, offsetY: Int, side: CrosshairSettings.CenterSide
    ) -> Placement {
        let grid = gridSize(frame: displayFrame, scale: scale)
        let target = PixelPoint(
            x: (centerIndex(count: grid.width, side: side) + offsetX).clamped(to: 0...max(grid.width - 1, 0)),
            y: (centerIndex(count: grid.height, side: side) + offsetY).clamped(to: 0...max(grid.height - 1, 0)))
        let origin = PixelPoint(x: target.x - hotPixel.x, y: target.y - hotPixel.y)
        let unit = max(1, Int(scale.rounded()))
        let canvasLeft = floorMultiple(origin.x, of: unit)
        let canvasTop = floorMultiple(origin.y, of: unit)
        let spriteOrigin = PixelPoint(x: origin.x - canvasLeft, y: origin.y - canvasTop)
        let canvas = PixelSize(
            width: ceilMultiple(spriteOrigin.x + spriteSize.width, of: unit),
            height: ceilMultiple(spriteOrigin.y + spriteSize.height, of: unit))
        let frame = CGRect(
            x: displayFrame.minX + CGFloat(canvasLeft) / scale,
            y: displayFrame.maxY - CGFloat(canvasTop + canvas.height) / scale,
            width: CGFloat(canvas.width) / scale,
            height: CGFloat(canvas.height) / scale)
        return Placement(windowFrame: frame, canvasSize: canvas, spriteOrigin: spriteOrigin, targetPixel: target)
    }

    /// The scale (never above 1) needed to fit `spriteSize` inside `displaySize` with `margin` points of
    /// breathing room on every side, keeping the sprite's own aspect ratio. 1 when it already fits.
    ///
    /// `fittedOffset` below only repositions a sprite — it can't shrink one that's bigger than the space
    /// it's being placed into. A preview box fixed at a small size (built for showing a crosshair at its
    /// true pixel size) needs this too, or a large enough size setting just overflows the box and gets
    /// clipped by its edge.
    static func fitScale(spriteSize: PixelSize, within displaySize: PixelSize, margin: Int) -> Double {
        let maxWidth = max(1, displaySize.width - margin * 2)
        let maxHeight = max(1, displaySize.height - margin * 2)
        return min(1.0, Double(maxWidth) / Double(max(spriteSize.width, 1)), Double(maxHeight) / Double(max(spriteSize.height, 1)))
    }

    /// An offset adjusted so the sprite's full bounding box stays inside `displaySize`.
    ///
    /// `placement` only keeps the *target* (aim) pixel on the display, which is right for the real
    /// overlay: a sprite can bleed a little past a real screen's edge with nobody noticing. The
    /// settings-page mock preview is a tiny fixed box, though, so a size or offset that would be
    /// unremarkable on a real display can push most of the sprite past the mock box's edge, where
    /// `Canvas` clips it — a crosshair that looks cropped even though nothing is actually wrong with
    /// its shape. Call this before `placement` when placing into a bounded preview, not a real display.
    static func fittedOffset(
        displaySize: PixelSize, spriteSize: PixelSize, hotPixel: PixelPoint,
        offsetX: Int, offsetY: Int, side: CrosshairSettings.CenterSide
    ) -> (x: Int, y: Int) {
        let centerX = centerIndex(count: displaySize.width, side: side)
        let centerY = centerIndex(count: displaySize.height, side: side)
        let fittedTargetX = fittedTarget(wanted: centerX + offsetX, displayExtent: displaySize.width, hot: hotPixel.x, spriteExtent: spriteSize.width)
        let fittedTargetY = fittedTarget(wanted: centerY + offsetY, displayExtent: displaySize.height, hot: hotPixel.y, spriteExtent: spriteSize.height)
        return (fittedTargetX - centerX, fittedTargetY - centerY)
    }

    /// The closest target pixel to `wanted` whose sprite (of `spriteExtent`, `hot` pixels from its
    /// leading edge) fits entirely within `0..<displayExtent`. Falls back to centering the sprite (which
    /// still overhangs evenly on both sides) when it doesn't fit at all.
    private static func fittedTarget(wanted: Int, displayExtent: Int, hot: Int, spriteExtent: Int) -> Int {
        let minTarget = hot
        let maxTarget = displayExtent - (spriteExtent - hot)
        guard minTarget <= maxTarget else { return displayExtent / 2 }
        return wanted.clamped(to: minTarget...maxTarget)
    }

    /// Whether macOS is resampling this display (a "More Space" resolution): the mode's native pixel
    /// size differs from the frame's size times the backing scale.
    static func isScaledMode(frame: CGRect, backingScale: CGFloat, pixelSize: CGSize) -> Bool {
        abs(pixelSize.width - frame.width * backingScale) > 0.5 || abs(pixelSize.height - frame.height * backingScale) > 0.5
    }

    private static func floorMultiple(_ value: Int, of unit: Int) -> Int {
        let remainder = ((value % unit) + unit) % unit
        return value - remainder
    }

    private static func ceilMultiple(_ value: Int, of unit: Int) -> Int {
        (value + unit - 1) / unit * unit
    }
}
