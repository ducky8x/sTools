import CoreGraphics

/// Pure placement-mode snapping math (spec 5.1.5 and 5.6.5, "Snapping"): pulls a dragged frame's edges and
/// center onto the display's edges and center when within `threshold`, independently per axis. Shared by the
/// overlays placed by dragging, the NBB Overlay and the Timer Overlay.
public enum PlacementSnapping {
    public static func snapped(_ frame: CGRect, in display: CGRect, threshold: CGFloat) -> CGRect {
        var origin = frame.origin
        origin.x = closest(origin.x, to: [display.minX, display.maxX - frame.width, display.midX - frame.width / 2], within: threshold)
        origin.y = closest(origin.y, to: [display.minY, display.maxY - frame.height, display.midY - frame.height / 2], within: threshold)
        return CGRect(origin: origin, size: frame.size)
    }

    private static func closest(_ value: CGFloat, to candidates: [CGFloat], within threshold: CGFloat) -> CGFloat {
        guard let best = candidates.min(by: { abs($0 - value) < abs($1 - value) }), abs(best - value) <= threshold else {
            return value
        }
        return best
    }
}
