import CoreGraphics

/// Where the NBB Overlay's plate sits (spec 5.1.5), as pure math that never touches a window.
///
/// The position is stored as points from the display's center to the plate's center, +x right and +y down. A plate
/// that would leave the display is kept inside it, but the stored offset is never rewritten for that, as for Timer
/// Overlay's (spec 5.6.5): on a wide display the same offset is the exact old spot again. The default, 750 points
/// right of center, fits a 1920-point display and not a MacBook's screen (1147, 1440 or 1512 points), where the plate
/// would be half or wholly off it, out of sight and out of reach of a drag.
enum NBBPlacement {
    /// The plate's frame for the stored offsets on `display` (AppKit global points), kept inside it.
    static func plateFrame(size: CGSize, offsetX: Int, offsetY: Int, on display: CGRect) -> CGRect {
        let origin = CGPoint(
            x: display.midX + CGFloat(offsetX) - size.width / 2,
            y: display.midY - CGFloat(offsetY) - size.height / 2)
        return kept(CGRect(origin: origin, size: size), inside: display)
    }

    /// `frame` moved the least to lie inside `bounds`; one larger than `bounds` keeps its top-left corner on it.
    static func kept(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        var origin = frame.origin
        origin.x = frame.width > bounds.width ? bounds.minX : min(max(origin.x, bounds.minX), bounds.maxX - frame.width)
        origin.y = frame.height > bounds.height
            ? bounds.maxY - frame.height
            : min(max(origin.y, bounds.minY), bounds.maxY - frame.height)
        return CGRect(origin: origin, size: frame.size)
    }
}
