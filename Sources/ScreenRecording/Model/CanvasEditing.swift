import Foundation

/// The canvas editor's drag math (spec 5.4.3): which handle a press lands on, and what a drag does to a source's
/// frame or crop. Pure, so the editor view only translates points.
public enum CanvasEditing {
    public enum Handle: Equatable, Sendable {
        /// Inside the frame: moves it.
        case body
        /// A corner or an edge: resizes those edges.
        case resize(ResizeEdges)
        /// The same handles with ⌥ held: crops those edges.
        case crop(ResizeEdges)
    }

    public struct Result: Equatable, Sendable {
        /// The new frame, as fractions of the canvas (what the layout saves).
        public var frame: CanvasRect
        public var crop: CropInsets
        /// In canvas pixels.
        public var guides: [SnapGuide]
    }

    /// The handle under `point` of a frame (both in the same units, such as the editor's points): its corners and
    /// edge midpoints within `tolerance`, else its body when the point is inside. Nil when the press misses it.
    public static func handle(at point: (x: Double, y: Double), frame: PixelRect, tolerance: Double, cropping: Bool) -> Handle? {
        let xs: [(Double, ResizeEdges)] = [(frame.minX, .left), (frame.midX, []), (frame.maxX, .right)]
        let ys: [(Double, ResizeEdges)] = [(frame.minY, .top), (frame.midY, []), (frame.maxY, .bottom)]
        var best: (distance: Double, edges: ResizeEdges)?
        for (x, horizontal) in xs {
            for (y, vertical) in ys {
                let edges = horizontal.union(vertical)
                guard !edges.isEmpty else { continue }
                let distance = max(abs(point.x - x), abs(point.y - y))
                if distance <= tolerance, best == nil || distance < best!.distance { best = (distance, edges) }
            }
        }
        if let best { return cropping ? .crop(best.edges) : .resize(best.edges) }
        let inside = point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
        return inside ? .body : nil
    }

    /// The source after dragging `handle` by `delta` canvas pixels from where it was when the drag began. The math
    /// runs in pixels of `canvas` (the canvas in use now); the frame comes back as fractions of it.
    /// Moves and resizes snap (`SnapEngine`) within a distance relative to the canvas; crops follow the pointer
    /// across the content as it is drawn.
    public static func drag(
        _ handle: Handle, source: VideoSource, by delta: (dx: Double, dy: Double),
        canvas: PixelSize, others: [CanvasRect], contentSize: PixelSize?
    ) -> Result {
        let mapping = CanvasMapping(canvas)
        let frame = mapping.rect(source.frame)
        let others = others.map(mapping.rect)
        let threshold = SnapEngine.threshold(for: canvas)
        func fractions(_ rect: PixelRect) -> CanvasRect { mapping.canvasRect(LayoutMath.clamp(rect, to: canvas)).clamped() }
        switch handle {
        case .body:
            let moved = LayoutMath.clamp(frame.offsetBy(dx: delta.dx, dy: delta.dy), to: canvas)
            let snapped = SnapEngine.snapMove(moved, canvas: canvas, others: others, threshold: threshold)
            return Result(frame: fractions(snapped.frame), crop: source.crop, guides: snapped.guides)
        case .resize(let edges):
            var left = frame.minX, right = frame.maxX, top = frame.minY, bottom = frame.maxY
            if edges.contains(.left) { left += delta.dx }
            if edges.contains(.right) { right += delta.dx }
            if edges.contains(.top) { top += delta.dy }
            if edges.contains(.bottom) { bottom += delta.dy }
            let proposed = PixelRect(x: min(left, right), y: min(top, bottom), width: abs(right - left), height: abs(bottom - top))
            let snapped = SnapEngine.snapResize(proposed, edges: edges, canvas: canvas, others: others, threshold: threshold)
            return Result(frame: fractions(snapped.frame), crop: source.crop, guides: snapped.guides)
        case .crop(let edges):
            let size = contentSize ?? PixelSize(width: Int(frame.width), height: Int(frame.height))
            let shown = LayoutMath.contentRect(sourceSize: size, crop: source.crop, in: frame)
            let crop = source.crop
            // One canvas pixel across the drawn content is this fraction of the whole source.
            let perX = shown.width > 0 ? (1 - crop.left - crop.right) / shown.width : 0
            let perY = shown.height > 0 ? (1 - crop.top - crop.bottom) / shown.height : 0
            var next = crop
            if edges.contains(.left) { next.left += delta.dx * perX }
            if edges.contains(.right) { next.right -= delta.dx * perX }
            if edges.contains(.top) { next.top += delta.dy * perY }
            if edges.contains(.bottom) { next.bottom -= delta.dy * perY }
            return Result(frame: source.frame, crop: next.clamped(), guides: [])
        }
    }
}
