import CoreGraphics
import STPlatform

/// Where the plate sits (spec 5.6.5), as pure math that never touches a window.
///
/// The position is stored as an offset in points from the display's center to the plate's center, +x right and
/// +y down, the NBB Overlay's convention. The plate grows around that center, and frames are AppKit global points.
/// A plate that would leave the display is kept inside it, but the stored offset is never rewritten for that
/// (plan decision 2): on the owner's display the same offset is the exact old spot again.
///
/// Frames sit on the display's pixel grid, so the plate's text is never blurred by a half-pixel origin. The
/// offset and the frame convert both ways: `offset(of:on:)` gives back the offset a frame came from, so a dragged
/// plate settles exactly where its stored offset puts it next time.
public enum TimerPlacement {
    /// Points from the display's center to the plate's center: +x right, +y down.
    public struct Offset: Equatable, Hashable, Sendable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }

        /// The offset `settings` stores (`offsetX`, `offsetY`).
        public init(_ settings: TimerOverlaySettings) {
            self.init(x: settings.offsetX, y: settings.offsetY)
        }
    }

    /// Where a dragged plate comes to rest, and the offset that puts it there.
    public struct Settled: Equatable, Sendable {
        public let frame: CGRect
        public let offset: Offset
    }

    /// How close, in points, a dropped plate's edge or center must come to the display's to snap: the NBB Overlay's
    /// distance.
    public static let snapThreshold: CGFloat = 14

    // MARK: - The display

    /// The display the overlay goes on (spec 5.6.1, 5.6.7 Display): Minecraft's display while following it, the
    /// chosen display, and the main display when that one isn't connected or Minecraft isn't running. Nil only
    /// when no display is connected.
    public static func display(
        choice: TimerOverlaySettings.DisplayChoice, specificDisplayID: UInt32?, minecraftDisplayID: UInt32?,
        in displays: [DisplayInfo]
    ) -> DisplayInfo? {
        let wanted = choice == .followMinecraft ? minecraftDisplayID : specificDisplayID
        if let wanted, let display = displays.first(where: { $0.id == wanted }) { return display }
        return displays.first(where: \.isMain) ?? displays.first
    }

    /// `display(choice:specificDisplayID:minecraftDisplayID:in:)` with the choice the settings hold.
    public static func display(
        for settings: TimerOverlaySettings, minecraftDisplayID: UInt32?, in displays: [DisplayInfo]
    ) -> DisplayInfo? {
        display(choice: settings.displayChoice, specificDisplayID: settings.specificDisplayID,
                minecraftDisplayID: minecraftDisplayID, in: displays)
    }

    // MARK: - Offset to frame and back

    /// The plate's frame for `offset` on `display`: centered on the offset, its size rounded up to whole pixels and
    /// its origin down to whole pixels, then kept inside the display. A plate larger than the display keeps its
    /// top-left corner on it.
    public static func plateFrame(size: CGSize, offset: Offset, on display: DisplayInfo) -> CGRect {
        let grid = PixelGrid(display)
        let bounds = display.frame
        let width = grid.up(size.width)
        let height = grid.up(size.height)
        let center = CGPoint(x: bounds.midX + CGFloat(offset.x), y: bounds.midY - CGFloat(offset.y))
        let origin = CGPoint(x: grid.down(center.x - width / 2), y: grid.down(center.y - height / 2))
        return kept(CGRect(origin: origin, size: CGSize(width: width, height: height)), inside: bounds)
    }

    /// The offset `plateFrame(size:offset:on:)` turns into `frame`. Away from the edges it's the exact inverse; a frame
    /// touching an edge rounds toward that edge, so the plate placed from the offset is flush with it again.
    public static func offset(of frame: CGRect, on display: DisplayInfo) -> Offset {
        let bounds = display.frame
        let rawX = frame.midX - bounds.midX
        let rawY = bounds.midY - frame.midY
        // `plateFrame` rounds origins down, so a frame's center sits at most a pixel left of, and below, the exact
        // spot: x comes back up and y (measured downward) comes back down. At the left or bottom edge the rounding
        // flips, so the offset lands at or past the edge and keeping the plate inside brings it back flush.
        let x = frame.minX <= bounds.minX + epsilon ? (rawX + epsilon).rounded(.down) : (rawX - epsilon).rounded(.up)
        let y = frame.minY <= bounds.minY + epsilon ? (rawY - epsilon).rounded(.up) : (rawY + epsilon).rounded(.down)
        return Offset(x: Int(x), y: Int(y))
    }

    // MARK: - Dragging

    /// Where a plate dropped at `draggedFrame` comes to rest (spec 5.6.5): snapped to the display's edges and center
    /// when `snapping` is on and it's within `snapThreshold`, kept inside the display, and then exactly where the
    /// returned offset puts it, so storing the offset never moves the plate again.
    public static func settle(_ draggedFrame: CGRect, on display: DisplayInfo, snapping: Bool) -> Settled {
        var frame = draggedFrame
        if snapping { frame = PlacementSnapping.snapped(frame, in: display.frame, threshold: snapThreshold) }
        frame = kept(frame, inside: display.frame)
        let offset = offset(of: frame, on: display)
        return Settled(frame: plateFrame(size: draggedFrame.size, offset: offset, on: display), offset: offset)
    }

    // MARK: - Helpers

    /// Absorbs floating-point noise in values that are whole pixels.
    private static let epsilon: CGFloat = 1e-6

    /// `frame` moved the least to lie inside `bounds`; one larger than `bounds` keeps its top-left corner on it.
    private static func kept(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        var origin = frame.origin
        origin.x = frame.width > bounds.width ? bounds.minX : min(max(origin.x, bounds.minX), bounds.maxX - frame.width)
        origin.y = frame.height > bounds.height
            ? bounds.maxY - frame.height
            : min(max(origin.y, bounds.minY), bounds.maxY - frame.height)
        return CGRect(origin: origin, size: frame.size)
    }
}

/// Whole pixels of one display, in points.
private struct PixelGrid {
    let scale: CGFloat

    init(_ display: DisplayInfo) {
        scale = display.backingScale > 0 ? display.backingScale : 1
    }

    func down(_ value: CGFloat) -> CGFloat { (value * scale + 1e-6).rounded(.down) / scale }
    func up(_ value: CGFloat) -> CGFloat { (value * scale - 1e-6).rounded(.up) / scale }
}
