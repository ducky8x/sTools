import CoreGraphics

/// Pure helpers for moving between Core Graphics and AppKit global coordinates.
public enum DisplayGeometry {
    /// The display whose bounds share the largest area with `frame` (Core Graphics coordinates).
    /// An exact tie goes to the earlier display; no overlap returns nil.
    public static func display(forCGFrame frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: DisplayInfo?
        var bestArea: CGFloat = 0
        for display in displays {
            let overlap = display.bounds.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                best = display
                bestArea = area
            }
        }
        return best
    }

    /// Converts a Core Graphics global rect (top-left origin) to AppKit global coordinates
    /// (bottom-left origin). `primaryScreenHeight` is the height of the display at the global origin.
    public static func convertToAppKit(cgRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: cgRect.minX,
            y: primaryScreenHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}
